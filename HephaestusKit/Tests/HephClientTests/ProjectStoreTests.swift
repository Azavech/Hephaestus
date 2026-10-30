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
                    permissionMode: .acceptEdits, status: pending.isEmpty ? .idle : .waitingPermission,
                    pendingPermissions: pending)
    }

    private func run(_ id: UUID = UUID(), minute: Int, state: RunState = .succeeded) -> RunInfo {
        RunInfo(id: id, projectID: "HEPH", name: "Test", command: "./scripts/test.sh",
                startedAt: start.addingTimeInterval(TimeInterval(minute * 60)),
                endedAt: state == .running ? nil : start.addingTimeInterval(TimeInterval(minute * 60 + 30)),
                exitCode: state == .running ? nil : 0, state: state)
    }

    private func snapshot(_ projectID: String = "HEPH", mainID: UUID, tasks: [TaskItem] = [],
                          sessions: [SessionInfo] = [], runs: [RunInfo] = []) -> ProjectsSnapshotResult {
        ProjectsSnapshotResult(project: TestMesh.project(projectID, mainID: mainID), tasks: tasks, sessions: sessions,
                               runs: runs)
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
        let firstRun = run(minute: 1)
        let secondRun = run(minute: 2)
        let (_, _, store) = try await loadedStore { mainID in
            self.snapshot(mainID: mainID, tasks: [TestMesh.task("HEPH-10"), TestMesh.task("HEPH-2")],
                          sessions: [late, early], runs: [secondRun, firstRun])
        }
        XCTAssertEqual(store.tasks.map(\.id), ["HEPH-2", "HEPH-10"])
        XCTAssertEqual(store.sessions.map(\.id), [early.id, late.id])
        XCTAssertEqual(store.runs.map(\.id), [firstRun.id, secondRun.id])
        XCTAssertNotNil(store.project)
    }

    func testIdempotentEvents() async throws {
        let (_, fakeMain, store) = try await loadedStore { mainID in
            self.snapshot(mainID: mainID, tasks: [TestMesh.task("HEPH-1", name: "Old")])
        }
        let changed = TestMesh.task("HEPH-1", name: "New", updated: start.addingTimeInterval(60))
        fakeMain.emit(.taskChanged(TaskChangedPayload(projectID: "HEPH", task: changed)))
        fakeMain.emit(.taskChanged(TaskChangedPayload(projectID: "HEPH", task: changed)))
        // A marker applied after both events.
        fakeMain.emit(.taskChanged(TaskChangedPayload(projectID: "HEPH", task: TestMesh.task("HEPH-3"))))
        try await waitUntil { store.task("HEPH-3") != nil }
        XCTAssertEqual(store.tasks, [changed, TestMesh.task("HEPH-3")])

        fakeMain.emit(.taskRemoved(TaskRemovedPayload(projectID: "HEPH", taskID: "HEPH-99")))
        fakeMain.emit(.taskChanged(TaskChangedPayload(projectID: "HEPH", task: TestMesh.task("HEPH-4"))))
        try await waitUntil { store.task("HEPH-4") != nil }
        XCTAssertEqual(store.tasks.map(\.id), ["HEPH-1", "HEPH-3", "HEPH-4"])
        XCTAssertEqual(store.task("HEPH-1"), changed)
    }

    func testEventsDuringLoad() async throws {
        let mainID = UUID()
        let (workspace, fakeMain, _) = try await connectedWorkspace(
            projects: [TestMesh.summary("HEPH", mainID: mainID)], mainID: mainID
        ) { fakeMain in
            fakeMain.answer("projects.snapshot",
                            with: self.snapshot(mainID: mainID, tasks: [TestMesh.task("HEPH-1", name: "Old")]),
                            after: .milliseconds(300))
        }
        let store = workspace.projectStore(mainDeviceID: mainID, projectID: "HEPH")
        try await waitUntil { fakeMain.requests("projects.snapshot").count == 1 }
        XCTAssertEqual(store.phase, .loading)
        let newer = TestMesh.task("HEPH-1", name: "New", updated: start.addingTimeInterval(60))
        fakeMain.emit(.taskChanged(TaskChangedPayload(projectID: "HEPH", task: newer)))

        try await waitUntil { store.phase == .loaded }
        XCTAssertEqual(store.task("HEPH-1"), newer)
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

    func testRunsTrim() async throws {
        let finished = (0..<21).map { run(minute: $0) }
        let running = run(minute: 30, state: .running)
        let (_, _, store) = try await loadedStore { mainID in
            self.snapshot(mainID: mainID, runs: finished + [running])
        }
        XCTAssertEqual(store.runs.count, 20)
        XCTAssertEqual(store.runs.map(\.id), finished.suffix(19).map(\.id) + [running.id])
        XCTAssertTrue(store.runs.contains { $0.state == .running })
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
        let original = TestMesh.task("HEPH-1", name: "Original")
        let (workspace, fakeMain, store) = try await loadedStore { mainID in
            self.snapshot(mainID: mainID, tasks: [original])
        }
        let connection = try XCTUnwrap(workspace.connection(fakeMain.device.id))
        let created = TestMesh.task("HEPH-5", name: "Created")
        fakeMain.answer("tasks.create", with: created)
        _ = try await connection.createTask(projectID: "HEPH", name: "Created")
        XCTAssertEqual(store.task("HEPH-5"), created)

        fakeMain.answer("tasks.update", with: TestMesh.task("HEPH-1", name: "Changed"))
        let result = try await connection.updateTask(projectID: "HEPH", taskID: "HEPH-1", patch: TaskPatch(name: "x"))
        XCTAssertEqual(result.name, "Changed")
        XCTAssertEqual(store.task("HEPH-1"), original)
        XCTAssertEqual(store.tasks.map(\.id), ["HEPH-1", "HEPH-5"])
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
