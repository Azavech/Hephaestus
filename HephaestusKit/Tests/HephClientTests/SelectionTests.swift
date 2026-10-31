import Foundation
import XCTest
@testable import HephClient
@testable import HephCore
@testable import HephNet

@MainActor
final class SelectionTests: XCTestCase {
    /// A connected workspace whose Main hosts HEPH with its sub project API, and a selection on API.
    private func selectionOnSubproject() async throws
        -> (workspace: Workspace, fakeMain: FakeMain, selection: Selection) {
        let mainID = UUID()
        let tree = [TestMesh.summary("HEPH", mainID: mainID, children: [TestMesh.summary("API", mainID: mainID)])]
        let (workspace, fakeMain, _) = try await connectedWorkspace(projects: tree, mainID: mainID)
        let selection = workspace.makeSelection()
        selection.mainDeviceID = mainID
        selection.projectID = "API"
        selection.section = .tickets
        selection.item = "API-1"
        return (workspace, fakeMain, selection)
    }

    private func progress(_ migrationID: UUID, projectID: String, from: UUID, to: UUID,
                          state: MigrationState) -> ServerEvent {
        .migrationProgress(MigrationProgressPayload(migrationID: migrationID, projectID: projectID, fromDeviceID: from,
                                                    toDeviceID: to, state: state, bytesDone: 0, bytesTotal: 0))
    }

    func testMainGone() async throws {
        let (workspace, fakeMain, selection) = try await selectionOnSubproject()
        let mainID = fakeMain.device.id
        var revoked = fakeMain.snapshot
        let index = try XCTUnwrap(revoked.devices.firstIndex { $0.id == mainID })
        revoked.devices[index].revoked = true
        revoked.devices[index].updatedAt = TestEnvironment.now
        fakeMain.emit(.meshChanged(MeshChangedPayload(snapshot: revoked)))

        try await waitUntil { selection.mainDeviceID == nil }
        XCTAssertNil(selection.projectID)
        XCTAssertNil(selection.item)
        XCTAssertEqual(selection.section, .tickets)
        XCTAssertNil(workspace.connection(mainID))
    }

    func testSubprojectRemoved() async throws {
        let (_, fakeMain, selection) = try await selectionOnSubproject()
        let mainID = fakeMain.device.id
        fakeMain.emit(.projectsChanged(ProjectsChangedPayload(deviceID: mainID,
                                                              projects: [TestMesh.summary("HEPH", mainID: mainID)])))
        try await waitUntil { selection.projectID == "HEPH" }
        XCTAssertNil(selection.item)
        XCTAssertEqual(selection.mainDeviceID, mainID)
        XCTAssertEqual(selection.section, .tickets)
    }

    func testMigrationWaits() async throws {
        let (workspace, fakeMain, selection) = try await selectionOnSubproject()
        let mainID = fakeMain.device.id
        let destination = UUID()
        let migrationID = UUID()
        fakeMain.emit(progress(migrationID, projectID: "HEPH", from: mainID, to: destination, state: .committing))
        fakeMain.emit(.projectsChanged(ProjectsChangedPayload(deviceID: mainID, projects: [])))
        try await waitUntil { workspace.connection(mainID)?.projects.isEmpty == true }
        XCTAssertEqual(workspace.migrations[migrationID]?.state, .committing)
        XCTAssertEqual(selection.mainDeviceID, mainID)
        XCTAssertEqual(selection.projectID, "API")
        XCTAssertEqual(selection.section, .tickets)
        XCTAssertEqual(selection.item, "API-1")
    }

    func testMigrationMoves() async throws {
        let (workspace, fakeMain, selection) = try await selectionOnSubproject()
        let mainID = fakeMain.device.id
        let destination = UUID()
        let migrationID = UUID()
        fakeMain.emit(progress(migrationID, projectID: "HEPH", from: mainID, to: destination, state: .committing))
        fakeMain.emit(.projectsChanged(ProjectsChangedPayload(deviceID: mainID, projects: [])))
        try await waitUntil { workspace.connection(mainID)?.projects.isEmpty == true }
        XCTAssertEqual(selection.mainDeviceID, mainID)

        fakeMain.emit(progress(migrationID, projectID: "HEPH", from: mainID, to: destination, state: .completed))
        try await waitUntil { selection.mainDeviceID == destination }
        XCTAssertEqual(selection.projectID, "API")
        XCTAssertEqual(selection.section, .tickets)
        XCTAssertEqual(selection.item, "API-1")
    }

    func testProjectAppeared() async throws {
        let first = TestMesh.main("Studio")
        let second = TestMesh.main("Sam's MacBook Pro")
        let registry = TestMesh.registry([(first, "Sams-Mac-mini.local"), (second, "198.51.100.2")])
        let firstMain = TestMesh.fakeMain(first, registry: registry)
        let secondMain = TestMesh.fakeMain(second, registry: registry)
        let environment = makeEnvironment(fakeMains: ["Sams-Mac-mini.local": firstMain, "198.51.100.2": secondMain],
                                          registry: registry)
        let workspace = startWorkspace(environment)
        try await waitUntil {
            workspace.connection(first.id)?.projectsLoaded == true
                && workspace.connection(second.id)?.projectsLoaded == true
        }
        let selection = workspace.makeSelection()
        selection.mainDeviceID = first.id
        selection.projectID = "HEPH"
        selection.section = .overview

        secondMain.emit(.projectsChanged(ProjectsChangedPayload(deviceID: second.id,
                                                                projects: [TestMesh.summary("HEPH",
                                                                                            mainID: second.id)])))
        try await waitUntil { selection.mainDeviceID == second.id }
        XCTAssertEqual(selection.projectID, "HEPH")
        XCTAssertEqual(selection.section, .overview)
    }

    func testFeedbackSelection() {
        let mainID = UUID()
        let selection = Selection(mainDeviceID: mainID, projectID: "HEPH", section: .tickets, item: "HEPH-12")
        XCTAssertEqual(selection.feedbackSelection,
                       FeedbackSelection(mainDeviceID: mainID, projectID: "HEPH", section: "tickets", item: "HEPH-12"))
        XCTAssertEqual(Selection().feedbackSelection, FeedbackSelection())
    }

    func testWeak() async throws {
        let (workspace, fakeMain, _) = try await connectedWorkspace()
        let mainID = fakeMain.device.id
        weak var released: Selection?
        do {
            let selection = workspace.makeSelection()
            selection.mainDeviceID = mainID
            released = selection
        }
        XCTAssertNil(released)

        // A registry change runs the rules over the selections still alive.
        let kept = workspace.makeSelection()
        kept.mainDeviceID = mainID
        var revoked = fakeMain.snapshot
        let index = try XCTUnwrap(revoked.devices.firstIndex { $0.id == mainID })
        revoked.devices[index].revoked = true
        revoked.devices[index].updatedAt = TestEnvironment.now
        fakeMain.emit(.meshChanged(MeshChangedPayload(snapshot: revoked)))
        try await waitUntil { kept.mainDeviceID == nil }
        XCTAssertNil(released)
    }
}
