import Foundation
import XCTest
@testable import HephCore

final class EnvelopeTests: XCTestCase {
    // The four example frames of docs/protocol/envelope.md.
    private let requestFrame =
        #"{"id":7,"kind":"request","method":"tickets.create","params":{"name":"Fix the sidebar","projectID":"HEPH"}}"#
    private let responseFrame =
        #"{"id":7,"kind":"response","result":{"comments":[],"created":"2026-10-29T21:04:00.123Z","description":"","id":"HEPH-13","name":"Fix the sidebar","status":"todo","updated":"2026-10-29T21:04:00.123Z"}}"#
    private let errorFrame =
        #"{"error":{"code":"notFound","message":"Project HEPH is not hosted on this Main."},"id":7,"kind":"response"}"#
    private let eventFrame =
        #"{"event":"ticket.removed","kind":"event","params":{"projectID":"HEPH","ticketID":"HEPH-13"}}"#

    func testExampleFrames() throws {
        let created = try XCTUnwrap(WireCoding.parseDate("2026-10-29T21:04:00.123Z"))
        let ticket = TicketItem(id: "HEPH-13", name: "Fix the sidebar", description: "", status: .todo, created: created,
                            updated: created, comments: [])

        let request = try WireCoding.encodeRequest(id: 7, method: RPCMethod.ticketsCreate.rawValue,
                                                   params: TicketsCreateParams(projectID: "HEPH", name: "Fix the sidebar"))
        try assertSameJSON(request, requestFrame)
        let response = WireCoding.encodeResponse(id: 7, resultJSON: try WireCoding.encodeJSON(ticket))
        try assertSameJSON(response, responseFrame)
        let error = try WireCoding.encodeError(id: 7, error: ProtocolError(.notFound, "Project HEPH is not hosted on this Main."))
        try assertSameJSON(error, errorFrame)
        let event = try WireCoding.encodeEvent(name: EventName.ticketRemoved.rawValue,
                                               params: TicketRemovedPayload(projectID: "HEPH", ticketID: "HEPH-13"))
        try assertSameJSON(event, eventFrame)
        let serverEvent = ServerEvent.ticketRemoved(TicketRemovedPayload(projectID: "HEPH", ticketID: "HEPH-13"))
        try assertSameJSON(try serverEvent.encodeFrame(), eventFrame)

        let parsedRequest = try WireCoding.parseFrame(Data(requestFrame.utf8))
        XCTAssertEqual(parsedRequest.kind, .request)
        XCTAssertEqual(parsedRequest.id, 7)
        XCTAssertEqual(parsedRequest.method, "tickets.create")
        XCTAssertNil(parsedRequest.event)
        XCTAssertNil(parsedRequest.error)
        let params = try InboundRequest(id: 7, method: "tickets.create", params: parsedRequest.body)
            .decodeParams(TicketsCreateParams.self)
        XCTAssertEqual(params, TicketsCreateParams(projectID: "HEPH", name: "Fix the sidebar"))

        let parsedResponse = try WireCoding.parseFrame(Data(responseFrame.utf8))
        XCTAssertEqual(parsedResponse.kind, .response)
        XCTAssertEqual(parsedResponse.id, 7)
        XCTAssertNil(parsedResponse.method)
        XCTAssertNil(parsedResponse.error)
        XCTAssertEqual(try WireCoding.decodeJSON(TicketItem.self, from: parsedResponse.body), ticket)

        let parsedError = try WireCoding.parseFrame(Data(errorFrame.utf8))
        XCTAssertEqual(parsedError.kind, .response)
        XCTAssertEqual(parsedError.id, 7)
        XCTAssertEqual(parsedError.error, ProtocolError(.notFound, "Project HEPH is not hosted on this Main."))
        XCTAssertTrue(parsedError.body.isEmpty)

        let parsedEvent = try WireCoding.parseFrame(Data(eventFrame.utf8))
        XCTAssertEqual(parsedEvent.kind, .event)
        XCTAssertNil(parsedEvent.id)
        XCTAssertEqual(parsedEvent.event, "ticket.removed")
        let decoded = try ServerEvent.decode(InboundEvent(name: "ticket.removed", params: parsedEvent.body))
        XCTAssertEqual(decoded, serverEvent)
        XCTAssertNil(try ServerEvent.decode(InboundEvent(name: "unknown.event", params: Data("{}".utf8))))
    }

    func testDates() throws {
        struct Stamp: Codable, Equatable {
            var at: Date
        }
        for text in ["2026-10-29T21:04:00.123Z", "2026-10-29T21:04:00.999Z", "2026-10-29T21:04:00.000Z"] {
            let decoded = try WireCoding.decodeJSON(Stamp.self, from: Data(#"{"at":"\#(text)"}"#.utf8))
            let encoded = try WireCoding.encodeJSON(decoded)
            try assertSameJSON(encoded, #"{"at":"\#(text)"}"#)
        }
        let whole = try WireCoding.decodeJSON(Stamp.self, from: Data(#"{"at":"2026-10-29T21:04:00Z"}"#.utf8))
        try assertSameJSON(try WireCoding.encodeJSON(whole), #"{"at":"2026-10-29T21:04:00.000Z"}"#)
        XCTAssertThrowsError(try WireCoding.decodeJSON(Stamp.self, from: Data(#"{"at":"yesterday"}"#.utf8)))
    }

    func testDataAndUUID() throws {
        let id = try XCTUnwrap(UUID(uuidString: "7C3A0E1B-29D4-4E6A-9B1F-3C2D5E8A4F10"))
        let params = MeshRekeyParams(meshKey: Data([0x00, 0x01, 0x02, 0xFD, 0xFE, 0xFF]))
        try assertSameJSON(try WireCoding.encodeJSON(params), #"{"meshKey":"AAEC/f7/"}"#)
        XCTAssertEqual(try WireCoding.decodeJSON(MeshRekeyParams.self, from: WireCoding.encodeJSON(params)), params)

        let revoke = MeshRevokeDeviceParams(deviceID: id)
        try assertSameJSON(try WireCoding.encodeJSON(revoke), #"{"deviceID":"7C3A0E1B-29D4-4E6A-9B1F-3C2D5E8A4F10"}"#)
        let lowercase = Data(#"{"deviceID":"7c3a0e1b-29d4-4e6a-9b1f-3c2d5e8a4f10"}"#.utf8)
        XCTAssertEqual(try WireCoding.decodeJSON(MeshRevokeDeviceParams.self, from: lowercase), revoke)

        let patch = TicketPatch(name: "Renamed")
        try assertSameJSON(try WireCoding.encodeJSON(patch), #"{"name":"Renamed"}"#)
        let withNull = Data(#"{"description":null,"name":"Renamed"}"#.utf8)
        XCTAssertEqual(try WireCoding.decodeJSON(TicketPatch.self, from: withNull), patch)
        try assertSameJSON(try WireCoding.encodeJSON(EmptyPayload()), "{}")
    }

    func testMalformedFrames() {
        let frames = [
            "[1,2]",
            #""request""#,
            "{",
            #"{"id":1,"kind":"call","method":"hello","params":{}}"#,
            #"{"id":1,"method":"hello","params":{}}"#,
            #"{"kind":"request","method":"hello","params":{}}"#,
            #"{"id":0,"kind":"request","method":"hello","params":{}}"#,
            #"{"id":true,"kind":"request","method":"hello","params":{}}"#,
            #"{"id":1,"kind":"request","params":{}}"#,
            #"{"kind":"response","result":{}}"#,
            #"{"kind":"event","params":{}}"#,
            // JSONSerialization reads -1e400 as minus infinity, which it cannot write back.
            #"{"id":1,"kind":"request","method":"hello","params":{"x":-1e400}}"#,
        ]
        for frame in frames {
            XCTAssertThrowsError(try WireCoding.parseFrame(Data(frame.utf8)), frame) { error in
                XCTAssertEqual((error as? ProtocolError)?.code, .badRequest, frame)
            }
        }
        // A missing params member reads as {}.
        XCTAssertEqual(try WireCoding.parseFrame(Data(#"{"id":2,"kind":"request","method":"projects.list"}"#.utf8)).body,
                       Data("{}".utf8))
    }

    func testUnknownErrorCode() throws {
        let error = try WireCoding.decodeJSON(ProtocolError.self, from: Data(#"{"code":"strange","message":"x"}"#.utf8))
        XCTAssertEqual(error, ProtocolError(.internal, "x"))
        let frame = #"{"error":{"code":"strange","message":"x"},"id":3,"kind":"response"}"#
        XCTAssertEqual(try WireCoding.parseFrame(Data(frame.utf8)).error, ProtocolError(.internal, "x"))
    }

    func testTopics() throws {
        let id = try XCTUnwrap(UUID(uuidString: "7C3A0E1B-29D4-4E6A-9B1F-3C2D5E8A4F10"))
        XCTAssertEqual(Topic.session(id).rawValue, "session:7C3A0E1B-29D4-4E6A-9B1F-3C2D5E8A4F10")
        XCTAssertEqual(Topic(rawValue: "session:7c3a0e1b-29d4-4e6a-9b1f-3c2d5e8a4f10"), .session(id))
        XCTAssertNil(Topic(rawValue: "foo:1"))
        XCTAssertNil(Topic(rawValue: "session:x"))
    }

    /// The two frames hold the same JSON object.
    private func assertSameJSON(_ data: Data, _ expected: String, file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let actual = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let wanted = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSDictionary
        XCTAssertNotNil(actual, file: file, line: line)
        XCTAssertEqual(actual, wanted, file: file, line: line)
    }
}
