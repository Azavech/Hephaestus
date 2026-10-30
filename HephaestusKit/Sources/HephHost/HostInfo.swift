#if os(macOS)
import Foundation
import HephCore

/// `host.info` and `host.listDirectories` (docs/services/host.md §10).
actor HostInfoService: HostMethodHandler {
    private let host: HostService
    private(set) var gitAvailable = false

    init(host: HostService) {
        self.host = host
    }

    /// start() step 4, and when claudePath changes.
    func refresh() async {
        await ClaudeLocator.shared.resolve(configured: await host.settings().claudeURL)
        gitAvailable = await Self.findGit()
    }

    /// ClaudeLocator.shared.lastResolvedPath.
    var claudePath: String? {
        get async {
            await ClaudeLocator.shared.lastResolvedPath
        }
    }

    // MARK: - HostMethodHandler

    func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .hostInfo:
                _ = try Self.decode(EmptyPayload.self, params, method)
                return try WireCoding.encodeJSON(await info())
            case .hostListDirectories:
                let request = try Self.decode(HostListDirectoriesParams.self, params, method)
                return try WireCoding.encodeJSON(try listDirectories(request.path))
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - host.info (§10.1)

    private func info() async -> HostInfoResult {
        let path = await claudePath
        return HostInfoResult(device: await host.mesh.localDevice(),
                              projectsFolder: await host.settings().projectsFolderURL.path,
                              claudeAvailable: path != nil,
                              claudePath: path ?? "",
                              gitAvailable: gitAvailable,
                              forge: await host.forge.config())
    }

    // MARK: - host.listDirectories (§10.2)

    private func listDirectories(_ requested: String) throws -> HostListDirectoriesResult {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        // 1. The path.
        let absolute: String
        if requested.isEmpty || requested == "~" {
            absolute = home
        } else if requested.hasPrefix("~/") {
            absolute = home + "/" + requested.dropFirst(2)
        } else if requested.hasPrefix("/") {
            absolute = requested
        } else {
            throw ProtocolError(.badRequest, "The path must be absolute.")
        }
        // 2. Standardized; an existing folder.
        let folder = URL(fileURLWithPath: absolute, isDirectory: true).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProtocolError(.notFound, "No folder at \(folder).")
        }
        // 3. Inside the home folder, symlinks resolved.
        let realHome = ClaudePathEncoding.canonicalPath(home) ?? home
        guard let realFolder = ClaudePathEncoding.canonicalPath(folder), Self.isInside(realFolder, realHome) else {
            throw ProtocolError(.badRequest, "Only folders inside the home folder can be listed.")
        }
        // 4. Readable.
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: realFolder)
        } catch {
            throw ProtocolError(.unavailable, error.localizedDescription)
        }
        // 5. Its subfolders, a symlink counting when it resolves to a folder inside the home folder.
        let entries = names
            .filter { !$0.hasPrefix(".") }
            .filter { name in
                let path = realFolder + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0 else { return false }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    return true
                case S_IFLNK:
                    var isFolder: ObjCBool = false
                    guard let target = ClaudePathEncoding.canonicalPath(path),
                          fileManager.fileExists(atPath: target, isDirectory: &isFolder), isFolder.boolValue
                    else { return false }
                    return Self.isInside(target, realHome)
                default:
                    return false
                }
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { DirectoryEntry(name: $0, path: realFolder + "/" + $0) }
        return HostListDirectoriesResult(path: realFolder, entries: entries)
    }

    // MARK: - Private

    /// `path` is `folder` or inside it.
    private static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    /// The first executable file named git in the directories of the login environment's PATH; /usr/bin/git counts
    /// only when the Command Line Tools are installed (`/usr/bin/xcode-select -p` exits with status 0).
    private static func findGit() async -> Bool {
        let environment = await LoginEnvironment.shared.environment()
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fileManager = FileManager.default
        var found: String?
        for directory in directories where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent("git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate) {
                found = candidate
                break
            }
        }
        guard let found else { return false }
        guard found == "/usr/bin/git" else { return true }
        let configuration = ChildProcessConfiguration(executable: "/usr/bin/xcode-select", arguments: ["-p"],
                                                      workingDirectory: fileManager.homeDirectoryForCurrentUser.path,
                                                      environment: environment)
        do {
            let output = try await ChildProcess.capture(configuration, timeout: .seconds(5))
            return !output.timedOut && output.termination == .exited(0)
        } catch {
            Log.host.error("Could not run xcode-select: \(String(describing: error))")
            return false
        }
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}
#endif
