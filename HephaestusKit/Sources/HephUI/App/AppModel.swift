import Foundation
import HephClient
import HephCore
import Observation
#if os(macOS)
import AppKit
import HephHost
#endif

/// The root object of the app (docs/ui/shell.md §3): what lives as long as the app, and the app wiring.
@MainActor @Observable
public final class AppModel {
    public enum Phase: Equatable, Sendable { case launching, onboarding, ready }

    /// `AppModel(appSupport: AppSupport.standard())`; the app stops when Application Support is not available.
    public static let shared: AppModel = {
        do {
            return AppModel(appSupport: try AppSupport.standard())
        } catch {
            fatalError("Application Support is not available: \(error)")
        }
    }()

    /// The id of the main window group.
    public static let mainWindowID = "main"

    public let appSupport: AppSupport
    public let settings: SettingsStore
    public let identity: DeviceIdentityStore
    public let workspace: Workspace
    /// Posts banners to the active window (§8.2).
    public let banners: AppBannerRouter
    /// 3 s have passed since `workspace.start()` and since the last `WorkspaceEvent.disconnected` (§10).
    public private(set) var graceElapsed: Bool
    #if os(macOS)
    /// Running while this Mac is a Main.
    public let host: HostService
    /// Copy of `host.listenerError`, read after `host.start()` and `host.restartListener()`, and by
    /// `refreshListenerError()`.
    public private(set) var listenerError: String?
    public let updateModel: UpdateModel
    public let updater: UpdateService
    #endif

    /// `start()` has finished.
    private var launchFinished: Bool
    /// `becomeMain()` runs: a device without a mesh stays in onboarding until the host has created it.
    private var isTurningMainOn = false
    @ObservationIgnored private var startCalled = false
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var reportsTask: Task<Void, Never>?

    /// Only for `shared`: creates the stored properties in the order of the table of §3; on macOS the shared host.
    init(appSupport: AppSupport) {
        self.appSupport = appSupport
        let settings = SettingsStore(appSupport: appSupport)
        self.settings = settings
        let identity = DeviceIdentityStore(appSupport: appSupport, settings: settings)
        self.identity = identity
        workspace = Workspace(
            device: identity.deviceInfo,
            environment: .live(appSupport: appSupport, credentialStore: KeychainCredentialStore.shared,
                               identityStore: identity)
        )
        banners = AppBannerRouter()
        graceElapsed = false
        #if os(macOS)
        let host = HostService.makeShared(appSupport: appSupport, settings: settings,
                                          credentialStore: KeychainCredentialStore.shared)
        self.host = host
        listenerError = nil
        let updateModel = UpdateModel()
        self.updateModel = updateModel
        updater = UpdateService(model: updateModel, isBusy: { [identity, host] in
            guard await identity.isMain else { return false }
            return await host.hasActiveWork()
        })
        #endif
        launchFinished = false
    }

    #if os(macOS)
    /// The model of previews and snapshot tests (§5.4): every part given, nothing started.
    private init(appSupport: AppSupport, settings: SettingsStore, identity: DeviceIdentityStore, workspace: Workspace,
                 host: HostService, updateModel: UpdateModel, updater: UpdateService) {
        self.appSupport = appSupport
        self.settings = settings
        self.identity = identity
        self.workspace = workspace
        banners = AppBannerRouter()
        graceElapsed = true
        self.host = host
        listenerError = nil
        self.updateModel = updateModel
        self.updater = updater
        launchFinished = true
    }
    #else
    /// The model of previews and snapshot tests (§5.4): every part given, nothing started.
    private init(appSupport: AppSupport, settings: SettingsStore, identity: DeviceIdentityStore,
                 workspace: Workspace) {
        self.appSupport = appSupport
        self.settings = settings
        self.identity = identity
        self.workspace = workspace
        banners = AppBannerRouter()
        graceElapsed = true
        launchFinished = true
    }
    #endif

    /// A new model for previews and snapshot tests (§5.4): a temporary Application Support folder, the sample data's
    /// this device, `Workspace.preview()`; it starts nothing and uses neither the Keychain nor the app's folder.
    public static func preview() -> AppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephaestusPreview-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Log.ui.error("Could not create the preview folder: \(error.localizedDescription)")
        }
        let appSupport = AppSupport(root: root)
        let settings = SettingsStore(appSupport: appSupport)
        if let thisDevice = UUID(uuidString: "00000000-0000-4000-8000-000000000002") {
            do {
                try DeviceFile(id: thisDevice, name: "Sam's MacBook Pro").save(appSupport)
            } catch {
                Log.ui.error("Could not write the preview device.json: \(error.localizedDescription)")
            }
        }
        let identity = DeviceIdentityStore(appSupport: appSupport, settings: settings)
        #if os(macOS)
        let updateModel = UpdateModel()
        return AppModel(
            appSupport: appSupport,
            settings: settings,
            identity: identity,
            workspace: Workspace.preview(),
            host: HostService(appSupport: appSupport, settings: settings, credentialStore: InMemoryCredentialStore()),
            updateModel: updateModel,
            updater: UpdateService(model: updateModel, isBusy: { false })
        )
        #else
        return AppModel(appSupport: appSupport, settings: settings, identity: identity,
                        workspace: Workspace.preview())
        #endif
    }

    /// `.launching` until `start()` has finished; then `.onboarding` while the device has no mesh and is not a Main
    /// (nor becoming one: onboarding shows its progress and its failure, docs/ui/onboarding.md); else `.ready`.
    public var phase: Phase {
        guard launchFinished else { return .launching }
        if !workspace.hasMesh && (!identity.isMain || isTurningMainOn) {
            return .onboarding
        }
        return .ready
    }

    // MARK: - Launch (§3.1)

    /// The launch; only the first call runs, later calls return at once. The launch runs in a task of its own, so it
    /// finishes even when the window whose `.task` started it closes meanwhile.
    public func start() async {
        guard !startCalled else { return }
        startCalled = true
        await Task {
            await self.launch()
        }.value
    }

    /// The steps of §3.1.
    private func launch() async {
        #if os(macOS)
        if identity.isMain {
            do {
                try await host.start()
                workspace.setLocalHostLink(HostServiceLink(host: host))
                listenerError = await host.listenerError
                if await host.projectsFileWasReset {
                    postError("projects.json was unreadable and has been reset; folders are untouched")
                }
            } catch {
                let message = Banner.message(of: error)
                Log.ui.error("This Mac could not start as a Main: \(message)")
                postError("This Mac could not start as a Main: \(message)")
            }
        }
        #endif

        let events = workspace.events()
        workspace.start()
        startGraceTimer()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard case .disconnected = event else { continue }
                self?.connectionWasLost()
            }
        }

        let reports = workspace.errorReports()
        reportsTask = Task { [weak self] in
            for await message in reports {
                self?.postError(message)
            }
        }

        #if os(macOS)
        await updater.start()
        let updater = updater
        workspace.forge.releaseObserver = { build in
            Task {
                await updater.releaseNoticed(build: build)
            }
        }
        if let listenerError {
            postError("This Mac cannot accept connections from other devices: \(listenerError)")
        }
        #endif

        launchFinished = true
        Log.ui.info("Launch finished")
    }

    /// Sets `graceElapsed` 3 s from now, replacing the pending timer.
    private func startGraceTimer() {
        graceTask?.cancel()
        graceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            self?.graceElapsed = true
        }
    }

    /// A `WorkspaceEvent.disconnected`: the grace period starts again.
    private func connectionWasLost() {
        graceElapsed = false
        startGraceTimer()
    }

    private func postError(_ message: String) {
        banners.post(Banner(style: .error, message: message))
    }

    // MARK: - Device names (§3.2)

    /// Before the device belongs to a mesh: saves the local name and hands the identity to the Workspace.
    public func setLocalName(_ name: String) throws {
        try identity.setName(name)
        workspace.updateLocalDevice(identity.deviceInfo)
    }

    /// Renames a device of the mesh through `renameConnection`; throws `unavailable` "No Main is online." without one.
    public func renameDevice(_ id: UUID, to name: String) async throws {
        let validated = try DeviceIdentityStore.validateName(name)
        guard let connection = renameConnection else {
            throw ProtocolError(.unavailable, "No Main is online.")
        }
        _ = try await connection.renameDevice(id, to: validated)
    }

    /// The local connection when it is connected, else the first connected Main of `workspace.mains`, else nil.
    public var renameConnection: MainConnection? {
        if let local = workspace.localConnection, local.isConnected {
            return local
        }
        for main in workspace.mains {
            if let connection = workspace.connection(main.id), connection.isConnected {
                return connection
            }
        }
        return nil
    }

    // MARK: - Mesh membership (§3.4)

    /// Pairing stored the credentials and the registry: the Workspace starts again with them, so the grace period of
    /// §3.1 step 2 starts again.
    public func didJoinMesh() {
        workspace.restart()
        graceElapsed = false
        startGraceTimer()
    }

    /// Leaves the mesh, after the caller's confirmation (docs/devices/roles.md, Leaving the mesh, steps 3–5).
    public func leaveMesh() async throws {
        #if os(macOS)
        if identity.isMain {
            try await resignMain()
        }
        #endif
        try KeychainCredentialStore.shared.delete()
        try RegistryCache.delete(appSupport)
        workspace.reset()
        Log.ui.notice("Left the mesh")
    }

    #if os(macOS)
    // MARK: - Main toggle (§3.3)

    /// Turns this Mac into a Main; on a failure of the host the role is turned off again and the error rethrown.
    public func becomeMain() async throws {
        isTurningMainOn = true
        defer { isTurningMainOn = false }
        try identity.setIsMain(true)
        do {
            try await host.start()
        } catch {
            try? identity.setIsMain(false)
            throw error
        }
        workspace.setLocalHostLink(HostServiceLink(host: host))
        workspace.updateLocalDevice(identity.deviceInfo)
        listenerError = await host.listenerError
        if await host.projectsFileWasReset {
            postError("projects.json was unreadable and has been reset; folders are untouched")
        }
        Log.ui.notice("This Mac is a Main")
    }

    /// Stops being a Main, after the caller's confirmation.
    public func resignMain() async throws {
        await host.mesh.resignMain()
        await host.stop()
        try identity.setIsMain(false)
        workspace.setLocalHostLink(nil)
        workspace.updateLocalDevice(identity.deviceInfo)
        listenerError = nil
        Log.ui.notice("This Mac is no longer a Main")
    }

    /// A migration runs on this Mac, as source or destination.
    public func isMigrationActive() async -> Bool {
        await host.migration.isActive()
    }

    /// Restarts the listener after a change of its port.
    public func restartListener() async {
        await host.restartListener()
        listenerError = await host.listenerError
    }

    /// Reads `host.listenerError` again: `MeshService` sets or clears it when it replaces the listener after a key
    /// change. Settings ▸ General calls it when it appears.
    public func refreshListenerError() async {
        listenerError = await host.listenerError
    }

    // MARK: - Other app wiring (§3.5)

    /// App termination: stops the Workspace, the updater and the host; waits at most 10 s.
    public func shutdown() async {
        workspace.stop()
        let (finished, continuation) = AsyncStream.makeStream(of: Void.self)
        let updater = updater
        let host = host
        let stopsHost = identity.isMain
        Task {
            await updater.stop()
            if stopsHost {
                await host.stop()
            }
            continuation.yield()
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            continuation.yield()
        }
        for await _ in finished {
            break
        }
        deadline.cancel()
        continuation.finish()
    }

    /// The number of private terms (Settings ▸ Forge & Updates).
    public func privateTermsCount() -> Int {
        host.forge.privateTermsCount()
    }

    /// Writes the pre-filled private terms file when it is missing, then opens it in the default text editor.
    public func editPrivateTerms() async throws {
        let url = try await host.forge.preparePrivateTerms()
        NSWorkspace.shared.open(url)
    }

    /// The suggested private terms the file neither holds nor dismisses.
    public func privateTermSuggestions() async -> [String] {
        await host.forge.privateTermSuggestions()
    }

    /// Adds a suggested term to the private terms file.
    public func addPrivateTerm(_ term: String) async throws {
        try await host.forge.addPrivateTerm(term)
    }

    /// Dismisses a suggested term: the file records that it is not private.
    public func dismissPrivateTerm(_ term: String) async throws {
        try await host.forge.dismissPrivateTerm(term)
    }
    #endif
}
