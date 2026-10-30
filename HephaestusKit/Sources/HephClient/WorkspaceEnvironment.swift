import Foundation
import HephCore
import HephNet

/// What the Workspace needs from outside: storage, transport, Bonjour and time (docs/client/workspace.md,
/// "WorkspaceEnvironment"). The app passes `live(...)`, previews `preview`, tests their own closures.
public struct WorkspaceEnvironment: Sendable {
    public var loadCredentials: @Sendable () -> MeshCredentials?
    public var saveCredentials: @Sendable (MeshCredentials) throws -> Void
    public var loadRegistry: @Sendable () -> MeshSnapshot?
    public var saveRegistry: @Sendable (MeshSnapshot) -> Void
    public var saveDevice: @MainActor @Sendable (DeviceInfo) -> Void
    public var openChannel: @Sendable (_ url: URL, _ credentials: MeshCredentials) async throws -> any MessageChannel
    public var browse: @Sendable (_ onChange: @escaping @Sendable ([BonjourAdvert]) -> Void) -> @Sendable () -> Void
    public var sleep: @Sendable (_ duration: Duration) async throws -> Void
    public var now: @Sendable () -> Date
    public var attachmentCache: AttachmentCache

    public init(
        loadCredentials: @escaping @Sendable () -> MeshCredentials?,
        saveCredentials: @escaping @Sendable (MeshCredentials) throws -> Void,
        loadRegistry: @escaping @Sendable () -> MeshSnapshot?,
        saveRegistry: @escaping @Sendable (MeshSnapshot) -> Void,
        saveDevice: @escaping @MainActor @Sendable (DeviceInfo) -> Void,
        openChannel: @escaping @Sendable (_ url: URL, _ credentials: MeshCredentials) async throws
            -> any MessageChannel,
        browse: @escaping @Sendable (_ onChange: @escaping @Sendable ([BonjourAdvert]) -> Void)
            -> @Sendable () -> Void,
        sleep: @escaping @Sendable (_ duration: Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date,
        attachmentCache: AttachmentCache
    ) {
        self.loadCredentials = loadCredentials
        self.saveCredentials = saveCredentials
        self.loadRegistry = loadRegistry
        self.saveRegistry = saveRegistry
        self.saveDevice = saveDevice
        self.openChannel = openChannel
        self.browse = browse
        self.sleep = sleep
        self.now = now
        self.attachmentCache = attachmentCache
    }

    /// The environment of the app: the credential store, `registry.json`, the device identity, TLS-PSK WebSocket
    /// channels that give up after 5 s, Bonjour browsing, real time and the standard attachment cache.
    public static func live(appSupport: AppSupport, credentialStore: any MeshCredentialStore,
                            identityStore: DeviceIdentityStore) -> WorkspaceEnvironment {
        WorkspaceEnvironment(
            loadCredentials: {
                do {
                    return try credentialStore.load()
                } catch {
                    Log.client.error("Could not load the mesh credentials: \(String(describing: error))")
                    return nil
                }
            },
            saveCredentials: { credentials in
                try credentialStore.save(credentials)
            },
            loadRegistry: {
                RegistryCache.load(appSupport)
            },
            saveRegistry: { snapshot in
                do {
                    try RegistryCache.save(snapshot, appSupport)
                } catch {
                    Log.client.error("Could not save registry.json: \(String(describing: error))")
                }
            },
            saveDevice: { device in
                identityStore.save(device)
            },
            openChannel: { url, credentials in
                try await WebSocketChannel.connect(url: url, credentials: credentials, timeout: .seconds(5))
            },
            browse: { onChange in
                let browser = BonjourBrowser()
                browser.start(onChange: onChange)
                return { browser.stop() }
            },
            sleep: { duration in
                try await Task.sleep(for: duration)
            },
            now: {
                Date()
            },
            attachmentCache: AttachmentCache.standard()
        )
    }

    /// The environment of `Workspace.preview()`: the sample credentials, no registry, no saves, no channel, no
    /// browsing, real time and an attachment cache in the temporary directory.
    public static var preview: WorkspaceEnvironment {
        WorkspaceEnvironment(
            loadCredentials: { PreviewData.credentials },
            saveCredentials: { _ in },
            loadRegistry: { nil },
            saveRegistry: { _ in },
            saveDevice: { _ in },
            openChannel: { _, _ in
                throw ProtocolError(.unavailable, "Not available in previews")
            },
            browse: { _ in
                { }
            },
            sleep: { duration in
                try await Task.sleep(for: duration)
            },
            now: {
                Date()
            },
            attachmentCache: AttachmentCache(root: FileManager.default.temporaryDirectory
                .appending(path: "Hephaestus-Preview", directoryHint: .isDirectory)
                .appending(path: "Attachments", directoryHint: .isDirectory))
        )
    }
}

/// The in-process link to this Mac's `HostService` (docs/client/workspace.md, "LocalHostLink"). The app wiring
/// implements it on macOS with `HostService.makeLoopbackChannel()`.
public protocol LocalHostLink: Sendable {
    /// Returns the client end of a new in-process channel whose other end the local HostService serves.
    func makeChannel() async throws -> any MessageChannel
}
