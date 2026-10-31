#if os(macOS)
import Foundation
import HephCore

/// Moving projects between Mains (docs/devices/migration.md): `projects.migrate` and the source runs of this Main, the
/// `migration.*` methods it serves as a destination, its migration journal (`migrations.json`), the recovery after a
/// restart and the outcome checks.
public actor MigrationService: HostMethodHandler {
    /// An outcome check asks again every 10 s while the peer link is established.
    static let checkInterval: Duration = .seconds(10)

    private let host: HostService
    /// migrations.json in memory, written whole with `MigrationJournal.save` after each change.
    private var journal: [MigrationJournalEntry] = []
    /// The source runs of this Main, by migration id.
    private var sources: [UUID: SourceRun] = [:]
    /// Top-level projects between the checks of projects.migrate and the start of their source run.
    private var starting: Set<String> = []
    /// The unfinished migrations this Main receives, by migration id.
    private var receivers: [UUID: MigrationReceiver] = [:]
    /// The commits in progress, ending with their error (nil on success); migration.abort and migration.status wait
    /// for them.
    private var commits: [UUID: Task<ProtocolError?, Never>] = [:]
    /// The pending outcome checks, by migration id.
    private var checks: [UUID: OutcomeCheck] = [:]
    /// `migration.abort` queued by the recovery for `transferring` entries: migration id → target Main.
    private var queuedAborts: [UUID: UUID] = [:]
    private var abortTasks: [UUID: Task<Void, Never>] = [:]
    /// Set by stop(), cleared by recover(): no outcome check starts and no queued abort is sent.
    private var stopped = false

    private struct SourceRun {
        let projectID: String
        /// The run only waits for an outcome check: it does not count as active.
        var waitingForOutcome = false
    }

    private struct OutcomeCheck {
        let targetDeviceID: UUID
        /// Wakes the check when the peer link to the target opens.
        let wake: AsyncStream<Void>.Continuation
        /// The answer of the target, nil when the check was cancelled.
        let task: Task<MigrationOutcome?, Never>
    }

    public init(host: HostService) {
        self.host = host
    }

    /// True while a migration runs here, as source or destination (Main toggle, Leave mesh, host active work); a move
    /// that only waits for an outcome check does not count.
    public func isActive() -> Bool {
        !starting.isEmpty || !receivers.isEmpty || sources.values.contains { !$0.waitingForOutcome }
    }

    /// HostService.start() step 2: loads migrations.json and handles its source entries (Recovery after a restart).
    /// Nothing is emitted: no device is connected yet.
    func recover() async {
        stopped = false
        journal = MigrationJournal.load(host.appSupport)
        for entry in journal {
            switch entry.state {
            case .received:
                continue
            case .committed:
                // The destination has the project: the cleanup of the source is finished.
                await finishCommitted(entry)
            case .committing:
                // The outcome is unknown: the project stays locked until an outcome check answers.
                if let project = await topLevelProject(at: entry.rootPath), project.id == entry.projectID {
                    await host.registry.setMigrating(entry.projectID, true)
                }
                startRecoveredCheck(entry)
            case .transferring:
                // The move had not reached the commit: the project is served as before.
                removeEntry(entry.migrationID)
                if let target = entry.targetDeviceID {
                    queuedAborts[entry.migrationID] = target
                }
            }
        }
    }

    /// HostService.stop() step 3: cancels the outcome checks, whose entries stay `committing` in the journal for the
    /// next start, and drops the queued aborts, whose entries `recover()` already removed: an abort not sent during
    /// this run of the host is never sent.
    func stop() {
        stopped = true
        for check in checks.values {
            check.task.cancel()
            check.wake.finish()
        }
        checks.removeAll()
        queuedAborts.removeAll()
        for task in abortTasks.values {
            task.cancel()
        }
        abortTasks.removeAll()
    }

    /// The host's peer-link observer: a link to `deviceID` was established; runs its pending checks and aborts.
    func peerLinkOpened(_ deviceID: UUID) async {
        guard !stopped else { return }
        for check in checks.values where check.targetDeviceID == deviceID {
            check.wake.yield()
        }
        for (migrationID, target) in queuedAborts where target == deviceID {
            queuedAborts[migrationID] = nil
            let mesh: MeshService = host.mesh
            // Sent once, best effort: the result is ignored.
            abortTasks[migrationID] = Task.detached { [self] in
                _ = try? await mesh.requestPeer(deviceID, method: RPCMethod.migrationAbort.rawValue,
                                                params: MigrationAbortParams(migrationID: migrationID),
                                                as: EmptyPayload.self, timeout: MigrationSender.abortTimeout)
                await self.abortSent(migrationID)
            }
        }
    }

    /// Called by MeshService when a connection served by this Main closes: every unfinished migration begun on it is
    /// aborted (a commit in progress ends first and is kept).
    func connectionClosed(connectionID: UUID) async {
        let begun = receivers.values.filter { $0.connectionID == connectionID }.map(\.migrationID)
        for migrationID in begun {
            await abortReceived(migrationID)
        }
    }

    // MARK: - HostMethodHandler

    /// projects.migrate, migration.begin, migration.chunk, migration.commit, migration.abort, migration.status.
    public func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .projectsMigrate:
                let request = try Self.decode(ProjectsMigrateParams.self, params, method)
                return try WireCoding.encodeJSON(try await migrate(projectID: request.projectID,
                                                                   targetDeviceID: request.targetDeviceID))
            case .migrationBegin:
                let request = try Self.decode(MigrationBeginParams.self, params, method)
                return try WireCoding.encodeJSON(try await begin(request, context: context))
            case .migrationChunk:
                let request = try Self.decode(MigrationChunkParams.self, params, method)
                try chunk(request, context: context)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .migrationCommit:
                let request = try Self.decode(MigrationCommitParams.self, params, method)
                try await commit(request.migrationID, context: context)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .migrationAbort:
                let request = try Self.decode(MigrationAbortParams.self, params, method)
                await abortReceived(request.migrationID)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .migrationStatus:
                let request = try Self.decode(MigrationStatusParams.self, params, method)
                return try WireCoding.encodeJSON(await status(request.migrationID))
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - Starting a move (source)

    private func migrate(projectID: String, targetDeviceID: UUID) async throws -> ProjectsMigrateResult {
        let registry: ProjectRegistry = host.registry
        // Checks, in order. Not hosted: notFound "Project <id> is not hosted on this Main.".
        let project = try await registry.hosted(projectID)
        let name = project.file.name
        guard project.parentID == nil else {
            throw ProtocolError(.badRequest, "Sub projects move with their parent project.")
        }
        guard !project.migrating, !isMoving(projectID) else {
            throw ProtocolError(.locked, "\(name) is already being moved.")
        }
        let localDevice = await host.mesh.localDevice()
        guard targetDeviceID != localDevice.id else {
            throw ProtocolError(.badRequest, "\(name) is already on this Main.")
        }
        guard let target = await host.mesh.snapshot().devices.first(where: { $0.id == targetDeviceID && !$0.revoked })
        else {
            throw ProtocolError(.notFound, "No device \(targetDeviceID.uuidString).")
        }
        guard target.isMain else {
            throw ProtocolError(.badRequest, "\(target.name) is not a Main.")
        }
        guard await host.mesh.connectedPeerMains().contains(where: { $0.id == targetDeviceID }) else {
            throw ProtocolError(.unavailable, "\(target.name) is not connected.")
        }
        let liveWork = ProtocolError(.conflict, "Stop the Claude sessions of \(name) first.")
        guard await !hasLiveWork(projectID) else { throw liveWork }
        guard await !hasActiveBundle(projectID) else {
            throw ProtocolError(.conflict, "Stop the bundles of \(name) first.")
        }
        // A concurrent projects.migrate of the same project may have passed the checks meanwhile.
        guard !isMoving(projectID) else {
            throw ProtocolError(.locked, "\(name) is already being moved.")
        }

        // 1. Locked, behind the project's pending writes.
        starting.insert(projectID)
        await registry.setMigrating(projectID, true)
        // 2. The live-work check again.
        if await hasLiveWork(projectID) {
            await registry.setMigrating(projectID, false)
            starting.remove(projectID)
            throw liveWork
        }
        // 3, 4. A new migration id is answered; the source run starts in a new task.
        let migrationID = UUID()
        sources[migrationID] = SourceRun(projectID: projectID)
        starting.remove(projectID)
        let sender = MigrationSender(migrationID: migrationID, projectID: projectID, targetDeviceID: targetDeviceID,
                                     sourceDeviceID: localDevice.id, host: host, service: self)
        Task.detached {
            await sender.run()
        }
        Log.host.notice("Migration \(migrationID.uuidString, privacy: .public): moving \(projectID, privacy: .public) to \(targetDeviceID.uuidString, privacy: .public)")
        return ProjectsMigrateResult(migrationID: migrationID)
    }

    /// The project is being moved by this Main, or is about to be.
    private func isMoving(_ projectID: String) -> Bool {
        starting.contains(projectID) || sources.values.contains { $0.projectID == projectID }
    }

    /// A session with a CLI process in the project or one of its sub projects.
    private func hasLiveWork(_ projectID: String) async -> Bool {
        let tree = [projectID] + (await host.registry.descendants(of: projectID))
        for id in tree {
            if await host.sessions.hasProcess(projectID: id) {
                return true
            }
        }
        return false
    }

    /// A bundle in `running` or `review` in the project or one of its sub projects.
    private func hasActiveBundle(_ projectID: String) async -> Bool {
        let tree = [projectID] + (await host.registry.descendants(of: projectID))
        for id in tree {
            if await host.bundles.hasActiveBundle(projectID: id) {
                return true
            }
        }
        return false
    }

    // MARK: - Source runs (MigrationSender)

    /// Source run step 3: the entry `transferring`; a failure to write it fails the move.
    func addSourceEntry(migrationID: UUID, projectID: String, rootPath: String, targetDeviceID: UUID) throws {
        journal.append(MigrationJournalEntry(migrationID: migrationID, projectID: projectID, rootPath: rootPath,
                                             targetDeviceID: targetDeviceID, sourceDeviceID: nil,
                                             state: .transferring, updatedAt: Date()))
        try saveJournal(required: true)
    }

    /// Changes the state of an entry. `required` (before migration.commit is sent): a failure to write throws
    /// internal "Cannot write migrations.json: <reason>."; otherwise it is logged and the move goes on.
    func setEntryState(_ migrationID: UUID, _ state: MigrationJournalState, required: Bool) throws {
        guard let index = journal.firstIndex(where: { $0.migrationID == migrationID }) else { return }
        journal[index].state = state
        journal[index].updatedAt = Date()
        try saveJournal(required: required)
    }

    /// Removes an entry; a failure to write is logged.
    func removeEntry(_ migrationID: UUID) {
        guard journal.contains(where: { $0.migrationID == migrationID }) else { return }
        journal.removeAll { $0.migrationID == migrationID }
        try? saveJournal(required: false)
    }

    /// Lost commit answer: asks the destination until it answers (nil when stop() cancelled the check). Meanwhile the
    /// run does not count as active.
    func outcomeCheck(migrationID: UUID, targetDeviceID: UUID) async -> MigrationOutcome? {
        guard !stopped else { return nil }
        sources[migrationID]?.waitingForOutcome = true
        let outcome = await startCheck(migrationID: migrationID, targetDeviceID: targetDeviceID).value
        checks[migrationID] = nil
        sources[migrationID]?.waitingForOutcome = false
        return outcome
    }

    /// The source run ended.
    func sourceEnded(_ migrationID: UUID) {
        sources[migrationID] = nil
    }

    // MARK: - Recovery and outcome checks

    /// D has the project (`committed`): the project folder goes to the Trash when it still exists, the project is
    /// unregistered, and the entry is removed; when the Trash fails the entry stays `committed`, so that the next start
    /// tries again.
    private func finishCommitted(_ entry: MigrationJournalEntry) async {
        var trashed = true
        if let realRoot = ClaudePathEncoding.canonicalPath(entry.rootPath) {
            do {
                try host.appSupport.trashItem(URL(fileURLWithPath: realRoot, isDirectory: true))
            } catch {
                trashed = false
                Log.host.error("Migration \(entry.migrationID.uuidString, privacy: .public): could not move the folder of \(entry.projectID, privacy: .public) to the Trash: \(error.localizedDescription)")
            }
        }
        await host.registry.forgetRoot(entry.rootPath)
        if trashed {
            removeEntry(entry.migrationID)
        }
    }

    /// The top-level project registered at `rootPath`.
    private func topLevelProject(at rootPath: String) async -> HostedProject? {
        let standardized = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.path
        return await host.registry.all().first {
            $0.parentID == nil && ($0.root.path == rootPath || $0.root.path == standardized)
        }
    }

    /// The outcome check of a `committing` entry found at start.
    private func startRecoveredCheck(_ entry: MigrationJournalEntry) {
        guard let targetDeviceID = entry.targetDeviceID else {
            Log.host.error("Migration \(entry.migrationID.uuidString, privacy: .public): its journal entry has no target")
            return
        }
        let check = startCheck(migrationID: entry.migrationID, targetDeviceID: targetDeviceID)
        Task {
            guard let outcome = await check.value else { return }
            await self.resolveRecovered(entry, targetDeviceID: targetDeviceID, outcome: outcome)
        }
    }

    /// `committed`: the entry becomes `committed`, then the cleanup of `finishCommitted`, then progress `completed`.
    /// `unknown`: the project is unlocked, the entry removed, then progress `failed`.
    private func resolveRecovered(_ entry: MigrationJournalEntry, targetDeviceID: UUID,
                                  outcome: MigrationOutcome) async {
        checks[entry.migrationID] = nil
        switch outcome {
        case .committed:
            try? setEntryState(entry.migrationID, .committed, required: false)
            await finishCommitted(entry)
            await broadcastRecovered(entry, targetDeviceID: targetDeviceID, state: .completed, error: nil)
            Log.host.notice("Migration \(entry.migrationID.uuidString, privacy: .public): \(entry.projectID, privacy: .public) is on \(targetDeviceID.uuidString, privacy: .public)")
        case .unknown:
            if (try? await host.registry.hosted(entry.projectID)) != nil {
                await host.registry.setMigrating(entry.projectID, false)
            }
            removeEntry(entry.migrationID)
            let name = await host.mesh.snapshot().devices.first { $0.id == targetDeviceID }?.name
                ?? targetDeviceID.uuidString
            await broadcastRecovered(entry, targetDeviceID: targetDeviceID, state: .failed,
                                     error: "The move to \(name) did not complete.")
            Log.host.notice("Migration \(entry.migrationID.uuidString, privacy: .public): \(entry.projectID, privacy: .public) stays on this Main")
        }
    }

    private func broadcastRecovered(_ entry: MigrationJournalEntry, targetDeviceID: UUID, state: MigrationState,
                                    error: String?) async {
        let payload = MigrationProgressPayload(migrationID: entry.migrationID, projectID: entry.projectID,
                                               fromDeviceID: await host.mesh.localDevice().id,
                                               toDeviceID: targetDeviceID, state: state, bytesDone: 0, bytesTotal: 0,
                                               error: error)
        await host.events.broadcast(.migrationProgress(payload))
    }

    /// Starts an outcome check and records it, so that peerLinkOpened(_:) wakes it and stop() cancels it.
    private func startCheck(migrationID: UUID, targetDeviceID: UUID) -> Task<MigrationOutcome?, Never> {
        let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let mesh: MeshService = host.mesh
        let task = Task.detached {
            await Self.askOutcome(migrationID: migrationID, targetDeviceID: targetDeviceID, mesh: mesh, wakes: wakes)
        }
        checks[migrationID] = OutcomeCheck(targetDeviceID: targetDeviceID, wake: wake, task: task)
        return task
    }

    /// `migration.status` as soon as the peer link to the target is established, then every 10 s while it stays
    /// established, until the target answers; a failed request is tried again, without time limit. Nil when cancelled.
    private static func askOutcome(migrationID: UUID, targetDeviceID: UUID, mesh: MeshService,
                                   wakes: AsyncStream<Void>) async -> MigrationOutcome? {
        var iterator = wakes.makeAsyncIterator()
        while !Task.isCancelled {
            if await mesh.connectedPeerMains().contains(where: { $0.id == targetDeviceID }) {
                do {
                    let result = try await mesh.requestPeer(targetDeviceID, method: RPCMethod.migrationStatus.rawValue,
                                                            params: MigrationStatusParams(migrationID: migrationID),
                                                            as: MigrationStatusResult.self,
                                                            timeout: MigrationSender.requestTimeout)
                    return result.state
                } catch {
                    Log.host.info("Migration \(migrationID.uuidString, privacy: .public): migration.status failed: \(ProjectRegistry.protocolError(error).message); asking again")
                }
                do {
                    try await Task.sleep(for: checkInterval)
                } catch {
                    return nil
                }
            } else if await iterator.next() == nil {
                return nil
            }
        }
        return nil
    }

    private func abortSent(_ migrationID: UUID) {
        abortTasks[migrationID] = nil
    }

    // MARK: - Destination

    /// migration.begin: checks, destination folder, staging folder, then the migration is recorded.
    private func begin(_ params: MigrationBeginParams, context: RequestContext) async throws -> MigrationBeginResult {
        let migrationID = params.migrationID
        let exists = ProtocolError(.badRequest, "Migration \(migrationID.uuidString) already exists.")
        // 1. Checks.
        guard !isKnown(migrationID) else { throw exists }
        try MigrationReceiver.checkFolderName(params.folderName)
        for identifier in MigrationReceiver.identifiers(of: params.project) {
            if let hosted = try? await host.registry.hosted(identifier) {
                throw ProtocolError(.conflict,
                                    "Identifier \(identifier) is already used by \(hosted.file.name) on this Main.")
            }
        }
        let transcriptRoots = try MigrationReceiver.checkLists(params)

        let projectsFolder = await host.settings().projectsFolderURL
        let configDirectory = ClaudePathEncoding.configDirectory(
            environment: await LoginEnvironment.shared.environment(),
            home: FileManager.default.homeDirectoryForCurrentUser)
        // The same id may have been begun meanwhile.
        guard !isKnown(migrationID) else { throw exists }

        // 2. Destination folder.
        let destination = try MigrationReceiver.makeDestination(projectsFolder: projectsFolder,
                                                                folderName: params.folderName)
        // 3. Staging folder for the transcripts.
        let staging: URL
        do {
            staging = try MigrationReceiver.makeStaging(configDirectory: configDirectory)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        // 4. Recorded.
        receivers[migrationID] = MigrationReceiver(params: params, sourceDeviceID: context.device.id,
                                                   connectionID: context.connectionID,
                                                   transcriptRoots: transcriptRoots, destination: destination,
                                                   staging: staging, configDirectory: configDirectory)
        Log.host.notice("Migration \(migrationID.uuidString, privacy: .public): receiving \(params.project.id, privacy: .public) from \(context.device.id.uuidString, privacy: .public)")
        return MigrationBeginResult(destinationPath: destination.path)
    }

    /// The id of a migration received now or recorded in the journal.
    private func isKnown(_ migrationID: UUID) -> Bool {
        receivers[migrationID] != nil || journal.contains { $0.migrationID == migrationID }
    }

    /// migration.chunk: the migration exists, is not finished, and was begun by the calling device.
    private func chunk(_ params: MigrationChunkParams, context: RequestContext) throws {
        guard commits[params.migrationID] == nil, let receiver = receivers[params.migrationID],
              receiver.sourceDeviceID == context.device.id
        else {
            throw ProtocolError(.notFound, "No migration \(params.migrationID.uuidString).")
        }
        try receiver.receive(params)
    }

    /// migration.commit: answers once the project is registered, or with the error after a roll-back.
    private func commit(_ migrationID: UUID, context: RequestContext) async throws {
        guard commits[migrationID] == nil, let receiver = receivers[migrationID],
              receiver.sourceDeviceID == context.device.id
        else {
            throw ProtocolError(.notFound, "No migration \(migrationID.uuidString).")
        }
        // The commit runs in a task of its own, which migration.abort and migration.status wait for.
        let task = Task {
            await self.performCommit(migrationID)
        }
        commits[migrationID] = task
        if let error = await task.value {
            throw error
        }
    }

    /// migration.commit steps 2 to 8. Removes its own entry of `commits` before it ends.
    private func performCommit(_ migrationID: UUID) async -> ProtocolError? {
        defer { commits[migrationID] = nil }
        guard let receiver = receivers[migrationID] else {
            return ProtocolError(.notFound, "No migration \(migrationID.uuidString).")
        }
        do {
            // 2. Verification.
            try receiver.verify()
            // 3–5. Project folder, modes and dates, transcripts.
            try receiver.install()
            // 6. Registration.
            _ = try await host.registry.register(root: receiver.destination, parentID: nil)
        } catch {
            receiver.rollBack()
            receivers[migrationID] = nil
            let failure = ProjectRegistry.protocolError(error)
            Log.host.error("Migration \(migrationID.uuidString, privacy: .public): the commit failed: \(failure.message)")
            return failure
        }
        // 7. The journal entry `received`; a failure to write it is logged.
        journal.append(MigrationJournalEntry(migrationID: migrationID, projectID: receiver.project.id,
                                             rootPath: receiver.destination.path, targetDeviceID: nil,
                                             sourceDeviceID: receiver.sourceDeviceID, state: .received,
                                             updatedAt: Date()))
        try? saveJournal(required: false)
        // 8. The staging folder is removed; the migration is finished.
        receiver.finish()
        receivers[migrationID] = nil
        Log.host.notice("Migration \(migrationID.uuidString, privacy: .public): \(receiver.project.id, privacy: .public) received")
        return nil
    }

    /// migration.abort, and a closed connection: an unknown or finished migration changes nothing; a commit in
    /// progress ends first, and a committed migration is not undone.
    private func abortReceived(_ migrationID: UUID) async {
        while let commit = commits[migrationID] {
            _ = await commit.value
        }
        guard let receiver = receivers.removeValue(forKey: migrationID) else { return }
        receiver.abort()
        Log.host.notice("Migration \(migrationID.uuidString, privacy: .public): aborted; the files received were removed")
    }

    /// migration.status: `committed` when the journal has a `received` entry with that id, else `unknown`; a commit in
    /// progress ends first.
    private func status(_ migrationID: UUID) async -> MigrationStatusResult {
        while let commit = commits[migrationID] {
            _ = await commit.value
        }
        let committed = journal.contains { $0.migrationID == migrationID && $0.state == .received }
        return MigrationStatusResult(state: committed ? .committed : .unknown)
    }

    // MARK: - Journal

    /// Writes the whole journal. `required`: a failure throws internal "Cannot write migrations.json: <reason>.";
    /// otherwise it is logged.
    private func saveJournal(required: Bool) throws {
        do {
            try MigrationJournal.save(journal, host.appSupport)
        } catch {
            var reason = (error as? DataError)?.message ?? error.localizedDescription
            let fileName = host.appSupport.migrationsFile.lastPathComponent + ": "
            if reason.hasPrefix(fileName) {
                reason.removeFirst(fileName.count)
            }
            while reason.hasSuffix(".") {
                reason.removeLast()
            }
            Log.host.error("Cannot write migrations.json: \(reason)")
            if required {
                throw ProtocolError(.internal, "Cannot write migrations.json: \(reason).")
            }
        }
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}
#endif
