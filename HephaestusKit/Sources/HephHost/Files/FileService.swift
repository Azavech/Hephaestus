#if os(macOS)
import Foundation
import HephCore

/// The `files.*` methods on the files of the hosted projects (docs/services/files.md §1, §5). Paths are relative to
/// the project root and resolved by a PathResolver on the project's realRoot. FileService emits no event: the file
/// watcher reports every change.
actor FileService: HostMethodHandler {
    private let host: HostService

    init(host: HostService) {
        self.host = host
    }

    /// files.list (§5.1).
    func list(projectID: String, path: String) async throws -> [FileEntry] {
        let project = try await host.registry.hosted(projectID)
        let url = try PathResolver(root: project.realRoot).resolve(path)
        guard let kind = Self.kind(url) else { throw ProtocolError(.notFound, "No folder at \(path).") }
        guard kind == .directory else { throw ProtocolError(.badRequest, "\(path) is a file.") }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            throw ProtocolError(.internal, error.localizedDescription)
        }
        let entries = names.compactMap { name -> FileEntry? in
            Self.entry(at: url.appendingPathComponent(name, isDirectory: false), name: name,
                       path: path.isEmpty ? name : path + "/" + name)
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// files.read (§5.2).
    func read(projectID: String, path: String, offset: Int?, length: Int?) async throws -> FilesReadResult {
        let project = try await host.registry.hosted(projectID)
        let url = try PathResolver(root: project.realRoot).resolve(path)
        guard let kind = Self.kind(url) else { throw ProtocolError(.notFound, "No file at \(path).") }
        guard kind != .directory else { throw ProtocolError(.badRequest, "\(path) is a folder.") }
        let size = try Self.fileSize(url)
        if offset == nil, length == nil {
            guard size <= MethodLimits.maxFileSize else {
                throw ProtocolError(.tooLarge, "\(path) is larger than 10 MiB.")
            }
            let content = try Self.contents(of: url)
            guard content.count <= MethodLimits.maxFileSize else {
                throw ProtocolError(.tooLarge, "\(path) is larger than 10 MiB.")
            }
            return FilesReadResult(data: content, revision: Revision.of(content), size: content.count)
        }
        let start = offset ?? 0
        guard start >= 0, start <= size else {
            throw ProtocolError(.badRequest, "Invalid offset \(start) for \(path).")
        }
        let requested = length ?? MethodLimits.maxChunkSize
        guard requested >= 1 else { throw ProtocolError(.badRequest, "Invalid length.") }
        let count = min(min(requested, MethodLimits.maxChunkSize), size - start)
        return FilesReadResult(data: try Self.readRange(url, offset: start, count: count), revision: "", size: size)
    }

    /// files.write (§5.3).
    func write(projectID: String, path: String, data: Data, baseRevision: String?) async throws -> FilesWriteResult {
        guard data.count <= MethodLimits.maxFileSize else {
            throw ProtocolError(.tooLarge, "The content is larger than 10 MiB.")
        }
        let (url, owner) = try await resolve(projectID: projectID, path: path, followLast: true)
        let parent = Self.parentPath(path)
        return try await host.registry.write(owner) { _ in
            if Self.kind(url) == .directory {
                throw ProtocolError(.badRequest, "\(path) is a folder.")
            }
            guard Self.kind(url.deletingLastPathComponent()) == .directory else {
                throw ProtocolError(.notFound, "No folder at \(parent).")
            }
            if let baseRevision {
                let deleted = ProtocolError(.conflict, "\(path) was deleted on the Main.")
                let changed = ProtocolError(.conflict, "\(path) was changed on the Main.")
                var info = stat()
                guard stat(url.path, &info) == 0 else { throw deleted }
                guard info.st_size <= MethodLimits.maxFileSize else { throw changed }
                let current: Data
                do {
                    current = try Data(contentsOf: url)
                } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
                    throw deleted
                }
                guard current.count <= MethodLimits.maxFileSize, Revision.of(current) == baseRevision else {
                    throw changed
                }
            }
            try AtomicFile.write(data, to: url)
            return FilesWriteResult(revision: Revision.of(data))
        }
    }

    /// files.create (§5.4).
    func create(projectID: String, path: String, isDirectory: Bool) async throws -> FileEntry {
        guard !path.isEmpty else { throw ProtocolError(.badRequest, "Invalid path.") }
        let (url, owner) = try await resolve(projectID: projectID, path: path, followLast: false)
        let parent = Self.parentPath(path)
        return try await host.registry.write(owner) { _ in
            guard Self.kind(url) == nil else {
                throw ProtocolError(.conflict, "\(path) already exists.")
            }
            guard Self.kind(url.deletingLastPathComponent()) == .directory else {
                throw ProtocolError(.notFound, "No folder at \(parent).")
            }
            if isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try AtomicFile.write(Data(), to: url)
            }
            guard let entry = Self.entry(at: url, name: url.lastPathComponent, path: path) else {
                throw ProtocolError(.notFound, "No file at \(path).")
            }
            return entry
        }
    }

    /// files.rename (§5.5).
    func rename(projectID: String, from: String, to: String) async throws {
        guard !from.isEmpty, !to.isEmpty else { throw ProtocolError(.badRequest, "Invalid path.") }
        for path in [from, to] where Self.protectedPaths.contains(path) {
            throw ProtocolError(.badRequest, "\(path) cannot be renamed or deleted.")
        }
        guard to != from, !to.hasPrefix(from + "/") else {
            throw ProtocolError(.badRequest, "A folder cannot be moved into itself.")
        }
        let (source, owner) = try await resolve(projectID: projectID, path: from, followLast: false)
        let project = try await host.registry.hosted(projectID)
        let destination = try PathResolver(root: project.realRoot).resolve(to, followLast: false)
        let parent = Self.parentPath(to)
        try await host.registry.write(owner) { _ in
            guard Self.kind(source) != nil else {
                throw ProtocolError(.notFound, "No file at \(from).")
            }
            guard Self.kind(destination.deletingLastPathComponent()) == .directory else {
                throw ProtocolError(.notFound, "No folder at \(parent).")
            }
            if Self.kind(destination) != nil, !Self.isSameItem(source, destination) {
                throw ProtocolError(.conflict, "\(to) already exists.")
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    /// files.delete (§5.6): the item goes to the Trash of the Main's user, never deleted permanently.
    func delete(projectID: String, path: String) async throws {
        guard !path.isEmpty else { throw ProtocolError(.badRequest, "Invalid path.") }
        guard !Self.protectedPaths.contains(path) else {
            throw ProtocolError(.badRequest, "\(path) cannot be renamed or deleted.")
        }
        let (url, owner) = try await resolve(projectID: projectID, path: path, followLast: false)
        let appSupport = host.appSupport
        try await host.registry.write(owner) { _ in
            guard Self.kind(url) != nil else {
                throw ProtocolError(.notFound, "No file at \(path).")
            }
            do {
                try appSupport.trashItem(url)
            } catch {
                var reason = error.localizedDescription
                if reason.hasSuffix(".") {
                    reason.removeLast()
                }
                throw ProtocolError(.unavailable, "Could not move \(path) to the Trash: \(reason).")
            }
        }
    }

    // MARK: - HostMethodHandler

    func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .filesList:
                let request = try Self.decode(FilesListParams.self, params, method)
                let entries = try await list(projectID: request.projectID, path: request.path)
                return try WireCoding.encodeJSON(FilesListResult(entries: entries))
            case .filesRead:
                let request = try Self.decode(FilesReadParams.self, params, method)
                return try WireCoding.encodeJSON(try await read(projectID: request.projectID, path: request.path,
                                                                offset: request.offset, length: request.length))
            case .filesWrite:
                let request = try Self.decode(FilesWriteParams.self, params, method)
                return try WireCoding.encodeJSON(try await write(projectID: request.projectID, path: request.path,
                                                                 data: request.data,
                                                                 baseRevision: request.baseRevision))
            case .filesCreate:
                let request = try Self.decode(FilesCreateParams.self, params, method)
                return try WireCoding.encodeJSON(try await create(projectID: request.projectID, path: request.path,
                                                                  isDirectory: request.isDirectory))
            case .filesRename:
                let request = try Self.decode(FilesRenameParams.self, params, method)
                try await rename(projectID: request.projectID, from: request.from, to: request.to)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .filesDelete:
                let request = try Self.decode(FilesDeleteParams.self, params, method)
                try await delete(projectID: request.projectID, path: request.path)
                return try WireCoding.encodeJSON(EmptyPayload())
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - Shared file helpers

    /// The size in bytes of a file (of its target for a symbolic link).
    static func fileSize(_ url: URL) throws -> Int {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw ProtocolError(.internal, String(cString: strerror(errno)))
        }
        return Int(info.st_size)
    }

    /// `count` bytes from `offset`: the file is opened with FileHandle and positioned at `offset`.
    static func readRange(_ url: URL, offset: Int, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }

    // MARK: - Private

    private enum Kind {
        case directory, other
    }

    /// Protected for files.rename and files.delete (§1).
    private static let protectedPaths: Set<String> = [".hephaestus", ".hephaestus/project.yml"]

    /// Resolves a path of the request's project and finds its owner: the deepest registered project that contains
    /// it (§1).
    private func resolve(projectID: String, path: String, followLast: Bool) async throws -> (URL, String) {
        let project = try await host.registry.hosted(projectID)
        let url = try PathResolver(root: project.realRoot).resolve(path, followLast: followLast)
        let owner = await host.registry.containing(url.path).first?.projectID ?? projectID
        return (url, owner)
    }

    /// What exists at `url`, tested with lstat (a dangling symlink exists); a symlink to a folder is a folder.
    private static func kind(_ url: URL) -> Kind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            return .directory
        }
        var target = stat()
        if (info.st_mode & S_IFMT) == S_IFLNK, stat(url.path, &target) == 0, (target.st_mode & S_IFMT) == S_IFDIR {
            return .directory
        }
        return .other
    }

    /// The FileEntry of an item; nil when it no longer exists.
    private static func entry(at url: URL, name: String, path: String) -> FileEntry? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            var target = stat()
            guard stat(url.path, &target) == 0 else {
                // A dangling symbolic link: the link's own date.
                return FileEntry(name: name, path: path, isDirectory: false, size: 0, modified: date(info))
            }
            info = target
        }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        return FileEntry(name: name, path: path, isDirectory: isDirectory, size: isDirectory ? 0 : Int(info.st_size),
                         modified: date(info))
    }

    private static func date(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private static func contents(of url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ProtocolError(.internal, error.localizedDescription)
        }
    }

    /// The project path of the folder holding `path` ("" for the root).
    private static func parentPath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// The same item: equal fileResourceIdentifier (a change of letter case on a case-insensitive volume).
    private static func isSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let right = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return left.isEqual(right)
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}
#endif
