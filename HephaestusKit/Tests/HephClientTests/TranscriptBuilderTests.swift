import Foundation
import XCTest
@testable import HephClient
@testable import HephCore

final class TranscriptBuilderTests: XCTestCase {
    private let at = TestMesh.updatedAt

    private func event(_ id: String, _ type: SessionEventType, text: String? = nil) -> SessionEvent {
        SessionEvent(id: id, at: at, type: type, text: text)
    }

    func testUser() {
        var builder = TranscriptBuilder()
        let deviceID = UUID()
        let attachment = TicketAttachment(file: "shot.png", type: "image/png", size: 10)
        builder.apply(SessionEvent(id: "u1", at: at, type: .user, text: "Hello", attachments: [attachment],
                                   deviceID: deviceID))
        XCTAssertEqual(builder.items, [.user(UserMessageItem(id: "u1", at: at, text: "Hello",
                                                             attachments: [attachment], deviceID: deviceID))])
    }

    func testTextEvents() {
        var builder = TranscriptBuilder()
        builder.apply(event("a1", .assistant, text: "Answer"))
        builder.apply(event("t1", .thinking, text: "Thought"))
        builder.apply(event("t2", .thinking, text: "  \n "))
        builder.apply(event("s1", .system, text: "Interrupted"))
        builder.apply(event("e1", .error, text: "Broken"))
        XCTAssertEqual(builder.items, [
            .assistant(TextItem(id: "a1", at: at, text: "Answer")),
            .thinking(TextItem(id: "t1", at: at, text: "Thought")),
            .system(TextItem(id: "s1", at: at, text: "Interrupted")),
            .error(TextItem(id: "e1", at: at, text: "Broken")),
        ])
        XCTAssertEqual(builder.items.map(\.id), ["a1", "t1", "s1", "e1"])
    }

    func testTools() {
        var builder = TranscriptBuilder()
        builder.apply(SessionEvent(id: "c1", at: at, type: .toolUse, toolUseID: "toolu_1", name: "Bash",
                                   input: #"{"command":"ls"}"#))
        builder.apply(SessionEvent(id: "r1", at: at, type: .toolResult, text: "a.txt", toolUseID: "toolu_1",
                                   isError: false))
        builder.apply(SessionEvent(id: "r2", at: at, type: .toolResult, text: "lost", toolUseID: "toolu_9",
                                   isError: true))
        XCTAssertEqual(builder.items, [
            .tool(ToolItem(toolUseID: "toolu_1", at: at, name: "Bash", input: #"{"command":"ls"}"#,
                           result: ToolResultItem(text: "a.txt", isError: false))),
            .tool(ToolItem(toolUseID: "toolu_9", at: at, name: "", input: "",
                           result: ToolResultItem(text: "lost", isError: true))),
        ])
        XCTAssertEqual(builder.items.map(\.id), ["tool:toolu_1", "tool:toolu_9"])

        // A call that arrives after its result fills that item with its time, name and input; the result stays.
        let later = at.addingTimeInterval(1)
        builder.apply(SessionEvent(id: "c9", at: later, type: .toolUse, toolUseID: "toolu_9", name: "Read",
                                   input: "{}"))
        XCTAssertEqual(builder.items.map(\.id), ["tool:toolu_1", "tool:toolu_9"])
        XCTAssertEqual(builder.items.last, .tool(ToolItem(toolUseID: "toolu_9", at: later, name: "Read", input: "{}",
                                                          result: ToolResultItem(text: "lost", isError: true))))
    }

    func testPermissions() {
        var builder = TranscriptBuilder()
        let deviceID = UUID()
        builder.apply(SessionEvent(id: "p1", at: at, type: .permission, input: #"{"command":"ls"}"#,
                                   requestID: "perm-1", toolName: "Bash", description: "List",
                                   suggestions: "[]", blockedPath: "/tmp"))
        builder.apply(SessionEvent(id: "p2", at: at, type: .permission, input: "{}", requestID: "perm-1",
                                   toolName: "Bash", suggestions: "[]"))
        builder.applyPermissionRequest(PermissionRequest(requestID: "perm-1", toolName: "Bash", input: "{}",
                                                         suggestions: "[]"), at: at)
        builder.apply(SessionEvent(id: "d1", at: at, type: .permissionDecision, deviceID: deviceID,
                                   requestID: "perm-1", decision: .allow))
        builder.apply(SessionEvent(id: "d2", at: at, type: .permissionDecision, deviceID: deviceID,
                                   requestID: "perm-unknown", decision: .deny))
        XCTAssertEqual(builder.items, [
            .permission(PermissionItem(requestID: "perm-1", at: at, toolName: "Bash", input: #"{"command":"ls"}"#,
                                       description: "List", suggestions: "[]", blockedPath: "/tmp",
                                       decision: PermissionDecisionItem(decision: .allow, deviceID: deviceID,
                                                                        at: at))),
        ])
        XCTAssertEqual(builder.items.map(\.id), ["permission:perm-1"])

        builder.applyPermissionRequest(PermissionRequest(requestID: "perm-2", toolName: "Edit", input: "{}",
                                                         suggestions: "[]"), at: at)
        builder.applyPermissionDecision(requestID: "perm-2", decision: .deny, deviceID: nil, at: at)
        XCTAssertEqual(builder.items.last, .permission(PermissionItem(
            requestID: "perm-2", at: at, toolName: "Edit", input: "{}", description: nil, suggestions: "[]",
            blockedPath: nil, decision: PermissionDecisionItem(decision: .deny, deviceID: nil, at: at))))
    }

    func testTurnEnd() {
        var builder = TranscriptBuilder()
        builder.apply(SessionEvent(id: "x1", at: at, type: .result, isError: false, durationMS: 8200, costUSD: 0.04,
                                   stopReason: "end_turn"))
        XCTAssertEqual(builder.items, [.turnEnd(TurnEndItem(id: "x1", at: at, isError: false, durationMS: 8200,
                                                            costUSD: 0.04, stopReason: "end_turn"))])
    }

    func testDeltasReplacedByEvent() {
        var builder = TranscriptBuilder()
        builder.applyDelta(messageID: "m1", index: 0, kind: .text, text: "Hel")
        builder.applyDelta(messageID: "m1", index: 0, kind: .text, text: "lo")
        builder.applyDelta(messageID: "m1", index: 1, kind: .toolInput, text: "{")
        XCTAssertEqual(builder.items, [
            .streaming(StreamingItem(messageID: "m1", index: 0, kind: .text, text: "Hello")),
            .streaming(StreamingItem(messageID: "m1", index: 1, kind: .toolInput, text: "{")),
        ])
        XCTAssertEqual(builder.items.map(\.id), ["stream:m1:0", "stream:m1:1"])

        // A user message is appended before the streaming items.
        builder.apply(event("u1", .user, text: "Wait"))
        XCTAssertEqual(builder.items.map(\.id), ["u1", "stream:m1:0", "stream:m1:1"])

        // The final assistant event replaces its block.
        builder.apply(SessionEvent(id: "a1", at: at, type: .assistant, text: "Hello", messageID: "m1", index: 0))
        XCTAssertEqual(builder.items.map(\.id), ["u1", "a1", "stream:m1:1"])

        builder.apply(SessionEvent(id: "c1", at: at, type: .toolUse, messageID: "m1", index: 1, toolUseID: "t1",
                                   name: "Read", input: "{}"))
        XCTAssertEqual(builder.items.map(\.id), ["u1", "a1", "tool:t1"])

        builder.applyDelta(messageID: "m2", index: 0, kind: .thinking, text: "Hmm")
        builder.apply(SessionEvent(id: "th", at: at, type: .thinking, text: "Hmm", messageID: "m2", index: 0))
        XCTAssertEqual(builder.items.map(\.id), ["u1", "a1", "tool:t1", "th"])
    }

    func testResultAndErrorClearStreaming() {
        var builder = TranscriptBuilder()
        builder.applyDelta(messageID: "m1", index: 0, kind: .text, text: "Par")
        builder.apply(SessionEvent(id: "x1", at: at, type: .result, isError: false))
        XCTAssertEqual(builder.items.map(\.id), ["x1"])

        builder.applyDelta(messageID: "m2", index: 0, kind: .text, text: "tial")
        builder.apply(event("e1", .error, text: "Failed"))
        XCTAssertEqual(builder.items.map(\.id), ["x1", "e1"])

        builder.applyDelta(messageID: "m3", index: 0, kind: .text, text: "More")
        builder.clearStreaming()
        XCTAssertEqual(builder.items.map(\.id), ["x1", "e1"])
    }

    func testAppliedTwice() {
        var builder = TranscriptBuilder()
        let assistant = SessionEvent(id: "a1", at: at, type: .assistant, text: "Once", messageID: "m1", index: 0)
        builder.apply(assistant)
        let before = builder.items
        builder.apply(assistant)
        XCTAssertEqual(builder.items, before)

        // The streaming effect of an event already applied still applies.
        builder.applyDelta(messageID: "m1", index: 0, kind: .text, text: "Again")
        builder.apply(assistant)
        XCTAssertEqual(builder.items, before)
    }
}
