import Foundation
import XCTest
@testable import HephClient
@testable import HephCore
@testable import HephNet

@MainActor
final class ProjectStoreTests: XCTestCase {
    private let start = TestMesh.updatedAt

    private func session(_ id: UUID = UUID(), created: Date, pending: [PermissionRequest] = []) -> SessionInfo {
        SessionInfo(id: id, kind: .project, title: "Chat", created: created, updated: created,
                    permissionMode: .acceptEdits, allowsAllTools: false, status: pending.isEmpty ? .idle : .waitingPermission,
                    pendingPermissions: pending)
    }

    private func snapshot(_ projectID: String = "HEPH", mainID: UUID, tickets: [TicketItem] = [],
                          sessions: [SessionInfo] = []) -> ProjectsSnapshotResult {
        ProjectsSnapshotResult(project: TestMesh.project(projectID, mainID: mainID), tickets: tickets, bundles: [],
                               sessions: sessions)
    }

    /// A connected workspace whose Main hosts HEPH, and the loaded store of HEPH.
    private func loadedStore(_ snapshot: (UUID) -> ProjectsSnapshotResult) async throws
        -> (workspace: Workspace, fakeMain: FakeMain, store: ProjectStore) {
        let mainID = UUID()
        let (workspace, fakeMain, _) = try await connectedWorkspace(
            projects: [TestMesh.summary("HEPH", mainID: mainID)], mainID: mainID
        ) { fakeMain in
            fakeMain.answer("projects.snapshot", with: snapshot(mainID))
        }
        let store = workspace.projectStore(mainDeviceID: mainID, projectID: "HEPH")
        try await waitUntil { store.phase == .loaded }
        return (workspace, fakeMain, store)
    }

    func testSnapshotSorted() async throws {
        let early = session(created: start)
        let late = session(created: start.addingTimeInterval(60))
        let (_, _, store) = try await loadedStore { mainID in
            self.snapshot(mainID: mainID, tickets: [TestMesh.ticket("HEPH-10"), TestMesh.ticket("HEPH-2")],
                          sessions: [late, early])
        }
        XCTAssertEqual(store.tickets.map(\.id), ["HEPH-2", "HEPH-10"])
        XCTAssertEqual(store.sessions.map(\.id), [early.id, late.id])
        XCTAssertNotNil(store.project)
    }

    func testIdempotentEvents() async throws {
        let (_, fakeMain, store) = try await loadedStore { mainID in
            self.snapshot(mainID: mainID, tickets: [TestMesh.ticket("HEPH-1", name: "Old")])
        }
        let changed = TestMesh.ticket("HEPH-1", name: "New", updated: start.addingTimeInterval(60))
        fakeMain.emit(.ticketChanged(TicketChangedPayload(projectID: "HEPH", ticket: changed)))
        fakeMain.emit(.ticketChanged(TicketChangedPayload(projectID: "HEPH", ticket: changed)))
        // A marker applied after both events.
        fakeMain.emit(.ticketChanged(TicketChangedPayload(projectID: "HEPH", ticket: TestMesh.ticket("HEPH-3"))))
        try await waitUntil { store.ticket("HEPH-3") != nil }
        XCTAssertEqual(store.tickets, [changed, TestMesh.ticket("HEPH-3")])

        fakeMain.emit(.ticketRemoved(TicketRemovedPayload(projectID: "HEPH", ticketID: "HEPH-99")))
        fakeMain.emit(.ticketChanged(TicketChangedPayload(projectID: "HEPH", ticket: TestMesh.ticket("HEPH-4"))))
        try await waitUntil { store.ticket("HEPH-4") != nil }
        XCTAssertEqual(store.tickets.map(\.id), ["HEPH-1", "HEPH-3", "HEPH-4"])
        XCTAssertEqual(store.ticket("HEPH-1"), changed)
    }

    func testEventsDuringLoad() async throws {
        let mainID = UUID()
        let (workspace, fakeMain, _) = try await connectedWorkspace(
            projects: [TestMesh.summary("HEPH", mainID: mainID)], mainID: mainID
        ) { fakeMain in
            fakeMain.answer("projects.snapshot",
                            with: self.snapshot(mainID: mainID, tickets: [TestMesh.ticket("HEPH-1", name: "Old")]),
                            after: .milliseconds(300))
        }
        let store = workspace.projectStore(mainDeviceID: mainID, projectID: "HEPH")
        try await waitUntil { fakeMain.requests("projects.snapshot").count == 1 }
        XCTAssertEqual(store.phase, .loading)
        let newer = TestMesh.ticket("HEPH-1", name: "New", updated: start.addingTimeInterval(60))
        fakeMain.emit(.ticketChanged(TicketChangedPayload(projectID: "HEPH", ticket: newer)))

        try await waitUntil { store.phase == .loaded }
        XCTAssertEqual(store.ticket("HEPH-1"), newer)
    }

    func testUnknownSession() async throws {
        let (_, fakeMain, store) = try await loadedStore { mainID in
            self.snapshot(mainID: mainID, sessions: [self.session(created: self.start)])
        }
        XCTAssertEqual(fakeMain.requests("projects.snapshot").count, 1)
        let unknown = UUID()
        let event = SessionEvent(id: "e1", at: start, type: .system, text: "Started")
        fakeMain.emit(.sessionEvent(SessionEventPayload(projectID: "HEPH", sessionID: unknown, event: event)))
        try await waitUntil { fakeMain.requests("projects.snapshot").count == 2 }
        try await waitUntil { store.phase == .loaded }
    }

    func testRemovedProject() async throws {
        let (workspace, fakeMain, store) = try await loadedStore { mainID in
            self.snapshot(mainID: mainID)
        }
        let mainID = fakeMain.device.id
        fakeMain.emit(.projectsChanged(ProjectsChangedPayload(deviceID: mainID, projects: [])))
        try await waitUntil { store.isRemoved }
        let newStore = workspace.projectStore(mainDeviceID: mainID, projectID: "HEPH")
        XCTAssertFalse(newStore === store)
        XCTAssertFalse(newStore.isRemoved)
    }

    func testResultInserted() async throws {
        let original = TestMesh.ticket("HEPH-1", name: "Original")
        let (workspace, fakeMain, store) = try await loadedStore { mainID in
            self.snapshot(mainID: mainID, tickets: [original])
        }
        let connection = try XCTUnwrap(workspace.connection(fakeMain.device.id))
        let created = TestMesh.ticket("HEPH-5", name: "Created")
        fakeMain.answer("tickets.create", with: created)
        _ = try await connection.createTicket(projectID: "HEPH", name: "Created")
        XCTAssertEqual(store.ticket("HEPH-5"), created)

        fakeMain.answer("tickets.update", with: TestMesh.ticket("HEPH-1", name: "Changed"))
        let result = try await connection.updateTicket(projectID: "HEPH", ticketID: "HEPH-1", patch: TicketPatch(name: "x"))
        XCTAssertEqual(result.name, "Changed")
        XCTAssertEqual(store.ticket("HEPH-1"), original)
        XCTAssertEqual(store.tickets.map(\.id), ["HEPH-1", "HEPH-5"])
    }

    func testPendingPermissions() async throws {
        let mainID = UUID()
        let request = PermissionRequest(requestID: "perm-1", toolName: "Bash", input: #"{"command":"ls"}"#,
                                        suggestions: "[]")
        let pendingSession = session(created: start, pending: [request])
        let (workspace, fakeMain, _) = try await connectedWorkspace(projects: [], mainID: mainID) { fakeMain in
            fakeMain.answer("projects.snapshot",
                            with: self.snapshot("API", mainID: mainID, sessions: [pendingSession]))
        }
        let tree = [TestMesh.summary("HEPH", mainID: mainID,
                                     children: [TestMesh.summary("API", mainID: mainID, pendingPermissionCount: 1)])]
        fakeMain.emit(.projectsChanged(ProjectsChangedPayload(deviceID: mainID, projects: tree)))

        try await waitUntil { fakeMain.requests("projects.snapshot").count == 1 }
        XCTAssertEqual(fakeMain.requests("projects.snapshot").first?.json, ["projectID": "API"])
        try await waitUntil { !workspace.sessionCenter.pendingPermissions.isEmpty }
        let pending = try XCTUnwrap(workspace.sessionCenter.pendingPermissions.first)
        XCTAssertEqual(pending.request, request)
        XCTAssertEqual(pending.mainID, mainID)
        XCTAssertEqual(pending.projectID, "API")
        XCTAssertEqual(pending.sessionID, pendingSession.id)
    }
}
