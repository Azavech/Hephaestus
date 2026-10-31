#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// The lines written to the CLI's standard input (docs/claude/cli.md §3.2, §4.2), compared with the recordings.
final class PermissionResponseTests: XCTestCase {
    func testAllowMatchesRecording() throws {
        let request = try recordedRequest()
        let answer = PermissionBroker.answer(to: request, decision: .allow, message: nil, deviceName: "Mac")
        let recorded = try XCTUnwrap(try fixtureLines("tool-permission.stdin").last)
        XCTAssertEqual(try object(answer), try object(Data(recorded.utf8)))
    }

    func testAllowAlways() throws {
        let request = try recordedRequest()
        let answer = try object(PermissionBroker.answer(to: request, decision: .allowAlways, message: nil,
                                                        deviceName: "Mac"))
        let response = try inner(answer)
        XCTAssertEqual(response["behavior"] as? String, "allow")
        XCTAssertEqual(response["updatedInput"] as? NSDictionary, try object(Data(request.input.utf8)))
        let suggestions = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(request.suggestions.utf8))
            as? [NSDictionary])
        let kept = suggestions.filter { ["addRules", "addDirectories"].contains($0["type"] as? String ?? "") }
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(response["updatedPermissions"] as? [NSDictionary], kept)
        // The other fields are those of the allow answer.
        let allow = try object(PermissionBroker.answer(to: request, decision: .allow, message: nil, deviceName: "Mac"))
        let withoutPermissions = NSMutableDictionary(dictionary: response)
        withoutPermissions.removeObject(forKey: "updatedPermissions")
        XCTAssertEqual(withoutPermissions as NSDictionary, try inner(allow))
        XCTAssertEqual(answer["type"] as? String, "control_response")
    }

    func testAllowAll() throws {
        let request = try recordedRequest()
        let allowAll = PermissionBroker.answer(to: request, decision: .allowAll, message: nil, deviceName: "Mac")
        let allow = PermissionBroker.answer(to: request, decision: .allow, message: nil, deviceName: "Mac")
        XCTAssertEqual(try object(allowAll), try object(allow))
    }

    func testDeny() throws {
        let request = try recordedRequest()
        let denied = try object(PermissionBroker.answer(to: request, decision: .deny, message: nil, deviceName: "Mac"))
        XCTAssertEqual(try inner(denied), ["behavior": "deny", "message": "Denied from Mac"] as NSDictionary)
        let blank = try object(PermissionBroker.answer(to: request, decision: .deny, message: "  \n",
                                                       deviceName: "Mac"))
        XCTAssertEqual(try inner(blank), ["behavior": "deny", "message": "Denied from Mac"] as NSDictionary)
        let explained = try object(PermissionBroker.answer(to: request, decision: .deny,
                                                           message: "Use the test target instead.", deviceName: "Mac"))
        XCTAssertEqual(try inner(explained),
                       ["behavior": "deny", "message": "Use the test target instead."] as NSDictionary)
        let envelope = try XCTUnwrap(denied["response"] as? NSDictionary)
        XCTAssertEqual(envelope["subtype"] as? String, "success")
        XCTAssertEqual(envelope["request_id"] as? String, request.requestID)
    }

    func testStdinLines() throws {
        let recorded = try fixtureLines("interrupt-multiturn.stdin")
        XCTAssertGreaterThanOrEqual(recorded.count, 3)
        let userLine = try object(Data(recorded[1].utf8))
        let text = try XCTUnwrap((userLine["message"] as? NSDictionary)?["content"] as? String)
        XCTAssertEqual(try object(ClaudeProcess.StdinMessage.initialize.json), try object(Data(recorded[0].utf8)))
        XCTAssertEqual(try object(ClaudeProcess.StdinMessage.user(text: text).json), userLine)
        XCTAssertEqual(try object(ClaudeProcess.StdinMessage.interrupt(requestID: "interrupt-1").json),
                       try object(Data(recorded[2].utf8)))
    }

    // MARK: - Helpers

    /// The permission request parsed from tool-permission.jsonl.
    private func recordedRequest() throws -> PermissionRequest {
        var parser = StreamJSONParser()
        for line in try fixtureLines("tool-permission") {
            for case .permissionRequest(let request) in parser.parse(line) {
                return request
            }
        }
        XCTFail("No permission request in tool-permission.jsonl")
        throw CocoaError(.fileReadCorruptFile)
    }

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    /// The `response.response` object of an answer line.
    private func inner(_ answer: NSDictionary) throws -> NSDictionary {
        try XCTUnwrap((answer["response"] as? NSDictionary)?["response"] as? NSDictionary)
    }
}
#endif
