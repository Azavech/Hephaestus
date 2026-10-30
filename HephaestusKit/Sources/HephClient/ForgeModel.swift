import Foundation
import HephCore
import Observation

/// The client-side mirror of the Forge: the Forge hosts among the connected Mains and the state of the first one
/// (docs/ui/forge.md, "ForgeModel"). One per Workspace, fed by its calls.
@MainActor @Observable
public final class ForgeModel {
    /// For each connected Main whose Forge is enabled, its config.
    public private(set) var forgeConfigs: [UUID: ForgeConfig] = [:]
    /// The last `ForgeState` received from `forgeHostID`.
    public private(set) var state: ForgeState?
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    /// Gets the build of every latestRelease received; set by the shell on macOS (UpdateService).
    @ObservationIgnored public var releaseObserver: (@MainActor (Int) -> Void)?

    @ObservationIgnored private weak var workspace: Workspace?

    /// Weak reference; the Workspace owns the model.
    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// The Mains of `forgeConfigs`, in `workspace.mains` order (by name, then id).
    public var forgeHostIDs: [UUID] {
        let order = workspace?.mains.map(\.id) ?? []
        var ids = order.filter { forgeConfigs[$0] != nil }
        let others = forgeConfigs.keys.filter { !order.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        ids.append(contentsOf: others)
        return ids
    }

    /// The first Forge host; nil when there is none. Feedback, Regenerate Now and Retry go to it.
    public var forgeHostID: UUID? {
        forgeHostIDs.first
    }

    // MARK: - Called by the Workspace

    /// `hostInfo()` on that connection: the Main enters `forgeConfigs` when its `forge` is set, else leaves it; then,
    /// when `forgeHostID` is not the host of `state`, `state` = nil and `refresh()`.
    public func mainDidConnect(_ mainID: UUID) {
        Task { [weak self] in
            guard let self, let connection = self.workspace?.connection(mainID) else { return }
            do {
                let info = try await connection.hostInfo()
                self.forgeConfigs[mainID] = info.forge
            } catch {
                Log.client.error("host.info failed on \(mainID, privacy: .public): \(Workspace.message(of: error))")
                return
            }
            if self.state?.hostDeviceID != self.forgeHostID {
                self.state = nil
                await self.refresh()
            }
        }
    }

    /// The Main leaves `forgeConfigs`; when it was the host of `state`, `state` = nil, then `refresh()` when another
    /// Forge host remains.
    public func mainDidDisconnect(_ mainID: UUID) {
        forgeConfigs[mainID] = nil
        guard state?.hostDeviceID == mainID else { return }
        state = nil
        if forgeHostID != nil {
            Task { [weak self] in
                await self?.refresh()
            }
        }
    }

    /// A `forge.changed` from `mainID`: its config enters or leaves `forgeConfigs`; when `mainID` is `forgeHostID`,
    /// `state` becomes the state; when `mainID` is the host of `state` and left `forgeConfigs`, `state` = nil, then
    /// `refresh()` when another Forge host remains. A `latestRelease` goes to `releaseObserver`.
    public func apply(_ state: ForgeState, from mainID: UUID) {
        if state.enabled, let config = state.config {
            forgeConfigs[mainID] = config
        } else {
            forgeConfigs[mainID] = nil
        }
        if mainID == forgeHostID {
            self.state = state
        } else if self.state?.hostDeviceID == mainID, forgeConfigs[mainID] == nil {
            self.state = nil
            if forgeHostID != nil {
                Task { [weak self] in
                    await self?.refresh()
                }
            }
        }
        if let release = state.latestRelease {
            releaseObserver?(release.build)
        }
    }

    /// `forgeStatus()` on the connection of `forgeHostID`, then `apply`. No Forge host: `state` = nil.
    public func refresh() async {
        guard let hostID = forgeHostID else {
            state = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let status = try await connection(hostID).forgeStatus()
            loadError = nil
            apply(status, from: hostID)
        } catch {
            loadError = Workspace.message(of: error)
        }
    }

    // MARK: - Requests

    /// `regenerate()`, then `refresh()`.
    public func regenerate() async throws {
        try await hostConnection().regenerate()
        await refresh()
    }

    /// `retryForge(itemTaskID:)`, then `refresh()`.
    public func retry(itemTaskID: String) async throws {
        try await hostConnection().retryForge(itemTaskID: itemTaskID)
        await refresh()
    }

    /// Uploads the screenshot (when there is one) to the Forge's source project, then sends forge.feedback.
    public func sendFeedback(screenshot: Data?, comment: String, context: FeedbackContext,
                             progress: @escaping @MainActor (TransferProgress) -> Void) async throws
        -> ForgeFeedbackResult {
        guard let hostID = forgeHostID, let config = forgeConfigs[hostID] else {
            throw ProtocolError(.unavailable, "No Forge is online.")
        }
        let connection = try connection(hostID)
        var reference: UploadRef?
        if let screenshot {
            reference = try await connection.upload(fileName: "screenshot.png", projectID: config.sourceProjectID,
                                                    source: .data(screenshot), progress: progress)
        }
        return try await connection.sendFeedback(screenshot: reference, comment: comment, context: context)
    }

    // MARK: - Private

    /// The connection of the Forge host; without a Forge host, `unavailable` "No Forge is online.".
    private func hostConnection() throws -> MainConnection {
        guard let hostID = forgeHostID else {
            throw ProtocolError(.unavailable, "No Forge is online.")
        }
        return try connection(hostID)
    }

    private func connection(_ mainID: UUID) throws -> MainConnection {
        guard let connection = workspace?.connection(mainID) else {
            throw ProtocolError(.unavailable, "No Forge is online.")
        }
        return connection
    }
}
