import Foundation
import HephCore

/// The file access of one project, through the request functions of its Main's connection (docs/ui/code.md,
/// "ProjectFiles"). Used by the Code and Docs sections.
@MainActor public final class ProjectFiles {
    public let workspace: Workspace
    public let projectID: String
    /// The Main hosting the project; the Code section updates it when the project moves to another Main.
    public var mainDeviceID: UUID

    public init(workspace: Workspace, mainDeviceID: UUID, projectID: String) {
        self.workspace = workspace
        self.mainDeviceID = mainDeviceID
        self.projectID = projectID
    }

    /// `workspace.connection(mainDeviceID)`
    public var connection: MainConnection? {
        workspace.connection(mainDeviceID)
    }

    /// `connection?.isConnected == true`
    public var isConnected: Bool {
        connection?.isConnected == true
    }

    /// `connection?.name`, else "the Main".
    public var mainName: String {
        connection?.name ?? "the Main"
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        try await requireConnection().listFiles(projectID: projectID, path: path)
    }

    public func read(_ path: String) async throws -> FilesReadResult {
        try await requireConnection().readFile(projectID: projectID, path: path)
    }

    /// A file of any size, read in ranges into the attachment cache; returns its local URL.
    public func download(_ path: String,
                         progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> URL {
        try await requireConnection().downloadFile(projectID: projectID, path: path, progress: progress)
    }

    public func write(_ path: String, data: Data, baseRevision: String?) async throws -> String {
        try await requireConnection().writeFile(projectID: projectID, path: path, data: data,
                                                baseRevision: baseRevision)
    }

    public func create(_ path: String, isDirectory: Bool) async throws -> FileEntry {
        try await requireConnection().createFile(projectID: projectID, path: path, isDirectory: isDirectory)
    }

    public func rename(from: String, to: String) async throws {
        try await requireConnection().renameFile(projectID: projectID, from: from, to: to)
    }

    public func delete(_ path: String) async throws {
        try await requireConnection().deleteFile(projectID: projectID, path: path)
    }

    /// `files.changed` events of this project from its Main, and the Main's reconnections. The stream iterates
    /// `workspace.events()` in a task it owns, cancelled when the stream terminates; `mainDeviceID` is read when each
    /// event arrives.
    public func changes() -> AsyncStream<ProjectFileChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: ProjectFileChange.self, bufferingPolicy: .unbounded)
        let events = workspace.events()
        let task = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                switch event {
                case .event(let mainDeviceID, .filesChanged(let payload)):
                    if mainDeviceID == self.mainDeviceID, payload.projectID == self.projectID {
                        continuation.yield(.paths(payload.paths))
                    }
                case .connected(let mainDeviceID):
                    if mainDeviceID == self.mainDeviceID {
                        continuation.yield(.reconnected)
                    }
                default:
                    break
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    /// The connection; without one, `ProtocolError(.unavailable, "The Main of <projectID> is not available.")`.
    private func requireConnection() throws -> MainConnection {
        guard let connection else {
            throw ProtocolError(.unavailable, "The Main of \(projectID) is not available.")
        }
        return connection
    }
}

/// What `ProjectFiles.changes()` delivers.
public enum ProjectFileChange: Sendable, Equatable {
    /// A files.changed event: project-relative paths.
    case paths([String])
    /// The Main completed a handshake; what is shown is fetched again.
    case reconnected
}

/// Functions on project-relative paths: `/`-separated, without a leading `/`, `""` being the project root
/// (docs/ui/code.md, "ProjectFiles").
public enum ProjectPath {
    /// Split at `/`, empty and `.` components removed, joined with `/`: `.`, `./` and `""` give `""`.
    public static func normalize(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .joined(separator: "/")
    }

    /// Both normalized; `name` when `folder` is `""`, `folder` when `name` is `""`, else `folder + "/" + name`.
    public static func join(_ folder: String, _ name: String) -> String {
        let folder = normalize(folder)
        let name = normalize(name)
        if folder.isEmpty {
            return name
        }
        if name.isEmpty {
            return folder
        }
        return folder + "/" + name
    }

    /// The path without its last component; `""` for a top-level item.
    public static func parent(of path: String) -> String {
        let components = normalize(path).split(separator: "/")
        return components.dropLast().joined(separator: "/")
    }

    /// The last component.
    public static func name(of path: String) -> String {
        normalize(path).split(separator: "/").last.map(String.init) ?? ""
    }

    /// `path == folder`, or `folder == ""`, or `path` starts with `folder + "/"`.
    public static func isSameOrInside(_ path: String, _ folder: String) -> Bool {
        path == folder || folder.isEmpty || path.hasPrefix(folder + "/")
    }

    /// For a `path` same as or inside `from`: `to` followed by the rest of `path`; else `path`.
    public static func rebase(_ path: String, from: String, to: String) -> String {
        guard isSameOrInside(path, from) else { return path }
        if path == from {
            return to
        }
        let rest = from.isEmpty ? path : String(path.dropFirst(from.count + 1))
        return join(to, rest)
    }

    /// For an `item` ending with `#L` followed by decimal digits only, whose value is an `Int` ≥ 1: the part before
    /// that `#L` and the value; else `item` and nil.
    public static func splitLineSuffix(_ item: String) -> (path: String, line: Int?) {
        guard let marker = item.range(of: "#L", options: .backwards) else {
            return (item, nil)
        }
        let digits = item[marker.upperBound...]
        guard !digits.isEmpty,
              digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let line = Int(digits), line >= 1
        else {
            return (item, nil)
        }
        return (String(item[..<marker.lowerBound]), line)
    }
}
