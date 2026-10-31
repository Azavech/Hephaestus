import Foundation
import XCTest
@testable import HephClient
@testable import HephCore

@MainActor
final class PreviewDataTests: XCTestCase {
    private let studioID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let macBookProID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let ticketSessionID = UUID(uuidString: "00000000-0000-4000-8000-000000000302")!

    func testPreviewState() throws {
        let workspace = Workspace.preview()
        XCTAssertTrue(workspace.isPreview)
        XCTAssertEqual(workspace.device.id, macBookProID)
        XCTAssertTrue(workspace.hasMesh)
        XCTAssertEqual(workspace.mesh?.devices.count, 3)
        XCTAssertEqual(workspace.mains.map(\.name), ["Sam's MacBook Pro", "Studio"])
        XCTAssertEqual(workspace.localConnection?.id, macBookProID)
        XCTAssertEqual(workspace.onlineDeviceCount, 2)
        XCTAssertEqual(workspace.connections.count, 2)
        XCTAssertTrue(workspace.connections.values.allSatisfy(\.isConnected))
        XCTAssertNotNil(workspace.connection(studioID)?.hostInfo?.forge)
        XCTAssertEqual(workspace.connection(studioID)?.skills.map(\.name), ["release-notes"])
        XCTAssertEqual(workspace.summary(of: "HEPH", on: studioID)?.pendingPermissionCount, 1)
        XCTAssertEqual(workspace.projectPath(of: "API", on: studioID), ["HEPH", "API"])

        let store = workspace.projectStore(mainDeviceID: studioID, projectID: "HEPH")
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.tickets.map(\.id), ["HEPH-1", "HEPH-2", "HEPH-3", "HEPH-4"])
        XCTAssertEqual(Set(store.tickets.map(\.status)), Set(TicketStatus.allCases))
        XCTAssertEqual(store.sessions.count, 2)
        let ticketSession = try XCTUnwrap(store.session(ticketSessionID))
        XCTAssertEqual(ticketSession.pendingPermissions.map(\.requestID), ["perm-1"])
        XCTAssertEqual(workspace.projectStore(mainDeviceID: studioID, projectID: "API").phase, .loaded)
        XCTAssertEqual(workspace.forge.forgeHostID, studioID)
    }

    func testAnswers() async throws {
        let workspace = Workspace.preview()
        let connection = try XCTUnwrap(workspace.connection(studioID))

        let history = try await connection.sessionHistory(projectID: "HEPH", sessionID: ticketSessionID)
        XCTAssertEqual(history.events.count, 5)
        XCTAssertEqual(history.firstIndex, 0)
        XCTAssertEqual(history.total, 5)
        let last = try XCTUnwrap(history.events.last)
        XCTAssertEqual(last.type, .permission)
        XCTAssertNil(last.decision)
        XCTAssertEqual(last.requestID, "perm-1")

        let content = "# Hephaestus\n\nMulti-device project workbench.\n"
        let file = try await connection.readFile(projectID: "HEPH", path: "README.md")
        XCTAssertEqual(file.data, Data(content.utf8))
        XCTAssertEqual(file.revision, Revision.of(Data(content.utf8)))
        XCTAssertEqual(file.size, content.utf8.count)
    }

    func testUnavailable() async throws {
        let workspace = Workspace.preview()
        let connection = try XCTUnwrap(workspace.connection(studioID))
        do {
            _ = try await connection.createTicket(projectID: "HEPH", name: "New ticket")
            XCTFail("createTicket succeeded in a preview")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }
}
