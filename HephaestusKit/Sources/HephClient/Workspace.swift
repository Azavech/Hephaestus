import Foundation
import HephCore
import HephNet
import Observation

/// What `Workspace.events()` delivers.
public enum WorkspaceEvent: Sendable {
    /// After the handshake and the re-subscription.
    case connected(mainDeviceID: UUID)
    /// The connection left `connected`.
    case disconnected(mainDeviceID: UUID)
    case event(mainDeviceID: UUID, ServerEvent)
}

/// The mirror, on this device, of the state of every Main of the mesh, and the only way the UI talks to the Mains
/// (docs/client/workspace.md). One per process; every window observes it and has its own `Selection`.
@MainActor @Observable
public final class Workspace {
    /// This device.
    public private(set) var device: DeviceInfo
    /// Mesh credentials are loaded.
    public private(set) var hasMesh = false
    /// Merged registry and merged presence; nil without a mesh.
    public private(set) var mesh: MeshSnapshot?
    /// Merged presence by device id.
    public private(set) var presence: [UUID: Presence] = [:]
    /// One per Main, by the Main's device id, the local one included.
    public private(set) var connections: [UUID: MainConnection] = [:]
    /// Mains currently seen by Bonjour, by device id.
    public private(set) var seenHosts: [UUID: BonjourAdvert] = [:]
    /// Latest `migration.progress` per migration id, from every connected Main, kept while the app runs.
    public private(set) var migrations: [UUID: MigrationProgressPayload] = [:]
    /// Incremented when the registry, the set of connections, a connection state, a projects list or a migration
    /// state changes.
    public private(set) var topologyRevision = 0
    @ObservationIgnored public private(set) var sessionCenter: SessionCenter!
    @ObservationIgnored public private(set) var forge: ForgeModel!
    /// True for `Workspace.preview()`.
    public let isPreview: Bool

    @ObservationIgnored let environment: WorkspaceEnvironment
    /// The mesh credentials in use; nil without a mesh.
    @ObservationIgnored private(set) var credentials: MeshCredentials?
    @ObservationIgnored var topicHolders: [TopicKey: Int] = [:]
    /// The last `subscribe` or `unsubscribe` request queued per Main; the next one waits for it.
    @ObservationIgnored var topicQueues: [UUID: Task<Void, Never>] = [:]
    /// The downloads in progress, by destination path.
    @ObservationIgnored var downloadGates: [String: DownloadGate] = [:]
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var localHostLink: (any LocalHostLink)?
    /// One presence report per connected Main.
    @ObservationIgnored private var reports: [UUID: [Presence]] = [:]
    @ObservationIgnored private var lastSeen: [UUID: Date] = [:]
    @ObservationIgnored private var stores: [StoreKey: ProjectStore] = [:]
    @ObservationIgnored private var selections: [SelectionEntry] = []
    @ObservationIgnored private var eventContinuations: [UUID: AsyncStream<WorkspaceEvent>.Continuation] = [:]
    @ObservationIgnored private var reportContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    @ObservationIgnored private var stopBrowsing: (@Sendable () -> Void)?
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var registrySaveTask: Task<Void, Never>?
    @ObservationIgnored private var registrySavePending = false
    /// The registry saves, each one after the previous one, off the main actor.
    @ObservationIgnored private var registryWrite: Task<Void, Never>?

    /// Stores its arguments, then creates `sessionCenter` and `forge`. No I/O, no connection.
    public convenience init(device: DeviceInfo, environment: WorkspaceEnvironment) {
        self.init(device: device, environment: environment, isPreview: false)
    }

    init(device: DeviceInfo, environment: WorkspaceEnvironment, isPreview: Bool) {
        self.device = device
        self.environment = environment
        self.isPreview = isPreview
        sessionCenter = SessionCenter(workspace: self)
        forge = ForgeModel(workspace: self)
    }

    // MARK: - Computed state

    /// Registry records with `isMain` and not `revoked`, sorted by name, then id.
    public var mains: [DeviceRecord] {
        PresenceModel.sortedByName((mesh?.devices ?? []).filter { $0.isMain && !$0.revoked })
    }

    /// The loopback connection to this Mac's host service.
    public var localConnection: MainConnection? {
        guard let connection = connections[device.id], connection.isLoopback else { return nil }
        return connection
    }

    /// Number of `presence` entries that are online, this device included.
    public var onlineDeviceCount: Int {
        presence.values.filter(\.online).count
    }

    // MARK: - Lifecycle

    /// Migrates the attachment cache, loads the credentials and the cached registry, starts browsing, creates the
    /// connections and starts connecting them. Does nothing when started.
    public func start() {
        guard !isStarted, !isPreview else { return }
        isStarted = true
        environment.attachmentCache.migrateFromTasks()
        loadMesh()
        startBrowsing()
        reconcileConnections()
        if let localHostLink, connections[device.id] == nil {
            connections[device.id] = MainConnection(id: device.id, workspace: self, localLink: localHostLink)
            topologyRevision += 1
        }
        for connection in connections.values {
            connection.startConnecting()
        }
    }

    /// Stops browsing, closes every connection, cancels the Workspace's tasks and writes a pending registry save.
    /// Keeps the data.
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        stopBrowsingNow()
        for connection in connections.values {
            connection.close()
        }
        registrySaveTask?.cancel()
        registrySaveTask = nil
        if registrySavePending {
            writeRegistry()
        }
    }

    /// `stop()`, then forgets the mirrored state, then `start()`: credentials and registry are read again.
    public func restart() {
        stop()
        forgetMirroredState()
        start()
    }

    /// Closes every connection and forgets the mirrored state. Browsing continues when started.
    public func reset() {
        forgetMirroredState()
    }

    /// Every connection in state `failed` starts an attempt now, whatever its `retryAt`.
    public func retryNow() {
        for connection in connections.values {
            connection.attemptNow()
        }
    }

    /// With a link: loads the credentials again, creates or replaces the loopback connection of this device and
    /// connects it when started. With nil: closes and removes that connection and its stores.
    public func setLocalHostLink(_ link: (any LocalHostLink)?) {
        localHostLink = link
        if let link {
            reloadCredentials()
            if let existing = connections[device.id] {
                existing.close()
                connections[device.id] = nil
            }
            registrySaveTask?.cancel()
            registrySaveTask = nil
            registrySavePending = false
            let connection = MainConnection(id: device.id, workspace: self, localLink: link)
            connections[device.id] = connection
            reconcileConnections()
            topologyRevision += 1
            if isStarted {
                connection.startConnecting()
            }
        } else if let existing = connections[device.id], existing.isLoopback {
            removeConnection(existing)
            topologyRevision += 1
        }
    }

    /// Replaces `device`; the next handshakes send it. No reconnection.
    public func updateLocalDevice(_ device: DeviceInfo) {
        self.device = device
    }

    /// A new empty `Selection`, kept by a weak reference for the selection rules.
    public func makeSelection() -> Selection {
        let selection = Selection()
        selections.removeAll { $0.selection == nil }
        selections.append(SelectionEntry(selection))
        return selection
    }

    /// A new stream of the messages of failures of work the Workspace starts by itself; it ends when the task
    /// iterating it is cancelled.
    public func errorReports() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let id = UUID()
        reportContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.reportContinuations[id] = nil
            }
        }
        return stream
    }

    /// A new stream that receives everything emitted after the call; it ends when the task iterating it is
    /// cancelled.
    public func events() -> AsyncStream<WorkspaceEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: WorkspaceEvent.self, bufferingPolicy: .unbounded)
        let id = UUID()
        eventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.eventContinuations[id] = nil
            }
        }
        return stream
    }

    // MARK: - Lookups

    /// The connection of a Main.
    public func connection(_ mainDeviceID: UUID) -> MainConnection? {
        connections[mainDeviceID]
    }

    /// The store of a project, created with phase `idle` when missing; a new store starts loading when its Main is
    /// connected.
    public func projectStore(mainDeviceID: UUID, projectID: String) -> ProjectStore {
        let key = StoreKey(mainDeviceID: mainDeviceID, projectID: projectID)
        if let store = stores[key] {
            return store
        }
        let store = ProjectStore(workspace: self, mainDeviceID: mainDeviceID, projectID: projectID)
        stores[key] = store
        if connections[mainDeviceID]?.isConnected == true {
            Task {
                await store.reload()
            }
        }
        return store
    }

    /// A project of a Main's tree.
    public func summary(of projectID: String, on mainDeviceID: UUID) -> ProjectSummary? {
        guard let tree = connections[mainDeviceID]?.projects else { return nil }
        return Self.chain(of: projectID, in: tree)?.last
    }

    /// The chain of project ids from the top-level project down to `projectID`.
    public func projectPath(of projectID: String, on mainDeviceID: UUID) -> [String]? {
        guard let tree = connections[mainDeviceID]?.projects else { return nil }
        return Self.chain(of: projectID, in: tree)?.map(\.id)
    }

    // MARK: - Internal API of the client models

    /// The registry record of a device.
    func record(of deviceID: UUID) -> DeviceRecord? {
        mesh?.devices.first { $0.id == deviceID }
    }

    /// The name of a Main for messages: its registry name, else its connection's, else "Main".
    func mainName(_ mainDeviceID: UUID) -> String {
        connections[mainDeviceID]?.name ?? record(of: mainDeviceID)?.name ?? "Main"
    }

    /// The store of a project when it exists.
    func existingStore(mainDeviceID: UUID, projectID: String) -> ProjectStore? {
        stores[StoreKey(mainDeviceID: mainDeviceID, projectID: projectID)]
    }

    /// A store whose load answered `notFound` is dropped.
    func dropStore(_ store: ProjectStore) {
        let key = StoreKey(mainDeviceID: store.mainDeviceID, projectID: store.projectID)
        if stores[key] === store {
            stores[key] = nil
        }
    }

    /// Every store of a Main reloads (after its handshake).
    func reloadStores(of mainDeviceID: UUID) {
        for store in stores.values where store.mainDeviceID == mainDeviceID {
            Task {
                await store.reload()
            }
        }
    }

    /// Yields the message of a failure of work the Workspace started by itself.
    func report(_ message: String) {
        Log.client.error("\(message)")
        for continuation in reportContinuations.values {
            continuation.yield(message)
        }
    }

    func topologyDidChange() {
        topologyRevision += 1
    }

    /// `<error>` of the messages: the ProtocolError message, the DataError message, else the localizedDescription.
    nonisolated static func message(of error: any Error) -> String {
        if let error = error as? ProtocolError {
            return error.message
        }
        if let error = error as? DataError {
            return error.message
        }
        return error.localizedDescription
    }

    // MARK: - Mesh

    /// Loads the credentials; when present, the cached registry of the same mesh, whose presence seeds the last-seen
    /// table.
    private func loadMesh() {
        credentials = environment.loadCredentials()
        hasMesh = credentials != nil
        guard let credentials else {
            mesh = nil
            recomputePresence()
            return
        }
        var devices: [DeviceRecord] = []
        if let cached = environment.loadRegistry() {
            if cached.meshID == credentials.meshID {
                devices = PresenceModel.mergeRegistry([], with: cached.devices)
                for entry in cached.presence {
                    raiseLastSeen(entry.deviceID, to: entry.lastSeen)
                }
            } else {
                Log.client.error("Ignored the cached registry of another mesh")
            }
        }
        mesh = MeshSnapshot(meshID: credentials.meshID, devices: devices, presence: [])
        recomputePresence()
        topologyRevision += 1
    }

    /// Loads the credentials again (a Mac that just became a Main may have created the mesh).
    private func reloadCredentials() {
        let loaded = environment.loadCredentials()
        credentials = loaded
        hasMesh = loaded != nil
        if let loaded {
            if mesh?.meshID != loaded.meshID {
                mesh = MeshSnapshot(meshID: loaded.meshID, devices: [], presence: [])
                reports = [:]
                recomputePresence()
                topologyRevision += 1
            }
        } else if mesh != nil {
            mesh = nil
            recomputePresence()
            topologyRevision += 1
        }
    }

    /// A snapshot received on a connection (`hello` result, `mesh.changed`, `meshSnapshot()`): its devices are
    /// merged and its presence becomes the connection's report. A snapshot of another mesh is ignored.
    func receiveSnapshot(_ snapshot: MeshSnapshot, from connection: MainConnection) {
        guard let credentials, snapshot.meshID == credentials.meshID else {
            Log.client.error("Ignored a registry of another mesh from \(connection.id, privacy: .public)")
            return
        }
        mergeRecords(snapshot.devices)
        storeReport(snapshot.presence, of: connection.id)
    }

    /// The registry merge, then, when it changed the registry: own name, connections and selections, presence,
    /// persistence, `topologyRevision`.
    func mergeRecords(_ incoming: [DeviceRecord]) {
        guard let current = mesh else { return }
        let merged = PresenceModel.mergeRegistry(current.devices, with: incoming)
        guard merged != current.devices else { return }
        mesh?.devices = merged
        // 1. Own name: the registry name wins.
        if let record = merged.first(where: { $0.id == device.id }), record.name != device.name {
            device.name = record.name
            environment.saveDevice(device)
        }
        // 2. Connections and selections.
        reconcileConnections(previousRecords: current.devices)
        applyMainGoneRule()
        // 3. Presence.
        recomputePresence()
        // 4. Persistence.
        scheduleRegistrySave()
        // 5.
        topologyRevision += 1
    }

    /// Stores a connection's report; each entry raises the last-seen table.
    private func storeReport(_ report: [Presence], of mainDeviceID: UUID) {
        reports[mainDeviceID] = report
        for entry in report {
            raiseLastSeen(entry.deviceID, to: entry.lastSeen)
        }
        recomputePresence()
        scheduleRegistrySave()
    }

    /// The connection left `connected` (or its handshake ended): every device its report showed online is last seen
    /// now, then the report is dropped.
    func dropReport(of mainDeviceID: UUID) {
        guard let report = reports.removeValue(forKey: mainDeviceID) else { return }
        let now = environment.now()
        for entry in report where entry.online {
            lastSeen[entry.deviceID] = now
        }
        recomputePresence()
        scheduleRegistrySave()
    }

    private func raiseLastSeen(_ deviceID: UUID, to date: Date) {
        if let current = lastSeen[deviceID], current >= date {
            return
        }
        lastSeen[deviceID] = date
    }

    /// `presence` and `mesh.presence` (sorted by device id).
    private func recomputePresence() {
        let merged = PresenceModel.mergePresence(devices: mesh?.devices ?? [], reports: Array(reports.values),
                                                 lastSeen: lastSeen, localDeviceID: device.id,
                                                 now: environment.now())
        presence = merged
        if mesh != nil {
            mesh?.presence = merged.values.sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
        }
    }

    // MARK: - Registry persistence

    /// Without a local host link, `mesh` is saved 1 s after the last change of its devices or presence.
    private func scheduleRegistrySave() {
        guard localHostLink == nil, !isPreview, mesh != nil else { return }
        registrySavePending = true
        registrySaveTask?.cancel()
        registrySaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            self?.writeRegistry()
        }
    }

    private func writeRegistry() {
        registrySaveTask = nil
        guard registrySavePending, localHostLink == nil, let mesh else { return }
        registrySavePending = false
        let save = environment.saveRegistry
        let previous = registryWrite
        registryWrite = Task.detached {
            await previous?.value
            save(mesh)
        }
    }

    // MARK: - Connections

    /// The network Mains each get one connection while credentials are loaded; a network connection whose device is
    /// no longer a Main is closed and removed with its stores. A connection failed with a `retryAt` that is not nil
    /// whose record's addresses or port changed starts an attempt now.
    private func reconcileConnections(previousRecords: [DeviceRecord] = []) {
        let networkMains = credentials == nil ? [] : mains.filter { $0.id != device.id }
        let wanted = Set(networkMains.map(\.id))
        var changed = false
        for connection in Array(connections.values) where !connection.isLoopback && !wanted.contains(connection.id) {
            removeConnection(connection)
            changed = true
        }
        for record in networkMains where connections[record.id] == nil {
            let connection = MainConnection(id: record.id, workspace: self)
            connections[record.id] = connection
            changed = true
            if isStarted {
                connection.startConnecting()
            }
        }
        for record in networkMains {
            guard let old = previousRecords.first(where: { $0.id == record.id }),
                  old.addresses != record.addresses || old.port != record.port,
                  let connection = connections[record.id], case .failed(_, retryAt: .some) = connection.state
            else { continue }
            connection.attemptNow()
        }
        if changed {
            topologyRevision += 1
        }
    }

    /// Closes and removes a connection; its stores get `isRemoved = true` and are dropped.
    private func removeConnection(_ connection: MainConnection) {
        connection.close()
        if connections[connection.id] === connection {
            connections[connection.id] = nil
        }
        for (key, store) in stores where key.mainDeviceID == connection.id {
            store.markRemoved()
            stores[key] = nil
        }
    }

    /// The addresses an attempt tries, in order, without duplicates: the Bonjour advert when it matches this mesh and
    /// protocol version, then the record's addresses with its port.
    func addresses(of mainDeviceID: UUID, credentials: MeshCredentials) -> [(host: String, port: Int)] {
        var result: [(host: String, port: Int)] = []
        func add(_ host: String, _ port: Int) {
            guard !result.contains(where: { $0.host == host && $0.port == port }) else { return }
            result.append((host, port))
        }
        if let advert = seenHosts[mainDeviceID], advert.protocolVersion == WireCoding.protocolVersion,
           advert.meshTag == MeshCrypto.meshTag(credentials) {
            add(advert.host, advert.port)
        }
        if let record = record(of: mainDeviceID) {
            for address in record.addresses {
                add(address, record.port)
            }
        }
        return result
    }

    /// Reconnect sequence step 4: the centers and the Forge model learn the connection, then `connected` is emitted.
    func connectionDidConnect(_ connection: MainConnection) {
        sessionCenter.mainDidConnect(connection.id)
        forge.mainDidConnect(connection.id)
        emit(.connected(mainDeviceID: connection.id))
    }

    /// A drop, or the closing of a connected connection.
    func connectionDidLeaveConnected(_ connection: MainConnection) {
        sessionCenter.mainDidDisconnect(connection.id)
        forge.mainDidDisconnect(connection.id)
        emit(.disconnected(mainDeviceID: connection.id))
    }

    // MARK: - Bonjour

    private func startBrowsing() {
        let (stream, continuation) = AsyncStream.makeStream(of: [BonjourAdvert].self, bufferingPolicy: .unbounded)
        stopBrowsing = environment.browse { adverts in
            continuation.yield(adverts)
        }
        browseTask = Task { [weak self] in
            for await adverts in stream {
                self?.applySeenHosts(adverts)
            }
        }
    }

    private func stopBrowsingNow() {
        stopBrowsing?()
        stopBrowsing = nil
        browseTask?.cancel()
        browseTask = nil
    }

    /// Each list replaces `seenHosts`; a new or changed advert of a Main whose connection is failed with a `retryAt`
    /// that is not nil starts an attempt now.
    private func applySeenHosts(_ adverts: [BonjourAdvert]) {
        var hosts: [UUID: BonjourAdvert] = [:]
        for advert in adverts {
            hosts[advert.id] = advert
        }
        let previous = seenHosts
        seenHosts = hosts
        for (id, advert) in hosts where previous[id] != advert {
            if let connection = connections[id], case .failed(_, retryAt: .some) = connection.state {
                connection.attemptNow()
            }
        }
    }

    // MARK: - Incoming requests

    /// The request handler of every connection: `mesh.rekey`; any other method is unknown.
    func requestHandler(channel: ObservedChannel) -> RPCPeer.RequestHandler {
        { [weak self] request in
            guard request.method == RPCMethod.meshRekey.rawValue else {
                throw ProtocolError(.badRequest, "Unknown method \(request.method).")
            }
            let params = try request.decodeParams(MeshRekeyParams.self)
            guard let self else {
                throw ProtocolError(.internal, "Could not store the mesh key")
            }
            try await self.answerRekey(params.meshKey, requestID: request.id, channel: channel)
            return try WireCoding.encodeJSON(EmptyPayload())
        }
    }

    /// Stores a new mesh key; once the response is sent, the Workspace uses it and every network connection closes
    /// and starts an attempt at once with `failures = 0`.
    private func answerRekey(_ meshKey: Data, requestID: Int, channel: ObservedChannel) throws {
        guard meshKey.count == 32 else {
            throw ProtocolError(.badRequest, "The mesh key must be 32 bytes.")
        }
        guard let current = credentials else {
            Log.client.error("mesh.rekey received without mesh credentials")
            throw ProtocolError(.internal, "Could not store the mesh key")
        }
        guard meshKey != current.meshKey else { return }
        let rekeyed = MeshCredentials(meshID: current.meshID, meshKey: meshKey)
        do {
            try environment.saveCredentials(rekeyed)
        } catch {
            report("Could not store the mesh key: \(Self.message(of: error))")
            throw ProtocolError(.internal, "Could not store the mesh key")
        }
        channel.afterSendingResponse(to: requestID) { [weak self] in
            Task { @MainActor in
                self?.useRekeyedCredentials(rekeyed)
            }
        }
    }

    private func useRekeyedCredentials(_ rekeyed: MeshCredentials) {
        guard credentials?.meshID == rekeyed.meshID else { return }
        credentials = rekeyed
        for connection in connections.values where !connection.isLoopback {
            connection.reconnectAfterRekey()
        }
    }

    // MARK: - Events

    /// An event received on `connection`: the `projects.changed` and `skills.changed` events that arrive while their
    /// list is loading are queued; the others are applied at once.
    func handleEvent(_ event: ServerEvent, from connection: MainConnection) {
        switch event {
        case .projectsChanged(let payload):
            if let target = connections[payload.deviceID], target.projectsListsInFlight > 0 {
                target.queuedProjectsEvents.append((event, connection.id))
                return
            }
        case .skillsChanged:
            if connection.skillsListsInFlight > 0 {
                connection.queuedSkillsEvents.append(event)
                return
            }
        default:
            break
        }
        applyEvent(event, from: connection.id)
    }

    /// Applies an event of the Main `mainDeviceID`, forwards it, then yields it to every `events()` stream.
    func applyEvent(_ event: ServerEvent, from mainDeviceID: UUID) {
        switch event {
        case .meshChanged(let payload):
            if let connection = connections[mainDeviceID] {
                receiveSnapshot(payload.snapshot, from: connection)
            }
        case .projectsChanged(let payload):
            if let target = connections[payload.deviceID] {
                replaceProjects(payload.projects, of: target)
            }
        case .projectChanged(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.project.id)?.receive(event)
            if let connection = connections[mainDeviceID], connection.projectsLoaded,
               Self.chain(of: payload.project.id, in: connection.projects) == nil {
                Task {
                    do {
                        _ = try await connection.listProjects()
                    } catch {
                        let message = Self.message(of: error)
                        Log.client.error("projects.list failed on \(mainDeviceID, privacy: .public): \(message)")
                    }
                }
            }
        case .ticketChanged(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.projectID)?.receive(event)
        case .ticketRemoved(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.projectID)?.receive(event)
        case .bundleChanged(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.projectID)?.receive(event)
        case .bundleRemoved(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.projectID)?.receive(event)
        case .sessionChanged(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.projectID)?.receive(event)
            sessionCenter.handleSessionChanged(mainDeviceID: mainDeviceID, projectID: payload.projectID,
                                               session: payload.session)
        case .sessionRemoved(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.projectID)?.receive(event)
            sessionCenter.handleSessionRemoved(mainDeviceID: mainDeviceID, projectID: payload.projectID,
                                               sessionID: payload.sessionID)
        case .sessionEvent(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.projectID)?
                .reloadIfUnknown(sessionID: payload.sessionID)
            sessionCenter.handleSessionEvent(mainDeviceID: mainDeviceID, projectID: payload.projectID,
                                             sessionID: payload.sessionID, event: payload.event)
        case .sessionDelta(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.projectID)?
                .reloadIfUnknown(sessionID: payload.sessionID)
            sessionCenter.handleSessionDelta(mainDeviceID: mainDeviceID, projectID: payload.projectID,
                                             sessionID: payload.sessionID, messageID: payload.messageID,
                                             index: payload.index, kind: payload.kind, text: payload.text)
        case .permissionRequested(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.projectID)?
                .reloadIfUnknown(sessionID: payload.sessionID)
            sessionCenter.handlePermissionRequested(mainDeviceID: mainDeviceID, projectID: payload.projectID,
                                                    sessionID: payload.sessionID, request: payload.request)
        case .permissionResolved(let payload):
            existingStore(mainDeviceID: mainDeviceID, projectID: payload.projectID)?
                .reloadIfUnknown(sessionID: payload.sessionID)
            sessionCenter.handlePermissionResolved(mainDeviceID: mainDeviceID, projectID: payload.projectID,
                                                   sessionID: payload.sessionID, requestID: payload.requestID,
                                                   decision: payload.decision, deviceID: payload.deviceID)
        case .skillsChanged(let payload):
            connections[mainDeviceID]?.setSkills(payload.skills)
        case .migrationProgress(let payload):
            let previous = migrations[payload.migrationID]
            migrations[payload.migrationID] = payload
            if previous?.state != payload.state {
                topologyRevision += 1
            }
            if payload.state == .completed {
                applyProjectMovedRule(payload)
            }
        case .forgeChanged(let payload):
            forge.apply(payload.state, from: mainDeviceID)
        case .filesChanged:
            break
        }
        emit(.event(mainDeviceID: mainDeviceID, event))
    }

    private func emit(_ event: WorkspaceEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Projects list

    /// A Main's tree is replaced: its stores of projects no longer in it are dropped, the selection rules 3 and 4 run,
    /// and a store is created for every project with pending permission requests.
    func replaceProjects(_ projects: [ProjectSummary], of connection: MainConnection) {
        let oldTree = connection.projects
        let wasLoaded = connection.projectsLoaded
        connection.setProjects(projects)
        if !wasLoaded || oldTree != projects {
            topologyRevision += 1
        }
        let ids = Set(Self.flatten(projects).map(\.id))
        for (key, store) in stores where key.mainDeviceID == connection.id && !ids.contains(key.projectID) {
            store.markRemoved()
            stores[key] = nil
        }
        applyProjectGoneRule(mainDeviceID: connection.id, oldTree: oldTree, newTree: projects)
        applyProjectAppearedRule(mainDeviceID: connection.id, newTree: projects)
        for summary in Self.flatten(projects) where summary.pendingPermissionCount > 0 {
            _ = projectStore(mainDeviceID: connection.id, projectID: summary.id)
        }
    }

    /// Every project of a tree, sub projects included, parents first.
    static func flatten(_ tree: [ProjectSummary]) -> [ProjectSummary] {
        var result: [ProjectSummary] = []
        for project in tree {
            result.append(project)
            result.append(contentsOf: flatten(project.children))
        }
        return result
    }

    /// The summaries from the top-level project down to `projectID`; nil when it is not in the tree.
    static func chain(of projectID: String, in tree: [ProjectSummary]) -> [ProjectSummary]? {
        for project in tree {
            if project.id == projectID {
                return [project]
            }
            if let chain = chain(of: projectID, in: project.children) {
                return [project] + chain
            }
        }
        return nil
    }

    // MARK: - Selection rules

    private func liveSelections() -> [SelectionEntry] {
        selections.removeAll { $0.selection == nil }
        return selections
    }

    /// Rule 1: after a registry change, a selection on a device that is no longer a Main (nor the local connection)
    /// loses its Main, project and item.
    private func applyMainGoneRule() {
        var mainIDs = Set(mains.map(\.id))
        if let localConnection {
            mainIDs.insert(localConnection.id)
        }
        for entry in liveSelections() {
            guard let selection = entry.selection, let mainDeviceID = selection.mainDeviceID,
                  !mainIDs.contains(mainDeviceID)
            else { continue }
            selection.mainDeviceID = nil
            selection.projectID = nil
            selection.item = nil
            entry.waiting = nil
        }
    }

    /// Rule 2: a migration completed; the selections on its source of the project, of a project under it, or waiting
    /// on it move to the destination.
    private func applyProjectMovedRule(_ migration: MigrationProgressPayload) {
        let sourceTree = connections[migration.fromDeviceID]?.projects ?? []
        let moved = Self.chain(of: migration.projectID, in: sourceTree)?.last
        let underMoved = Set(Self.flatten(moved?.children ?? []).map(\.id))
        for entry in liveSelections() {
            guard let selection = entry.selection, selection.mainDeviceID == migration.fromDeviceID,
                  let projectID = selection.projectID
            else { continue }
            let waits = entry.waiting?.migrationID == migration.migrationID && entry.waiting?.projectID == projectID
            if projectID == migration.projectID || underMoved.contains(projectID) || waits {
                selection.mainDeviceID = migration.toDeviceID
                entry.waiting = nil
            }
        }
    }

    /// Rule 3: the tree of a Main lost the project of a selection: it moves to another connected Main holding it,
    /// waits on the migration of its top-level project, or falls back to the deepest project of its old chain.
    private func applyProjectGoneRule(mainDeviceID: UUID, oldTree: [ProjectSummary], newTree: [ProjectSummary]) {
        let newIDs = Set(Self.flatten(newTree).map(\.id))
        for entry in liveSelections() {
            guard let selection = entry.selection, selection.mainDeviceID == mainDeviceID,
                  let projectID = selection.projectID, !newIDs.contains(projectID),
                  let oldChain = Self.chain(of: projectID, in: oldTree)
            else { continue }
            if let other = connectedMain(holding: projectID, except: mainDeviceID) {
                selection.mainDeviceID = other
                entry.waiting = nil
                continue
            }
            if let topLevel = oldChain.first?.id,
               let migration = migrations.values.first(where: {
                   $0.fromDeviceID == mainDeviceID && $0.projectID == topLevel
                       && [.preparing, .transferring, .committing, .completed].contains($0.state)
               }) {
                entry.waiting = SelectionEntry.Waiting(migrationID: migration.migrationID, projectID: projectID)
                continue
            }
            selection.projectID = oldChain.reversed().first { newIDs.contains($0.id) }?.id
            selection.item = nil
            entry.waiting = nil
        }
    }

    /// Rule 4: the tree of a Main got the project of a selection on another Main whose loaded tree lacks it: the
    /// selection moves there.
    private func applyProjectAppearedRule(mainDeviceID: UUID, newTree: [ProjectSummary]) {
        let newIDs = Set(Self.flatten(newTree).map(\.id))
        for entry in liveSelections() {
            guard let selection = entry.selection, let selectedMain = selection.mainDeviceID,
                  selectedMain != mainDeviceID, let projectID = selection.projectID, newIDs.contains(projectID),
                  let selectedConnection = connections[selectedMain], selectedConnection.projectsLoaded,
                  Self.chain(of: projectID, in: selectedConnection.projects) == nil
            else { continue }
            selection.mainDeviceID = mainDeviceID
            entry.waiting = nil
        }
    }

    /// The first connected Main, in `mains` order, other than `mainDeviceID`, whose tree holds the project.
    private func connectedMain(holding projectID: String, except mainDeviceID: UUID) -> UUID? {
        var order = mains.map(\.id)
        if let localConnection, !order.contains(localConnection.id) {
            order.append(localConnection.id)
        }
        return order.first { id in
            guard id != mainDeviceID, let connection = connections[id], connection.isConnected else { return false }
            return Self.chain(of: projectID, in: connection.projects) != nil
        }
    }

    // MARK: - Reset

    /// Closes every connection and forgets the credentials, registry, presence, last-seen table, reports,
    /// migrations, connections and stores.
    private func forgetMirroredState() {
        for connection in connections.values {
            connection.close()
        }
        for store in stores.values {
            store.markRemoved()
        }
        stores = [:]
        connections = [:]
        credentials = nil
        hasMesh = false
        mesh = nil
        reports = [:]
        lastSeen = [:]
        presence = [:]
        migrations = [:]
        registrySaveTask?.cancel()
        registrySaveTask = nil
        registrySavePending = false
        applyMainGoneRule()
        topologyRevision += 1
    }

    // MARK: - Preview

    /// Sets the state of `Workspace.preview()` from the sample data.
    func applyPreview(mesh: MeshSnapshot, credentials: MeshCredentials) {
        self.credentials = credentials
        hasMesh = true
        self.mesh = mesh
        presence = Dictionary(uniqueKeysWithValues: mesh.presence.map { ($0.deviceID, $0) })
    }

    func addPreviewConnection(_ connection: MainConnection) {
        connections[connection.id] = connection
    }

    /// A store loaded with the sample snapshot, without a request.
    func addPreviewStore(mainDeviceID: UUID, snapshot: ProjectsSnapshotResult) {
        let store = ProjectStore(workspace: self, mainDeviceID: mainDeviceID, projectID: snapshot.project.id)
        store.applyPreview(snapshot)
        stores[StoreKey(mainDeviceID: mainDeviceID, projectID: snapshot.project.id)] = store
        sessionCenter.handleSessions(mainDeviceID: mainDeviceID, projectID: snapshot.project.id,
                                     sessions: store.sessions)
    }
}

/// A store of a project of a Main.
struct StoreKey: Hashable {
    let mainDeviceID: UUID
    let projectID: String
}

/// A selection made by `makeSelection()`, held weakly, with the migration it waits on (selection rule 3).
@MainActor
final class SelectionEntry {
    struct Waiting {
        let migrationID: UUID
        let projectID: String
    }

    weak var selection: Selection?
    var waiting: Waiting?

    init(_ selection: Selection) {
        self.selection = selection
    }
}
