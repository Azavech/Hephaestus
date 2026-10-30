import Foundation
import Synchronization
import XCTest
@testable import HephClient
@testable import HephCore
@testable import HephNet

/// The mesh credentials of the tests: mesh id 00000000-0000-4000-8000-000000000100, a key of 32 bytes 0x01.
let testCredentials = MeshCredentials(meshID: UUID(uuidString: "00000000-0000-4000-8000-000000000100")!,
                                      meshKey: Data(repeating: 0x01, count: 32))

/// The error thrown by `waitUntil` when the condition does not hold in time.
struct WaitTimedOut: Error {}

/// Waits until `condition` holds, polling every 10 ms; fails the test and throws after `timeout`.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () async throws -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("The condition did not hold within \(timeout).", file: file, line: line)
            throw WaitTimedOut()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - FakeMain

/// The server end of LoopbackChannel pairs, served with an RPCPeer: `hello` answered with `device` and `snapshot`, or
/// with `helloError`; the methods given canned results answered in order (the last one repeats), optionally after a
/// delay; other methods answered with `notFound`. It records every request, emits events on demand, can send
/// `mesh.rekey` and can close its end.
@MainActor
final class FakeMain {
    /// A request received: its method and params JSON.
    struct Request {
        let method: String
        let params: Data

        /// The params as a parsed JSON object.
        var json: NSDictionary {
            ((try? JSONSerialization.jsonObject(with: params)) as? NSDictionary) ?? [:]
        }

        func decode<P: Decodable>(_ type: P.Type) throws -> P {
            try WireCoding.decodeJSON(type, from: params)
        }
    }

    private struct Canned {
        let result: Result<Data, ProtocolError>
        let delay: Duration?
    }

    var device: DeviceInfo
    var snapshot: MeshSnapshot
    var helloError: ProtocolError?
    /// Events emitted on a new connection right before the `hello` answer.
    var eventsBeforeHello: [ServerEvent] = []
    private(set) var requests: [Request] = []
    /// The server ends of the channels, in order.
    private(set) var serverChannels: [LoopbackChannel] = []
    private var peers: [RPCPeer] = []
    private var canned: [String: [Canned]] = [:]
    private var lastCanned: [String: Canned] = [:]

    init(device: DeviceInfo, snapshot: MeshSnapshot) {
        self.device = device
        self.snapshot = snapshot
    }

    var channelCount: Int {
        serverChannels.count
    }

    func requests(_ method: String) -> [Request] {
        requests.filter { $0.method == method }
    }

    /// Queues a result for `method`.
    func answer(_ method: String, with result: some Encodable, after delay: Duration? = nil) {
        do {
            canned[method, default: []].append(Canned(result: .success(try WireCoding.encodeJSON(result)),
                                                      delay: delay))
        } catch {
            XCTFail("Cannot encode the canned result of \(method): \(error)")
        }
    }

    /// Queues an error for `method`.
    func fail(_ method: String, with error: ProtocolError, after delay: Duration? = nil) {
        canned[method, default: []].append(Canned(result: .failure(error), delay: delay))
    }

    /// The client end of a new pair whose server end this Main serves.
    func makeChannel() -> LoopbackChannel {
        let (client, server) = LoopbackChannel.makePair()
        let peer = RPCPeer(channel: server)
        serverChannels.append(server)
        peers.append(peer)
        let handler: RPCPeer.RequestHandler = { [weak self] request in
            guard let self else {
                throw ProtocolError(.unavailable, "The fake Main is gone.")
            }
            return try await self.handle(request, on: peer)
        }
        Task {
            await peer.setRequestHandler(handler)
            await peer.run()
        }
        return client
    }

    /// Emits an event on the latest connection.
    func emit(_ event: ServerEvent) {
        peers.last?.emit(event)
    }

    /// Sends `mesh.rekey` on the latest connection and returns the answer read as `[String: String]`: unlike
    /// `EmptyPayload`, which decodes from any object, an answer with a member fails to decode or is not empty.
    func rekey(_ meshKey: Data) async throws -> [String: String] {
        guard let peer = peers.last else {
            throw ProtocolError(.unavailable, "No connection.")
        }
        return try await peer.request(.meshRekey, MeshRekeyParams(meshKey: meshKey), as: [String: String].self)
    }

    /// Closes the latest connection.
    func closeConnection() {
        peers.last?.close()
    }

    private func handle(_ request: InboundRequest, on peer: RPCPeer) async throws -> Data {
        requests.append(Request(method: request.method, params: request.params))
        if request.method == RPCMethod.hello.rawValue {
            for event in eventsBeforeHello {
                peer.emit(event)
            }
            if let helloError {
                throw helloError
            }
            return try WireCoding.encodeJSON(HelloResult(device: device, mesh: snapshot))
        }
        let answer: Canned
        if var queue = canned[request.method], !queue.isEmpty {
            answer = queue.removeFirst()
            canned[request.method] = queue
            lastCanned[request.method] = answer
        } else if let last = lastCanned[request.method] {
            answer = last
        } else {
            throw ProtocolError(.notFound, "No answer for \(request.method).")
        }
        if let delay = answer.delay {
            try await Task.sleep(for: delay)
        }
        return try answer.result.get()
    }
}

// MARK: - TestEnvironment

/// A `WorkspaceEnvironment` for the tests: channels to the `FakeMain` registered under the URL's host, in-memory
/// credentials and registry whose saves are recorded, a Bonjour list the test controls, a `sleep` that records each
/// duration and returns at once (unless the test holds the sleeps), a fixed `now` and an attachment cache in a
/// temporary folder.
final class TestEnvironment: Sendable {
    private struct State {
        var credentials: MeshCredentials?
        var registry: MeshSnapshot?
        var savedCredentials: [MeshCredentials] = []
        var savedRegistries: [MeshSnapshot] = []
        var savedDevices: [DeviceInfo] = []
        var sleeps: [Duration] = []
        var openedHosts: [String] = []
        var adverts: [BonjourAdvert] = []
        var onAdverts: (@Sendable ([BonjourAdvert]) -> Void)?
        var holdsSleeps = false
        var heldSleeps: [CheckedContinuation<Void, Never>] = []
    }

    /// 2026-10-29T21:00:00.000Z
    static let now = Date(timeIntervalSince1970: 1_793_307_600)

    let folder: URL
    let fakeMains: [String: FakeMain]
    private let state: Mutex<State>

    private init(fakeMains: [String: FakeMain], credentials: MeshCredentials?, registry: MeshSnapshot?) {
        self.fakeMains = fakeMains
        folder = FileManager.default.temporaryDirectory
            .appending(path: "HephClientTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        state = Mutex(State(credentials: credentials, registry: registry))
    }

    static func make(fakeMains: [String: FakeMain], credentials: MeshCredentials?,
                     registry: MeshSnapshot?) -> TestEnvironment {
        TestEnvironment(fakeMains: fakeMains, credentials: credentials, registry: registry)
    }

    /// The attachment cache folder.
    var cacheRoot: URL {
        folder.appending(path: "Attachments", directoryHint: .isDirectory)
    }

    var environment: WorkspaceEnvironment {
        let fakeMains = fakeMains
        return WorkspaceEnvironment(
            loadCredentials: { [self] in
                self.state.withLock { $0.credentials }
            },
            saveCredentials: { [self] credentials in
                self.state.withLock {
                    $0.credentials = credentials
                    $0.savedCredentials.append(credentials)
                }
            },
            loadRegistry: { [self] in
                self.state.withLock { $0.registry }
            },
            saveRegistry: { [self] snapshot in
                self.state.withLock {
                    $0.registry = snapshot
                    $0.savedRegistries.append(snapshot)
                }
            },
            saveDevice: { [self] device in
                self.state.withLock { $0.savedDevices.append(device) }
            },
            openChannel: { [self] url, _ in
                let host = url.host(percentEncoded: false) ?? ""
                self.state.withLock { $0.openedHosts.append(host) }
                guard let fakeMain = fakeMains[host] else {
                    throw ProtocolError(.unavailable, "Nothing listens at \(host).")
                }
                return await fakeMain.makeChannel()
            },
            browse: { [self] onChange in
                let adverts = self.state.withLock { state in
                    state.onAdverts = onChange
                    return state.adverts
                }
                onChange(adverts)
                return { [self] in
                    self.state.withLock { $0.onAdverts = nil }
                }
            },
            sleep: { [self] duration in
                let holds = self.state.withLock { state in
                    state.sleeps.append(duration)
                    return state.holdsSleeps
                }
                if holds {
                    await withCheckedContinuation { continuation in
                        let held = self.state.withLock { state in
                            guard state.holdsSleeps else { return false }
                            state.heldSleeps.append(continuation)
                            return true
                        }
                        if !held {
                            continuation.resume()
                        }
                    }
                } else {
                    await Task.yield()
                }
            },
            now: {
                TestEnvironment.now
            },
            attachmentCache: AttachmentCache(root: cacheRoot)
        )
    }

    var savedCredentials: [MeshCredentials] {
        state.withLock { $0.savedCredentials }
    }

    var savedDevices: [DeviceInfo] {
        state.withLock { $0.savedDevices }
    }

    var sleeps: [Duration] {
        state.withLock { $0.sleeps }
    }

    var openedHosts: [String] {
        state.withLock { $0.openedHosts }
    }

    /// The list reported by the browser.
    func setAdverts(_ adverts: [BonjourAdvert]) {
        let onChange = state.withLock { state in
            state.adverts = adverts
            return state.onAdverts
        }
        onChange?(adverts)
    }

    /// While true, a sleep waits for `releaseSleeps()`.
    func holdSleeps(_ holds: Bool) {
        let released = state.withLock { state in
            state.holdsSleeps = holds
            let held = holds ? [] : state.heldSleeps
            if !holds {
                state.heldSleeps = []
            }
            return held
        }
        for continuation in released {
            continuation.resume()
        }
    }

    /// Lets the sleeps that wait return.
    func releaseSleeps() {
        let released = state.withLock { state in
            let held = state.heldSleeps
            state.heldSleeps = []
            return held
        }
        for continuation in released {
            continuation.resume()
        }
    }

    var heldSleepCount: Int {
        state.withLock { $0.heldSleeps.count }
    }

    func removeFiles() {
        releaseSleeps()
        try? FileManager.default.removeItem(at: folder)
    }
}

// MARK: - Fixtures

/// The devices, records and workspaces of the client tests.
enum TestMesh {
    /// 2026-10-29T08:00:00.000Z
    static let updatedAt = Date(timeIntervalSince1970: 1_793_260_800)
    /// 2026-10-01T09:00:00.000Z
    static let pairedAt = Date(timeIntervalSince1970: 1_790_845_200)

    /// This device: an iPad.
    static let local = DeviceInfo(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!,
                                  name: "Sam's iPad", platform: .iPadOS, isMain: false, appVersion: "1.0", build: 1)

    static func main(_ name: String, id: UUID = UUID()) -> DeviceInfo {
        DeviceInfo(id: id, name: name, platform: .macOS, isMain: true, appVersion: "1.0", build: 1)
    }

    static func record(_ device: DeviceInfo, addresses: [String] = [], port: Int = 47100,
                       updatedAt: Date = updatedAt, revoked: Bool = false) -> DeviceRecord {
        DeviceRecord(id: device.id, name: device.name, platform: device.platform, isMain: device.isMain,
                     addresses: device.isMain ? addresses : [], port: device.isMain ? port : 0,
                     appVersion: device.appVersion, build: device.build, pairedAt: pairedAt, updatedAt: updatedAt,
                     revoked: revoked)
    }

    /// The registry of the Mains at their hosts, and this device.
    static func registry(_ mains: [(device: DeviceInfo, host: String)]) -> MeshSnapshot {
        MeshSnapshot(meshID: testCredentials.meshID,
                     devices: mains.map { record($0.device, addresses: [$0.host]) } + [record(local)],
                     presence: [])
    }

    static func hostInfo(_ device: DeviceInfo) -> HostInfoResult {
        HostInfoResult(device: device, projectsFolder: "/Users/user/Developer", claudeAvailable: true,
                       claudePath: "/Users/user/.local/bin/claude", gitAvailable: true)
    }

    static func summary(_ id: String, mainID: UUID, children: [ProjectSummary] = [],
                        pendingPermissionCount: Int = 0) -> ProjectSummary {
        ProjectSummary(id: id, name: id, deviceID: mainID, rootPath: "/Users/user/Developer/\(id)",
                       children: children, migrating: false, pendingPermissionCount: pendingPermissionCount)
    }

    static func project(_ id: String, mainID: UUID) -> Project {
        Project(id: id, name: id, created: pairedAt, code: ".", docs: "docs", taskCounter: 0, subprojects: [],
                webTabs: [], runs: [], skills: [], claude: ClaudeDefaults(), deviceID: mainID,
                rootPath: "/Users/user/Developer/\(id)", migrating: false)
    }

    static func task(_ id: String, name: String = "Task", updated: Date = updatedAt) -> TaskItem {
        TaskItem(id: id, name: name, description: "", status: .todo, created: pairedAt, updated: updated,
                 comments: [])
    }

    /// A FakeMain answering host.info, projects.list (with `projects`), skills.list and subscribe.
    @MainActor
    static func fakeMain(_ device: DeviceInfo, registry: MeshSnapshot, projects: [ProjectSummary] = []) -> FakeMain {
        let fakeMain = FakeMain(device: device, snapshot: registry)
        fakeMain.answer("host.info", with: hostInfo(device))
        fakeMain.answer("projects.list", with: ProjectsListResult(projects: projects))
        fakeMain.answer("skills.list", with: SkillsListResult(skills: []))
        fakeMain.answer("subscribe", with: EmptyPayload())
        fakeMain.answer("unsubscribe", with: EmptyPayload())
        return fakeMain
    }
}

extension XCTestCase {
    /// A `TestEnvironment` whose files are removed at teardown.
    func makeEnvironment(fakeMains: [String: FakeMain], credentials: MeshCredentials? = testCredentials,
                         registry: MeshSnapshot?) -> TestEnvironment {
        let environment = TestEnvironment.make(fakeMains: fakeMains, credentials: credentials, registry: registry)
        addTeardownBlock {
            environment.removeFiles()
        }
        return environment
    }

    /// A started Workspace of this device on `environment`, stopped at teardown.
    @MainActor
    func startWorkspace(_ environment: TestEnvironment) -> Workspace {
        let workspace = Workspace(device: TestMesh.local, environment: environment.environment)
        workspace.start()
        addTeardownBlock { @MainActor in
            workspace.stop()
        }
        return workspace
    }

    /// A Workspace connected to one FakeMain at `Sams-Mac-mini.local`.
    @MainActor
    func connectedWorkspace(projects: [ProjectSummary] = [], name: String = "Studio", mainID: UUID = UUID(),
                            configure: (FakeMain) -> Void = { _ in }) async throws
        -> (workspace: Workspace, fakeMain: FakeMain, environment: TestEnvironment) {
        let device = TestMesh.main(name, id: mainID)
        let registry = TestMesh.registry([(device, "Sams-Mac-mini.local")])
        let fakeMain = TestMesh.fakeMain(device, registry: registry, projects: projects)
        configure(fakeMain)
        let environment = makeEnvironment(fakeMains: ["Sams-Mac-mini.local": fakeMain], registry: registry)
        let workspace = startWorkspace(environment)
        try await waitUntil { workspace.connection(device.id)?.isConnected == true }
        try await waitUntil { workspace.connection(device.id)?.projectsLoaded == true }
        return (workspace, fakeMain, environment)
    }
}
