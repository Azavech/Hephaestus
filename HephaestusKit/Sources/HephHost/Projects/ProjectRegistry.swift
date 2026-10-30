#if os(macOS)
import Foundation
import HephCore

/// A project hosted by this Main (docs/services/host.md §6).
struct HostedProject: Sendable {
    let id: String              // project identifier = projectID
    let root: URL               // standardized path, as registered (projects.json form, symlinks not resolved)
    let realRoot: URL           // realpath(3) of root: path checks and FSEvents matching
    let parentID: String?       // nil for a top-level project
    var file: ProjectFile       // last valid project.yml (../data/project-yml.md)
    var modified: Date          // modification date of project.yml when `file` was read
    var parseError: String?     // set while project.yml on disk is invalid (§6.6)
    var migrating: Bool
    var pendingPermissions: [UUID: Int]   // pending permission requests per session of the project (§6.1)
}

/// The hosted projects in memory (docs/services/host.md §6): the top-level projects of `projects.json` and their sub
/// projects, found through each parent's `subprojects`, recursively. The only writer of `projects.json`.
actor ProjectRegistry {
    private let host: HostService
    private var projects: [String: HostedProject] = [:]
    private var queues: [String: ProjectWriteQueue] = [:]
    private var projectsFile = ProjectsFile(projects: [])
    /// This Main's device id (§6.1 `deviceID`), read from the mesh at load and registration.
    private var deviceID: UUID?

    init(host: HostService) {
        self.host = host
    }

    // MARK: - Loading

    /// start() step 2; true: projects.json was reset (§6.2).
    func load() async -> Bool {
        projects.removeAll()
        queues.removeAll()
        deviceID = await host.mesh.localDevice().id
        let loaded = ProjectsFile.load(host.appSupport)
        projectsFile = loaded.file
        if loaded.wasReset {
            Log.host.error("projects.json was unreadable and has been reset; the registry starts empty")
            return true
        }
        for path in loaded.file.projects {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue
            else {
                Log.host.error("The folder of the project \(path) is missing; it stays in projects.json")
                continue
            }
            do {
                _ = try await register(root: root, parentID: nil, announce: false)
            } catch {
                Log.host.error("The project \(path) is not served: \(Self.protocolError(error).message)")
            }
        }
        return false
    }

    /// stop() step 5.
    func unload() {
        projects.removeAll()
        queues.removeAll()
    }

    // MARK: - Queries

    /// notFound when not hosted.
    func hosted(_ projectID: String) throws -> HostedProject {
        guard let project = projects[projectID] else {
            throw ProtocolError(.notFound, "Project \(projectID) is not hosted on this Main.")
        }
        return project
    }

    /// Every project, any level.
    func all() -> [HostedProject] {
        projects.values.sorted { $0.id < $1.id }
    }

    /// Registered direct sub projects, in `subprojects` order.
    func children(of projectID: String) -> [HostedProject] {
        guard let parent = projects[projectID] else { return [] }
        var seen = Set<String>()
        return parent.file.subprojects.compactMap { entry -> HostedProject? in
            guard let normalized = ProjectFile.normalizedRelativePath(entry), normalized != "." else { return nil }
            let rootPath = Self.subprojectRoot(of: parent.root, entry: normalized).path
            guard let child = projects.values.first(where: { $0.parentID == projectID && $0.root.path == rootPath }),
                  seen.insert(child.id).inserted
            else { return nil }
            return child
        }
    }

    /// Ids of every nested sub project.
    func descendants(of projectID: String) -> [String] {
        var result: [String] = []
        var pending = [projectID]
        while let current = pending.popLast() {
            let direct = projects.values.filter { $0.parentID == current }.map(\.id).sorted()
            result.append(contentsOf: direct)
            pending.append(contentsOf: direct.reversed())
        }
        return result
    }

    /// projects.list (§7.1): the top-level projects ordered by name, each with its sub projects in `children`.
    func summaries() -> [ProjectSummary] {
        projects.values
            .filter { $0.parentID == nil }
            .sorted(by: Self.byName)
            .map(summary)
    }

    /// The wire Project (§6.1).
    func project(_ projectID: String) async throws -> Project {
        _ = try hosted(projectID)
        let highest = await host.tasks.highestNumber(projectID: projectID)
        return wireProject(try hosted(projectID), highestTaskNumber: highest)
    }

    /// Every registered project whose realRoot contains `absolutePath`, deepest first, with the relative path.
    func containing(_ absolutePath: String) -> [(projectID: String, relativePath: String)] {
        var matches: [(projectID: String, relativePath: String, depth: Int)] = []
        for project in projects.values {
            if let relative = Self.relativePath(of: absolutePath, inside: project.realRoot.path) {
                matches.append((project.id, relative, project.realRoot.path.count))
            }
        }
        return matches
            .sorted { $0.depth != $1.depth ? $0.depth > $1.depth : $0.projectID < $1.projectID }
            .map { ($0.projectID, $0.relativePath) }
    }

    // MARK: - Registration

    func register(root: URL, parentID: String?) async throws -> HostedProject {
        try await register(root: root, parentID: parentID, announce: true)
    }

    func unregister(_ projectID: String, forget: Bool) async {
        await unregister(projectID, forget: forget, announce: true)
    }

    /// Migration recovery: unregisters the top-level project registered at `rootPath` (forget: true); with none,
    /// removes `rootPath` from projects.json and unwatches it (§6.5).
    func forgetRoot(_ rootPath: String) async {
        let standardized = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        if let project = projects.values.first(where: {
            $0.parentID == nil && ($0.root.path == rootPath || $0.root.path == standardized)
        }) {
            await unregister(project.id, forget: true)
            return
        }
        let before = projectsFile
        projectsFile.remove(rootPath)
        if projectsFile != before {
            saveProjectsFile()
        }
        await host.watcher.unwatch(URL(fileURLWithPath: rootPath, isDirectory: true))
    }

    /// project.yml was read or written (§6.6).
    func reloaded(_ projectID: String, file: ProjectFile, modified: Date) async {
        guard projects[projectID] != nil else { return }
        let highest = await host.tasks.highestNumber(projectID: projectID)
        guard var project = projects[projectID] else { return }
        let previous = wireProject(project, highestTaskNumber: highest)
        let previousSummary = SummaryFields(project)
        let previousEntries = Self.normalizedEntries(project.file.subprojects)

        project.file = file
        project.modified = modified
        project.parseError = nil
        projects[projectID] = project

        let current = wireProject(project, highestTaskNumber: highest)
        if current != previous {
            await host.emit(.projectChanged(ProjectChangedPayload(project: current)))
        }

        let entries = Self.normalizedEntries(file.subprojects)
        for entry in previousEntries where !entries.contains(entry) {
            let rootPath = Self.subprojectRoot(of: project.root, entry: entry).path
            if let child = projects.values.first(where: { $0.parentID == projectID && $0.root.path == rootPath }) {
                await unregister(child.id, forget: false, announce: false)
            }
        }
        for entry in entries where !previousEntries.contains(entry) {
            await registerSubproject(entry: entry, parentID: projectID)
        }

        if let updated = projects[projectID], SummaryFields(updated) != previousSummary {
            await emitProjectsChanged()
        }
    }

    /// project.yml on disk is invalid (§6.6): the last valid file stays and is served.
    func markInvalid(_ projectID: String, error: String) async {
        guard var project = projects[projectID], project.parseError != error else { return }
        project.parseError = error
        projects[projectID] = project
        Log.host.error("The project.yml of \(projectID, privacy: .public) is invalid: \(error)")
        if let current = try? await self.project(projectID) {
            await host.emit(.projectChanged(ProjectChangedPayload(project: current)))
        }
        await emitProjectsChanged()
    }

    /// true: runs as an operation of the project's queue, then sets the flag; false: clears it at once (§6.8).
    func setMigrating(_ projectID: String, _ migrating: Bool) async {
        if migrating {
            guard let queue = queues[projectID] else { return }
            do {
                try await queue.perform {
                    await self.applyMigrating(projectID, true)
                }
            } catch {
                Log.host.error("Could not lock \(projectID, privacy: .public): \(Self.protocolError(error).message)")
            }
        } else {
            await applyMigrating(projectID, false)
        }
    }

    /// Stores the pending permission count of one session (0 removes it); emits projectsChanged when the project's
    /// sum changed (§6.1).
    func setPendingPermissions(_ projectID: String, sessionID: UUID, count: Int) async {
        guard var project = projects[projectID] else { return }
        let before = project.pendingPermissions.values.reduce(0, +)
        project.pendingPermissions[sessionID] = count > 0 ? count : nil
        projects[projectID] = project
        if project.pendingPermissions.values.reduce(0, +) != before {
            await emitProjectsChanged()
        }
    }

    // MARK: - Writes

    /// locked "<name> is being moved to another Main." when the project or one of its ancestors is migrating.
    func checkWritable(_ projectID: String) throws {
        var current = try hosted(projectID)
        while true {
            if current.migrating {
                throw ProtocolError(.locked, "\(current.file.name) is being moved to another Main.")
            }
            guard let parentID = current.parentID, let parent = projects[parentID] else { return }
            current = parent
        }
    }

    /// Runs `body` as an operation of the project's write queue (§6.8).
    func write<T: Sendable>(_ projectID: String,
                            _ body: @Sendable (HostedProject) async throws -> T) async throws -> T {
        guard let queue = queues[projectID] else {
            throw ProtocolError(.notFound, "Project \(projectID) is not hosted on this Main.")
        }
        return try await queue.perform {
            let project = try await self.beginWrite(projectID, queue: queue)
            return try await body(project)
        }
    }

    /// Local check, then the projects of every connected peer Main (§6.7).
    func checkIdentifiersAvailable(_ identifiers: [String]) async throws {
        for identifier in identifiers {
            if let project = projects[identifier] {
                throw ProtocolError(.conflict,
                                    "Identifier \(identifier) is already used by \(project.file.name) on this Main.")
            }
        }
        let mesh: MeshService = host.mesh
        let mains = await mesh.connectedPeerMains()
        guard !mains.isEmpty else { return }
        let trees = await withTaskGroup(of: (UUID, [ProjectSummary]?).self) { group -> [UUID: [ProjectSummary]] in
            for main in mains {
                group.addTask {
                    do {
                        let result = try await mesh.requestPeer(main.id, method: RPCMethod.projectsList.rawValue,
                                                                params: EmptyPayload(), as: ProjectsListResult.self,
                                                                timeout: .seconds(5))
                        return (main.id, result.projects)
                    } catch {
                        return (main.id, nil)
                    }
                }
            }
            var trees: [UUID: [ProjectSummary]] = [:]
            for await (mainID, tree) in group {
                trees[mainID] = tree
            }
            return trees
        }
        for identifier in identifiers {
            for main in mains {
                guard let tree = trees[main.id], let match = Self.find(identifier, in: tree) else { continue }
                throw ProtocolError(.conflict,
                                    "Identifier \(identifier) is already used by \(match.name) on \(main.name).")
            }
        }
    }

    // MARK: - Data errors

    /// The protocol error of a thrown error (§6.9): a `DataError` gets the code of its case and its message; a
    /// `ProtocolError` is kept; any other error is converted with `ProtocolError.init(_:)`.
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

    // MARK: - Private

    /// The fields of the project's own ProjectSummary compared by §6.6 step 3, with its sub project entries.
    private struct SummaryFields: Equatable {
        let name: String
        let description: String?
        let parseError: String?
        let subprojects: [String]

        init(_ project: HostedProject) {
            name = project.file.name
            description = project.file.description
            parseError = project.parseError
            subprojects = project.file.subprojects
        }
    }

    /// §6.4; `announce` false (load and sub projects): no event, no projects.json write, no watch.
    private func register(root rawRoot: URL, parentID: String?, announce: Bool) async throws -> HostedProject {
        let root = rawRoot.standardizedFileURL
        let file = try ProjectFile.load(projectRoot: root)
        let realRoot = URL(fileURLWithPath: ClaudePathEncoding.canonicalPath(root.path) ?? root.path, isDirectory: true)
        if projects.values.contains(where: { $0.realRoot.path == realRoot.path }) {
            throw ProtocolError(.conflict, "\(root.path) is already a project of this Main.")
        }
        if let existing = projects[file.id] {
            throw ProtocolError(.conflict, "Identifier \(file.id) is already used by \(existing.file.name) on this Main.")
        }
        if deviceID == nil {
            deviceID = await host.mesh.localDevice().id
        }
        let project = HostedProject(id: file.id, root: root, realRoot: realRoot, parentID: parentID, file: file,
                                    modified: Self.modificationDate(of: ProjectFile.url(projectRoot: root)),
                                    parseError: nil, migrating: false, pendingPermissions: [:])
        projects[file.id] = project
        queues[file.id] = ProjectWriteQueue()
        Log.host.info("Registered the project \(file.id, privacy: .public)")
        await host.tasks.load(projectID: file.id)
        for entry in Self.normalizedEntries(file.subprojects) {
            await registerSubproject(entry: entry, parentID: file.id)
        }
        if announce {
            if parentID == nil {
                let before = projectsFile
                projectsFile.add(root.path)
                if projectsFile != before {
                    saveProjectsFile()
                }
                await host.watcher.watch(root)
            }
            await emitProjectsChanged()
        }
        return projects[file.id] ?? project
    }

    /// §6.3: a sub project entry of a registered parent; a failed check is logged and the entry is skipped.
    private func registerSubproject(entry: String, parentID: String) async {
        guard let parent = projects[parentID] else { return }
        let root = Self.subprojectRoot(of: parent.root, entry: entry)
        guard !projects.values.contains(where: { $0.root.path == root.path }) else { return }
        guard let realPath = ClaudePathEncoding.canonicalPath(root.path),
              realPath.hasPrefix(parent.realRoot.path + "/")
        else {
            Log.host.error("The sub project \(entry) of \(parentID, privacy: .public) is not inside its folder or does not exist")
            return
        }
        do {
            _ = try await register(root: root, parentID: parentID, announce: false)
        } catch {
            Log.host.error("The sub project \(entry) of \(parentID, privacy: .public) is not served: \(Self.protocolError(error).message)")
        }
    }

    /// §6.5; `announce` false: no projectsChanged (the caller emits it).
    private func unregister(_ projectID: String, forget: Bool, announce: Bool) async {
        guard let project = projects[projectID] else { return }
        let removed = [projectID] + descendants(of: projectID)
        for id in removed {
            projects[id] = nil
            queues[id] = nil
        }
        Log.host.info("Unregistered the project \(projectID, privacy: .public)")
        for id in removed {
            await host.tasks.unload(projectID: id)
        }
        if project.parentID == nil, forget {
            let before = projectsFile
            projectsFile.remove(project.root.path)
            if projectsFile != before {
                saveProjectsFile()
            }
            await host.watcher.unwatch(project.root)
        }
        if announce {
            await emitProjectsChanged()
        }
    }

    private func applyMigrating(_ projectID: String, _ migrating: Bool) async {
        guard var project = projects[projectID] else { return }
        project.migrating = migrating
        projects[projectID] = project
        for id in [projectID] + descendants(of: projectID) {
            if let current = try? await self.project(id) {
                await host.emit(.projectChanged(ProjectChangedPayload(project: current)))
            }
        }
        await emitProjectsChanged()
    }

    /// §6.8 step 3: the operation starts.
    private func beginWrite(_ projectID: String, queue: ProjectWriteQueue) throws -> HostedProject {
        guard queues[projectID] === queue else {
            throw ProtocolError(.notFound, "Project \(projectID) is not hosted on this Main.")
        }
        let project = try hosted(projectID)
        try checkWritable(projectID)
        return project
    }

    private func summary(_ project: HostedProject) -> ProjectSummary {
        ProjectSummary(id: project.id,
                       name: project.file.name,
                       description: project.file.description,
                       deviceID: deviceID ?? Self.unknownDevice,
                       rootPath: project.root.path,
                       children: children(of: project.id).map(summary),
                       migrating: isMigrating(project),
                       parseError: project.parseError,
                       pendingPermissionCount: project.pendingPermissions.values.reduce(0, +))
    }

    private func wireProject(_ project: HostedProject, highestTaskNumber: Int) -> Project {
        let file = project.file
        return Project(id: project.id,
                       name: file.name,
                       description: file.description,
                       created: file.created,
                       code: file.code,
                       docs: file.docs,
                       taskCounter: max(file.taskCounter, highestTaskNumber),
                       subprojects: file.subprojects,
                       webTabs: file.webTabValues,
                       runs: file.runConfigs,
                       skills: file.skills,
                       claude: file.claudeDefaults,
                       deviceID: deviceID ?? Self.unknownDevice,
                       rootPath: project.root.path,
                       migrating: isMigrating(project),
                       parseError: project.parseError)
    }

    /// The project's flag, or one of its ancestors' (§6.1).
    private func isMigrating(_ project: HostedProject) -> Bool {
        var current: HostedProject? = project
        while let candidate = current {
            if candidate.migrating { return true }
            current = candidate.parentID.flatMap { projects[$0] }
        }
        return false
    }

    private func emitProjectsChanged() async {
        let payload = ProjectsChangedPayload(deviceID: deviceID ?? Self.unknownDevice, projects: summaries())
        await host.emit(.projectsChanged(payload))
    }

    private func saveProjectsFile() {
        do {
            try projectsFile.save(host.appSupport)
        } catch {
            Log.host.error("Could not write projects.json: \(Self.protocolError(error).message)")
        }
    }

    /// The device id before the mesh answered (never sent in practice).
    private static let unknownDevice = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private static func byName(_ lhs: HostedProject, _ rhs: HostedProject) -> Bool {
        switch lhs.file.name.localizedStandardCompare(rhs.file.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id < rhs.id
        }
    }

    /// The normalized entries of `subprojects`, without `.`, invalid entries and repeats.
    private static func normalizedEntries(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let normalized = ProjectFile.normalizedRelativePath(entry), normalized != ".",
                  seen.insert(normalized).inserted
            else { return nil }
            return normalized
        }
    }

    /// The parent's root + the entry (§6.3), standardized.
    static func subprojectRoot(of parentRoot: URL, entry: String) -> URL {
        parentRoot.appendingPathComponent(entry, isDirectory: true).standardizedFileURL
    }

    /// `path` relative to `root` when `path` is `root` or inside it ("" for the root itself), compared at a `/`
    /// boundary and case-insensitively (APFS volumes are case-insensitive by default); nil otherwise.
    static func relativePath(of path: String, inside root: String) -> String? {
        guard let match = path.range(of: root, options: [.anchored, .caseInsensitive]) else { return nil }
        let rest = path[match.upperBound...]
        if rest.isEmpty { return "" }
        guard rest.hasPrefix("/") else { return nil }
        return String(rest.dropFirst())
    }

    /// The modification date of a file; now when it cannot be read.
    static func modificationDate(of url: URL) -> Date {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    /// A summary with that identifier in the tree, children included.
    private static func find(_ identifier: String, in tree: [ProjectSummary]) -> ProjectSummary? {
        for summary in tree {
            if summary.id == identifier { return summary }
            if let match = find(identifier, in: summary.children) { return match }
        }
        return nil
    }
}
#endif
