import Foundation
import XCTest
@testable import HephClient
@testable import HephCore
@testable import HephNet

@MainActor
final class ConnectionTests: XCTestCase {
    /// The events of a workspace, recorded from the moment of the call.
    private final class EventLog {
        var events: [WorkspaceEvent] = []
        var task: Task<Void, Never>?
    }

    private final class Counts {
        var values: [Int] = []
    }

    private func record(_ workspace: Workspace) -> EventLog {
        let log = EventLog()
        let stream = workspace.events()
        log.task = Task { @MainActor in
            for await event in stream {
                log.events.append(event)
            }
        }
        addTeardownBlock { @MainActor in
            log.task?.cancel()
        }
        return log
    }

    private func isConnectedEvent(_ event: WorkspaceEvent, _ mainID: UUID) -> Bool {
        if case .connected(let id) = event {
            return id == mainID
        }
        return false
    }

    func testConnects() async throws {
        let device = TestMesh.main("Studio")
        let registry = TestMesh.registry([(device, "Sams-Mac-mini.local")])
        let project = TestMesh.summary("HEPH", mainID: device.id)
        let skill = SkillSummary(name: "release-notes", description: "Notes", modified: TestMesh.updatedAt)
        let fakeMain = FakeMain(device: device, snapshot: registry)
        fakeMain.answer("host.info", with: TestMesh.hostInfo(device))
        fakeMain.answer("projects.list", with: ProjectsListResult(projects: [project]))
        fakeMain.answer("skills.list", with: SkillsListResult(skills: [skill]))
        let environment = makeEnvironment(fakeMains: ["Sams-Mac-mini.local": fakeMain], registry: registry)
        let workspace = Workspace(device: TestMesh.local, environment: environment.environment)
        let log = record(workspace)
        workspace.start()
        addTeardownBlock { @MainActor in
            workspace.stop()
        }

        let connection = try XCTUnwrap(workspace.connection(device.id))
        try await waitUntil { connection.state == .connected }
        try await waitUntil { connection.hostInfo != nil && connection.projectsLoaded && connection.skillsLoaded }
        XCTAssertEqual(connection.serverDevice, device)
        XCTAssertEqual(connection.hostInfo, TestMesh.hostInfo(device))
        XCTAssertEqual(connection.projects, [project])
        XCTAssertEqual(connection.skills, [skill])
        XCTAssertEqual(connection.connectedAddress, "Sams-Mac-mini.local")
        try await waitUntil { log.events.contains { self.isConnectedEvent($0, device.id) } }
        XCTAssertEqual(fakeMain.requests.first?.method, "hello")
    }

    func testNextAddress() async throws {
        let device = TestMesh.main("Studio")
        let other = TestMesh.main("Sam's MacBook Pro")
        let registry = MeshSnapshot(
            meshID: testCredentials.meshID,
            devices: [TestMesh.record(device, addresses: ["198.51.100.2", "Sams-Mac-mini.local"]),
                      TestMesh.record(TestMesh.local)],
            presence: []
        )
        let fakeMain = TestMesh.fakeMain(device, registry: registry)
        let otherMain = TestMesh.fakeMain(other, registry: registry)
        let environment = makeEnvironment(fakeMains: ["Sams-Mac-mini.local": fakeMain, "198.51.100.2": otherMain],
                                          registry: registry)
        let workspace = startWorkspace(environment)

        let connection = try XCTUnwrap(workspace.connection(device.id))
        try await waitUntil { connection.isConnected }
        XCTAssertEqual(connection.connectedAddress, "Sams-Mac-mini.local")
        XCTAssertEqual(environment.openedHosts.prefix(2), ["198.51.100.2", "Sams-Mac-mini.local"])
        XCTAssertEqual(otherMain.channelCount, 1)
        XCTAssertNotEqual(otherMain.serverChannels.first?.state, .open)
        XCTAssertEqual(fakeMain.serverChannels.first?.state, .open)
    }

    func testRevoked() async throws {
        let device = TestMesh.main("Studio")
        let registry = TestMesh.registry([(device, "Sams-Mac-mini.local")])
        let fakeMain = TestMesh.fakeMain(device, registry: registry)
        fakeMain.helloError = ProtocolError(.unauthorized, "This device was removed from the mesh")
        let environment = makeEnvironment(fakeMains: ["Sams-Mac-mini.local": fakeMain], registry: registry)
        let workspace = startWorkspace(environment)

        let connection = try XCTUnwrap(workspace.connection(device.id))
        let revoked = ConnectionState.failed(message: "This device was removed from the mesh", retryAt: nil)
        try await waitUntil { connection.state == revoked }
        XCTAssertEqual(environment.sleeps, [])
        XCTAssertEqual(fakeMain.requests("hello").count, 1)

        // A new advert of M with another mesh tag starts no attempt.
        let otherMesh = MeshCredentials(meshID: UUID(), meshKey: testCredentials.meshKey)
        let advert = BonjourAdvert(id: device.id, name: device.name, meshTag: MeshCrypto.meshTag(otherMesh),
                                   protocolVersion: WireCoding.protocolVersion, host: "Sams-Mac-mini.local",
                                   port: 47100, pairingOpen: false)
        XCTAssertNotEqual(advert.meshTag, MeshCrypto.meshTag(testCredentials))
        environment.setAdverts([advert])
        try await waitUntil { workspace.seenHosts[device.id] == advert }
        // An attempt started by the list would have set the state to connecting before this task resumes.
        await Task.yield()
        XCTAssertEqual(connection.state, revoked)
        XCTAssertEqual(environment.openedHosts.count, 1)
        XCTAssertEqual(fakeMain.requests("hello").count, 1)

        workspace.retryNow()
        try await waitUntil { fakeMain.requests("hello").count == 2 }
        try await waitUntil { connection.state == revoked }
        XCTAssertEqual(environment.sleeps, [])
    }

    func testIncompatible() async throws {
        let device = TestMesh.main("Studio")
        let registry = TestMesh.registry([(device, "Sams-Mac-mini.local")])
        let fakeMain = TestMesh.fakeMain(device, registry: registry)
        fakeMain.helloError = ProtocolError(.badRequest, "Unsupported protocol version 1")
        let environment = makeEnvironment(fakeMains: ["Sams-Mac-mini.local": fakeMain], registry: registry)
        environment.holdSleeps(true)
        let workspace = startWorkspace(environment)

        let connection = try XCTUnwrap(workspace.connection(device.id))
        try await waitUntil { environment.heldSleepCount == 1 }
        XCTAssertEqual(connection.state, .failed(message: "Incompatible version",
                                                 retryAt: TestEnvironment.now.addingTimeInterval(1)))
        environment.releaseSleeps()
        try await waitUntil { environment.heldSleepCount == 1 && environment.sleeps.count == 2 }
        XCTAssertEqual(connection.state, .failed(message: "Incompatible version",
                                                 retryAt: TestEnvironment.now.addingTimeInterval(2)))
        XCTAssertEqual(environment.sleeps, [.seconds(1), .seconds(2)])
        XCTAssertEqual(fakeMain.requests("hello").count, 2)
    }

    func testBackoff() async throws {
        let device = TestMesh.main("Studio")
        let registry = TestMesh.registry([(device, "Sams-Mac-mini.local")])
        let fakeMain = TestMesh.fakeMain(device, registry: registry)
        fakeMain.helloError = ProtocolError(.internal, "Not ready.")
        let environment = makeEnvironment(fakeMains: ["Sams-Mac-mini.local": fakeMain], registry: registry)
        let workspace = startWorkspace(environment)

        try await waitUntil { environment.sleeps.count >= 6 }
        XCTAssertEqual(Array(environment.sleeps.prefix(6)),
                       [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30), .seconds(30)])

        fakeMain.helloError = nil
        let connection = try XCTUnwrap(workspace.connection(device.id))
        try await waitUntil { connection.isConnected }
        let before = environment.sleeps.count
        fakeMain.closeConnection()
        try await waitUntil { environment.sleeps.count > before }
        XCTAssertEqual(environment.sleeps[before], .seconds(1))
        try await waitUntil { connection.isConnected }
    }

    func testResubscribe() async throws {
        let (workspace, fakeMain, _) = try await connectedWorkspace()
        let mainID = fakeMain.device.id
        let sessionID = UUID()
        let subscription = await workspace.subscribe(.session(sessionID), on: mainID)
        XCTAssertEqual(fakeMain.requests("subscribe").count, 1)

        // The number of subscribe requests the FakeMain had received at each `connected` event.
        let counts = Counts()
        let stream = workspace.events()
        let listener = Task { @MainActor in
            for await event in stream {
                if self.isConnectedEvent(event, mainID) {
                    counts.values.append(fakeMain.requests("subscribe").count)
                }
            }
        }
        addTeardownBlock { @MainActor in
            listener.cancel()
        }

        fakeMain.closeConnection()
        try await waitUntil { !counts.values.isEmpty }
        XCTAssertEqual(counts.values, [2])
        let resubscribe = try XCTUnwrap(fakeMain.requests("subscribe").last)
        XCTAssertEqual(resubscribe.json, ["topics": ["session:\(sessionID.uuidString)"]])
        subscription.cancel()
    }

    func testEventsBeforeHello() async throws {
        let device = TestMesh.main("Studio")
        let registry = TestMesh.registry([(device, "Sams-Mac-mini.local")])
        let project = TestMesh.summary("HEPH", mainID: device.id)
        let fakeMain = FakeMain(device: device, snapshot: registry)
        fakeMain.answer("host.info", with: TestMesh.hostInfo(device))
        fakeMain.answer("skills.list", with: SkillsListResult(skills: []))
        fakeMain.eventsBeforeHello = [.projectsChanged(ProjectsChangedPayload(deviceID: device.id,
                                                                              projects: [project]))]
        let environment = makeEnvironment(fakeMains: ["Sams-Mac-mini.local": fakeMain], registry: registry)
        let workspace = startWorkspace(environment)

        let connection = try XCTUnwrap(workspace.connection(device.id))
        try await waitUntil { connection.isConnected }
        XCTAssertEqual(connection.projects, [project])
        XCTAssertTrue(connection.projectsLoaded)
        try await waitUntil { fakeMain.requests("projects.list").count == 1 }
        XCTAssertEqual(connection.projects, [project])
    }

    func testRekey() async throws {
        let (workspace, fakeMain, environment) = try await connectedWorkspace()
        let newKey = Data(repeating: 0x02, count: 32)
        let answer = try await fakeMain.rekey(newKey)
        XCTAssertEqual(answer, [:])
        XCTAssertEqual(environment.savedCredentials.last,
                       MeshCredentials(meshID: testCredentials.meshID, meshKey: newKey))
        try await waitUntil { fakeMain.channelCount == 2 }
        let connection = try XCTUnwrap(workspace.connection(fakeMain.device.id))
        try await waitUntil { connection.isConnected }
        XCTAssertEqual(environment.sleeps, [])
    }

    func testOffline() async throws {
        let device = TestMesh.main("Studio")
        let registry = TestMesh.registry([(device, "Sams-Mac-mini.local")])
        let fakeMain = TestMesh.fakeMain(device, registry: registry)
        let environment = makeEnvironment(fakeMains: [:], registry: registry)
        environment.holdSleeps(true)
        let workspace = startWorkspace(environment)

        let connection = try XCTUnwrap(workspace.connection(device.id))
        try await waitUntil { connection.isFailed }
        do {
            _ = try await connection.hostInfo()
            XCTFail("hostInfo() succeeded offline")
        } catch let error as ProtocolError {
            XCTAssertEqual(error, ProtocolError(.unavailable, "Studio is offline."))
        }
        XCTAssertTrue(fakeMain.requests.isEmpty)
    }

    func testOwnName() async throws {
        let (workspace, fakeMain, environment) = try await connectedWorkspace(name: "Sam's MacBook Pro")
        var renamed = fakeMain.snapshot
        let index = try XCTUnwrap(renamed.devices.firstIndex { $0.id == TestMesh.local.id })
        renamed.devices[index].name = "Studio"
        renamed.devices[index].updatedAt = TestEnvironment.now
        fakeMain.emit(.meshChanged(MeshChangedPayload(snapshot: renamed)))

        try await waitUntil { workspace.device.name == "Studio" }
        XCTAssertEqual(environment.savedDevices.last?.name, "Studio")
        XCTAssertEqual(environment.savedDevices.last?.id, TestMesh.local.id)
    }
}
