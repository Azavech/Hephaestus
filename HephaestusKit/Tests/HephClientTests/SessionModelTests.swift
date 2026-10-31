import Foundation
import XCTest
@testable import HephClient
@testable import HephCore
@testable import HephNet

@MainActor
final class SessionModelTests: XCTestCase {
    private let sessionID = UUID()

    /// The 2,000 `system` events of the log, texts `e0`…`e1999`.
    private let log: [SessionEvent] = (0..<2_000).map { index in
        SessionEvent(id: "event-\(index)", at: TestMesh.updatedAt, type: .system, text: "e\(index)")
    }

    /// A loaded store whose project has the session, and a `SessionModel` of it after `appear()`.
    private func appearedModel(configure: (FakeMain) -> Void) async throws
        -> (model: SessionModel, fakeMain: FakeMain) {
        let mainID = UUID()
        let session = SessionInfo(id: sessionID, kind: .project, title: "Chat", created: TestMesh.updatedAt,
                                  updated: TestMesh.updatedAt, permissionMode: .acceptEdits, allowsAllTools: false,
                                  status: .idle, pendingPermissions: [])
        let (workspace, fakeMain, _) = try await connectedWorkspace(
            projects: [TestMesh.summary("HEPH", mainID: mainID)], mainID: mainID
        ) { fakeMain in
            fakeMain.answer("projects.snapshot",
                            with: ProjectsSnapshotResult(project: TestMesh.project("HEPH", mainID: mainID), tasks: [],
                                                         bundles: [], sessions: [session], runs: []))
            configure(fakeMain)
        }
        let store = workspace.projectStore(mainDeviceID: mainID, projectID: "HEPH")
        try await waitUntil { store.phase == .loaded }
        let model = SessionModel(workspace: workspace, store: store, sessionID: sessionID)
        model.appear()
        addTeardownBlock { @MainActor in
            model.disappear()
        }
        try await waitUntil { model.phase == .loaded }
        return (model, fakeMain)
    }

    private func texts(_ items: [TranscriptItem]) -> [String] {
        items.map { item in
            if case .system(let text) = item {
                return text.text
            }
            return "?"
        }
    }

    func testPaging() async throws {
        let (model, fakeMain) = try await appearedModel { fakeMain in
            fakeMain.answer("sessions.history",
                            with: SessionsHistoryResult(events: Array(log[1_000...]), firstIndex: 1_000, total: 2_000))
            fakeMain.answer("sessions.history",
                            with: SessionsHistoryResult(events: Array(log[..<1_000]), firstIndex: 0, total: 2_000))
        }
        XCTAssertTrue(model.hasEarlier)
        XCTAssertEqual(model.firstIndex, 1_000)
        XCTAssertEqual(texts(model.items), (1_000..<2_000).map { "e\($0)" })

        try await model.loadEarlier()
        let requests = fakeMain.requests("sessions.history")
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].json["before"])
        XCTAssertEqual(requests[1].json["before"] as? Int, 1_000)
        XCTAssertEqual(texts(model.items), (0..<2_000).map { "e\($0)" })
        XCTAssertFalse(model.hasEarlier)
        XCTAssertFalse(model.isLoadingEarlier)
    }

    func testLoadEarlierFailure() async throws {
        let (model, _) = try await appearedModel { fakeMain in
            fakeMain.answer("sessions.history",
                            with: SessionsHistoryResult(events: Array(log[1_000...]), firstIndex: 1_000, total: 2_000))
            fakeMain.fail("sessions.history", with: ProtocolError(.internal, "The log cannot be read."))
        }
        let items = model.items
        do {
            try await model.loadEarlier()
            XCTFail("loadEarlier() succeeded")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.message, "The log cannot be read.")
        }
        XCTAssertEqual(model.items, items)
        XCTAssertEqual(model.firstIndex, 1_000)
        XCTAssertFalse(model.isLoadingEarlier)
    }
}
