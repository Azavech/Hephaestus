#if os(macOS)
import Foundation
import HephCore

/// The title call of 5.10 (docs/claude/cli.md): one short call to the Claude CLI with the model `haiku` that titles a
/// `project`, `feedback` or `bundle` session from its first message.
public enum SessionTitler {
    /// argv[1...] of step 3.
    public static let arguments: [String] = [
        "-p", "--model", "haiku", "--output-format", "text", "--no-session-persistence", "--tools", "",
        "--strict-mcp-config", "--disable-slash-commands", "--system-prompt", Prompts.titleSystemPrompt,
    ]

    /// Runs the call of step 3 with the cleanup of step 4; nil when it fails or leaves nothing. Throws only
    /// CancellationError.
    public static func generate(executable: String, text: String, environment: [String: String]) async throws
        -> String? {
        let configuration = ChildProcessConfiguration(
            executable: executable, arguments: arguments,
            workingDirectory: FileManager.default.temporaryDirectory.path, environment: environment)
        let output: CapturedOutput
        do {
            output = try await ChildProcess.capture(configuration, input: Data(Prompts.titleRequest(text).utf8),
                                                    timeout: .seconds(60))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.host.error("The title call could not start: \(String(describing: error), privacy: .public)")
            return nil
        }
        if output.timedOut {
            Log.host.error("The title call timed out")
            return nil
        }
        guard output.termination == .exited(0) else {
            Log.host.error("The title call ended with exit code \(output.termination.exitCode, privacy: .public)")
            return nil
        }
        guard let title = cleanTitle(String(decoding: output.standardOutput, as: UTF8.self)) else {
            Log.host.error("The title call gave no title")
            return nil
        }
        return title
    }

    /// Step 4: the first line not empty after trimming, trimmed; one pair of surrounding quotes removed, then a final
    /// `.`, then whitespace again; cut to its first 80 characters and trimmed. Nil when nothing is left.
    public static func cleanTitle(_ output: String) -> String? {
        guard let line = output.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        var title = line
        let quotes: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("`", "`")]
        if title.count >= 2, let first = title.first, let last = title.last,
           quotes.contains(where: { $0.0 == first && $0.1 == last }) {
            title = String(title.dropFirst().dropLast())
        }
        if title.hasSuffix(".") {
            title.removeLast()
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = String(title.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Step 5; `id` is the ticket id of a feedback session, the bundle id of a bundle session, ignored for the others.
    public static func sessionTitle(_ title: String, kind: SessionKind, id: String?) -> String {
        switch kind {
        case .feedback, .bundle:
            return "\(id ?? "") · \(title)"
        case .project, .ticket, .regeneration:
            return title
        }
    }
}
#endif
