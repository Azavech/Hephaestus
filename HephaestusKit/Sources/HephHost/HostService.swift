#if os(macOS)
import Foundation
import HephCore
import HephNet
import Synchronization

/// What a Mac runs while it is a Main (docs/services/host.md): it serves the methods of the protocol to every
/// connection, owns the hosted projects, watches their folders and emits the events. `HostService.init` creates every
/// host object once (§1); `start()` activates them and `stop()` deactivates them.
public actor HostService {
    /// The app's instance, created at launch by makeShared before any other use.
    @MainActor public private(set) static var shared: HostService!

    /// Creates the app's instance with `HostOptions()` and stores it in `shared`.
    @MainActor public static func makeShared(appSupport: AppSupport, settings: SettingsStore,
                                             credentialStore: any MeshCredentialStore) -> HostService {
        let host = HostService(appSupport: appSupport, settings: settings, credentialStore: credentialStore)
        shared = host
        return host
    }

    public enum State: Sendable { case stopped, starting, running, stopping }
    public private(set) var state: State = .stopped
    /// Set when the network listener could not start (§3.1) or could not be replaced after a key change (§3.3); nil
    /// otherwise.
    public private(set) var listenerError: String?
    /// True when the last start() found projects.json unreadable and reset it (§6.2); the app shows a banner.
    public private(set) var projectsFileWasReset = false

    public nonisolated let appSupport: AppSupport
    public nonisolated let settingsStore: SettingsStore
    public nonisolated let credentialStore: any MeshCredentialStore
    nonisolated let options: HostOptions

    /// The host objects of §1, created by init once the host itself is initialized.
    private nonisolated let objectsCell = HostObjectsCell()

    /// Keeps the app out of App Nap while it is a Main (§3.1).
    private var activity: (any NSObjectProtocol)?
    /// The served connections (§4).
    private var connections: [UUID: Connection] = [:]
    /// The observers of §3.1 step 11.
    private var settingsObserver: Task<Void, Never>?
    private var peerLinkObserver: Task<Void, Never>?
    /// The settings value last compared by the settings observer (§3.4).
    private var observedSettings: DeviceSettings?
    /// The last lifecycle transition: start(), stop() and restartListener() run one at a time.
    private var lifecycleTail: Task<Void, Never>?
    /// One SessionArchive per registered project, created on first use (§12.1).
    private var archives: [String: SessionArchive] = [:]

    /// Creates every host object (§1). Tests pass an AppSupport on temporary folders (with its own Trash), an
    /// InMemoryCredentialStore and test options; the app passes HostOptions().
    public init(appSupport: AppSupport, settings: SettingsStore, credentialStore: any MeshCredentialStore,
                options: HostOptions = HostOptions()) {
        self.appSupport = appSupport
        self.settingsStore = settings
        self.credentialStore = credentialStore
        self.options = options
        objectsCell.store(HostObjects(host: self, appSupport: appSupport, settings: settings,
                                      credentialStore: credentialStore, options: options))
    }

    // MARK: - Host objects (§1)

    private nonisolated var objects: HostObjects {
        guard let objects = objectsCell.objects else {
            fatalError("HostService.init has not created the host objects")
        }
        return objects
    }

    public nonisolated var events: EventHub { objects.events }
    nonisolated var registry: ProjectRegistry { objects.registry }
    nonisolated var watcher: FileWatcher { objects.watcher }
    nonisolated var projects: ProjectService { objects.projects }
    nonisolated var tasks: TaskService { objects.tasks }
    nonisolated var bundles: BundleService { objects.bundles }
    nonisolated var tabs: TabService { objects.tabs }
    nonisolated var hostInfo: HostInfoService { objects.hostInfo }
    nonisolated var files: FileService { objects.files }
    public nonisolated var uploads: UploadService { objects.uploads }
    nonisolated var runs: RunService { objects.runs }
    nonisolated var search: SearchService { objects.search }
    public nonisolated var mesh: MeshService { objects.mesh }
    public nonisolated var migration: MigrationService { objects.migration }
    public nonisolated var sessions: SessionService { objects.sessions }
    public nonisolated var mcp: MCPServer { objects.mcp }
    public nonisolated var skills: SkillsService { objects.skills }
    public nonisolated var forge: ForgeService { objects.forge }

    // MARK: - Lifecycle (§3)

    /// Main toggle on, or app launch with isMain true.
    public func start() async throws {
        try await serialized {
            try await self.performStart()
        }
    }

    /// Main toggle off, leaving the mesh, app termination.
    public func stop() async {
        try? await serialized {
            await self.performStop()
        }
    }

    /// The listener port setting changed.
    public func restartListener() async {
        try? await serialized {
            await self.performRestartListener()
        }
    }

    /// mesh.boundListenerPort(): the port the network listener is bound to while it runs, kept during the 50 ms tries
    /// of its replacement after a key change (§3.3); nil otherwise.
    public func boundListenerPort() async -> Int? {
        await mesh.boundListenerPort()
    }

    /// Sets listenerError: MeshService, when it replaces the listener after a key change (§3.3).
    func setListenerError(_ message: String?) {
        listenerError = message
    }

    private func performStart() async throws {
        guard state == .stopped else { return }
        state = .starting
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Hephaestus is a Main")
        var startedServices = false
        do {
            // 1. The mesh.
            try await mesh.ensureMesh()
            // 2. The projects, then the migration recovery.
            projectsFileWasReset = await registry.load()
            await migration.recover()
            // 3. File watching and the upload store.
            await watcher.start()
            await uploads.start()
            startedServices = true
            // 4. host.info.
            await hostInfo.refresh()
            // 5. The MCP server, before any session process.
            try await mcp.start()
        } catch {
            if startedServices {
                await watcher.stopAll()
                await uploads.stop()
                await migration.stop()
                await registry.unload()
            }
            endActivity()
            state = .stopped
            Log.host.error("The host could not start: \(ProjectRegistry.protocolError(error).message)")
            throw error
        }
        // 6 and 7. Sessions and skills.
        await sessions.start()
        await skills.start()
        // 8. The Forge.
        let settings = await settings()
        observedSettings = settings
        await forge.configure(Self.forgeConfig(settings))
        // 9. The network listener; a failure does not fail start().
        await startListener()
        // 10. Bonjour.
        await mesh.startAdvertising()
        // 11. The observers.
        startObservers()
        // 12. The peer links.
        await mesh.startPeerLinks()
        state = .running
        Log.host.info("The host runs")
    }

    private func performStop() async {
        guard state == .running else { return }
        state = .stopping
        // 1. Peer links, Bonjour, listener; the observers.
        await mesh.stopPeerLinks()
        await mesh.stopAdvertising()
        await mesh.stopListener()
        settingsObserver?.cancel()
        settingsObserver = nil
        peerLinkObserver?.cancel()
        peerLinkObserver = nil
        // 2. Every served connection, network and loopback.
        await events.closeAll()
        for connection in connections.values {
            connection.peer.close()
        }
        // 3. Forge, skills, migration.
        await forge.shutdown()
        await skills.stop()
        await migration.stop()
        // 4. Sessions and runs, concurrently.
        let sessions = sessions
        let runs = runs
        async let sessionsStopped: Void = sessions.stopAll()
        async let runsStopped: Void = runs.stopAll(projectID: nil)
        _ = await (sessionsStopped, runsStopped)
        // 5. MCP server, file watching, uploads, search cache, projects.
        await mcp.stop()
        await watcher.stopAll()
        await uploads.stop()
        await search.clearCache()
        await registry.unload()
        archives.removeAll()
        endActivity()
        state = .stopped
        listenerError = nil
        Log.host.info("The host stopped")
    }

    private func performRestartListener() async {
        guard state == .running else { return }
        await mesh.stopAdvertising()
        await mesh.stopListener()
        await startListener()
        await mesh.startAdvertising()
    }

    /// `mesh.startListener(acceptor:)`; `listenerError` is set from the outcome.
    private func startListener() async {
        do {
            try await mesh.startListener(acceptor: { [weak self] channel in
                guard let self else {
                    channel.close()
                    return
                }
                await self.accept(channel)
            })
            listenerError = nil
        } catch {
            listenerError = error.localizedDescription
            Log.host.error("The network listener could not start: \(error.localizedDescription)")
        }
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
    }

    /// Runs `body` after the lifecycle transitions requested before it.
    private func serialized<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = lifecycleTail
        let transition = Task<T, Error> {
            await previous?.value
            return try await body()
        }
        lifecycleTail = Task {
            _ = try? await transition.value
        }
        return try await transition.value
    }

    // MARK: - Settings changes (§3.4)

    /// The ForgeConfig of the forge settings, with the repository ForgeConfig.publicRepository, while forge.enabled is
    /// true; nil otherwise.
    static func forgeConfig(_ settings: DeviceSettings) -> ForgeConfig? {
        guard settings.forge.enabled else { return nil }
        return ForgeConfig(sourceProjectID: settings.forge.sourceProjectID, repository: ForgeConfig.publicRepository,
                           branch: settings.forge.branch, autoRegenerate: settings.forge.autoRegenerate)
    }

    /// Starts the observers of §3.1 step 11: settings changes and the peer link events.
    private func startObservers() {
        let store = settingsStore
        settingsObserver = Task { [weak self] in
            let changes = await MainActor.run { store.changes() }
            let current = await MainActor.run { store.settings }
            await self?.settingsChanged(current)
            for await value in changes {
                guard let self else { return }
                await self.settingsChanged(value)
            }
        }
        let mesh = mesh
        peerLinkObserver = Task { [weak self] in
            let events = await mesh.peerLinkEvents()
            for await event in events {
                guard let self else { return }
                await self.peerLinkEvent(event)
            }
        }
    }

    /// A change of any forge key → forge.configure; a change of claudePath → hostInfo.refresh().
    private func settingsChanged(_ value: DeviceSettings) async {
        guard state == .running || state == .starting else { return }
        let previous = observedSettings ?? value
        observedSettings = value
        if value.forge != previous.forge {
            await forge.configure(Self.forgeConfig(value))
        }
        if value.claudePath != previous.claudePath {
            await hostInfo.refresh()
        }
    }

    /// Sync triggers (§12.2): a link to another Main became connected, or an event arrived on it.
    private func peerLinkEvent(_ event: PeerLinkEvent) async {
        switch event {
        case .connected(let device):
            let skills = skills
            let migration = migration
            async let skillsPulled: Void = skills.peerLinkOpened(device.id)
            async let checksRun: Void = migration.peerLinkOpened(device.id)
            _ = await (skillsPulled, checksRun)
        case .event(let mainID, let inbound) where inbound.name == EventName.skillsChanged.rawValue:
            await skills.peerSkillsChanged(mainID)
        default:
            break
        }
    }

    /// The current device settings (SettingsStore.settings, read on the main actor).
    public func settings() async -> DeviceSettings {
        let store = settingsStore
        return await MainActor.run { store.settings }
    }

    // MARK: - Connections (§4)

    /// One served connection.
    private struct Connection {
        let peer: RPCPeer
        /// The hello device, once the handshake succeeded.
        var device: DeviceInfo?
        /// A hello is being handled.
        var helloStarted = false
        /// mesh.connectionOpened, started right after the hello.
        var opened: Task<Void, Never>?
    }

    /// Serves one connection (network or loopback) until it closes (§4).
    public func accept(_ channel: any MessageChannel) async {
        guard state == .running else {
            channel.close()
            return
        }
        let peer = RPCPeer(channel: channel)
        let connectionID = UUID()
        connections[connectionID] = Connection(peer: peer)
        await peer.setRequestHandler { [weak self] request in
            guard let self else { throw ProtocolError(.unavailable, "Not connected.") }
            return try await self.handleRequest(request, connectionID: connectionID)
        }
        let inboundEvents = Task { [weak self] in
            for await _ in peer.events {
                await self?.eventReceived(connectionID: connectionID)
            }
        }
        let handshakeTimeout = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            await self?.handshakeTimedOut(connectionID: connectionID)
        }
        await peer.run()
        handshakeTimeout.cancel()
        inboundEvents.cancel()
        // §4.3 Closing.
        let connection = connections.removeValue(forKey: connectionID)
        await connection?.opened?.value
        await events.remove(connectionID)
        await mesh.connectionClosed(connectionID: connectionID)
    }

    /// LoopbackChannel.makePair(): serves the server end, returns the client end for this Mac's Workspace.
    public func makeLoopbackChannel() async -> any MessageChannel {
        let pair = LoopbackChannel.makePair()
        let server = pair.server
        Task {
            await self.accept(server)
        }
        return pair.client
    }

    /// An event received before the handshake closes the connection; later events are ignored.
    private func eventReceived(connectionID: UUID) {
        guard let connection = connections[connectionID], connection.device == nil else { return }
        connection.peer.close()
    }

    /// No hello 10 s after accept: the connection is closed.
    private func handshakeTimedOut(connectionID: UUID) {
        guard let connection = connections[connectionID], connection.device == nil else { return }
        Log.host.info("Closed a connection without hello")
        connection.peer.close()
    }

    /// The handshake, the subscriptions, then the dispatch of §4.4.
    private func handleRequest(_ request: InboundRequest, connectionID: UUID) async throws -> Data {
        guard let connection = connections[connectionID] else {
            throw ProtocolError(.unavailable, "Not connected.")
        }
        if let device = connection.device {
            switch request.method {
            case RPCMethod.hello.rawValue:
                throw ProtocolError(.badRequest, "Already authenticated")
            case RPCMethod.subscribe.rawValue:
                let params = try Self.decode(SubscribeParams.self, request.params, request.method)
                await events.subscribe(connectionID, try Self.topics(params.topics))
                return try WireCoding.encodeJSON(EmptyPayload())
            case RPCMethod.unsubscribe.rawValue:
                let params = try Self.decode(UnsubscribeParams.self, request.params, request.method)
                await events.unsubscribe(connectionID, try Self.topics(params.topics))
                return try WireCoding.encodeJSON(EmptyPayload())
            default:
                let context = RequestContext(device: device, connectionID: connectionID, author: nil)
                return try await dispatch(request.method, params: request.params, context: context)
            }
        }
        guard request.method == RPCMethod.hello.rawValue else {
            // Before the handshake: closed without a reply.
            connection.peer.close()
            throw ProtocolError(.unauthorized, "Not authenticated.")
        }
        guard !connection.helloStarted else {
            throw ProtocolError(.badRequest, "Already authenticated")
        }
        connections[connectionID]?.helloStarted = true
        return try await hello(request, connectionID: connectionID, peer: connection.peer)
    }

    /// §4.2: the checks, each failure answered with an error response and then the close; on success the
    /// connection is authenticated and registered for broadcast events.
    private func hello(_ request: InboundRequest, connectionID: UUID, peer: RPCPeer) async throws -> Data {
        let params: HelloParams
        do {
            params = try WireCoding.decodeJSON(HelloParams.self, from: request.params)
        } catch {
            throw refuse(ProtocolError(.badRequest, "Invalid hello"), request: request, peer: peer)
        }
        guard params.protocolVersion == WireCoding.protocolVersion else {
            throw refuse(ProtocolError(.badRequest, "Unsupported protocol version \(params.protocolVersion)"),
                         request: request, peer: peer)
        }
        guard !params.device.isMain || params.device.platform == .macOS else {
            throw refuse(ProtocolError(.badRequest, "Only a Mac can be a Main"), request: request, peer: peer)
        }
        guard await !mesh.isRevoked(params.device.id) else {
            throw refuse(ProtocolError(.unauthorized, "This device was removed from the mesh"), request: request,
                         peer: peer)
        }
        guard connections[connectionID] != nil else {
            throw ProtocolError(.unavailable, "Not connected.")
        }
        // 1. Authenticated. 2. Broadcast events.
        connections[connectionID]?.device = params.device
        await events.add(connectionID, peer: peer)
        // 3. The result.
        let result = HelloResult(device: await mesh.localDevice(), mesh: await mesh.snapshot())
        // 4. Presence and the registry record, in a new task.
        let mesh = mesh
        let device = params.device
        let opened = Task {
            await mesh.connectionOpened(device: device, connectionID: connectionID, peer: peer)
        }
        connections[connectionID]?.opened = opened
        Log.host.info("Connection of \(device.id.uuidString, privacy: .public) authenticated")
        return try WireCoding.encodeJSON(result)
    }

    /// Sends the error response of a refused hello, then closes the connection; returns the error to throw (its own
    /// response is dropped, the channel being closed).
    private func refuse(_ error: ProtocolError, request: InboundRequest, peer: RPCPeer) -> ProtocolError {
        if let frame = try? WireCoding.encodeError(id: request.id, error: error) {
            peer.channel.send(frame)
        }
        peer.close()
        Log.host.info("Refused a hello: \(error.message)")
        return error
    }

    /// Each topic parsed with `Topic(rawValue:)`; one that does not parse fails the request.
    private static func topics(_ values: [String]) throws -> [Topic] {
        try values.map { value in
            guard let topic = Topic(rawValue: value) else {
                throw ProtocolError(.badRequest, "Invalid topic \(value)")
            }
            return topic
        }
    }

    // MARK: - Dispatch (§4.4)

    /// A session of this Main is starting, running or waitingPermission, a run is running, or a migration runs
    /// (§12.5).
    public func hasActiveWork() async -> Bool {
        guard state == .running else { return false }
        if await sessions.isRunningTurn() {
            return true
        }
        if await runs.activeRunCount(projectID: nil) > 0 {
            return true
        }
        return await migration.isActive()
    }

    /// Runs a method in process exactly as if it came from a connection (§4.4); JSON params and result.
    public func perform(_ method: String, params: Data, context: RequestContext) async throws -> Data {
        switch method {
        case RPCMethod.hello.rawValue, RPCMethod.subscribe.rawValue, RPCMethod.unsubscribe.rawValue:
            throw ProtocolError(.badRequest, "\(method) cannot be performed in process.")
        default:
            return try await dispatch(method, params: params, context: context)
        }
    }

    /// Steps 1 to 4 of §4.4: the method, its callers, its handler; errors as protocol errors.
    private func dispatch(_ method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            guard let known = RPCMethod(rawValue: method) else {
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
            switch known.callers {
            case .anyDevice:
                break
            case .mainPeers:
                if context.connectionID != nil, !context.device.isMain {
                    throw ProtocolError(.unauthorized, "Main only")
                }
            case .servingMain:
                throw ProtocolError(.badRequest, "mesh.rekey is not served by a Main")
            }
            return try await route(known, params: params, context: context)
        } catch {
            let protocolError = ProjectRegistry.protocolError(error)
            if protocolError.code == .internal {
                Log.host.error("\(method, privacy: .public) failed: \(protocolError.message)")
            }
            throw protocolError
        }
    }

    /// The handler of the dispatch table.
    private func route(_ method: RPCMethod, params: Data, context: RequestContext) async throws -> Data {
        let name = method.rawValue
        let handler: any HostMethodHandler
        switch method {
        case .hello, .subscribe, .unsubscribe:
            throw ProtocolError(.badRequest, "\(name) cannot be performed in process.")
        case .meshSnapshot, .meshSync, .meshRenameDevice, .meshRevokeDevice, .meshRekey, .meshSetAddresses,
             .pairingOpen, .pairingClose:
            handler = mesh
        case .hostInfo, .hostListDirectories:
            handler = hostInfo
        case .projectsList, .projectsSnapshot, .projectsCreate, .projectsImport, .projectsUpdate, .projectsRemove:
            handler = projects
        case .projectsMigrate, .migrationBegin, .migrationChunk, .migrationCommit, .migrationAbort, .migrationStatus:
            handler = migration
        case .uploadsBegin, .uploadsChunk, .uploadsCancel:
            handler = uploads
        case .tasksCreate, .tasksUpdate, .tasksDelete, .tasksAddComment, .tasksUpdateComment, .tasksDeleteComment,
             .attachmentsRead:
            handler = tasks
        case .bundlesCreate, .bundlesUpdate, .bundlesDelete, .bundlesStart, .bundlesStop:
            handler = bundles
        case .filesList, .filesRead, .filesWrite, .filesCreate, .filesRename, .filesDelete:
            handler = files
        case .tabsOpen, .tabsUpdate, .tabsClose, .tabsMove:
            handler = tabs
        case .sessionsStart, .sessionsHistory, .sessionsReadAttachment, .sessionsSend, .sessionsInterrupt,
             .sessionsStop, .sessionsRespond, .sessionsUpdate, .sessionsDelete:
            handler = sessions
        case .runsStart, .runsStop, .runsOutput:
            handler = runs
        case .searchQuery:
            handler = search
        case .skillsList, .skillsCreate, .skillsFiles, .skillsReadFile, .skillsWriteFile, .skillsDeleteFile,
             .skillsRename, .skillsDelete, .skillsManifest:
            handler = skills
        case .forgeStatus:
            _ = try Self.decode(EmptyPayload.self, params, name)
            return try WireCoding.encodeJSON(await forge.status())
        case .forgeFeedback:
            let request = try Self.decode(ForgeFeedbackParams.self, params, name)
            let result = try await forge.feedback(screenshot: request.screenshot, comment: request.comment,
                                                  context: request.context, from: context.device.id)
            return try WireCoding.encodeJSON(result)
        case .forgeRegenerate:
            _ = try Self.decode(EmptyPayload.self, params, name)
            try await forge.regenerate()
            return try WireCoding.encodeJSON(EmptyPayload())
        case .forgeRetry:
            let request = try Self.decode(ForgeRetryParams.self, params, name)
            try await forge.retry(itemTaskID: request.itemTaskID)
            return try WireCoding.encodeJSON(EmptyPayload())
        }
        return try await handler.handle(method: name, params: params, context: context)
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }

    // MARK: - Events (§5)

    /// Delivers an event (§5). Every service of this doc emits through it.
    public func emit(_ event: ServerEvent) async {
        if event.topic != nil {
            await events.publish(event)
        } else {
            await events.broadcast(event)
        }
        switch event {
        case .sessionChanged(let payload):
            await registry.setPendingPermissions(payload.projectID, sessionID: payload.session.id,
                                                 count: payload.session.pendingPermissions.count)
            await bundles.sessionChanged(projectID: payload.projectID, session: payload.session)
            await forge.sessionChanged(projectID: payload.projectID, session: payload.session)
        case .sessionRemoved(let payload):
            await registry.setPendingPermissions(payload.projectID, sessionID: payload.sessionID, count: 0)
            await forge.sessionRemoved(projectID: payload.projectID, sessionID: payload.sessionID.uuidString)
        case .taskChanged(let payload):
            await forge.taskChanged(projectID: payload.projectID, task: payload.task)
        case .taskRemoved(let payload):
            await forge.taskRemoved(projectID: payload.projectID, taskID: payload.taskID)
        case .projectsChanged:
            await dropUnregisteredArchives()
        default:
            break
        }
    }

    /// The SessionArchive of a project is dropped at its unregistration.
    private func dropUnregisteredArchives() async {
        guard !archives.isEmpty else { return }
        let registered = Set(await registry.all().map(\.id))
        archives = archives.filter { registered.contains($0.key) }
    }

    /// Forwards JSON to another Main over the peer link (§12.2).
    private func forward(_ method: String, params: Data, to deviceID: UUID, timeout: Duration) async throws -> Data {
        let value: JSONValue
        do {
            value = try WireCoding.decodeJSON(JSONValue.self, from: params)
        } catch {
            throw ProtocolError(.badRequest, "Invalid params for \(method).")
        }
        let result = try await mesh.requestPeer(deviceID, method: method, params: value, as: JSONValue.self,
                                                timeout: timeout)
        return try WireCoding.encodeJSON(result)
    }

    /// The methods that carry or return file content, or attach uploads: 120 s on another Main
    /// (../client/workspace.md, Conventions).
    private static let longMethods: Set<String> = [
        RPCMethod.uploadsChunk, .tasksAddComment, .sessionsStart, .sessionsSend, .forgeFeedback, .filesWrite,
        .filesRead, .attachmentsRead, .sessionsReadAttachment, .skillsReadFile, .skillsWriteFile,
    ].reduce(into: Set<String>()) { $0.insert($1.rawValue) }
}

// MARK: - SessionHost (§12.1)

extension HostService: SessionHost {
    public func localDevice() async -> DeviceInfo {
        await mesh.localDevice()
    }

    /// The records of the registry with `revoked == false`.
    public func devices() async -> [DeviceRecord] {
        await mesh.snapshot().devices.filter { !$0.revoked }
    }

    /// A parent that is not hosted (both are being unregistered) throws the notFound of registry.hosted(_:) for it, so
    /// that cli.md 3.5 never takes a sub project for a top-level project.
    public func claudeProject(_ projectID: String) async throws -> ClaudeProjectContext {
        let project = try await registry.hosted(projectID)
        let codeFolder = Self.folder(project.root, project.file.code)
        var parent: ProjectRef?
        if let parentID = project.parentID {
            let parentProject = try await registry.hosted(parentID)
            parent = ProjectRef(id: parentProject.id, name: parentProject.file.name, root: parentProject.root)
        }
        let subprojects = await registry.children(of: projectID).map { child in
            ProjectRef(id: child.id, name: child.file.name, root: child.root)
        }
        return ClaudeProjectContext(id: project.id, name: project.file.name, root: project.root,
                                    codeFolder: codeFolder, docsFolder: Self.folder(codeFolder, project.file.docs),
                                    parent: parent, subprojects: subprojects, claude: project.file.claudeDefaults,
                                    skills: project.file.skills)
    }

    public func claudeTask(projectID: String, taskID: String) async throws -> ClaudeTaskContext {
        let item = try await tasks.task(projectID: projectID, taskID: taskID)
        let project = try await registry.hosted(projectID)
        guard let id = TaskID(taskID) else {
            throw ProtocolError(.notFound, "Task \(taskID) does not exist.")
        }
        let yaml: String
        do {
            yaml = try String(contentsOf: TaskFile.url(projectRoot: project.root, id: id), encoding: .utf8)
        } catch {
            throw ProtocolError(.notFound, "Task \(taskID) does not exist.")
        }
        let folder = TaskFile.attachmentsFolder(projectRoot: project.root, id: id)
        let attachments = item.comments.flatMap { comment in
            comment.attachments.map { folder.appendingPathComponent($0.file, isDirectory: false) }
        }
        return ClaudeTaskContext(id: item.id, name: item.name, description: item.description, yaml: yaml,
                                 attachments: attachments, parseError: item.parseError)
    }

    /// From the cached BundleItem and the cached TaskItem of each of its tasks.
    public func claudeBundle(projectID: String, bundleID: String) async throws -> ClaudeBundleContext {
        let id = BundleID(bundleID)?.description ?? bundleID
        guard let bundle = await bundles.list(projectID: projectID).first(where: { $0.id == id }) else {
            throw ProtocolError(.notFound, "Bundle \(id) does not exist.")
        }
        var tasks: [ClaudeBundleTask] = []
        for task in bundle.tasks {
            let item = try? await self.tasks.task(projectID: projectID, taskID: task.taskID)
            tasks.append(ClaudeBundleTask(id: task.taskID, name: item?.name ?? "", status: item?.status))
        }
        return ClaudeBundleContext(id: bundle.id, name: bundle.name, base: bundle.base ?? "", tasks: tasks,
                                   maxParallel: await settings().bundles.maxParallel)
    }

    public func bundleWorkFolder(projectID: String, taskID: String) async throws -> URL {
        try await bundles.workFolder(projectID: projectID, taskID: taskID)
    }

    public func checkWritable(_ projectID: String) async throws {
        try await registry.checkWritable(projectID)
    }

    /// One SessionArchive(projectRoot: root) per registered project, created on first use.
    public func sessionArchive(_ projectID: String) async throws -> SessionArchive {
        let project = try await registry.hosted(projectID)
        if let archive = archives[projectID], archive.projectRoot == project.root {
            return archive
        }
        let archive = SessionArchive(projectRoot: project.root)
        archives[projectID] = archive
        return archive
    }

    public func sessionChanged(projectID: String, session: SessionInfo) async {
        await emit(.sessionChanged(SessionChangedPayload(projectID: projectID, session: session)))
    }

    public func sessionRemoved(projectID: String, sessionID: UUID) async {
        await emit(.sessionRemoved(SessionRemovedPayload(projectID: projectID, sessionID: sessionID)))
    }

    public func sessionEvent(projectID: String, sessionID: UUID, event: SessionEvent) async {
        await emit(.sessionEvent(SessionEventPayload(projectID: projectID, sessionID: sessionID, event: event)))
    }

    public func sessionDelta(projectID: String, sessionID: UUID, messageID: String, index: Int,
                             kind: SessionDeltaKind, text: String) async {
        await emit(.sessionDelta(SessionDeltaPayload(projectID: projectID, sessionID: sessionID,
                                                     messageID: messageID, index: index, kind: kind, text: text)))
    }

    public func permissionRequested(projectID: String, sessionID: UUID, request: PermissionRequest) async {
        await emit(.permissionRequested(PermissionRequestedPayload(projectID: projectID, sessionID: sessionID,
                                                                   request: request)))
    }

    public func permissionResolved(projectID: String, sessionID: UUID, requestID: String,
                                   decision: PermissionDecision, deviceID: UUID) async {
        await emit(.permissionResolved(PermissionResolvedPayload(projectID: projectID, sessionID: sessionID,
                                                                 requestID: requestID, decision: decision,
                                                                 deviceID: deviceID)))
    }

    /// `base` + a relative folder of project.yml (`.` is `base`).
    private static func folder(_ base: URL, _ relative: String) -> URL {
        guard relative != "." else { return base }
        return base.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
    }
}

// MARK: - SkillsHost (§12.2)

extension HostService: SkillsHost {
    public func appSupport() async -> AppSupport {
        appSupport
    }

    public func broadcastSkillsChanged(_ skills: [SkillSummary]) async {
        await emit(.skillsChanged(SkillsChangedPayload(skills: skills)))
    }

    public func requestPeer(_ deviceID: UUID, method: String, params: Data) async throws -> Data {
        try await forward(method, params: params, to: deviceID, timeout: RPCPeer.defaultTimeout)
    }
}

// MARK: - MCPHost (§12.3)

extension HostService: MCPHost {
    public func localMain() async -> MCPMain {
        let device = await mesh.localDevice()
        return MCPMain(id: device.id, name: device.name, online: true)
    }

    /// The non-revoked records with `isMain` other than this Main; online when in `mesh.connectedPeerMains()`.
    public func otherMains() async -> [MCPMain] {
        let localID = await mesh.localDevice().id
        let connected = Set(await mesh.connectedPeerMains().map(\.id))
        return await mesh.snapshot().devices
            .filter { $0.isMain && !$0.revoked && $0.id != localID }
            .map { MCPMain(id: $0.id, name: $0.name, online: connected.contains($0.id)) }
    }

    public func perform(_ method: String, params: Data, on deviceID: UUID) async throws -> Data {
        let local = await mesh.localDevice()
        if deviceID == local.id {
            return try await perform(method, params: params, context: .local(device: local, author: "Claude"))
        }
        let timeout = Self.longMethods.contains(method) ? Duration.seconds(120) : RPCPeer.defaultTimeout
        return try await forward(method, params: params, to: deviceID, timeout: timeout)
    }

    public func localProjectRoot(_ projectID: String) async -> URL? {
        try? await registry.hosted(projectID).root
    }

    public func forgePushDocs(sessionID: UUID) async throws -> String {
        try await forge.pushDocs(sessionID: sessionID)
    }

    public func forgePushRegen(sessionID: UUID) async throws -> String {
        try await forge.pushRegen(sessionID: sessionID)
    }

    /// The BundleService function of a bundle tool, its result as JSON text. `instructions` of start_bundle_task empty
    /// after trimming counts as absent.
    public func bundleTool(_ name: String, projectID: String, bundleID: String, arguments: Data) async throws
        -> String {
        let result: Data
        switch name {
        case "get_bundle":
            result = try WireCoding.encodeJSON(try await bundles.details(projectID: projectID, bundleID: bundleID))
        case "start_bundle_task":
            let request = try Self.decodeArguments(StartBundleTaskArguments.self, arguments, name)
            let instructions = request.instructions.flatMap { text in
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            }
            result = try WireCoding.encodeJSON(try await bundles.startTask(projectID: projectID, bundleID: bundleID,
                                                                           taskID: request.task,
                                                                           instructions: instructions))
        case "update_bundle":
            let request = try Self.decodeArguments(UpdateBundleArguments.self, arguments, name)
            result = try WireCoding.encodeJSON(try await bundles.setStatus(projectID: projectID, bundleID: bundleID,
                                                                           status: request.status))
        case "finish_bundle":
            result = try WireCoding.encodeJSON(try await bundles.finish(projectID: projectID, bundleID: bundleID))
        default:
            throw ProtocolError(.badRequest, "Unknown tool: \(name)")
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// The arguments of start_bundle_task.
    private struct StartBundleTaskArguments: Decodable {
        var task: String
        var instructions: String?
    }

    /// The arguments of update_bundle.
    private struct UpdateBundleArguments: Decodable {
        var status: BundleStatus
    }

    /// WireCoding decoding of a tool's arguments; a failure is badRequest "Invalid params for <tool>: <coding path>.".
    private static func decodeArguments<P: Decodable>(_ type: P.Type, _ arguments: Data, _ tool: String) throws -> P {
        try InboundRequest(id: 1, method: tool, params: arguments).decodeParams(type)
    }
}

// MARK: - Types (§2)

/// The network side of a HostService in tests (../testing.md); the app uses HostOptions().
public struct HostOptions: Sendable {
    public var listenerHost: String?   // address the network listener binds; nil: every interface
    public var listenerPort: Int?      // replaces the listenerPort setting; 0: any free port; nil: the setting
    public var bonjour: Bool           // false: no Bonjour advertisement, no Bonjour browser for the peer links

    public init(listenerHost: String? = nil, listenerPort: Int? = nil, bonjour: Bool = true) {
        self.listenerHost = listenerHost
        self.listenerPort = listenerPort
        self.bonjour = bonjour
    }
}

/// Who sends a request. Passed to every handler.
public struct RequestContext: Sendable {
    public var device: DeviceInfo      // the hello device; this Main's DeviceInfo for in-process calls
    public var connectionID: UUID?     // nil for in-process calls
    public var author: String?         // comment author for in-process calls ("Claude" for MCP tools)

    public init(device: DeviceInfo, connectionID: UUID? = nil, author: String? = nil) {
        self.device = device
        self.connectionID = connectionID
        self.author = author
    }

    /// An in-process call made as this Main (the MCP tools, ../claude/mcp.md).
    public static func local(device: DeviceInfo, author: String?) -> RequestContext {
        RequestContext(device: device, connectionID: nil, author: author)
    }
}

/// Implemented by every service whose methods are routed to it (§4.4).
public protocol HostMethodHandler: Actor {
    /// `params`: UTF-8 JSON of the request's params object (`InboundRequest.params`). Returns UTF-8 JSON of the
    /// result object. Throws `ProtocolError`; any other error is converted with `ProtocolError.init(_:)`.
    func handle(method: String, params: Data, context: RequestContext) async throws -> Data
}

/// Any JSON value. Carries JSON through typed APIs unchanged (requests forwarded to other Mains, §12).
enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The host objects of §1.
private struct HostObjects: Sendable {
    let events: EventHub
    let registry: ProjectRegistry
    let watcher: FileWatcher
    let projects: ProjectService
    let tasks: TaskService
    let bundles: BundleService
    let tabs: TabService
    let hostInfo: HostInfoService
    let files: FileService
    let uploads: UploadService
    let runs: RunService
    let search: SearchService
    let mesh: MeshService
    let migration: MigrationService
    let sessions: SessionService
    let mcp: MCPServer
    let skills: SkillsService
    let forge: ForgeService

    init(host: HostService, appSupport: AppSupport, settings: SettingsStore,
         credentialStore: any MeshCredentialStore, options: HostOptions) {
        events = EventHub(host: host)
        registry = ProjectRegistry(host: host)
        watcher = FileWatcher(host: host)
        projects = ProjectService(host: host)
        tasks = TaskService(host: host)
        bundles = BundleService(host: host)
        tabs = TabService(host: host)
        hostInfo = HostInfoService(host: host)
        files = FileService(host: host)
        uploads = UploadService(host: host)
        runs = RunService(host: host)
        search = SearchService(host: host)
        mesh = MeshService(host: host, appSupport: appSupport, settings: settings, credentialStore: credentialStore,
                           options: options)
        migration = MigrationService(host: host)
        sessions = SessionService(host: host)
        mcp = MCPServer(host: host)
        skills = SkillsService(host: host)
        forge = ForgeService(host: host)
    }
}

/// Holds the host objects, stored once by HostService.init; read from any isolation behind a lock.
private final class HostObjectsCell: Sendable {
    private let value = Mutex<HostObjects?>(nil)

    func store(_ objects: HostObjects) {
        value.withLock { $0 = objects }
    }

    var objects: HostObjects? {
        value.withLock { $0 }
    }
}
#endif
