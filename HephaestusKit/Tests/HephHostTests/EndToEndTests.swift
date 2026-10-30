#if os(macOS)
import Foundation
import XCTest
@testable import HephClient
@testable import HephCore
@testable import HephHost
@testable import HephNet

/// End to end (docs/testing.md, "EndToEndTests"; docs/services/host.md, docs/client/workspace.md): a TestHost and a
/// Workspace of another device, connected through a TLS-PSK WebSocket on 127.0.0.1.
@MainActor
final class EndToEndTests: XCTestCase {
    func testWorkspaceAgainstHost() async throws {
        let testHost = try await startTestHost()
        let hostID = testHost.identity.id
        let hostDevice = await testHost.host.mesh.localDevice()
        XCTAssertEqual(hostDevice.id, hostID)

        // The host's record, as the Workspace's cached registry holds it.
        let now = Date()
        let record = DeviceRecord(id: hostID, name: hostDevice.name, platform: hostDevice.platform, isMain: true,
                                  addresses: ["127.0.0.1"], port: testHost.port, appVersion: hostDevice.appVersion,
                                  build: hostDevice.build, pairedAt: now, updatedAt: now, revoked: false)
        let registry = MeshSnapshot(meshID: testCredentials.meshID, devices: [record], presence: [])
        let cacheRoot = try makeTemporaryDirectory().appendingPathComponent("Attachments", isDirectory: true)
        let environment = WorkspaceEnvironment(
            loadCredentials: { testCredentials },
            saveCredentials: { _ in },
            loadRegistry: { registry },
            saveRegistry: { _ in },
            saveDevice: { _ in },
            openChannel: { url, credentials in
                try await WebSocketChannel.connect(url: url, credentials: credentials, timeout: .seconds(5))
            },
            browse: { _ in { @Sendable in } },
            sleep: { duration in try await Task.sleep(for: duration) },
            now: { Date() },
            attachmentCache: AttachmentCache(root: cacheRoot)
        )
        let device = DeviceInfo(id: UUID(), name: "Sam's iPad", platform: .iPadOS, isMain: false, appVersion: "1.0",
                                build: 1)
        let workspace = Workspace(device: device, environment: environment)
        let recorder = EventRecorder(workspace: workspace)
        addTeardownBlock { @MainActor in
            recorder.stop()
            workspace.stop()
        }
        workspace.start()

        try await waitUntil { workspace.connection(hostID)?.isConnected == true }
        let connection = try XCTUnwrap(workspace.connection(hostID))

        // 1. createProject → ProjectSummary HEPH; projects.changed; `projects` contains HEPH.
        var mark = recorder.count
        let summary = try await connection.createProject(name: "Hephaestus", identifier: "HEPH")
        XCTAssertEqual(summary.id, "HEPH")
        try await waitUntil {
            recorder.events(since: mark).contains { event in
                guard case .projectsChanged(let payload) = event else { return false }
                return payload.deviceID == hostID && payload.projects.contains { $0.id == "HEPH" }
            }
        }
        try await waitUntil { connection.projects.contains { $0.id == "HEPH" } }
        let store = workspace.projectStore(mainDeviceID: hostID, projectID: "HEPH")
        try await waitUntil { store.phase == .loaded }

        // 2. createTask → HEPH-1, status todo; task.changed; the store of HEPH has HEPH-1.
        mark = recorder.count
        let created = try await connection.createTask(projectID: "HEPH", name: "Sidebar breaks on iPad")
        XCTAssertEqual(created.id, "HEPH-1")
        XCTAssertEqual(created.status, .todo)
        try await waitUntil {
            recorder.events(since: mark).contains { event in
                guard case .taskChanged(let payload) = event else { return false }
                return payload.projectID == "HEPH" && payload.task.id == "HEPH-1"
            }
        }
        try await waitUntil { store.task("HEPH-1") != nil }

        // 3. updateTask with status review → status review; task.changed with status review.
        mark = recorder.count
        let updated = try await connection.updateTask(projectID: "HEPH", taskID: "HEPH-1",
                                                      patch: TaskPatch(status: .review))
        XCTAssertEqual(updated.status, .review)
        try await waitUntil {
            recorder.events(since: mark).contains { event in
                guard case .taskChanged(let payload) = event else { return false }
                return payload.task.id == "HEPH-1" && payload.task.status == .review
            }
        }

        // 4. upload of 1 KiB, then addComment "Screenshot" with its UploadRef → one comment with shot.png;
        //    task.changed.
        let screenshot = Data((0..<1024).map { UInt8(truncatingIfNeeded: $0) })
        let reference = try await connection.upload(fileName: "shot.png", projectID: "HEPH",
                                                    source: .data(screenshot), progress: { _ in })
        mark = recorder.count
        let commented = try await connection.addComment(projectID: "HEPH", taskID: "HEPH-1", body: "Screenshot",
                                                        attachments: [reference])
        XCTAssertEqual(commented.comments.count, 1)
        XCTAssertEqual(commented.comments.first?.body, "Screenshot")
        XCTAssertEqual(commented.comments.first?.attachments.map(\.file), ["shot.png"])
        try await waitUntil {
            recorder.events(since: mark).contains { event in
                guard case .taskChanged(let payload) = event else { return false }
                return payload.task.id == "HEPH-1" && payload.task.comments.count == 1
            }
        }

        // 5. downloadAttachment → a file of the attachment cache holding the 1 KiB.
        let downloaded = try await connection.downloadAttachment(projectID: "HEPH", taskID: "HEPH-1",
                                                                 fileName: "shot.png", size: 1024, progress: { _ in })
        XCTAssertTrue(downloaded.standardizedFileURL.path.hasPrefix(cacheRoot.standardizedFileURL.path + "/"))
        XCTAssertEqual(try Data(contentsOf: downloaded), screenshot)

        // 6. writeFile notes.md "a" without a base revision → revision r1; files.changed with notes.md (15 s).
        mark = recorder.count
        let revision = try await connection.writeFile(projectID: "HEPH", path: "notes.md", data: Data("a".utf8),
                                                      baseRevision: nil)
        XCTAssertFalse(revision.isEmpty)
        try await waitUntil(timeout: .seconds(15)) {
            recorder.events(since: mark).contains { event in
                guard case .filesChanged(let payload) = event else { return false }
                return payload.projectID == "HEPH" && payload.paths.contains("notes.md")
            }
        }

        // 7. readFile notes.md → data "a", revision r1.
        let read = try await connection.readFile(projectID: "HEPH", path: "notes.md")
        XCTAssertEqual(read.data, Data("a".utf8))
        XCTAssertEqual(read.revision, revision)

        // 8. writeFile notes.md "b" on the base revision 0000000000000000 → conflict.
        await assertProtocolError(.conflict) {
            try await connection.writeFile(projectID: "HEPH", path: "notes.md", data: Data("b".utf8),
                                           baseRevision: "0000000000000000")
        }

        // 9. openTab locked → a locked WebTab; project.changed with the tab.
        mark = recorder.count
        let tab = try await connection.openTab(projectID: "HEPH", url: "https://example.com", locked: true)
        XCTAssertTrue(tab.locked)
        XCTAssertEqual(tab.url, "https://example.com")
        try await waitUntil {
            recorder.events(since: mark).contains { event in
                guard case .projectChanged(let payload) = event else { return false }
                return payload.project.id == "HEPH" && payload.project.webTabs.contains(tab)
            }
        }

        // 10. closeTab of that tab → locked.
        await assertProtocolError(.locked) {
            try await connection.closeTab(projectID: "HEPH", tabID: tab.id)
        }

        // 11. search "sidebar" → a result of kind tasks for HEPH-1.
        let results = try await connection.search(query: "sidebar")
        XCTAssertTrue(results.contains { $0.kind == .tasks && $0.projectID == "HEPH" && $0.itemID == "HEPH-1" },
                      "\(results)")
    }
}

/// Records the server events of a Workspace's `events()` stream, in arrival order.
@MainActor
private final class EventRecorder {
    private(set) var received: [ServerEvent] = []
    private var task: Task<Void, Never>?

    init(workspace: Workspace) {
        let stream = workspace.events()
        task = Task { [weak self] in
            for await event in stream {
                guard case .event(_, let serverEvent) = event else { continue }
                self?.received.append(serverEvent)
            }
        }
    }

    /// The number of events received so far.
    var count: Int { received.count }

    /// The events received after the first `index` ones.
    func events(since index: Int) -> ArraySlice<ServerEvent> {
        received[min(index, received.count)...]
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
#endif
