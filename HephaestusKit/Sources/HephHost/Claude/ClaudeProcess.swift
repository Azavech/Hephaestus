#if os(macOS)
import Foundation
import HephCore
import os

/// One running `claude` for one session (docs/claude/cli.md §3): spawned with `ChildProcess` (stdin, stdout and stderr
/// as separate pipes), driven in stream-json mode. Its standard output is read with `LineReader` and parsed with
/// `StreamJSONParser` into `messages`; a task keeps the last 4 KiB of its standard error. `Sendable` because its
/// mutable state (the stderr tail, the time of the last activity) is guarded by `OSAllocatedUnfairLock`s.
public final class ClaudeProcess: Sendable {
    public struct Options: Sendable {
        public var executable: String
        public var sessionID: UUID
        public var resume: Bool                 // --resume instead of --session-id
        public var permissionMode: PermissionMode
        public var model: String?
        public var mcpConfig: String            // MCPServer.configJSON(token:)
        public var allowedTools: [String]       // ["mcp__hephaestus", …] (§3.1, §3.5)
        public var disallowedTools: [String]    // §3.1, §3.5
        public var pluginFolder: URL
        public var systemPromptFile: URL        // --append-system-prompt-file (§5.3 step 4)
        public var title: String
        public var workingDirectory: URL
        public var environment: [String: String] // the login environment; changed as in §3.5 for its sessions

        public init(executable: String, sessionID: UUID, resume: Bool, permissionMode: PermissionMode,
                    model: String?, mcpConfig: String, allowedTools: [String], disallowedTools: [String],
                    pluginFolder: URL, systemPromptFile: URL, title: String, workingDirectory: URL,
                    environment: [String: String]) {
            self.executable = executable
            self.sessionID = sessionID
            self.resume = resume
            self.permissionMode = permissionMode
            self.model = model
            self.mcpConfig = mcpConfig
            self.allowedTools = allowedTools
            self.disallowedTools = disallowedTools
            self.pluginFolder = pluginFolder
            self.systemPromptFile = systemPromptFile
            self.title = title
            self.workingDirectory = workingDirectory
            self.environment = environment
        }
    }

    /// A line written to the CLI's standard input (§3.2).
    public enum StdinMessage: Sendable {
        case initialize
        case user(text: String)
        case interrupt(requestID: String)
        case permission(answer: Data)           // PermissionBroker.answer(…)
        case refuse(requestID: String)

        /// The line of §3.2 without its trailing newline.
        public var json: Data {
            let object: [String: Any]
            switch self {
            case .initialize:
                object = ["type": "control_request", "request_id": "init",
                          "request": ["subtype": "initialize", "hooks": NSNull()] as [String: Any]]
            case .user(let text):
                object = ["type": "user", "message": ["role": "user", "content": text],
                          "parent_tool_use_id": NSNull(), "session_id": ""]
            case .interrupt(let requestID):
                object = ["type": "control_request", "request_id": requestID,
                          "request": ["subtype": "interrupt"]]
            case .permission(let answer):
                return answer
            case .refuse(let requestID):
                object = ["type": "control_response",
                          "response": ["subtype": "error", "request_id": requestID, "error": "Unsupported request"]]
            }
            return (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        }
    }

    public let sessionID: UUID
    /// Parsed stdout, in order; finishes at stdout's end of file.
    public let messages: AsyncStream<CLIMessage>

    private let child: ChildProcess
    /// The last bytes of stderr, at most `tailSize`.
    private let errorTail: OSAllocatedUnfairLock<Data>
    /// When a line was last written to stdin or read from stdout (the activity of the idle stop, §5.6).
    private let activity: OSAllocatedUnfairLock<ContinuousClock.Instant>

    private static let tailSize = 4_096

    private init(sessionID: UUID, child: ChildProcess, messages: AsyncStream<CLIMessage>,
                 errorTail: OSAllocatedUnfairLock<Data>, activity: OSAllocatedUnfairLock<ContinuousClock.Instant>) {
        self.sessionID = sessionID
        self.child = child
        self.messages = messages
        self.errorTail = errorTail
        self.activity = activity
    }

    /// argv[1...] of §3.1.
    public static func arguments(_ options: Options) -> [String] {
        let sessionID = SessionFile.fileStem(options.sessionID)
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages", "--permission-prompt-tool", "stdio"]
        arguments += options.resume ? ["--resume", sessionID] : ["--session-id", sessionID]
        arguments += ["--permission-mode", options.permissionMode.rawValue]
        if let model = options.model {
            arguments += ["--model", model]
        }
        arguments += ["--mcp-config", options.mcpConfig]
        arguments += ["--allowedTools"] + options.allowedTools
        arguments += ["--disallowedTools"] + options.disallowedTools
        arguments += ["--plugin-dir", options.pluginFolder.path]
        arguments += ["--append-system-prompt-file", options.systemPromptFile.path]
        arguments.append("--name=" + options.title)
        return arguments
    }

    /// Spawns the process and writes the initialize request. Spawn errors are thrown (`ChildProcessError`).
    public static func launch(_ options: Options) throws -> ClaudeProcess {
        let configuration = ChildProcessConfiguration(executable: options.executable,
                                                      arguments: arguments(options),
                                                      workingDirectory: options.workingDirectory.path,
                                                      environment: options.environment,
                                                      standardInput: .pipe,
                                                      mergeStandardError: false)
        let child = try ChildProcess.spawn(configuration)
        let errorTail = OSAllocatedUnfairLock(initialState: Data())
        let activity = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let (messages, continuation) = AsyncStream.makeStream(of: CLIMessage.self, bufferingPolicy: .unbounded)

        Task {
            var reader = LineReader()
            var parser = StreamJSONParser()
            for await chunk in child.standardOutput {
                for line in reader.append(chunk) {
                    activity.withLock { $0 = ContinuousClock.now }
                    for message in parser.parse(line) {
                        continuation.yield(message)
                    }
                }
            }
            if let rest = reader.finish() {
                activity.withLock { $0 = ContinuousClock.now }
                for message in parser.parse(rest) {
                    continuation.yield(message)
                }
            }
            continuation.finish()
        }
        Task {
            for await chunk in child.standardError {
                errorTail.withLock { tail in
                    tail.append(chunk)
                    if tail.count > ClaudeProcess.tailSize {
                        tail = Data(tail.suffix(ClaudeProcess.tailSize))
                    }
                }
            }
        }

        let process = ClaudeProcess(sessionID: options.sessionID, child: child, messages: messages,
                                    errorTail: errorTail, activity: activity)
        do {
            try process.send(.initialize)
        } catch {
            // The process is gone already: its exit is handled when its output ends.
            Log.host.error("Could not write the initialize request of session \(options.sessionID.uuidString, privacy: .public): \(String(describing: error))")
        }
        return process
    }

    /// Writes one line (the message and a newline) to the CLI's standard input.
    public func send(_ message: StdinMessage) throws {
        var line = message.json
        line.append(0x0A)
        try child.write(line)
        activity.withLock { $0 = ContinuousClock.now }
    }

    /// The last 4 KiB of stderr decoded as UTF-8 (lossy), whitespace-trimmed.
    public var standardErrorTail: String {
        String(decoding: errorTail.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stop sequence of `ChildProcess.terminate()`: SIGTERM to the group, SIGKILL after 5 s.
    public func terminate() async {
        await child.terminate()
    }

    public func waitForExit() async -> ChildTermination {
        await child.waitForExit()
    }

    /// When a line was last written to stdin or read from stdout.
    var lastActivity: ContinuousClock.Instant {
        activity.withLock { $0 }
    }
}
#endif
