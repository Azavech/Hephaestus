#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// Generated session titles (docs/claude/cli.md 5.10, docs/claude/prompts.md "Title call"). No case runs the Claude
/// CLI: `testGenerate` runs a script of the test in its place.
final class SessionTitlerTests: XCTestCase {
    func testArguments() {
        XCTAssertEqual(SessionTitler.arguments, [
            "-p", "--model", "haiku", "--output-format", "text", "--no-session-persistence", "--tools", "",
            "--strict-mcp-config", "--disable-slash-commands", "--system-prompt", Prompts.titleSystemPrompt,
        ])
        XCTAssertEqual(SessionTitler.arguments.count, 12)
        XCTAssertEqual(SessionTitler.arguments[7], "")
        XCTAssertEqual(SessionTitler.arguments.last, Prompts.titleSystemPrompt)
        XCTAssertEqual(Prompts.titleSystemPrompt, "You write short titles for conversations.")
    }

    func testCleanTitle() {
        XCTAssertEqual(SessionTitler.cleanTitle("iPad sidebar breaks on rotation\n"), "iPad sidebar breaks on rotation")
        XCTAssertEqual(SessionTitler.cleanTitle("\n  \"Plan the Runs screen.\"  \nmore"), "Plan the Runs screen")
        XCTAssertEqual(SessionTitler.cleanTitle("“Fix login”"), "Fix login")
        XCTAssertEqual(SessionTitler.cleanTitle(String(repeating: "a", count: 100)), String(repeating: "a", count: 80))
        for output in ["   \n", "\"\"", "."] {
            XCTAssertNil(SessionTitler.cleanTitle(output), output)
        }
    }

    func testSessionTitle() {
        XCTAssertEqual(SessionTitler.sessionTitle("Plan the Runs screen", kind: .project, id: nil), "Plan the Runs screen")
        XCTAssertEqual(SessionTitler.sessionTitle("Sidebar fix", kind: .feedback, id: "HEPH-F1"), "HEPH-F1 · Sidebar fix")
        XCTAssertEqual(SessionTitler.sessionTitle("Sidebar fix", kind: .bundle, id: "HEPH-B1"), "HEPH-B1 · Sidebar fix")
    }

    func testTitleRequest() {
        XCTAssertEqual(Prompts.titleRequest("  Hello\n"), request("Hello"))
        let long = String(repeating: "é", count: 5_000)
        XCTAssertEqual(Prompts.titleRequest(long), request(String(repeating: "é", count: 4_000)))
    }

    func testGenerate() async throws {
        let folder = try makeTemporaryDirectory()
        let environment = ["PATH": "/usr/bin:/bin"]
        let recorder = try script(in: folder, name: "claude", body: """
            dir=$(dirname "$0")
            for argument in "$@"; do printf '%s\\n' "$argument"; done > "$dir/args"
            cat > "$dir/stdin"
            printf 'Sidebar fix.\\n'
            """)
        let title = try await SessionTitler.generate(executable: recorder.path, text: "Fix the sidebar",
                                                     environment: environment)
        XCTAssertEqual(title, "Sidebar fix")
        let arguments = try String(contentsOf: folder.appendingPathComponent("args", isDirectory: false),
                                   encoding: .utf8)
        XCTAssertEqual(arguments, SessionTitler.arguments.map { $0 + "\n" }.joined())
        let input = try Data(contentsOf: folder.appendingPathComponent("stdin", isDirectory: false))
        XCTAssertEqual(input, Data(Prompts.titleRequest("Fix the sidebar").utf8))

        let failing = try script(in: folder, name: "failing", body: """
            cat > /dev/null
            printf 'Sidebar fix\\n'
            exit 1
            """)
        let failed = try await SessionTitler.generate(executable: failing.path, text: "Fix the sidebar",
                                                      environment: environment)
        XCTAssertNil(failed)
        let silent = try script(in: folder, name: "silent", body: """
            cat > /dev/null
            exit 0
            """)
        let nothing = try await SessionTitler.generate(executable: silent.path, text: "Fix the sidebar",
                                                       environment: environment)
        XCTAssertNil(nothing)
    }

    // MARK: - Helpers

    /// The title request template of docs/claude/prompts.md with `{message}` replaced.
    private func request(_ message: String) -> String {
        """
        Write a title of at most 6 words for a conversation that starts with the message below. Reply with the title alone, in the language of the message, without quotes or a final period.

        <message>
        \(message)
        </message>
        """
    }

    /// An executable `/bin/sh` script in `folder`.
    private func script(in folder: URL, name: String, body: String) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: false)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
#endif
