import Foundation
import HephCore
import HephNet
import Observation
import Synchronization

/// The state of a `MainConnection`.
public enum ConnectionState: Equatable, Sendable {
    /// Not trying: before start, after stop or close.
    case disconnected
    /// An attempt is running; attempt = consecutive failures + 1.
    case connecting(attempt: Int)
    /// Handshake done.
    case connected
    /// Waiting for the next attempt; nil = no automatic retry.
    case failed(message: String, retryAt: Date?)
}

/// The connection to one Main: connection state, handshake, projects and skills lists (docs/client/workspace.md,
/// "MainConnection"). The Workspace creates one per Main of the registry, and one loopback connection to this Mac's
/// host while a `LocalHostLink` is set.
@MainActor @Observable
public final class MainConnection: Identifiable {
    /// The Main's device id.
    public nonisolated let id: UUID
    public let isLoopback: Bool
    public private(set) var state: ConnectionState = .disconnected {
        didSet {
            if state != oldValue {
                workspace?.topologyDidChange()
            }
        }
    }
    /// From the last hello result.
    public private(set) var serverDevice: DeviceInfo?
    /// host.info, fetched after each handshake.
    public private(set) var hostInfo: HostInfoResult?
    /// Top-level projects, sub projects in `children`.
    public private(set) var projects: [ProjectSummary] = []
    /// `projects` reflects this Main since the last handshake.
    public private(set) var projectsLoaded = false
    /// The Main's skills library.
    public private(set) var skills: [SkillSummary] = []
    public private(set) var skillsLoaded = false
    /// Host used by the current connection.
    public private(set) var connectedAddress: String?

    /// Registry name, else serverDevice name, else "Main".
    public var name: String {
        workspace?.record(of: id)?.name ?? serverDevice?.name ?? "Main"
    }

    /// `state == .connected`
    public var isConnected: Bool {
        state == .connected
    }

    /// host.info again; a failure is logged.
    public func refreshHostInfo() async {
        do {
            _ = try await hostInfo()
        } catch {
            Log.client.error("host.info failed on \(self.id, privacy: .public): \(Workspace.message(of: error))")
        }
    }

    // MARK: - State of the connection

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private let localLink: (any LocalHostLink)?
    /// The peer of the current channel, from the handshake until the channel closes.
    @ObservationIgnored private(set) var peer: RPCPeer?
    /// Counts the failed attempts and the drops since the last successful handshake.
    @ObservationIgnored private var failures = 0
    /// Incremented for each new peer and each teardown: work of an older peer is ignored.
    @ObservationIgnored private var generation = 0
    /// The generation whose `peer.run()` returned.
    @ObservationIgnored private var finishedGeneration = -1
    /// The attempts and their backoff sleeps.
    @ObservationIgnored private var attemptTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// host.info, projects.list and skills.list after a handshake.
    @ObservationIgnored private var refreshTasks: [Task<Void, Never>] = []
    /// The events received before the hello result; nil outside the handshake.
    @ObservationIgnored private var handshakeQueue: [ServerEvent]?
    /// `projects.list` requests in flight, and the `projects.changed` events (with their sender) queued meanwhile.
    @ObservationIgnored var projectsListsInFlight = 0
    @ObservationIgnored var queuedProjectsEvents: [(event: ServerEvent, mainDeviceID: UUID)] = []
    /// `skills.list` requests in flight, and the `skills.changed` events queued meanwhile.
    @ObservationIgnored var skillsListsInFlight = 0
    @ObservationIgnored var queuedSkillsEvents: [ServerEvent] = []

    /// A network connection; with `localLink`, the loopback connection of this Mac. `isLoopback` without a link:
    /// the preview's connection of this device.
    init(id: UUID, workspace: Workspace, localLink: (any LocalHostLink)? = nil, isLoopback: Bool? = nil) {
        self.id = id
        self.isLoopback = isLoopback ?? (localLink != nil)
        self.localLink = localLink
        self.workspace = workspace
    }

    /// The seconds of the backoff, by number of failures.
    private static let backoff = [1, 2, 5, 10, 30]

    // MARK: - Lifecycle (Workspace)

    /// Starts an attempt at once unless one runs or the connection is connected.
    func startConnecting() {
        switch state {
        case .connecting, .connected:
            return
        case .disconnected, .failed:
            launchAttempts(after: nil)
        }
    }

    /// A failed connection starts an attempt now. `retryNow()` calls it whatever the `retryAt`; a new Bonjour sighting
    /// and a change of the record's addresses or port call it only when `retryAt` is not nil.
    func attemptNow() {
        guard case .failed = state else { return }
        launchAttempts(after: nil)
    }

    var isFailed: Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    /// Cancels the attempt and sleep tasks, closes the peer, drops the presence report and sets state
    /// `disconnected`; when it was connected, makes the calls of a drop without the backoff.
    func close() {
        attemptTask?.cancel()
        attemptTask = nil
        let wasConnected = state == .connected
        tearDownPeer()
        state = .disconnected
        if wasConnected {
            workspace?.connectionDidLeaveConnected(self)
        }
    }

    /// After a key rotation: closes, then starts an attempt at once with `failures = 0`.
    func reconnectAfterRekey() {
        close()
        failures = 0
        launchAttempts(after: nil)
    }

    /// The preview state: connected, with the sample host info, projects and skills.
    func applyPreview(serverDevice: DeviceInfo, hostInfo: HostInfoResult, projects: [ProjectSummary],
                      skills: [SkillSummary]) {
        self.serverDevice = serverDevice
        self.hostInfo = hostInfo
        self.projects = projects
        projectsLoaded = true
        self.skills = skills
        skillsLoaded = true
        state = .connected
    }

    // MARK: - Mirrors (request API, events)

    func setHostInfo(_ info: HostInfoResult) {
        hostInfo = info
    }

    /// Replaces the projects tree; `projectsLoaded` becomes true.
    func setProjects(_ projects: [ProjectSummary]) {
        self.projects = projects
        projectsLoaded = true
    }

    /// Replaces the skills; `skillsLoaded` becomes true.
    func setSkills(_ skills: [SkillSummary]) {
        self.skills = skills
        skillsLoaded = true
    }

    /// Applies the `projects.changed` events queued while `projects.list` was in flight, in arrival order.
    func flushQueuedProjectsEvents() {
        let queued = queuedProjectsEvents
        queuedProjectsEvents = []
        for item in queued {
            workspace?.applyEvent(item.event, from: item.mainDeviceID)
        }
    }

    /// Applies the `skills.changed` events queued while `skills.list` was in flight, in arrival order.
    func flushQueuedSkillsEvents() {
        let queued = queuedSkillsEvents
        queuedSkillsEvents = []
        for event in queued {
            workspace?.applyEvent(event, from: id)
        }
    }

    // MARK: - Attempts

    private enum AttemptOutcome {
        case connected
        /// The attempt failed; the backoff applies.
        case failed(String)
        /// The attempt failed; no automatic retry.
        case stopped(String)
        /// Cancelled, or nothing to try with.
        case cancelled
    }

    private enum HandshakeOutcome {
        case connected
        /// This address failed with this message; the next address is tried.
        case nextAddress(String)
        /// The attempt ends.
        case end(AttemptOutcome)
    }

    /// Replaces the attempt task. `delay`: the backoff of a failure recorded before, slept before the first attempt.
    private func launchAttempts(after delay: Int?) {
        attemptTask?.cancel()
        attemptTask = Task { [weak self] in
            await self?.runAttempts(after: delay)
        }
    }

    private func runAttempts(after initialDelay: Int?) async {
        var delay = initialDelay
        while !Task.isCancelled {
            if let seconds = delay {
                guard let workspace else { return }
                do {
                    try await workspace.environment.sleep(.seconds(seconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
            }
            state = .connecting(attempt: failures + 1)
            let outcome = await attempt()
            // A cancelled attempt was replaced or closed: whoever cancelled it owns the state.
            guard !Task.isCancelled else { return }
            switch outcome {
            case .connected:
                return
            case .failed(let message):
                delay = recordFailure(message)
            case .stopped(let message):
                failures += 1
                state = .failed(message: message, retryAt: nil)
                return
            case .cancelled:
                if !Task.isCancelled {
                    state = .disconnected
                }
                return
            }
        }
    }

    /// A failed attempt or a drop: `failures += 1`, state `failed(message, retryAt: now + delay)`; returns the delay
    /// in seconds, `[1, 2, 5, 10, 30][min(failures, 5) - 1]`.
    private func recordFailure(_ message: String) -> Int {
        failures += 1
        let seconds = Self.backoff[min(failures, Self.backoff.count) - 1]
        let now = workspace?.environment.now() ?? Date()
        state = .failed(message: message, retryAt: now.addingTimeInterval(TimeInterval(seconds)))
        return seconds
    }

    /// One attempt: the loopback link, or the addresses one after the other.
    private func attempt() async -> AttemptOutcome {
        guard let workspace else { return .cancelled }
        if isLoopback {
            guard let localLink else { return .cancelled }
            let channel: any MessageChannel
            do {
                channel = try await localLink.makeChannel()
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(Workspace.message(of: error))
            }
            switch await handshake(on: channel, address: nil) {
            case .connected:
                return .connected
            case .nextAddress(let message):
                return .failed(message)
            case .end(let outcome):
                return outcome
            }
        }
        guard let credentials = workspace.credentials else { return .cancelled }
        let addresses = workspace.addresses(of: id, credentials: credentials)
        var lastMessage = "No address for \(name)"
        var triedOne = false
        for address in addresses {
            guard let url = WebSocketChannel.url(host: address.host, port: address.port,
                                                 path: MeshConstants.transportPath)
            else { continue }
            triedOne = true
            let channel: any MessageChannel
            do {
                channel = try await workspace.environment.openChannel(url, credentials)
            } catch is CancellationError {
                return .cancelled
            } catch MeshTransportError.authenticationFailed {
                return .failed("The mesh key was not accepted")
            } catch {
                lastMessage = Workspace.message(of: error)
                continue
            }
            switch await handshake(on: channel, address: address.host) {
            case .connected:
                return .connected
            case .nextAddress(let message):
                lastMessage = message
            case .end(let outcome):
                return outcome
            }
        }
        if !triedOne {
            lastMessage = "No address for \(name)"
        }
        return .failed(lastMessage)
    }

    /// Steps 2–4 of an attempt on an open channel, then the reconnect sequence.
    private func handshake(on transport: any MessageChannel, address: String?) async -> HandshakeOutcome {
        guard let workspace, !Task.isCancelled else {
            transport.close()
            return .end(.cancelled)
        }
        // 2. The peer, its request handler, its events task, then run().
        tearDownPeer()
        let channel = ObservedChannel(transport)
        let peer = RPCPeer(channel: channel)
        let generation = generation
        self.peer = peer
        handshakeQueue = []
        await peer.setRequestHandler(workspace.requestHandler(channel: channel))
        guard generation == self.generation, !Task.isCancelled else {
            peer.close()
            return .end(.cancelled)
        }
        startEvents(of: peer, generation: generation)
        Task { @MainActor [weak self] in
            await peer.run()
            self?.peerDidFinish(generation: generation)
        }

        // 3. hello.
        let result: HelloResult
        do {
            result = try await peer.request(.hello,
                                            HelloParams(device: workspace.device,
                                                        protocolVersion: WireCoding.protocolVersion),
                                            as: HelloResult.self)
        } catch {
            endHandshake(generation: generation)
            if error is CancellationError {
                return .end(.cancelled)
            }
            if let error = error as? ProtocolError {
                switch error.code {
                case .unauthorized:
                    return .end(.stopped("This device was removed from the mesh"))
                case .badRequest:
                    return .end(.failed("Incompatible version"))
                default:
                    return .nextAddress(error.message)
                }
            }
            return .nextAddress(Workspace.message(of: error))
        }
        guard generation == self.generation, !Task.isCancelled else {
            endHandshake(generation: generation)
            return .end(.cancelled)
        }
        guard result.device.id == id else {
            endHandshake(generation: generation)
            return .nextAddress("Reached \(result.device.name) instead of \(name)")
        }

        // Reconnect sequence. 1. The lists reflect this Main again once fetched (or replaced by an event).
        serverDevice = result.device
        connectedAddress = address
        failures = 0
        projectsLoaded = false
        skillsLoaded = false
        // 2.
        workspace.receiveSnapshot(result.mesh, from: self)
        let queued = handshakeQueue ?? []
        handshakeQueue = nil
        for event in queued {
            workspace.handleEvent(event, from: self)
        }
        // 3. The held topics; a topic held while the request runs is subscribed before the connection is connected.
        var subscribed = Set<Topic>()
        while true {
            let topics = workspace.heldTopics(on: id).filter { !subscribed.contains($0) }
            guard !topics.isEmpty else { break }
            subscribed.formUnion(topics)
            do {
                _ = try await peer.request(.subscribe, SubscribeParams(topics: topics.map(\.rawValue)),
                                           as: EmptyPayload.self)
            } catch {
                let message = Workspace.message(of: error)
                Log.client.error("Could not subscribe again on \(self.id, privacy: .public): \(message)")
            }
            guard generation == self.generation, !Task.isCancelled else {
                endHandshake(generation: generation)
                return .end(.cancelled)
            }
            guard finishedGeneration != generation else {
                endHandshake(generation: generation)
                return .nextAddress("Not connected.")
            }
        }
        // 4.
        state = .connected
        workspace.connectionDidConnect(self)
        // 5.
        startRefresh()
        return .connected
    }

    /// Step 5 of the reconnect sequence: host.info, projects.list and skills.list concurrently; every store of this
    /// Main reloads.
    private func startRefresh() {
        let generation = generation
        refreshTasks.forEach { $0.cancel() }
        refreshTasks = [
            Task { [weak self] in
                await self?.refreshHostInfo()
            },
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.listProjects()
                } catch {
                    guard generation == self.generation, !(error is CancellationError) else { return }
                    let message = Workspace.message(of: error)
                    self.workspace?.report("Could not load the projects of \(self.name): \(message)")
                }
            },
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.listSkills()
                } catch {
                    guard generation == self.generation, !(error is CancellationError) else { return }
                    let message = Workspace.message(of: error)
                    Log.client.error("skills.list failed on \(self.id, privacy: .public): \(message)")
                }
            },
        ]
        workspace?.reloadStores(of: id)
    }

    // MARK: - Peer

    /// The events of the peer, decoded off the main actor and applied on it one at a time, in arrival order.
    private func startEvents(of peer: RPCPeer, generation: Int) {
        let events = peer.events
        eventsTask = Task.detached { [weak self] in
            for await inbound in events {
                let decoded = Result { try ServerEvent.decode(inbound) }
                guard let self else { return }
                await self.receive(decoded, name: inbound.name, generation: generation)
            }
        }
    }

    private func receive(_ decoded: Result<ServerEvent?, Error>, name: String, generation: Int) {
        guard generation == self.generation, let workspace else { return }
        switch decoded {
        case .failure(let error):
            let message = Workspace.message(of: error)
            let mainID = id
            Log.client.error("Ignored the event \(name, privacy: .public) from \(mainID, privacy: .public): \(message)")
        case .success(nil):
            return
        case .success(let event?):
            if handshakeQueue != nil {
                handshakeQueue?.append(event)
            } else {
                workspace.handleEvent(event, from: self)
            }
        }
    }

    /// `peer.run()` returned. While connected, this is a drop: the presence report is dropped, the centers and the
    /// Forge model learn it, the `disconnected` event is emitted and the backoff applies with "Connection lost".
    private func peerDidFinish(generation: Int) {
        guard generation == self.generation else { return }
        finishedGeneration = generation
        guard state == .connected else { return }
        tearDownPeer()
        let delay = recordFailure("Connection lost")
        workspace?.connectionDidLeaveConnected(self)
        launchAttempts(after: delay)
    }

    /// The handshake on this generation failed: its peer is closed.
    private func endHandshake(generation: Int) {
        guard generation == self.generation else { return }
        tearDownPeer()
    }

    /// Closes the peer and forgets its tasks; the presence report of this connection is dropped.
    private func tearDownPeer() {
        generation += 1
        eventsTask?.cancel()
        eventsTask = nil
        refreshTasks.forEach { $0.cancel() }
        refreshTasks = []
        handshakeQueue = nil
        if let peer {
            peer.close()
            self.peer = nil
        }
        connectedAddress = nil
        workspace?.dropReport(of: id)
    }
}

/// The channel of a connection as its RPCPeer sees it: every call goes to the transport channel. An action can be
/// armed to run right after the response to a request has been handed to the transport: the connections close after
/// the response to `mesh.rekey` is sent.
final class ObservedChannel: MessageChannel {
    let base: any MessageChannel
    private let armed = Mutex<[(prefix: Data, action: @Sendable () -> Void)]>([])

    init(_ base: any MessageChannel) {
        self.base = base
    }

    var state: ChannelState {
        base.state
    }

    var inbound: AsyncStream<Data> {
        base.inbound
    }

    func send(_ frame: Data) {
        base.send(frame)
        let actions = armed.withLock { armed -> [@Sendable () -> Void] in
            guard !armed.isEmpty else { return [] }
            let matching = armed.filter { frame.starts(with: $0.prefix) }.map(\.action)
            armed.removeAll { frame.starts(with: $0.prefix) }
            return matching
        }
        for action in actions {
            action()
        }
    }

    func close() {
        base.close()
    }

    /// Runs `action` once the success response to request `requestID` has been sent.
    func afterSendingResponse(to requestID: Int, _ action: @escaping @Sendable () -> Void) {
        let prefix = Data("{\"id\":\(requestID),\"kind\":\"response\"".utf8)
        armed.withLock { $0.append((prefix, action)) }
    }
}
