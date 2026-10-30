#if os(macOS)
import CryptoKit
import Foundation
import HephCore
import HephNet
import Network

/// A change of the outgoing peer links, or an event received on one (docs/devices/mesh.md, "Swift API").
public enum PeerLinkEvent: Sendable {
    case connected(DeviceInfo)                  // an outgoing link completed hello and its first mesh.sync
    case disconnected(UUID)                     // that link closed
    case event(mainID: UUID, InboundEvent)      // an event received on an outgoing link
}

/// The mesh on a Main (docs/devices/mesh.md): credentials and keys, the listener and its Bonjour advertisement,
/// pairing, the registry and its sync, revocation and key rotation, presence, and the outgoing peer links.
public actor MeshService: HostMethodHandler {
    let host: HostService
    let appSupport: AppSupport
    let settings: SettingsStore
    let credentialStore: any MeshCredentialStore
    let options: HostOptions

    /// device.json: this Main's id and its name before it has a record.
    private var identity: DeviceFile?
    /// The id used while device.json cannot be read (a broken installation, logged).
    private let fallbackID = UUID()
    /// The key in use.
    private(set) var credentials: MeshCredentials?
    private(set) var registry: MeshRegistry?
    private(set) var presence = PresenceTable()
    /// After resignMain(): this Main's record says it is not a Main.
    private var resigned = false
    /// The computed addresses of this Main.
    private var addresses: [String] = []
    /// The listenerPort setting, read when the mesh is ensured and when the listener starts.
    private var listenerPortSetting = DeviceSettings().listenerPort

    private var listener: WebSocketListener?
    /// The port the mesh listener is bound to, kept while it is replaced; nil when it does not run.
    private var listenerBinding: Int?
    /// Changes with each start, stop and replacement of the mesh listener; a replacement of an older one stops.
    private var listenerGeneration = 0
    /// The port a failed replacement of the mesh listener is started on again in the background (key-change reaction
    /// step 2); nil when no retry runs. `boundListenerPort()` is nil meanwhile.
    private var listenerRetryPort: Int?
    private var listenerRetryTask: Task<Void, Never>?
    private var acceptor: (@Sendable (any MessageChannel) async -> Void)?
    private var advertising = false
    private var advertisement: Advertisement?

    let pairing = PairingHost()
    let links = PeerLinkManager()
    private let hostAddresses = HostAddresses()

    private var credentialObserver: Task<Void, Never>?
    /// The last key received on an outgoing link, with the Main that sent it.
    private var receivedKey: (key: Data, sender: UUID)?
    private var meshChangedTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var savePending = false
    private var peerLinksStarted = false
    private var browser: BonjourBrowser?
    private var browserTask: Task<Void, Never>?
    private(set) var adverts: [UUID: BonjourAdvert] = [:]
    private var pathTask: Task<Void, Never>?
    private var pathDelay: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var linkEventContinuations: [UUID: AsyncStream<PeerLinkEvent>.Continuation] = [:]

    /// What is advertised; the service is set again when it changes.
    private struct Advertisement: Equatable {
        let name: String
        let meshTag: String
        let host: String
        let port: Int
        let pairingOpen: Bool
        let pairingPort: Int
    }

    public init(host: HostService, appSupport: AppSupport, settings: SettingsStore,
                credentialStore: any MeshCredentialStore, options: HostOptions) {
        self.host = host
        self.appSupport = appSupport
        self.settings = settings
        self.credentialStore = credentialStore
        self.options = options
        identity = try? DeviceFile.load(appSupport)
    }

    // MARK: - Lifecycle (services/host.md §3)

    /// Loads the credentials, creating the mesh without them; loads the registry and applies the own-record rule;
    /// starts iterating `credentialStore.changes()` the first time only. Throws a DataError when the credential store
    /// fails.
    public func ensureMesh() async throws {
        resigned = false
        try await loadMesh()
    }

    public func startListener(acceptor: @escaping @Sendable (any MessageChannel) async -> Void) async throws {
        self.acceptor = acceptor
        listenerGeneration += 1
        let generation = listenerGeneration
        endListenerRetries()
        listener?.stop()
        listener = nil
        listenerBinding = nil
        advertisement = nil
        guard let credentials, let key = MeshCrypto.transportKey(credentials) else {
            throw MeshTransportError.invalidCredentials
        }
        let store = settings
        listenerPortSetting = await MainActor.run { store.settings.listenerPort }
        let started = WebSocketListener(port: options.listenerPort ?? listenerPortSetting, psk: key,
                                        identity: MeshConstants.transportIdentity, host: options.listenerHost)
        try await started.start(onChannel: { channel in
            Task { await acceptor(channel) }
        })
        guard listenerGeneration == generation else {
            started.stop()
            return
        }
        listener = started
        listenerBinding = started.port
        Log.host.info("The mesh listener runs on port \(started.port, privacy: .public)")
        await recomputeAddresses()
    }

    /// Stops the listener and closes the pairing window. Established connections stay open.
    public func stopListener() async {
        listenerGeneration += 1
        endListenerRetries()
        listener?.stop()
        listener = nil
        listenerBinding = nil
        advertisement = nil
        await pairing.close(mesh: self)
    }

    /// The port of the running mesh listener, kept during the 50 ms tries of its replacement after a key change;
    /// nil otherwise.
    public func boundListenerPort() async -> Int? {
        listenerBinding
    }

    public func startAdvertising() async {
        guard options.bonjour, listener != nil else { return }
        advertising = true
        await updateAdvertisement()
    }

    public func stopAdvertising() async {
        advertising = false
        advertisement = nil
        listener?.setService(nil)
    }

    public func startPeerLinks() async {
        guard !peerLinksStarted else { return }
        peerLinksStarted = true
        if options.bonjour {
            let (stream, continuation) = AsyncStream.makeStream(of: [BonjourAdvert].self,
                                                               bufferingPolicy: .bufferingNewest(1))
            let browser = BonjourBrowser()
            browser.start { adverts in continuation.yield(adverts) }
            self.browser = browser
            browserTask = Task { [weak self] in
                for await adverts in stream {
                    await self?.advertsChanged(adverts)
                }
            }
        }
        let (updates, update) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        hostAddresses.startMonitor { update.yield(()) }
        pathTask = Task { [weak self] in
            for await _ in updates {
                await self?.pathChanged()
            }
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: MeshConstants.addressRefreshInterval)
                } catch {
                    return
                }
                await self?.recomputeAddresses()
            }
        }
        links.start(mesh: self)
    }

    /// Closes every outgoing link, stops the browser, the path monitor and the refresh, writes a pending registry save.
    public func stopPeerLinks() async {
        peerLinksStarted = false
        links.stopAll(mesh: self)
        browser?.stop()
        browser = nil
        browserTask?.cancel()
        browserTask = nil
        adverts.removeAll()
        hostAddresses.stopMonitor()
        pathTask?.cancel()
        pathTask = nil
        pathDelay?.cancel()
        pathDelay = nil
        refreshTask?.cancel()
        refreshTask = nil
        if savePending {
            saveRegistryNow()
        }
    }

    /// Main turned off or Leave mesh, before HostService.stop() (roles.md).
    public func resignMain() async {
        resigned = true
        _ = applyOwnRecordRule()
        saveRegistryNow()
        await links.syncAll(timeout: MeshConstants.resignTimeout, mesh: self)
        meshChangedTask?.cancel()
        meshChangedTask = nil
        await host.events.broadcast(.meshChanged(MeshChangedPayload(snapshot: currentSnapshot())))
        await pairing.close(mesh: self)
    }

    // MARK: - Connections (services/host.md §4)

    /// This Main: its own record's name, isMain true.
    public func localDevice() async -> DeviceInfo {
        localDeviceInfo()
    }

    /// The registry and the presence report.
    public func snapshot() async -> MeshSnapshot {
        currentSnapshot()
    }

    public func isRevoked(_ deviceID: UUID) async -> Bool {
        registry?.isRevoked(deviceID) ?? false
    }

    /// Admission (docs/devices/mesh.md, "Admission (hello)").
    public func connectionOpened(device: DeviceInfo, connectionID: UUID, peer: RPCPeer) async {
        presence.add(connectionID, deviceID: device.id, peer: peer, outgoing: false)
        if var registry {
            let now = Date()
            var changed = false
            if var record = registry.record(device.id) {
                if record.platform != device.platform || record.isMain != device.isMain
                    || record.appVersion != device.appVersion || record.build != device.build {
                    if !device.isMain, record.isMain {
                        record.addresses = []
                        record.port = 0
                    }
                    record.platform = device.platform
                    record.isMain = device.isMain
                    record.appVersion = device.appVersion
                    record.build = device.build
                    record.updatedAt = registry.updateDate(for: device.id, now: now)
                    registry.set(record)
                    changed = true
                }
            } else {
                registry.set(DeviceRecord(id: device.id, name: device.name, platform: device.platform,
                                          isMain: device.isMain, addresses: [], port: 0, appVersion: device.appVersion,
                                          build: device.build, pairedAt: now, updatedAt: now, revoked: false))
                changed = true
            }
            self.registry = registry
            if changed {
                _ = applyOwnRecordRule()
                registryChanged(changedIDs: [device.id])
            }
        }
        refreshPresence()
    }

    public func connectionClosed(connectionID: UUID) async {
        presence.remove(connectionID)
        refreshPresence()
        await host.migration.connectionClosed(connectionID: connectionID)
    }

    // MARK: - Peer links (other host services)

    /// The DeviceInfo of each Main with an established outgoing link, sorted by name.
    public func connectedPeerMains() async -> [DeviceInfo] {
        links.connectedMains()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One request on the established outgoing link to that Main.
    public func requestPeer<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ deviceID: UUID, method: String, params: P, as resultType: R.Type, timeout: Duration) async throws -> R {
        let name = registry?.record(deviceID)?.name ?? deviceID.uuidString
        guard let peer = links.establishedPeer(deviceID) else {
            throw ProtocolError(.unavailable, "\(name) is not connected.")
        }
        do {
            return try await peer.request(method, params, as: resultType, timeout: timeout)
        } catch let error as ProtocolError
                    where error.code == .unavailable && error.message == "The device did not answer in time." {
            throw ProtocolError(.unavailable, "\(name) did not answer in time.")
        } catch let error as ProtocolError where error.code == .unavailable && error.message == "Not connected." {
            throw ProtocolError(.unavailable, "\(name) is not connected.")
        }
    }

    /// A new stream of link changes and of the events received on outgoing links.
    public func peerLinkEvents() -> AsyncStream<PeerLinkEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: PeerLinkEvent.self, bufferingPolicy: .unbounded)
        let id = UUID()
        linkEventContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLinkEventStream(id) }
        }
        return stream
    }

    // MARK: - HostMethodHandler

    /// mesh.snapshot, mesh.sync, mesh.renameDevice, mesh.revokeDevice, mesh.setAddresses, pairing.open, pairing.close.
    public func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .meshSnapshot:
                _ = try Self.decode(EmptyPayload.self, params, method)
                return try WireCoding.encodeJSON(currentSnapshot())
            case .meshSync:
                let request = try Self.decode(MeshSyncParams.self, params, method)
                mergeRecords(request.devices)
                storeRelayed(request.presence, from: context.device.id)
                return try WireCoding.encodeJSON(MeshSyncResult(devices: registry?.records ?? [],
                                                                presence: directEntries()))
            case .meshRenameDevice:
                let request = try Self.decode(MeshRenameDeviceParams.self, params, method)
                return try WireCoding.encodeJSON(try await rename(request.deviceID, to: request.name))
            case .meshRevokeDevice:
                let request = try Self.decode(MeshRevokeDeviceParams.self, params, method)
                try revoke(request.deviceID)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .meshSetAddresses:
                let request = try Self.decode(MeshSetAddressesParams.self, params, method)
                return try WireCoding.encodeJSON(try await setAddresses(request.addresses))
            case .pairingOpen:
                _ = try Self.decode(EmptyPayload.self, params, method)
                return try WireCoding.encodeJSON(try await pairing.open(mesh: self))
            case .pairingClose:
                _ = try Self.decode(EmptyPayload.self, params, method)
                await pairing.close(mesh: self)
                return try WireCoding.encodeJSON(EmptyPayload())
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - Methods

    /// mesh.renameDevice: trims the name; sets `name` and `updatedAt` on the record (revoked or not).
    private func rename(_ deviceID: UUID, to rawName: String) async throws -> DeviceRecord {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProtocolError(.badRequest, "Enter a device name.") }
        guard name.lowercased() != "claude" else { throw ProtocolError(.badRequest, "Claude is a reserved name.") }
        guard var registry, var record = registry.record(deviceID) else {
            throw ProtocolError(.notFound, "No device \(deviceID.uuidString).")
        }
        record.name = name
        record.updatedAt = registry.updateDate(for: deviceID, now: Date())
        registry.set(record)
        self.registry = registry
        registryChanged(changedIDs: [deviceID])
        if deviceID == ownID {
            await updateAdvertisement()
        }
        return record
    }

    /// mesh.setAddresses: the additionalAddresses setting, then this Main's recomputed record.
    private func setAddresses(_ entries: [String]) async throws -> DeviceRecord {
        var cleaned: [String] = []
        for entry in entries.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        where !entry.isEmpty && !cleaned.contains(entry) {
            cleaned.append(entry)
        }
        let store = settings
        let value = cleaned
        try await MainActor.run {
            try store.update { $0.additionalAddresses = value }
        }
        await recomputeAddresses()
        guard let record = registry?.record(ownID) else {
            throw ProtocolError(.notFound, "No device \(ownID.uuidString).")
        }
        return record
    }

    /// mesh.revokeDevice, steps 1–4 (docs/devices/mesh.md, "Revoking"); steps 5–9 run after the answer.
    private func revoke(_ deviceID: UUID) throws {
        guard var registry, var record = registry.record(deviceID) else {
            throw ProtocolError(.notFound, "No device \(deviceID.uuidString).")
        }
        guard deviceID != ownID else { throw ProtocolError(.badRequest, "A Main cannot revoke itself.") }
        if record.revoked { return }
        // 2.
        record.revoked = true
        record.updatedAt = registry.updateDate(for: deviceID, now: Date())
        registry.set(record)
        self.registry = registry
        saveRegistryNow()
        let connections = presence.removeDevice(deviceID)
        // 3.
        guard let current = credentials else { throw ProtocolError(.internal, "Could not store the mesh key.") }
        let rotated = MeshCredentials(meshID: current.meshID, meshKey: MeshCrypto.newMeshKey())
        try credentialStore.save(rotated)
        credentials = rotated
        Log.host.notice("Revoked the device \(deviceID.uuidString, privacy: .public); the mesh key was rotated")
        links.reconcile(changedIDs: [deviceID], mesh: self)
        scheduleMeshChanged()
        refreshPresence()
        // 4. The answer; then 5–9.
        Task {
            await self.finishRevocation(deviceID, key: rotated.meshKey, connections: connections)
        }
    }

    /// Revoking steps 5–9.
    private func finishRevocation(_ deviceID: UUID, key: Data, connections: [PresenceTable.Connection]) async {
        // 5. Every connection with the revoked device, inbound and outgoing.
        for connection in connections {
            connection.peer.close()
        }
        links.close(deviceID, mesh: self)
        // 6. mesh.sync on the outgoing links, so the other Mains know the revocation before they get the key.
        await links.syncAll(timeout: MeshConstants.rekeyTimeout, mesh: self)
        // 7. The listener uses the new transport key.
        await replaceListener()
        // 8. mesh.rekey on every inbound authenticated connection of a non-revoked device.
        let targets = presence.connections.values.filter { !$0.outgoing && !(registry?.isRevoked($0.deviceID) ?? false) }
        await Self.sendRekey(key, to: targets.map(\.peer))
        // 9. The outgoing links are redialed with the new key.
        links.redialAll(mesh: self)
    }

    // MARK: - Registry and presence

    /// device.json, the credentials (created when missing), the registry read from registry.json at every call, the
    /// own-record rule; the credential observer the first time only.
    func loadMesh() async throws {
        if identity == nil {
            guard let loaded = try DeviceFile.load(appSupport) else {
                throw DataError.notFound("device.json: the file does not exist")
            }
            identity = loaded
        }
        var stored = try credentialStore.load()
        if let invalid = stored, invalid.meshKey.count != 32 {
            Log.host.error("Ignoring mesh credentials whose key has \(invalid.meshKey.count, privacy: .public) bytes")
            stored = nil
        }
        let loaded: MeshCredentials
        if let stored {
            loaded = stored
        } else {
            loaded = MeshCredentials(meshID: UUID(), meshKey: MeshCrypto.newMeshKey())
            try credentialStore.save(loaded)
            Log.host.notice("Created the mesh \(loaded.meshID.uuidString, privacy: .public)")
        }
        credentials = loaded
        // registry.json is kept when it belongs to this mesh; its presence seeds the last-seen table.
        var table = PresenceTable()
        if let cached = RegistryCache.load(appSupport), cached.meshID == loaded.meshID {
            registry = MeshRegistry(meshID: loaded.meshID, records: cached.devices)
            table.seed(cached.presence)
        } else {
            registry = MeshRegistry(meshID: loaded.meshID)
        }
        presence = table
        let store = settings
        listenerPortSetting = await MainActor.run { store.settings.listenerPort }
        if credentialObserver == nil {
            let changes = credentialStore.changes()
            credentialObserver = Task { [weak self] in
                for await value in changes {
                    await self?.credentialsChanged(value)
                }
            }
        }
        await recomputeAddresses()
        refreshPresence()
    }

    /// The own-record rule with this Main's computed fields; true when the record was rewritten.
    func applyOwnRecordRule() -> Bool {
        guard var registry else { return false }
        let changed = registry.assertOwnRecord(id: ownID,
                                               defaultName: identity?.name ?? Self.fallbackName,
                                               isMain: !resigned,
                                               addresses: resigned ? [] : addresses,
                                               port: resigned ? 0 : (listenerBinding ?? listenerPortSetting),
                                               appVersion: Self.appVersion,
                                               build: Self.build,
                                               now: Date())
        self.registry = registry
        return changed
    }

    /// Merges records (docs/devices/mesh.md, "Merge"); a merge that changed something closes the connections of the
    /// devices that became revoked, applies the own-record rule, reconciles the links, saves and propagates.
    func mergeRecords(_ incoming: [DeviceRecord]) {
        guard var registry else { return }
        let changed = registry.merge(incoming)
        self.registry = registry
        guard !changed.isEmpty else { return }
        for record in changed where record.revoked {
            for connection in presence.removeDevice(record.id) {
                connection.peer.close()
            }
            links.close(record.id, mesh: self)
        }
        _ = applyOwnRecordRule()
        registryChanged(changedIDs: Set(changed.map(\.id)))
    }

    /// The direct entries of this Main now.
    func directEntries() -> [Presence] {
        guard let registry else { return [] }
        return presence.directEntries(selfID: ownID, records: registry.records, at: Date())
    }

    func allRecords() -> [DeviceRecord] {
        registry?.records ?? []
    }

    /// The `presence` of a `mesh.sync` with a peer Main: its relayed entries.
    func storeRelayed(_ entries: [Presence], from mainID: UUID) {
        presence.storeRelayed(entries, from: mainID)
        refreshPresence()
    }

    /// An outgoing link is established: it counts as a connection for presence.
    func linkEstablished(_ device: DeviceInfo, connectionID: UUID, peer: RPCPeer, relayed: [Presence]) {
        presence.add(connectionID, deviceID: device.id, peer: peer, outgoing: true)
        presence.storeRelayed(relayed, from: device.id)
        refreshPresence()
        yield(.connected(device))
        Log.host.info("Peer link to \(device.id.uuidString, privacy: .public) established")
    }

    /// An established outgoing link closed.
    func linkClosed(_ mainID: UUID, connectionID: UUID) {
        presence.remove(connectionID)
        refreshPresence()
        yield(.disconnected(mainID))
        Log.host.info("Peer link to \(mainID.uuidString, privacy: .public) closed")
    }

    /// Events on links: `mesh.changed` schedules a mesh.sync on that link; every event is yielded.
    func linkEvent(_ event: InboundEvent, mainID: UUID) {
        if event.name == EventName.meshChanged.rawValue {
            links.scheduleSync(mainID, mesh: self)
        }
        yield(.event(mainID: mainID, event))
    }

    /// The addresses of a link attempt (docs/devices/mesh.md, "Dialing"), without duplicates.
    func dialAddresses(for mainID: UUID) -> [(host: String, port: Int)] {
        var result: [(host: String, port: Int)] = []
        func add(_ host: String, _ port: Int) {
            if !result.contains(where: { $0.host == host && $0.port == port }) {
                result.append((host, port))
            }
        }
        if let advert = adverts[mainID], advert.protocolVersion == WireCoding.protocolVersion,
           advert.meshTag == MeshCrypto.meshTag(credentials) {
            add(advert.host, advert.port)
        }
        if let record = registry?.record(mainID) {
            for address in record.addresses {
                add(address, record.port)
            }
        }
        return result
    }

    /// The Mains to reach: every non-revoked record with isMain true other than this Main.
    func mainsToReach() -> Set<UUID> {
        Set((registry?.records ?? []).filter { $0.isMain && !$0.revoked && $0.id != ownID }.map(\.id))
    }

    /// mesh.rekey on an outgoing link (docs/devices/mesh.md, "Receiving a new key"); other methods are unknown.
    func serveLinkRequest(_ request: InboundRequest, from mainID: UUID) throws -> Data {
        guard request.method == RPCMethod.meshRekey.rawValue else {
            throw ProtocolError(.badRequest, "Unknown method \(request.method).")
        }
        let params = try request.decodeParams(MeshRekeyParams.self)
        guard params.meshKey.count == 32 else { throw ProtocolError(.badRequest, "The mesh key must be 32 bytes.") }
        receivedKey = (params.meshKey, mainID)
        let stored = try? credentialStore.load()
        if stored?.meshKey != params.meshKey {
            guard let meshID = stored?.meshID ?? credentials?.meshID else {
                throw ProtocolError(.internal, "Could not store the mesh key.")
            }
            do {
                try credentialStore.save(MeshCredentials(meshID: meshID, meshKey: params.meshKey))
            } catch {
                throw ProtocolError(.internal, "Could not store the mesh key.")
            }
        }
        return try WireCoding.encodeJSON(EmptyPayload())
    }

    var ownID: UUID {
        identity?.id ?? fallbackID
    }

    func localDeviceInfo() -> DeviceInfo {
        let name = registry?.record(ownID)?.name ?? identity?.name ?? Self.fallbackName
        return DeviceInfo(id: ownID, name: name, platform: .macOS, isMain: true, appVersion: Self.appVersion,
                          build: Self.build)
    }

    func currentSnapshot() -> MeshSnapshot {
        guard let registry else {
            return MeshSnapshot(meshID: credentials?.meshID ?? ownID, devices: [], presence: [])
        }
        return MeshSnapshot(meshID: registry.meshID, devices: registry.records,
                            presence: presence.report(selfID: ownID, records: registry.records, at: Date()))
    }

    /// The pairingPort setting.
    func pairingPortSetting() async -> Int {
        let store = settings
        return await MainActor.run { store.settings.pairingPort }
    }

    /// Sets the Bonjour service again when what it advertises changed (docs/devices/mesh.md, "Advertising").
    func updateAdvertisement() async {
        guard advertising, options.bonjour, let listener else { return }
        let pairingPort = await pairingPortSetting()
        guard advertising, self.listener === listener else { return }
        let device = localDeviceInfo()
        let current = Advertisement(name: BonjourTXT.serviceName(device.name),
                                    meshTag: MeshCrypto.meshTag(credentials),
                                    host: HostAddresses.localHostName() ?? "",
                                    port: listener.port,
                                    pairingOpen: pairing.isOpen,
                                    pairingPort: pairingPort)
        guard current != advertisement else { return }
        advertisement = current
        let txt = BonjourTXT.record(deviceID: device.id, meshTag: current.meshTag, host: current.host,
                                    port: current.port, pairingOpen: current.pairingOpen,
                                    pairingPort: current.pairingPort)
        listener.setService(NWListener.Service(name: current.name, type: MeshConstants.serviceType, domain: nil,
                                               txtRecord: txt))
    }

    // MARK: - Pairing and links (PairingHost, PeerLinkManager)

    func openPairingWindow() async throws -> PairingOpenResult {
        try await pairing.start(mesh: self)
    }

    func pairingChannel(_ channel: WebSocketChannel, generation: Int) async {
        await pairing.channelArrived(channel, generation: generation, mesh: self)
    }

    func pairingHandshakeFailed(generation: Int) async {
        await pairing.handshakeFailed(generation: generation, mesh: self)
    }

    func pairingExpired(generation: Int) async {
        await pairing.expired(generation: generation, mesh: self)
    }

    /// Pairing step 5: the joiner's record, replacing any record with that id; saved, announced and synced.
    func recordPairedDevice(_ device: DeviceInfo) {
        guard var registry else { return }
        let now = Date()
        registry.set(DeviceRecord(id: device.id, name: device.name, platform: device.platform, isMain: device.isMain,
                                  addresses: [], port: 0, appVersion: device.appVersion, build: device.build,
                                  pairedAt: now, updatedAt: registry.updateDate(for: device.id, now: now),
                                  revoked: false))
        self.registry = registry
        _ = applyOwnRecordRule()
        registryChanged(changedIDs: [device.id])
    }

    func runPeerLink(_ mainID: UUID, generation: Int) async {
        await links.run(mainID, generation: generation, mesh: self)
    }

    func sendLinkSync(_ mainID: UUID, generation: Int) async {
        await links.sendSync(mainID, generation: generation, mesh: self)
    }

    // MARK: - Private

    private static let fallbackName = "Mac"

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private static var build: Int {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) } ?? 0
    }

    /// After a registry change: the links are reconciled, the registry saved, mesh.changed and mesh.sync propagated.
    private func registryChanged(changedIDs: Set<UUID>) {
        links.reconcile(changedIDs: changedIDs, mesh: self)
        scheduleSave()
        scheduleMeshChanged()
        links.scheduleSyncAll(mesh: self)
        refreshPresence()
        if advertising, changedIDs.contains(ownID) {
            Task { await self.updateAdvertisement() }
        }
    }

    /// Recomputes the report: mesh.changed when it changed, mesh.sync when the direct entries changed, a save when the
    /// last-seen table changed.
    private func refreshPresence() {
        guard let registry else { return }
        let result = presence.refresh(selfID: ownID, records: registry.records, at: Date())
        if result.reportChanged {
            scheduleMeshChanged()
        }
        if result.directChanged {
            links.scheduleSyncAll(mesh: self)
        }
        if result.lastSeenChanged {
            scheduleSave()
        }
    }

    /// mesh.changed, `coalescingDelay` after the first of a burst of changes.
    private func scheduleMeshChanged() {
        guard meshChangedTask == nil else { return }
        meshChangedTask = Task {
            do {
                try await Task.sleep(for: MeshConstants.coalescingDelay)
            } catch {
                return
            }
            await self.broadcastMeshChanged()
        }
    }

    private func broadcastMeshChanged() async {
        meshChangedTask = nil
        await host.events.broadcast(.meshChanged(MeshChangedPayload(snapshot: currentSnapshot())))
    }

    /// registry.json, `registrySaveDelay` after the last change.
    private func scheduleSave() {
        savePending = true
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: MeshConstants.registrySaveDelay)
            } catch {
                return
            }
            self.saveRegistryNow()
        }
    }

    private func saveRegistryNow() {
        saveTask?.cancel()
        saveTask = nil
        savePending = false
        guard registry != nil else { return }
        do {
            try RegistryCache.save(currentSnapshot(), appSupport)
        } catch {
            Log.host.error("Could not save registry.json: \(ProjectRegistry.protocolError(error).message)")
        }
    }

    /// Recomputes this Main's addresses; a different result updates its record, a different host name the
    /// advertisement.
    private func recomputeAddresses() async {
        let store = settings
        let additional = await MainActor.run { store.settings.additionalAddresses }
        addresses = HostAddresses.compute(additionalAddresses: additional)
        if applyOwnRecordRule() {
            registryChanged(changedIDs: [ownID])
        }
        await updateAdvertisement()
    }

    /// A network path update: the addresses are recomputed `pathChangeDelay` later.
    private func pathChanged() {
        pathDelay?.cancel()
        pathDelay = Task {
            do {
                try await Task.sleep(for: MeshConstants.pathChangeDelay)
            } catch {
                return
            }
            await self.recomputeAddresses()
        }
    }

    /// The Bonjour adverts seen; a link whose Main's advert appeared or changed tries at once.
    private func advertsChanged(_ list: [BonjourAdvert]) {
        var seen: [UUID: BonjourAdvert] = [:]
        for advert in list {
            seen[advert.id] = advert
        }
        let changed = Set(seen.keys.filter { adverts[$0] != seen[$0] })
        adverts = seen
        links.advertsChanged(changed, mesh: self)
    }

    /// The key-change reaction (docs/devices/mesh.md, "Receiving a new key").
    private func credentialsChanged(_ value: MeshCredentials?) async {
        guard let value, let current = credentials, value.meshID == current.meshID else {
            Log.host.error("Ignored mesh credentials of another mesh, or none, while the host runs")
            return
        }
        guard value.meshKey != current.meshKey else { return }
        guard value.meshKey.count == 32 else {
            Log.host.error("Ignored a mesh key of \(value.meshKey.count, privacy: .public) bytes")
            return
        }
        // 1.
        credentials = value
        Log.host.notice("The mesh key changed")
        // 2.
        await replaceListener()
        // 3.
        let sender = receivedKey?.key == value.meshKey ? receivedKey?.sender : nil
        forwardKey(value.meshKey, sender: sender)
        // 4.
        if peerLinksStarted {
            links.redialAll(mesh: self)
        }
    }

    /// Forwards a key received from Main `sender` to the remotes it was not connected to, and to this Mac's own
    /// loopback connection when a sender is recorded; without waiting for the answers.
    private func forwardKey(_ key: Data, sender: UUID?) {
        guard let registry else { return }
        let reachedBySender = Set((sender.flatMap { presence.relayed[$0] } ?? []).map(\.deviceID))
        let targets = presence.connections.values.filter { connection in
            guard !connection.outgoing else { return false }
            if connection.deviceID == ownID {
                return sender != nil
            }
            guard let record = registry.record(connection.deviceID), !record.isMain, !record.revoked else {
                return false
            }
            return !reachedBySender.contains(connection.deviceID)
        }
        let peers = targets.map(\.peer)
        guard !peers.isEmpty else { return }
        Task {
            await Self.sendRekey(key, to: peers)
        }
    }

    /// mesh.rekey on each peer, in parallel, at most `rekeyTimeout` each; failures logged.
    private static func sendRekey(_ key: Data, to peers: [RPCPeer]) async {
        await withTaskGroup(of: Void.self) { group in
            for peer in peers {
                group.addTask {
                    do {
                        _ = try await peer.request(.meshRekey, MeshRekeyParams(meshKey: key), as: EmptyPayload.self,
                                                   timeout: MeshConstants.rekeyTimeout)
                    } catch {
                        Log.host.error("mesh.rekey failed: \(ProjectRegistry.protocolError(error).message)")
                    }
                }
            }
        }
    }

    /// The mesh listener uses the key in use (key-change reaction step 2, Revoking step 7): replaced on the port and
    /// address it is bound to, with the acceptor of the last startListener call; the advertisement is set again. The
    /// port of the listener just stopped can stay in use for a few milliseconds: a start that fails with
    /// `listenerFailed` is tried again every 50 ms, at most 40 times. When the last try fails, or the start fails another
    /// way, `listenerError` gets its message and the start is tried again in the background; this returns at once, so
    /// that the next steps run.
    private func replaceListener() async {
        guard let port = listenerBinding, let acceptor else { return }
        listenerGeneration += 1
        let generation = listenerGeneration
        listener?.stop()
        listener = nil
        advertisement = nil
        var retries = 0
        while true {
            do {
                let replacement = try await startTransportListener(port: port, acceptor: acceptor)
                guard listenerGeneration == generation else {
                    replacement.stop()
                    return
                }
                await adoptListener(replacement, port: port)
                return
            } catch MeshTransportError.listenerFailed where retries < 40 {
                retries += 1
                try? await Task.sleep(for: .milliseconds(50))
                guard listenerGeneration == generation else { return }
            } catch {
                guard listenerGeneration == generation else { return }
                // boundListenerPort() is nil and nothing is advertised until a start succeeds.
                listenerBinding = nil
                listenerRetryPort = port
                let message = error.localizedDescription
                Log.host.error("The mesh listener could not restart with the new key: \(message)")
                await host.setListenerError(message)
                guard listenerGeneration == generation, listenerRetryPort == port else { return }
                listenerRetryTask = Task { [weak self] in
                    await self?.retryListener(generation: generation)
                }
                return
            }
        }
    }

    /// The background retries of a failed replacement: after each delay of `backoff` (1, 2, 5, 10, then every 30 s),
    /// a start on the retried port with the key in use and the acceptor of the last startListener call. Each failure is
    /// logged and sets `listenerError` to its message; a success clears it, keeps the listener and sets the
    /// advertisement again. A startListener or stopListener call ends the retries.
    private func retryListener(generation: Int) async {
        var failures = 0
        while true {
            failures += 1
            do {
                try await Task.sleep(for: .seconds(MeshConstants.backoff[min(failures, 5) - 1]))
            } catch {
                return
            }
            guard listenerGeneration == generation, let port = listenerRetryPort, let acceptor else { return }
            do {
                let replacement = try await startTransportListener(port: port, acceptor: acceptor)
                guard listenerGeneration == generation else {
                    replacement.stop()
                    return
                }
                listenerRetryPort = nil
                listenerRetryTask = nil
                await adoptListener(replacement, port: port)
                await host.setListenerError(nil)
                return
            } catch {
                guard listenerGeneration == generation else { return }
                let message = error.localizedDescription
                Log.host.error("The mesh listener could not start again on port \(port, privacy: .public): \(message)")
                await host.setListenerError(message)
            }
        }
    }

    /// A mesh listener with the transport key of the key in use, on `port`, bound to `options.listenerHost`, started;
    /// every channel it delivers goes to `acceptor` in a new task.
    private func startTransportListener(
        port: Int, acceptor: @escaping @Sendable (any MessageChannel) async -> Void) async throws -> WebSocketListener {
        guard let credentials, let key = MeshCrypto.transportKey(credentials) else {
            throw MeshTransportError.invalidCredentials
        }
        let started = WebSocketListener(port: port, psk: key, identity: MeshConstants.transportIdentity,
                                        host: options.listenerHost)
        try await started.start(onChannel: { channel in
            Task { await acceptor(channel) }
        })
        return started
    }

    /// A replacement listener runs: it is kept, the own-record rule runs (the listener started) and the advertisement
    /// is set again when advertising.
    private func adoptListener(_ replacement: WebSocketListener, port: Int) async {
        listener = replacement
        listenerBinding = port
        Log.host.info("The mesh listener runs on port \(port, privacy: .public) with the new key")
        if applyOwnRecordRule() {
            registryChanged(changedIDs: [ownID])
        }
        await updateAdvertisement()
    }

    /// A startListener or stopListener call ends the background retries of a failed replacement.
    private func endListenerRetries() {
        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        listenerRetryPort = nil
    }

    private func yield(_ event: PeerLinkEvent) {
        for continuation in linkEventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeLinkEventStream(_ id: UUID) {
        linkEventContinuations[id] = nil
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}
#endif
