#if os(macOS)
import Foundation
import HephCore

/// Implemented by HostService (services/host.md).
public protocol SkillsHost: Sendable {
    func appSupport() async -> AppSupport
    /// Sends skills.changed {skills} to every authenticated connection (EventHub.broadcast).
    func broadcastSkillsChanged(_ skills: [SkillSummary]) async
    /// A request over this Main's outgoing peer link to another Main (MeshService.requestPeer); JSON params and
    /// result. Failures throw ProtocolError.
    func requestPeer(_ deviceID: UUID, method: String, params: Data) async throws -> Data
}

/// The skills library of this Main, `Skills/` in Application Support (docs/claude/skills.md): the `skills.*` methods,
/// the session plugin folders (SkillPluginFolder.swift) and the sync between Mains (SkillsSync.swift). Errors thrown
/// are `ProtocolError` values.
public actor SkillsService: HostMethodHandler {
    let host: any SkillsHost
    /// Set by `start()`.
    var appSupport: AppSupport?
    /// The `skills.changed` broadcasts, sent in order by `broadcaster`.
    var broadcasts: AsyncStream<[SkillSummary]>.Continuation?
    var broadcaster: Task<Void, Never>?
    /// The pulls requested and not finished; they run one at a time (SkillsSync.swift).
    var pulls: [UUID: Task<Void, Never>] = [:]
    var lastPull: Task<Void, Never>?

    static let invalidName = "Skill names use lowercase letters, digits and hyphens (1 to 64 characters)."
    static let skillFileName = "SKILL.md"
    static let skillFileKept = "SKILL.md cannot be deleted. Delete the skill instead."

    public init(host: any SkillsHost) {
        self.host = host
    }

    // MARK: - Host lifecycle (services/host.md §3)

    /// Creates Skills/ when missing, empties SessionPlugins/, scans.
    public func start() async {
        let appSupport = await host.appSupport()
        self.appSupport = appSupport
        if broadcaster == nil {
            let (stream, continuation) = AsyncStream.makeStream(of: [SkillSummary].self, bufferingPolicy: .unbounded)
            broadcasts = continuation
            let host = self.host
            broadcaster = Task {
                for await skills in stream {
                    await host.broadcastSkillsChanged(skills)
                }
            }
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: appSupport.skillsFolder, withIntermediateDirectories: true)
        } catch {
            Log.host.error("Could not create the skills folder: \(error.localizedDescription)")
        }
        // No session process exists yet: every session plugin folder is left over from an earlier run.
        let plugins = appSupport.sessionPluginsFolder
        for name in (try? fileManager.contentsOfDirectory(atPath: plugins.path)) ?? [] {
            do {
                try fileManager.removeItem(at: plugins.appendingPathComponent(name))
            } catch {
                Log.host.error("Could not remove a session plugin folder: \(error.localizedDescription)")
            }
        }
        _ = scan()
    }

    /// Cancels pulls in progress.
    public func stop() async {
        for pull in pulls.values {
            pull.cancel()
        }
        pulls.removeAll()
        lastPull = nil
        broadcasts?.finish()
        broadcasts = nil
        broadcaster = nil
    }

    // MARK: - skills.* methods

    public func list() throws -> [SkillSummary] {
        _ = try library()
        let index = scan()
        return try summaries(index)
    }

    public func create(name: String, description: String) throws -> SkillSummary {
        let skills = try skillsFolder()
        try Self.checkName(name)
        let oneLine = String(description.map { $0.isNewline ? " " : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...1_024).contains(oneLine.count) else {
            throw ProtocolError(.badRequest, "The description must have 1 to 1024 characters.")
        }
        let folder = skills.appendingPathComponent(name, isDirectory: true)
        guard !Self.exists(folder) else {
            throw ProtocolError(.conflict, "Skill \(name) already exists.")
        }
        do {
            try AtomicFile.write(Data(SkillFrontMatter.template(name: name, description: oneLine).utf8),
                                 to: folder.appendingPathComponent(Self.skillFileName, isDirectory: false))
        } catch {
            throw Self.protocolError(error)
        }
        Log.host.info("Created the skill \(name, privacy: .public)")
        let index = commit([(name, false)])
        return try summary(name, index: index)
    }

    public func files(name: String) throws -> [SkillFile] {
        let folder = try existingSkill(name)
        let root = URL(fileURLWithPath: ClaudePathEncoding.canonicalPath(folder.path) ?? folder.path, isDirectory: true)
        return SkillsIndex.regularFiles(in: root)
            .filter { ($0.path as NSString).lastPathComponent != ".DS_Store" }
            .sorted { $0.path < $1.path }
            .map { SkillFile(path: $0.path, size: $0.size, modified: $0.modified) }
    }

    public func readFile(name: String, path: String) throws -> Data {
        let folder = try existingSkill(name)
        let url = try Self.resolve(path, in: folder, followLast: true)
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ProtocolError(.notFound, "No file at \(path).")
        }
        guard Int(info.st_size) <= MethodLimits.maxFileSize else {
            throw ProtocolError(.tooLarge, "\(path) is larger than 10 MiB.")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ProtocolError(.internal, "\(path): \(error.localizedDescription)")
        }
    }

    public func writeFile(name: String, path: String, data: Data) throws {
        let folder = try existingSkill(name)
        let url = try Self.resolve(path, in: folder, followLast: true)
        guard data.count <= MethodLimits.maxFileSize else {
            throw ProtocolError(.tooLarge, "The content is larger than 10 MiB.")
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw ProtocolError(.badRequest, "\(path) is a folder.")
        }
        do {
            try AtomicFile.write(data, to: url)
        } catch {
            throw Self.protocolError(error)
        }
        commit([(name, false)])
    }

    public func deleteFile(name: String, path: String) throws {
        let folder = try existingSkill(name)
        _ = try Self.components(path)
        guard path != Self.skillFileName else {
            throw ProtocolError(.badRequest, Self.skillFileKept)
        }
        let url = try Self.resolve(path, in: folder, followLast: false)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR else {
            throw ProtocolError(.notFound, "No file at \(path).")
        }
        // The skill's SKILL.md itself under another path (another case, a folder link, a hard link): same device and
        // inode, the last component not followed.
        var skillFile = stat()
        if lstat(folder.appendingPathComponent(Self.skillFileName, isDirectory: false).path, &skillFile) == 0,
           skillFile.st_dev == info.st_dev, skillFile.st_ino == info.st_ino {
            throw ProtocolError(.badRequest, Self.skillFileKept)
        }
        let appSupport = try library()
        do {
            try appSupport.trashItem(url)
        } catch {
            throw ProtocolError(.internal, "\(path): \(error.localizedDescription)")
        }
        commit([(name, false)])
    }

    public func rename(name: String, newName: String) throws -> SkillSummary {
        let skills = try skillsFolder()
        try Self.checkName(newName)
        let folder = try existingSkill(name)
        let destination = skills.appendingPathComponent(newName, isDirectory: true)
        guard !Self.exists(destination) else {
            throw ProtocolError(.conflict, "Skill \(newName) already exists.")
        }
        do {
            try FileManager.default.moveItem(at: folder, to: destination)
        } catch {
            throw ProtocolError(.internal, "\(name): \(error.localizedDescription)")
        }
        // The front matter's name; a SKILL.md without a parseable front matter is left unchanged.
        let skillFile = destination.appendingPathComponent(Self.skillFileName, isDirectory: false)
        if let data = try? Data(contentsOf: skillFile), let content = String(data: data, encoding: .utf8),
           let renamed = SkillFrontMatter.renamed(content, to: newName) {
            do {
                try AtomicFile.write(Data(renamed.utf8), to: skillFile)
            } catch {
                Log.host.error("Could not rewrite the name of the skill \(newName, privacy: .public): \((error as? DataError)?.message ?? error.localizedDescription)")
            }
        }
        Log.host.info("Renamed the skill \(name, privacy: .public) to \(newName, privacy: .public)")
        let index = commit([(name, true), (newName, false)])
        return try summary(newName, index: index)
    }

    public func delete(name: String) throws {
        let folder = try existingSkill(name)
        let appSupport = try library()
        do {
            try appSupport.trashItem(folder)
        } catch {
            throw ProtocolError(.internal, "\(name): \(error.localizedDescription)")
        }
        Log.host.info("Deleted the skill \(name, privacy: .public)")
        commit([(name, true)])
    }

    public func manifest() throws -> [SkillManifest] {
        _ = try library()
        let index = scan()
        return index.entries
            .map { SkillManifest(name: $0.key, modified: $0.value.modified, deleted: $0.value.deleted) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - HostMethodHandler

    public func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .skillsList:
                _ = try Self.decode(EmptyPayload.self, params, method)
                return try WireCoding.encodeJSON(SkillsListResult(skills: try list()))
            case .skillsCreate:
                let request = try Self.decode(SkillsCreateParams.self, params, method)
                return try WireCoding.encodeJSON(try create(name: request.name, description: request.description))
            case .skillsFiles:
                let request = try Self.decode(SkillsFilesParams.self, params, method)
                return try WireCoding.encodeJSON(SkillsFilesResult(files: try files(name: request.name)))
            case .skillsReadFile:
                let request = try Self.decode(SkillsReadFileParams.self, params, method)
                return try WireCoding.encodeJSON(SkillsReadFileResult(data: try readFile(name: request.name,
                                                                                          path: request.path)))
            case .skillsWriteFile:
                let request = try Self.decode(SkillsWriteFileParams.self, params, method)
                try writeFile(name: request.name, path: request.path, data: request.data)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .skillsDeleteFile:
                let request = try Self.decode(SkillsDeleteFileParams.self, params, method)
                try deleteFile(name: request.name, path: request.path)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .skillsRename:
                let request = try Self.decode(SkillsRenameParams.self, params, method)
                return try WireCoding.encodeJSON(try rename(name: request.name, newName: request.newName))
            case .skillsDelete:
                let request = try Self.decode(SkillsDeleteParams.self, params, method)
                try delete(name: request.name)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .skillsManifest:
                _ = try Self.decode(EmptyPayload.self, params, method)
                return try WireCoding.encodeJSON(SkillsManifestResult(skills: try manifest()))
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw Self.protocolError(error)
        }
    }

    // MARK: - Index

    /// §7.2: loads the index, applies the scan; when it changed, writes it and broadcasts skills.changed.
    @discardableResult
    func scan() -> SkillsIndex {
        guard let appSupport else { return SkillsIndex() }
        var index = SkillsIndex.load(from: indexURL(appSupport))
        if index.scan(skillsFolder: appSupport.skillsFolder, now: Date()) {
            save(index, appSupport)
            broadcast(index)
        }
        return index
    }

    /// After a change made through skills.*: each entry's `modified` becomes the later of now and the skill's file
    /// date L, taken after the change (a tombstone for a deleted name); the index is written and skills.changed
    /// broadcast. Returns the index as written.
    @discardableResult
    func commit(_ changes: [(name: String, deleted: Bool)]) -> SkillsIndex {
        guard let appSupport else { return SkillsIndex() }
        var index = SkillsIndex.load(from: indexURL(appSupport))
        let now = Date()
        _ = index.scan(skillsFolder: appSupport.skillsFolder, now: now)
        for change in changes {
            let latest = SkillsIndex.latestModification(
                of: appSupport.skillsFolder.appendingPathComponent(change.name, isDirectory: true))
            index.entries[change.name] = SkillsIndexEntry(modified: SkillsIndex.truncated(max(now, latest)),
                                                         deleted: change.deleted)
        }
        save(index, appSupport)
        broadcast(index)
        return index
    }

    func save(_ index: SkillsIndex, _ appSupport: AppSupport) {
        do {
            try index.save(to: indexURL(appSupport))
        } catch {
            Log.host.error("Could not write the skills index: \((error as? DataError)?.message ?? error.localizedDescription)")
        }
    }

    /// Queues skills.changed with the full list of skills.list.
    func broadcast(_ index: SkillsIndex) {
        guard let broadcasts, let skills = try? summaries(index) else { return }
        broadcasts.yield(skills)
    }

    func indexURL(_ appSupport: AppSupport) -> URL {
        appSupport.skillsFolder.appendingPathComponent(".index.json", isDirectory: false)
    }

    // MARK: - Summaries

    /// Every skill of the index not deleted, sorted by name.
    func summaries(_ index: SkillsIndex) throws -> [SkillSummary] {
        try index.entries.filter { !$0.value.deleted }.keys.sorted().map { try summary($0, index: index) }
    }

    func summary(_ name: String, index: SkillsIndex) throws -> SkillSummary {
        let folder = try skillsFolder().appendingPathComponent(name, isDirectory: true)
        let check = validation(of: name, in: folder)
        let modified = index.entries[name]?.modified
            ?? SkillsIndex.latestModification(of: folder)
        return SkillSummary(name: name, description: check.description, modified: modified, problem: check.problem)
    }

    /// The validation of §4 of a skill folder's SKILL.md: its problem (nil when valid) and its description (`""` when
    /// invalid).
    func validation(of name: String, in folder: URL) -> (problem: String?, description: String) {
        guard let content = try? Data(contentsOf: folder.appendingPathComponent(Self.skillFileName,
                                                                               isDirectory: false))
        else {
            return ("SKILL.md is missing.", "")
        }
        if let problem = SkillFrontMatter.problem(in: content, skillName: name) {
            return (problem, "")
        }
        return (nil, SkillFrontMatter.description(in: content) ?? "")
    }

    // MARK: - Names and paths

    func library() throws -> AppSupport {
        guard let appSupport else {
            throw ProtocolError(.unavailable, "The skills library is not started.")
        }
        return appSupport
    }

    func skillsFolder() throws -> URL {
        try library().skillsFolder
    }

    /// The folder `Skills/<name>/` of an existing skill. badRequest for an invalid name, notFound without the folder.
    func existingSkill(_ name: String) throws -> URL {
        let skills = try skillsFolder()
        try Self.checkName(name)
        let folder = skills.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProtocolError(.notFound, "Skill \(name) does not exist.")
        }
        return folder
    }

    static func checkName(_ name: String) throws {
        guard SkillName.isValid(name) else {
            throw ProtocolError(.badRequest, invalidName)
        }
    }

    /// The components of a skill path: relative, `/`-separated, with no empty, `.` or `..` component. badRequest
    /// otherwise.
    static func components(_ path: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, !path.contains("\u{0}"), !path.hasPrefix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw ProtocolError(.badRequest, "Invalid path \(path).")
        }
        return components
    }

    /// The absolute URL of a skill path, which must resolve inside the skill folder; both are compared in their
    /// realpath(3) form, a path that does not exist yet through its deepest existing folder. With `followLast` false,
    /// the last component is not resolved (a symbolic link is deleted itself).
    static func resolve(_ path: String, in folder: URL, followLast: Bool) throws -> URL {
        let components = try components(path)
        let root = ClaudePathEncoding.canonicalPath(folder.path) ?? folder.path
        let resolvedCount = followLast ? components.count : components.count - 1
        var resolved = ([root] + components[0..<resolvedCount]).joined(separator: "/")
        var index = resolvedCount
        while index >= 0 {
            let candidate = ([root] + components[0..<index]).joined(separator: "/")
            if let real = ClaudePathEncoding.canonicalPath(candidate) {
                resolved = ([real] + components[index..<resolvedCount]).joined(separator: "/")
                break
            }
            index -= 1
        }
        if !followLast, let last = components.last {
            resolved += "/" + last
        }
        guard resolved.hasPrefix(root + "/") else {
            throw ProtocolError(.badRequest, "\(path) is outside the skill folder.")
        }
        return URL(fileURLWithPath: resolved, isDirectory: false)
    }

    /// Something exists at `url` (a dangling symbolic link included).
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// ProtocolError as it is; a DataError mapped as the host maps it (services/host.md §6.9).
    static func protocolError(_ error: any Error) -> ProtocolError {
        guard let dataError = error as? DataError else { return ProtocolError(error) }
        switch dataError {
        case .notFound(let message): return ProtocolError(.notFound, message)
        case .invalid(let message): return ProtocolError(.badRequest, message)
        case .refused(let message): return ProtocolError(.conflict, message)
        case .unreadable(let message): return ProtocolError(.unavailable, message)
        case .io(let message): return ProtocolError(.internal, message)
        }
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}
#endif
