#if os(macOS)
import Foundation
import HephCore

/// The Forge pipeline (docs/forge/pipeline.md): feedback intake, the cycles of regeneration, CI and release, the push
/// gate of Forge sessions, and the state sent with `forge.changed`. One Main runs it: the Forge host.
///
/// Every operation that changes state runs one at a time, in arrival order, through one internal queue (Concurrency);
/// `config()` and `status()` answer at once from the current state.
public actor ForgeService {
    /// The host whose members the Forge uses (services/host.md §12.4); kept for the app's life.
    nonisolated let host: HostService

    // MARK: - State (internal: the extensions in the other files of this doc use it)

    /// The configuration while the Forge is enabled; nil otherwise.
    var configuration: ForgeConfig?
    /// forge.json was loaded in this process.
    var storeLoaded = false
    /// The client of the configured repository, with the token read at enabling.
    var github: GitHubClient?
    /// `DocsHash.embedded` of the running app.
    var appDocsHash = DocsHash.embedded
    /// This Main's device id, read at enabling.
    var hostDeviceID: UUID?
    var head: ForgeHead?
    var cycle: ForgeCycle?
    var items: [ForgeItem] = []
    var latestRelease: ForgeRelease?
    /// The full SHA of the last head of the branch that the Forge pushed, or checked and trusts (Checks and triggers
    /// step 4); its scripts/check-public.sh judges the next pushes (MCP tools step 6).
    var trustedHead: String?
    var lastError: String?
    /// The regeneration sessions that have started a turn (Session observation).
    var turnsStarted: Set<UUID> = []
    /// The last state sent with `forge.changed`.
    var lastSentState: ForgeState?
    /// A background check waits in the queue.
    var checkQueued = false

    /// The last operation of the queue, and every operation not finished yet.
    var queueTail: Task<Void, Never>?
    var operations: [UUID: Task<Void, Never>] = [:]
    /// The 5-minute check timer and the polling loop.
    var timerTask: Task<Void, Never>?
    var pollingTask: Task<Void, Never>?

    /// Created by HostService.init with itself; keeps a strong reference for the app's life, like the other host
    /// services (services/host.md §1).
    public init(host: HostService) {
        self.host = host
    }

    // MARK: - Configuration

    /// The configuration built from the forge settings, nil when forge.enabled is false. Called by the host at its
    /// start and after every change of a forge setting.
    public func configure(_ config: ForgeConfig?) async {
        if config == nil, configuration != nil {
            stopBackgroundWork()
        }
        try? await perform {
            await self.apply(config, announce: true)
        }
    }

    /// Host stop: disables the Forge.
    public func shutdown() async {
        stopBackgroundWork()
        try? await perform {
            await self.apply(nil, announce: false)
        }
    }

    /// host.info `forge`: the configuration while enabled, else nil.
    public func config() -> ForgeConfig? {
        configuration
    }

    // MARK: - forge.* methods

    /// Never fails: while the Forge is not enabled, the disabled state of Methods.
    public func status() async -> ForgeState {
        guard configuration != nil else {
            return ForgeState(enabled: false, hostDeviceID: await host.mesh.localDevice().id,
                              appDocsHash: DocsHash.embedded, items: [])
        }
        if head.map({ Date().timeIntervalSince($0.checkedAt) > 60 }) ?? true {
            requestCheck()
        }
        return await currentState()
    }

    public func feedback(screenshot: UploadRef?, comment: String, context: FeedbackContext,
                         from deviceID: UUID) async throws -> ForgeFeedbackResult {
        try await enabledOperation {
            try await self.intake(screenshot: screenshot, comment: comment, context: context, from: deviceID)
        }
    }

    /// Answers once the configuration checks and the conflict check passed; then works in the background: a check of
    /// its own, whose step 4 trusts the changes of the guardrail it finds (Checks and triggers), then Retry when the
    /// cycle is failed, else the `manual` trigger.
    public func regenerate() async throws {
        try await enabledOperation {
            try await self.regenerateNow()
        }
    }

    /// Answers once the checks passed (the item must be failed and in the current cycle); then works in the
    /// background: a check of its own, as for `regenerate()`, then Retry.
    public func retry(itemTaskID: String) async throws {
        try await enabledOperation {
            try await self.retryNow(itemTaskID: itemTaskID)
        }
    }

    private func regenerateNow() async throws {
        _ = try await configurationChecks()
        if let cycle, Self.isActive(cycle.state) {
            throw ProtocolError(.conflict, "A regeneration is already in progress (\(cycle.state.rawValue)).")
        }
        enqueue {
            await self.checkTrustingGuardrail()
            guard !Task.isCancelled else { return }
            await self.retryOrManualTrigger()
        }
    }

    private func retryNow(itemTaskID: String) async throws {
        _ = try await configurationChecks()
        guard let item = items.first(where: { $0.taskID == itemTaskID }) else {
            throw ProtocolError(.notFound, "No Forge item for \(itemTaskID).")
        }
        guard item.state == .failed, let cycle, cycle.state == .failed, item.cycleID == cycle.id else {
            throw ProtocolError(.conflict, "\(itemTaskID) has not failed.")
        }
        enqueue {
            await self.checkTrustingGuardrail()
            guard !Task.isCancelled else { return }
            await self.retryCycle()
        }
    }

    /// The check that `forge.regenerate` and `forge.retry` run first: its step 4 trusts the changes of the guardrail
    /// it finds, since the user presses Regenerate Now or Retry after reviewing them. As after every check, a cycle
    /// still `released` runs Completion again.
    private func checkTrustingGuardrail() async {
        await runCheck(trustGuardrail: true)
        await resumeCompletion()
    }

    /// Retry when the cycle is `failed`, else the `manual` trigger, which needs no active cycle.
    private func retryOrManualTrigger() async {
        guard configuration != nil else { return }
        if let cycle, cycle.state == .failed {
            await retryCycle()
        } else if !(cycle.map { Self.isActive($0.state) } ?? false) {
            await startCycle(trigger: .manual)
        }
    }

    // MARK: - MCP tools

    /// forge_push_docs, through MCPHost: the tool result text, or a thrown ProtocolError whose message is the error
    /// text.
    public func pushDocs(sessionID: UUID) async throws -> String {
        try await enabledOperation {
            try await self.pushDocsNow(sessionID: sessionID)
        }
    }

    /// forge_push_regen, through MCPHost: the tool result text, or a thrown ProtocolError whose message is the error
    /// text.
    public func pushRegen(sessionID: UUID) async throws -> String {
        try await enabledOperation {
            try await self.pushRegenNow(sessionID: sessionID)
        }
    }

    // MARK: - Notifications (services/host.md §5)

    /// Called by HostService.emit for every session.changed; handled in the queue, not awaited.
    public func sessionChanged(projectID: String, session: SessionInfo) async {
        enqueue {
            await self.observeSession(session)
        }
    }

    /// Called by HostService.emit for every session.removed (`sessionID`: the session id's uuidString).
    public func sessionRemoved(projectID: String, sessionID: String) async {
        enqueue {
            await self.observeSessionRemoval(sessionID)
        }
    }

    /// Called by HostService.emit for every task.removed.
    public func taskRemoved(projectID: String, taskID: String) async {
        enqueue {
            await self.removeItem(projectID: projectID, taskID: taskID)
        }
    }

    // MARK: - Startup and shutdown

    /// Applies a configuration in the queue: enabling, disabling, or a new configuration while enabled.
    func apply(_ config: ForgeConfig?, announce: Bool) async {
        guard let config else {
            guard configuration != nil else { return }
            stopTimers()
            configuration = nil
            github = nil
            Log.host.notice("The Forge is disabled")
            if announce {
                let state = ForgeState(enabled: false, hostDeviceID: await host.mesh.localDevice().id,
                                       appDocsHash: appDocsHash, items: [])
                lastSentState = nil
                await host.emit(.forgeChanged(ForgeChangedPayload(state: state)))
            }
            return
        }
        guard configuration != nil else {
            await enable(config)
            return
        }
        if config.repository != configuration?.repository {
            github = GitHubClient(repository: config.repository, token: await GitHubClient.readToken())
        }
        configuration = config
        await broadcastIfChanged()
    }

    /// Enabling (Startup and shutdown, steps 1 to 5).
    private func enable(_ config: ForgeConfig) async {
        // 1. forge.json, the token, the app's docs hash.
        if !storeLoaded {
            loadStore()
            storeLoaded = true
        }
        github = GitHubClient(repository: config.repository, token: await GitHubClient.readToken())
        appDocsHash = DocsHash.embedded
        hostDeviceID = await host.mesh.localDevice().id
        configuration = config
        lastSentState = nil
        Log.host.notice("The Forge is enabled for \(config.sourceProjectID, privacy: .public)")
        // 2. The private terms.
        do {
            _ = try await preparePrivateTerms()
        } catch {
            Log.host.error("Could not write private-terms.txt: \(Self.message(of: error))")
            lastError = Self.message(of: error)
        }
        // 3. A regeneration whose session is not running.
        if let cycle, cycle.state == .regenerating {
            let sessions = (try? await host.sessions.sessions(projectID: config.sourceProjectID)) ?? []
            let running = sessions.contains { session in
                session.id == cycle.sessionID
                    && [.starting, .running, .waitingPermission].contains(session.status)
            }
            if !running {
                await failCycle("Interrupted: the regeneration session is not running.")
            }
        }
        // 4. Polling, or Completion from step 2.
        switch cycle?.state {
        case .regenPushed?, .building?:
            startPolling()
        case .released?:
            if await completeItems() {
                await finishCycle()
            }
        default:
            break
        }
        // 5. forge.changed, a check, the 5-minute timer.
        await broadcastIfChanged()
        requestCheck()
        startTimer()
    }

    /// Cancels the timer, the polling and the operations of the queue (disabling).
    func stopBackgroundWork() {
        stopTimers()
        for operation in operations.values {
            operation.cancel()
        }
    }

    /// Cancels the 5-minute timer and the polling.
    func stopTimers() {
        timerTask?.cancel()
        timerTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Forge host configuration

    /// The repository root: the source project's code folder, `<root>/<code>` of its project file (`.` is the root).
    static func repositoryRoot(of project: HostedProject) -> URL {
        let code = project.file.code
        guard code != "." else { return project.root }
        return project.root.appendingPathComponent(code, isDirectory: true).standardizedFileURL
    }

    // MARK: - Push tools (steps 1 and 8)

    private func pushDocsNow(sessionID: UUID) async throws -> String {
        // 1. Session, configuration checks, private terms.
        guard let config = configuration else { throw Self.notTheForge }
        guard let taskID = items.first(where: { $0.feedbackSessionID == sessionID })?.taskID else {
            throw ProtocolError(.conflict, "forge_push_docs is only available in Forge feedback sessions.")
        }
        guard cycle?.state != .regenerating else {
            throw ProtocolError(.conflict, "A regeneration is working in this repository; call forge_push_docs again "
                                    + "when it has pushed.")
        }
        let repository = try await configurationChecks()
        try await checkPrivateTermsForPush(.pushDocs)
        // 2 to 7. The push gate.
        let pushed = try await pushThroughGate(.pushDocs, repository: repository, branch: config.branch)
        // 8. Record: the trusted head, the item's event, the join rule, a check, then the tool trigger.
        recordTrustedPush(pushed)
        recordDocsPush(pushed.commit, taskID: taskID)
        if items.first(where: { $0.taskID == taskID })?.state == .docsPushed {
            await joinRule(taskIDs: [taskID])
        }
        saveStore()
        await broadcastIfChanged()
        await runCheck()
        await resumeCompletion()
        let item = items.first { $0.taskID == taskID }
        let inActiveCycle = cycle.map { cycle in Self.isActive(cycle.state) && item?.cycleID == cycle.id } ?? false
        let cycleActive = cycle.map { Self.isActive($0.state) } ?? false
        let autoRegenerate = configuration?.autoRegenerate == true
        let trusted = headIsTrusted
        var started = false
        if !inActiveCycle, !cycleActive, autoRegenerate, trusted {
            await startCycle(trigger: .tool)
            started = true
        }
        let text = "Pushed docs commit \(ForgePushGate.short(pushed.commit)) for \(taskID)."
        if inActiveCycle {
            return text + " It is part of the regeneration in progress."
        }
        if started {
            return text + " Regeneration started."
        }
        if cycleActive {
            return text + " It will be regenerated after the regeneration in progress."
        }
        if !autoRegenerate {
            return text + " Regenerate automatically is off: the user starts the regeneration from the Forge screen."
        }
        return text + " Commits pushed to \(config.branch) outside the Forge are not trusted yet: the regeneration "
            + "waits until they are (Forge screen)."
    }

    private func pushRegenNow(sessionID: UUID) async throws -> String {
        // 1. Session, configuration checks (a change of the guardrail fails the cycle at once), private terms.
        guard let config = configuration else { throw Self.notTheForge }
        guard let current = cycle, current.sessionID == sessionID,
              current.state == .regenerating || (current.state == .failed && current.failedState == .regenerating)
        else {
            throw ProtocolError(.conflict,
                                "forge_push_regen is only available in the current Forge regeneration session.")
        }
        let repository: Repository
        do {
            repository = try await checkConfiguration()
        } catch let failure as ConfigurationCheckFailure {
            if !failure.guardrailPaths.isEmpty {
                await failCycle(Self.guardrailCycleError(failure.guardrailPaths), failedState: .regenerating)
            }
            throw failure.error
        }
        try await checkPrivateTermsForPush(.pushRegen)
        // 2 to 7. The push gate; a change of the guardrail fails the cycle at once.
        let pushed = try await pushThroughGate(.pushRegen, repository: repository, branch: config.branch)
        // 8. Record: the trusted head, regenCommit, regenPushed, the join rule, polling.
        recordTrustedPush(pushed)
        let text = "Pushed regeneration commit \(ForgePushGate.short(pushed.commit)). The Forge now waits for the CI "
            + "run and the release."
        guard var cycle else { return text }
        cycle.regenCommit = pushed.commit
        cycle.pushedAt = Date()
        self.cycle = cycle
        await setCycleState(.regenPushed)
        await joinRule()
        saveStore()
        await broadcastIfChanged()
        startPolling()
        Log.host.notice("The regeneration pushed \(ForgePushGate.short(pushed.commit), privacy: .public)")
        return text
    }

    /// Step 1, after the configuration checks: the private terms file is written when it is missing (a failure is
    /// logged, and the file, still missing, holds no term); it must hold a term, and no suggestion may be pending.
    private func checkPrivateTermsForPush(_ tool: ForgePushGate.Tool) async throws {
        do {
            _ = try await preparePrivateTerms()
        } catch {
            Log.host.error("Could not write private-terms.txt: \(Self.message(of: error))")
        }
        guard privateTermsCount() > 0 else {
            throw ProtocolError(.conflict, "private-terms.txt holds no terms: add your names in Settings ▸ Forge & "
                                    + "Updates ▸ Private terms, then call \(tool.rawValue) again.")
        }
        let pending = await privateTermSuggestions()
        guard pending.isEmpty else {
            throw ProtocolError(.conflict, "Hephaestus suggests \(pending.count) new private terms: add or dismiss "
                                    + "them in Settings ▸ Forge & Updates ▸ Private terms, then call \(tool.rawValue) "
                                    + "again.")
        }
    }

    /// Steps 2 to 7 (`ForgePushGate`), called with `trustedHead`, whose published check step 6 runs: a refusal
    /// becomes `conflict` with its text. A refusal of `forge_push_regen` that names guardrail paths also fails the
    /// cycle at once (Session observation).
    private func pushThroughGate(_ tool: ForgePushGate.Tool, repository: Repository,
                                 branch: String) async throws -> ForgePushGate.Pushed {
        let gate = ForgePushGate(git: repository.git, branch: branch, termsFile: privateTermsURL)
        do {
            let pushed = try await gate.push(tool, trustedHead: trustedHead)
            let short = ForgePushGate.short(pushed.commit)
            Log.host.notice("\(tool.rawValue, privacy: .public) pushed \(short, privacy: .public)")
            return pushed
        } catch let refusal as ForgePushGate.Refusal {
            Log.host.notice("\(tool.rawValue, privacy: .public) refused a push")
            if tool == .pushRegen, !refusal.guardrailPaths.isEmpty {
                await failCycle(Self.guardrailCycleError(refusal.guardrailPaths), failedState: .regenerating)
            }
            throw ProtocolError(.conflict, refusal.message)
        }
    }

    /// Step 8: when `trustedHead` is the base of the push, it becomes the pushed commit and forge.json is written: the
    /// Forge trusts what it checked on a trusted base, and leaves the commits pushed elsewhere to the next check.
    private func recordTrustedPush(_ pushed: ForgePushGate.Pushed) {
        guard trustedHead == pushed.base else { return }
        trustedHead = pushed.commit
        saveStore()
    }

    /// The error of a cycle failed by a change of the guardrail in `forge_push_regen` (Session observation).
    static func guardrailCycleError(_ paths: [String]) -> String {
        "Guardrail files changed (\(paths.joined(separator: ", "))): review the unpushed commits, check them with "
            + "origin's script (docs/public-repository.md#protected-paths), push them by hand, then press Retry."
    }

    // MARK: - Broadcasting

    /// The current ForgeState while enabled.
    func currentState() async -> ForgeState {
        let deviceID: UUID
        if let hostDeviceID {
            deviceID = hostDeviceID
        } else {
            deviceID = await host.mesh.localDevice().id
        }
        return ForgeState(enabled: true, hostDeviceID: deviceID, config: configuration, appDocsHash: appDocsHash,
                          head: head, cycle: cycle, items: items.sorted { $0.created > $1.created },
                          latestRelease: latestRelease, lastError: lastError)
    }

    /// Sends `forge.changed` when a value of the ForgeState changed since the last one sent, while enabled.
    func broadcastIfChanged() async {
        guard configuration != nil else { return }
        let state = await currentState()
        guard state != lastSentState else { return }
        lastSentState = state
        await host.emit(.forgeChanged(ForgeChangedPayload(state: state)))
    }

    // MARK: - Concurrency

    /// Runs `operation` after every operation enqueued before it; does not wait for it.
    @discardableResult
    func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = queueTail
        let id = UUID()
        let task = Task {
            await previous?.value
            await operation()
            self.operationEnded(id)
        }
        queueTail = task
        operations[id] = task
        return task
    }

    /// Runs `operation` as one operation of the queue and returns its result.
    func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do {
                    continuation.resume(returning: try await operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// An operation of a method or a tool: `unavailable` "This Main is not the Forge." while the Forge is not
    /// enabled, also when disabling cancelled it.
    private func enabledOperation<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws
        -> T {
        do {
            return try await perform {
                guard await self.isEnabled else { throw Self.notTheForge }
                return try await operation()
            }
        } catch is CancellationError {
            throw Self.notTheForge
        }
    }

    private var isEnabled: Bool {
        configuration != nil
    }

    private func operationEnded(_ id: UUID) {
        operations[id] = nil
    }

    // MARK: - Helpers

    static let notTheForge = ProtocolError(.unavailable, "This Main is not the Forge.")

    /// A cycle is active while its state is `regenerating`, `regenPushed`, `building` or `released`.
    static func isActive(_ state: ForgeStage) -> Bool {
        [.regenerating, .regenPushed, .building, .released].contains(state)
    }

    /// The message of an error: a ProtocolError's message, a GitHubError's text, else the localized description.
    static func message(of error: any Error) -> String {
        if let protocolError = error as? ProtocolError {
            return protocolError.message
        }
        if let dataError = error as? DataError {
            return dataError.message
        }
        return error.localizedDescription
    }
}
#endif
