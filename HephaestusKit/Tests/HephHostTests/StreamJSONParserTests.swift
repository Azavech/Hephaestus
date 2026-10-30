#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// The stream-json parser on the recorded CLI transcripts (docs/claude/cli.md §3.3): each fixture's lines go through one
/// `StreamJSONParser`; the expected messages come in this order, among the others.
final class StreamJSONParserTests: XCTestCase {
    func testOneshot() throws {
        let lines = try parse("oneshot")
        let messages = lines.flatMap(\.messages)
        assertInOrder(messages, [
            ("initialized", {
                guard case .initialized(let info) = $0 else { return false }
                return info.model == "claude-haiku-5-5" && info.version == "2.1.309" && info.toolCount == 0
            }),
            ("block text OK", {
                guard case .block(_, _, .text("OK")) = $0 else { return false }
                return true
            }),
            ("result", {
                guard case .result(let result) = $0 else { return false }
                return !result.isError && result.subtype == "success" && result.stopReason == "end_turn"
            }),
        ])
        let rateLimit = lines.filter { $0.type == "rate_limit_event" }
        XCTAssertFalse(rateLimit.isEmpty)
        XCTAssertTrue(rateLimit.allSatisfy { $0.messages.isEmpty })
    }

    func testAutoAllowedTool() throws {
        let messages = try parse("auto-allowed-tool").flatMap(\.messages)
        let expectedInput: NSDictionary = ["command": "echo hello-from-test",
                                           "description": "Print hello-from-test via echo"]
        let toolInput = deltas(messages, kind: .toolInput)
        XCTAssertEqual(try object(toolInput), expectedInput)
        let finalText = "The output was `hello-from-test`."
        XCTAssertEqual(deltas(messages, kind: .text), finalText)
        assertInOrder(messages, [
            ("initialize response", { $0 == .controlResponse(requestID: "req_init", error: nil) }),
            ("tool use", {
                guard case .block(_, _, .toolUse(_, let name, let input)) = $0 else { return false }
                return name == "Bash" && (try? self.object(input)) == expectedInput
            }),
            ("tool result", { $0 == .toolResult(toolUseID: Self.toolUseID(of: $0), text: "hello-from-test",
                                                isError: false) }),
            ("text block", {
                guard case .block(_, _, .text(let text)) = $0 else { return false }
                return text == finalText
            }),
            ("result", {
                guard case .result(let result) = $0 else { return false }
                return !result.isError && result.subtype == "success"
            }),
        ])
        XCTAssertFalse(messages.contains { if case .permissionRequest = $0 { return true } else { return false } })
    }

    func testToolPermission() throws {
        let messages = try parse("tool-permission").flatMap(\.messages)
        let requestID = "00000000-0000-4000-8000-000000000301"
        assertInOrder(messages, [
            ("permission request", {
                guard case .permissionRequest(let request) = $0 else { return false }
                let input = try? self.object(request.input)
                let types = (try? JSONSerialization.jsonObject(with: Data(request.suggestions.utf8)) as? [[String: Any]])?
                    .compactMap { $0["type"] as? String }
                return request.requestID == requestID
                    && request.toolName == "Bash"
                    && input?["command"] as? String == "touch probe-file.txt && ls"
                    && types == ["addRules", "addDirectories", "setMode"]
                    && request.blockedPath == "/Users/user/Projects/Fixture/probe-file.txt"
            }),
            ("tool result", { $0 == .toolResult(toolUseID: Self.toolUseID(of: $0), text: "probe-file.txt\nstream.log",
                                                isError: false) }),
            ("result", {
                guard case .result(let result) = $0 else { return false }
                return !result.isError && result.subtype == "success"
            }),
        ])
    }

    func testInterruptMultiturn() throws {
        let lines = try parse("interrupt-multiturn")
        let messages = lines.flatMap(\.messages)
        assertInOrder(messages, [
            ("initialize response", { $0 == .controlResponse(requestID: "init", error: nil) }),
            ("interrupt response", { $0 == .controlResponse(requestID: "interrupt-1", error: nil) }),
            ("interrupted result", {
                guard case .result(let result) = $0 else { return false }
                return result.isError && result.subtype == "error_during_execution" && result.stopReason == nil
            }),
            ("second init", { if case .initialized = $0 { return true } else { return false } }),
            ("thinking block", {
                guard case .block(_, _, .thinking) = $0 else { return false }
                return true
            }),
            ("text block", {
                guard case .block(_, _, .text(let text)) = $0 else { return false }
                return text == "SECOND-TURN-OK"
            }),
            ("result", {
                guard case .result(let result) = $0 else { return false }
                return !result.isError && result.subtype == "success" && result.stopReason == "end_turn"
            }),
        ])
        XCTAssertEqual(messages.filter { if case .initialized = $0 { return true } else { return false } }.count, 2)
        // The second turn's blocks take the indexes of their deltas: the thinking block 0, the text block 1.
        let blocks = messages.compactMap { message -> (Int, AssistantBlock)? in
            guard case .block(_, let index, let block) = message else { return nil }
            return (index, block)
        }
        XCTAssertEqual(blocks.map(\.0), [0, 1])
        let interrupted = lines.filter { line in
            line.type == "user" && line.text.contains("[Request interrupted by user]")
        }
        XCTAssertFalse(interrupted.isEmpty)
        XCTAssertTrue(interrupted.allSatisfy { $0.messages.isEmpty })
    }

    func testResume() throws {
        let messages = try parse("resume").flatMap(\.messages)
        assertInOrder(messages, [
            ("initialize response", { $0 == .controlResponse(requestID: "init", error: nil) }),
            ("init", { if case .initialized = $0 { return true } else { return false } }),
            ("text block", {
                guard case .block(_, _, .text(let text)) = $0 else { return false }
                return text == "SECOND-TURN-OK"
            }),
            ("result", {
                guard case .result(let result) = $0 else { return false }
                return !result.isError && result.subtype == "success"
            }),
        ])
    }

    func testGarbage() {
        var parser = StreamJSONParser()
        for line in ["not json", "[]", #"{"type":1}"#] {
            XCTAssertEqual(parser.parse(line), [], line)
        }
    }

    // MARK: - Helpers

    private struct ParsedLine {
        let text: String
        let type: String?
        let messages: [CLIMessage]
    }

    /// Every line of a fixture through one parser, with the messages it gave.
    private func parse(_ fixture: String) throws -> [ParsedLine] {
        var parser = StreamJSONParser()
        return try fixtureLines(fixture).map { line in
            let type = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["type"] as? String
            return ParsedLine(text: line, type: type, messages: parser.parse(line))
        }
    }

    /// Fails unless messages matching the expectations appear in this order (other messages may come between).
    private func assertInOrder(_ messages: [CLIMessage], _ expectations: [(String, (CLIMessage) -> Bool)],
                               file: StaticString = #filePath, line: UInt = #line) {
        var position = messages.startIndex
        for (label, matches) in expectations {
            guard let found = messages[position...].firstIndex(where: matches) else {
                XCTFail("No \(label) in order", file: file, line: line)
                return
            }
            position = messages.index(after: found)
        }
    }

    /// The fragments of one kind, joined.
    private func deltas(_ messages: [CLIMessage], kind: SessionDeltaKind) -> String {
        messages.compactMap { message -> String? in
            guard case .delta(_, _, let deltaKind, let text) = message, deltaKind == kind else { return nil }
            return text
        }.joined()
    }

    private func object(_ text: String) throws -> NSDictionary {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    private static func toolUseID(of message: CLIMessage) -> String {
        if case .toolResult(let toolUseID, _, _) = message { return toolUseID }
        return ""
    }
}
#endif
