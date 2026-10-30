#if os(macOS)
import Foundation
import HephCore

/// Finds the Claude CLI (docs/claude/cli.md §2) and stores the result of the last resolution.
public actor ClaudeLocator {
    public static let shared = ClaudeLocator()

    /// The result of the last resolution; nil: not found.
    private var stored: String?

    /// Runs the resolution and stores its result (nil: not found). `configured`: DeviceSettings.claudeURL.
    @discardableResult public func resolve(configured: URL?) async -> String? {
        let path = await Self.locate(configured: configured)
        stored = path
        if let path {
            Log.host.info("Claude CLI found at \(path)")
        } else {
            Log.host.notice("Claude CLI not found")
        }
        return path
    }

    /// The stored path when it is still an executable file; otherwise runs the resolution.
    public func current(configured: URL?) async -> String? {
        if let stored, Self.isExecutableFile(stored) {
            return stored
        }
        return await resolve(configured: configured)
    }

    /// The stored result of the last resolution.
    public var lastResolvedPath: String? {
        stored
    }

    /// ClaudePathEncoding.transcriptsFolder(projectRoot: projectRoot.path, configDirectory:
    /// ClaudePathEncoding.configDirectory(environment: environment, home:
    /// FileManager.default.homeDirectoryForCurrentUser)) + SessionFile.fileStem(sessionID) + ".jsonl"
    public static func transcriptURL(projectRoot: URL, sessionID: UUID, environment: [String: String]) -> URL {
        let configDirectory = ClaudePathEncoding.configDirectory(
            environment: environment, home: FileManager.default.homeDirectoryForCurrentUser)
        return ClaudePathEncoding.transcriptsFolder(projectRoot: projectRoot.path, configDirectory: configDirectory)
            .appendingPathComponent(SessionFile.fileStem(sessionID) + ".jsonl", isDirectory: false)
    }

    // MARK: - Resolution

    /// 1. The configured file (no fallback); 2. `command -v claude` in a login shell; 3. the usual install folders.
    private static func locate(configured: URL?) async -> String? {
        if let configured {
            return isExecutableFile(configured.path) ? configured.path : nil
        }
        if let path = await commandLookup() {
            return path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { isExecutableFile($0) }
    }

    /// `/bin/zsh -lic 'command -v claude'` with the app's environment, stdin /dev/null, timeout 5 s: the last stdout
    /// line that starts with `/` and names an executable regular file.
    private static func commandLookup() async -> String? {
        let configuration = ChildProcessConfiguration(executable: "/bin/zsh",
                                                      arguments: ["-lic", "command -v claude"],
                                                      workingDirectory: FileManager.default
                                                          .homeDirectoryForCurrentUser.path,
                                                      environment: ProcessInfo.processInfo.environment)
        do {
            let output = try await ChildProcess.capture(configuration, timeout: .seconds(5))
            let lines = String(decoding: output.standardOutput, as: UTF8.self)
                .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
                .map(String.init)
            return lines.last { $0.hasPrefix("/") && isExecutableFile($0) }
        } catch {
            Log.host.error("Could not run the login shell to find the Claude CLI: \(String(describing: error))")
            return nil
        }
    }

    /// An executable regular file (symbolic links followed).
    private static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }
}
#endif
