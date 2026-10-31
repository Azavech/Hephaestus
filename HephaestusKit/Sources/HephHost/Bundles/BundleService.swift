#if os(macOS)
import Foundation
import HephCore

/// The result of the MCP tool `get_bundle` (docs/services/bundles.md, "Swift API").
struct BundleDetails: Codable, Sendable {
    /// One ticket of the bundle.
    struct Entry: Codable, Sendable {
        /// Absent for a deleted ticket.
        var ticket: TicketItem?
        /// Absent without one.
        var session: SessionInfo?
        /// `ticket/<id>`
        var branch: String
        /// Absent while the worktree does not exist.
        var workFolder: String?
    }

    var bundle: BundleItem
    var maxParallel: Int
    /// One per ticket, in order.
    var tickets: [Entry]
}

/// The result of the MCP tool `finish_bundle`.
struct BundleFinishResult: Codable, Sendable {
    var bundle: BundleItem
    /// The branches kept because their work is not on `base`.
    var keptBranches: [String]
}

/// The `bundles` service of the host (docs/services/bundles.md): `bundles.*`, the bundle cache, the worktrees and the
/// coordinators' tools.
actor BundleService: HostMethodHandler {
    private let host: HostService
    /// The BundleItem of every valid bundle file of every registered project.
    private var cache: [String: [BundleID: BundleItem]] = [:]
    /// The code folder of every loaded project: removeWorktrees runs once the registry has dropped the project.
    private var codeFolders: [String: URL] = [:]
    /// The last status seen of each ticket session of a bundle (Observing the ticket sessions).
    private var sessionStatuses: [UUID: SessionStatus] = [:]
    /// The last message sent to each coordinator: its messages are sent one after the other, in order.
    private var coordinatorMessages: [UUID: Task<Void, Never>] = [:]
    /// The bundles one of whose methods or tools runs, and the calls waiting for each, in order: the methods and tools
    /// of a bundle run one after the other, so that each finds the status the one before left (two `bundles.start` of
    /// a draft never start two coordinators, a `bundles.stop` stops the ticket session a `start_bundle_ticket` started).
    private var busyBundles: Set<BundleID> = []
    private var waitingCalls: [BundleID: [CheckedContinuation<Void, Never>]] = [:]

    init(host: HostService) {
        self.host = host
    }

    // MARK: - Cache

    /// BundleFile.loadAll for a registered project.
    func load(projectID: String) async {
        guard let project = try? await host.registry.hosted(projectID) else { return }
        var items: [BundleID: BundleItem] = [:]
        for file in BundleFile.loadAll(projectRoot: project.root, projectID: projectID) {
            if let id = BundleID(file.id) {
                items[id] = Self.item(file)
            }
        }
        cache[projectID] = items
        codeFolders[projectID] = Self.codeFolder(of: project)
    }

    func unload(projectID: String) {
        cache[projectID] = nil
        codeFolders[projectID] = nil
    }

    /// Projects removed or moved: `git worktree remove --force` for each folder of `Worktrees/<projectID>/` while the
    /// repository is still there, then `Worktrees/<projectID>/` is deleted. Errors logged.
    func removeWorktrees(projectID: String) async {
        let folder = host.appSupport.worktreesFolder.appendingPathComponent(projectID, isDirectory: true)
        guard Self.exists(folder) else { return }
        if let codeFolder = codeFolders[projectID], Self.exists(codeFolder), await host.hostInfo.gitAvailable {
            let git = BundleGit(codeFolder: codeFolder, environment: await LoginEnvironment.shared.environment())
            let worktrees = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
                ?? []
            for worktree in worktrees.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    try await git.removeWorktree(at: worktree)
                } catch {
                    Log.host.error("Could not remove a worktree of \(projectID, privacy: .public): \(ProjectRegistry.protocolError(error).message)")
                }
            }
        }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Log.host.error("Could not delete the worktrees of \(projectID, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// By bundle number.
    func list(projectID: String) -> [BundleItem] {
        (cache[projectID] ?? [:]).sorted { $0.key.number < $1.key.number }.map(\.value)
    }

    /// A bundle of the project is `running` or `review`.
    func hasActiveBundle(projectID: String) -> Bool {
        (cache[projectID] ?? [:]).values.contains { Self.isActive($0.status) }
    }

    /// The working directory of a ticket session of a bundle: `<worktree folder>/<rel>`.
    func workFolder(projectID: String, ticketID: String) async throws -> URL {
        let id = TicketID(ticketID)?.description ?? ticketID
        // SessionService adds "Could not start Claude: " to the message (claude/cli.md 5.3).
        let removed = ProtocolError(.notFound, "the worktree of \(id) was removed with its bundle.")
        let worktree = worktreeFolder(projectID: projectID, ticketID: id)
        guard Self.exists(worktree) else { throw removed }
        let folder = Self.workFolder(worktree, relative: try await git(projectID: projectID).repository().relative)
        guard Self.exists(folder) else { throw removed }
        return folder
    }

    /// Observing the ticket sessions: a status change of a ticket session of a bundle in `running` or `review` sends one
    /// message to the bundle's coordinator.
    func sessionChanged(projectID: String, session: SessionInfo) async {
        guard session.kind == .ticket, let bundleText = session.bundleID, let ticketID = session.ticketID else { return }
        let previous = sessionStatuses[session.id]
        sessionStatuses[session.id] = session.status
        guard previous != session.status,
              let id = BundleID(bundleText), id.projectID == projectID,
              let bundle = cache[projectID]?[id], Self.isActive(bundle.status),
              let coordinator = bundle.coordinatorSessionID
        else { return }
        let text: String
        switch session.status {
        case .waitingPermission:
            text = "\(ticketID) is waiting for a permission answer in its session."
        case .idle, .stopped:
            guard previous == .running || previous == .waitingPermission,
                  let ticket = try? await host.tickets.ticket(projectID: projectID, ticketID: ticketID)
            else { return }
            text = "\(ticketID) ended its turn. Ticket status: \(ticket.status.rawValue)."
        case .failed:
            text = "The session of \(ticketID) failed: \(session.error ?? "")"
        case .starting, .running:
            return
        }
        sendToCoordinator(text, projectID: projectID, coordinator: coordinator)
    }

    // MARK: - Methods

    /// bundles.create: a new draft with the tickets in the given order, repeats removed (first kept).
    func create(projectID: String, name: String, ticketIDs: [String]) async throws -> BundleItem {
        let validName = try Self.validatedName(name)
        let host = self.host
        return try await host.registry.write(projectID) { project in
            guard !ticketIDs.isEmpty else { throw Self.noTicket }
            var ids: [String] = []
            for ticketID in ticketIDs {
                let id = try await self.checkedTicket(ticketID, projectID: projectID).id
                if !ids.contains(id) {
                    ids.append(id)
                }
            }
            try await self.checkNotInOtherBundle(ids, projectID: projectID, except: nil)
            do {
                let id = try BundleFile.allocateID(projectRoot: project.root, projectID: projectID)
                let now = YAMLCoding.now()
                let file = BundleFile(id: id.description, name: validName, status: .draft, created: now, updated: now,
                                      base: nil, coordinator: nil,
                                      tickets: ids.map { BundleFile.Item(ticket: $0, session: nil) })
                try BundleFile.create(file, projectRoot: project.root)
                let item = Self.item(file)
                await self.store(projectID: projectID, id: id, item: item)
                return item
            } catch {
                throw ProjectRegistry.protocolError(error)
            }
        }
    }

    /// bundles.update: `name` in any status; `ticketIDs` in `draft` only, keeping the session of a ticket that stays
    /// (the tickets of a `done` bundle are frozen).
    func update(projectID: String, bundleID: String, patch: BundlePatch) async throws -> BundleItem {
        let name = try patch.name.map(Self.validatedName)
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        let host = self.host
        return try await host.registry.write(projectID) { project in
            let (id, bundle) = try await self.existing(bundleID, projectID: projectID)
            var ticketIDs: [String]?
            if let requested = patch.ticketIDs {
                switch bundle.status {
                case .draft:
                    break
                case .running, .review:
                    throw Self.stopFirst(id)
                case .done:
                    throw Self.isDone(id)
                }
                guard !requested.isEmpty else { throw Self.noTicket }
                var ids: [String] = []
                for ticketID in requested {
                    ids.append(try await self.checkedTicket(ticketID, projectID: projectID).id)
                }
                try await self.checkNotInOtherBundle(ids, projectID: projectID, except: id)
                ticketIDs = ids
            }
            do {
                let file = try BundleFile.update(projectRoot: project.root, id: id) { file in
                    if let name {
                        file.name = name
                    }
                    if let ticketIDs {
                        let sessions = Dictionary(file.tickets.map { ($0.ticket, $0.session) },
                                                  uniquingKeysWith: { first, _ in first })
                        file.tickets = ticketIDs.map { BundleFile.Item(ticket: $0, session: sessions[$0] ?? nil) }
                    }
                }
                let item = Self.item(file)
                await self.store(projectID: projectID, id: id, item: item)
                return item
            } catch {
                throw Self.bundleError(error, id: id)
            }
        }
    }

    /// bundles.delete: the worktrees of its tickets removed, the branches whose work is on `base` deleted, the file
    /// deleted.
    func delete(projectID: String, bundleID: String) async throws {
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        try await host.registry.checkWritable(projectID)
        let (id, bundle) = try existing(bundleID, projectID: projectID)
        await renameOldBranches(projectID: projectID, bundle: bundle)
        guard !Self.isActive(bundle.status) else { throw Self.stopFirst(id) }
        _ = try await removeWork(projectID: projectID, bundle: bundle)
        let host = self.host
        try await host.registry.write(projectID) { project in
            do {
                try BundleFile.delete(projectRoot: project.root, id: id)
            } catch {
                throw Self.bundleError(error, id: id)
            }
            await self.remove(projectID: projectID, id: id)
        }
    }

    /// bundles.start (Start): the repository check, the base, the coordinator, then status `running`. When the
    /// coordinator cannot be started or sent its message, nothing is written.
    func start(projectID: String, bundleID: String) async throws -> BundleItem {
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        try await host.registry.checkWritable(projectID)
        let (id, bundle) = try existing(bundleID, projectID: projectID)
        await renameOldBranches(projectID: projectID, bundle: bundle)
        switch bundle.status {
        case .draft:
            break
        case .running, .review:
            throw Self.stopFirst(id)
        case .done:
            throw Self.isDone(id)
        }
        // 1. The repository check.
        let git = try await git(projectID: projectID)
        _ = try await git.repository()
        // 2. The base.
        let base: String
        if let current = bundle.base {
            base = current
        } else {
            base = try await git.currentBranch()
        }
        // The coordinator's prompt, built while its process starts, reads the base from the cache.
        if bundle.base == nil {
            var pending = bundle
            pending.base = base
            cache[projectID]?[id] = pending
        }
        // 3. The coordinator.
        let mainID = await host.mesh.localDevice().id
        let coordinator: UUID
        do {
            if let existing = bundle.coordinatorSessionID, try await hasSession(existing, projectID: projectID) {
                let text = "Resume work on \(id): check the state of its tickets with get_bundle."
                try await host.sessions.send(projectID: projectID, sessionID: existing, text: text, attachments: [],
                                             deviceID: mainID)
                coordinator = existing
            } else {
                let session = try await host.sessions.start(SessionStart(projectID: projectID, kind: .bundle,
                                                                         deviceID: mainID, bundleID: id.description))
                coordinator = session.id
            }
        } catch {
            if bundle.base == nil, cache[projectID]?[id]?.base == base {
                cache[projectID]?[id]?.base = nil
            }
            throw error
        }
        // 4. Status running.
        return try await change(projectID: projectID, id: id) { file in
            file.base = base
            file.coordinator = coordinator
            file.status = .running
        }
    }

    /// bundles.stop: `sessions.stop` of the coordinator and of every ticket session of the bundle; status `draft`.
    func stop(projectID: String, bundleID: String) async throws -> BundleItem {
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        try await host.registry.checkWritable(projectID)
        let (id, bundle) = try existing(bundleID, projectID: projectID)
        guard Self.isActive(bundle.status) else { throw Self.notRunning(id) }
        let sessions = try await host.sessions.sessions(projectID: projectID)
        let stopped = sessions.filter { session in
            session.id == bundle.coordinatorSessionID || (session.kind == .ticket && session.bundleID == id.description)
        }
        for session in stopped {
            try await host.sessions.stop(projectID: projectID, sessionID: session.id)
        }
        return try await change(projectID: projectID, id: id) { file in
            file.status = .draft
        }
    }

    // MARK: - Tools of the coordinator

    /// get_bundle.
    func details(projectID: String, bundleID: String) async throws -> BundleDetails {
        let (_, bundle) = try existing(bundleID, projectID: projectID)
        await renameOldBranches(projectID: projectID, bundle: bundle)
        let sessions = try await host.sessions.sessions(projectID: projectID)
        var relative: String?
        var entries: [BundleDetails.Entry] = []
        for ticket in bundle.tickets {
            let worktree = worktreeFolder(projectID: projectID, ticketID: ticket.ticketID)
            var workFolder: String?
            if Self.exists(worktree) {
                if relative == nil {
                    relative = try await git(projectID: projectID).repository().relative
                }
                workFolder = Self.workFolder(worktree, relative: relative ?? "").path
            }
            entries.append(BundleDetails.Entry(
                ticket: try? await host.tickets.ticket(projectID: projectID, ticketID: ticket.ticketID),
                session: ticket.sessionID.flatMap { sessionID in sessions.first { $0.id == sessionID } },
                branch: Self.branch(ticket.ticketID),
                workFolder: workFolder))
        }
        return BundleDetails(bundle: bundle, maxParallel: await host.settings().bundles.maxParallel, tickets: entries)
    }

    /// start_bundle_ticket: instructions for the ticket's existing session, else a new ticket session in the ticket's
    /// worktree. The ticket's status follows the turns of its session (services/host.md §8.1).
    func startTicket(projectID: String, bundleID: String, ticketID: String, instructions: String?) async throws
        -> SessionInfo {
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        let (id, bundle) = try existing(bundleID, projectID: projectID)
        await renameOldBranches(projectID: projectID, bundle: bundle)
        // 1. The ticket is in the bundle, which runs.
        let ticketText = TicketID(ticketID)?.description ?? ticketID
        guard let entry = bundle.tickets.first(where: { $0.ticketID == ticketText }) else {
            throw ProtocolError(.badRequest, "\(ticketText) is not in \(id).")
        }
        guard Self.isActive(bundle.status) else { throw Self.notRunning(id) }
        _ = try await checkedTicket(ticketText, projectID: projectID)
        let mainID = await host.mesh.localDevice().id
        let sessions = try await host.sessions.sessions(projectID: projectID)
        // 2. The ticket's session gets the instructions.
        if let sessionID = entry.sessionID, let existing = sessions.first(where: { $0.id == sessionID }) {
            guard let instructions else {
                throw ProtocolError(.badRequest, "\(ticketText) already has a session: give instructions for it.")
            }
            try await host.sessions.send(projectID: projectID, sessionID: sessionID, text: instructions,
                                         attachments: [], deviceID: mainID)
            return try await host.sessions.sessions(projectID: projectID).first { $0.id == sessionID } ?? existing
        }
        // 3. The limit of parallel ticket sessions.
        let busy: Set<SessionStatus> = [.starting, .running, .waitingPermission]
        let running = sessions.filter { session in
            session.kind == .ticket && session.bundleID == id.description && busy.contains(session.status)
        }.count
        let maxParallel = await host.settings().bundles.maxParallel
        guard running < maxParallel else {
            throw ProtocolError(.conflict, "\(running) ticket sessions of \(id) are running, the limit of this Main "
                                + "(Settings ▸ Claude ▸ Bundles). Start \(ticketText) when one of them ends its turn.")
        }
        // 4. The worktree.
        let git = try await git(projectID: projectID)
        let worktree = worktreeFolder(projectID: projectID, ticketID: ticketText)
        if !Self.exists(worktree) {
            let base: String
            if let current = bundle.base {
                base = current
            } else {
                base = try await git.currentBranch()
            }
            try await git.createWorktree(at: worktree, branch: Self.branch(ticketText), base: base)
        }
        // 5. The ticket session.
        let session = try await host.sessions.start(SessionStart(projectID: projectID, kind: .ticket, ticketID: ticketText,
                                                                 mode: .implement, message: instructions,
                                                                 deviceID: mainID, bundleID: id.description))
        _ = try await change(projectID: projectID, id: id) { file in
            for index in file.tickets.indices where file.tickets[index].ticket == ticketText {
                file.tickets[index].session = session.id
            }
        }
        return session
    }

    /// update_bundle: `running` or `review` only, for a bundle in `running` or `review`.
    func setStatus(projectID: String, bundleID: String, status: BundleStatus) async throws -> BundleItem {
        guard Self.isActive(status) else {
            throw ProtocolError(.badRequest, "Invalid arguments: status must be one of running, review.")
        }
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        let (id, bundle) = try existing(bundleID, projectID: projectID)
        guard Self.isActive(bundle.status) else { throw Self.notRunning(id) }
        return try await change(projectID: projectID, id: id) { file in
            guard Self.isActive(file.status) else { throw Self.notRunning(id) }
            file.status = status
        }
    }

    /// finish_bundle, for a bundle in `running` or `review`: the worktrees removed, the branches whose work is on
    /// `base` deleted, the bundle `done`. The statuses of its tickets are left as they are.
    func finish(projectID: String, bundleID: String) async throws -> BundleFinishResult {
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        let (id, bundle) = try existing(bundleID, projectID: projectID)
        await renameOldBranches(projectID: projectID, bundle: bundle)
        guard Self.isActive(bundle.status) else { throw Self.notRunning(id) }
        let keptBranches = try await removeWork(projectID: projectID, bundle: bundle)
        let item = try await change(projectID: projectID, id: id) { file in
            file.status = .done
        }
        return BundleFinishResult(bundle: item, keptBranches: keptBranches)
    }

    // MARK: - HostMethodHandler

    func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .bundlesCreate:
                let request = try Self.decode(BundlesCreateParams.self, params, method)
                return try WireCoding.encodeJSON(try await create(projectID: request.projectID, name: request.name,
                                                                  ticketIDs: request.ticketIDs))
            case .bundlesUpdate:
                let request = try Self.decode(BundlesUpdateParams.self, params, method)
                return try WireCoding.encodeJSON(try await update(projectID: request.projectID,
                                                                  bundleID: request.bundleID, patch: request.patch))
            case .bundlesDelete:
                let request = try Self.decode(BundlesDeleteParams.self, params, method)
                try await delete(projectID: request.projectID, bundleID: request.bundleID)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .bundlesStart:
                let request = try Self.decode(BundlesStartParams.self, params, method)
                return try WireCoding.encodeJSON(try await start(projectID: request.projectID,
                                                                 bundleID: request.bundleID))
            case .bundlesStop:
                let request = try Self.decode(BundlesStopParams.self, params, method)
                return try WireCoding.encodeJSON(try await stop(projectID: request.projectID,
                                                                bundleID: request.bundleID))
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - Private

    private static let noTicket = ProtocolError(.badRequest, "A bundle needs at least one ticket.")

    private static func stopFirst(_ id: BundleID) -> ProtocolError {
        ProtocolError(.conflict, "Stop \(id) first.")
    }

    private static func isDone(_ id: BundleID) -> ProtocolError {
        ProtocolError(.conflict, "\(id) is done.")
    }

    private static func notRunning(_ id: BundleID) -> ProtocolError {
        ProtocolError(.conflict, "\(id) is not running.")
    }

    private static func noBundle(_ bundleID: String) -> ProtocolError {
        ProtocolError(.notFound, "Bundle \(BundleID(bundleID)?.description ?? bundleID) does not exist.")
    }

    /// The error of a bundle change: a bundle file that no longer exists is "Bundle <id> does not exist."; other
    /// errors are mapped as in services/host.md §6.9.
    private static func bundleError(_ error: any Error, id: BundleID) -> ProtocolError {
        if case DataError.notFound(let message) = error, message == "bundle \(id) not found" {
            return noBundle(id.description)
        }
        return ProjectRegistry.protocolError(error)
    }

    private static func isActive(_ status: BundleStatus) -> Bool {
        status == .running || status == .review
    }

    /// Waits until the methods and tools of the bundle called before have returned; the result goes to
    /// `endOperation`. A bundle id that does not parse waits for nothing: the call fails with notFound.
    private func beginOperation(_ bundleID: String, projectID: String) async -> BundleID? {
        guard let id = BundleID(bundleID), id.projectID == projectID else { return nil }
        if busyBundles.insert(id).inserted {
            return id
        }
        await withCheckedContinuation { continuation in
            waitingCalls[id, default: []].append(continuation)
        }
        return id
    }

    /// Lets the next waiting call of the bundle run.
    private func endOperation(_ id: BundleID?) {
        guard let id else { return }
        if var calls = waitingCalls[id], !calls.isEmpty {
            let next = calls.removeFirst()
            waitingCalls[id] = calls.isEmpty ? nil : calls
            next.resume()
        } else {
            busyBundles.remove(id)
        }
    }

    /// The bundle id of a request: parsed with the project's identifier and cached, else notFound.
    private func existing(_ bundleID: String, projectID: String) throws -> (BundleID, BundleItem) {
        guard let id = BundleID(bundleID), id.projectID == projectID, let bundle = cache[projectID]?[id] else {
            throw Self.noBundle(bundleID)
        }
        return (id, bundle)
    }

    /// A ticket id given to a method: a ticket of the project that is not broken.
    private func checkedTicket(_ ticketID: String, projectID: String) async throws -> TicketItem {
        let ticket = try await host.tickets.ticket(projectID: projectID, ticketID: ticketID)
        if let parseError = ticket.parseError {
            throw ProtocolError(.conflict, "The file is invalid: \(parseError)")
        }
        return ticket
    }

    /// A ticket is in at most one bundle that is not `done`: the first of `ticketIDs` that is in another such bundle of
    /// the project (by number) fails with conflict "<ticket id> is in <bundle id>.".
    private func checkNotInOtherBundle(_ ticketIDs: [String], projectID: String, except: BundleID?) throws {
        let others = (cache[projectID] ?? [:])
            .filter { $0.key != except && $0.value.status != .done }
            .sorted { $0.key.number < $1.key.number }
        for ticketID in ticketIDs {
            if let other = others.first(where: { $0.value.tickets.contains { $0.ticketID == ticketID } }) {
                throw ProtocolError(.conflict, "\(ticketID) is in \(other.key).")
            }
        }
    }

    /// Trimmed, not empty and on one line (badRequest).
    private static func validatedName(_ name: String) throws -> String {
        do {
            return try ProjectFile.validatedName(name)
        } catch {
            throw ProtocolError(.badRequest, "The name must not be empty and must be on one line.")
        }
    }

    /// The session is a session of the project.
    private func hasSession(_ sessionID: UUID, projectID: String) async throws -> Bool {
        try await host.sessions.sessions(projectID: projectID).contains { $0.id == sessionID }
    }

    /// One read-modify-write of the bundle file inside registry.write; the new item is cached and announced.
    private func change(projectID: String, id: BundleID,
                        _ body: @escaping @Sendable (inout BundleFile) throws -> Void) async throws -> BundleItem {
        let host = self.host
        return try await host.registry.write(projectID) { project in
            do {
                let file = try BundleFile.update(projectRoot: project.root, id: id, body)
                let item = Self.item(file)
                await self.store(projectID: projectID, id: id, item: item)
                return item
            } catch {
                throw Self.bundleError(error, id: id)
            }
        }
    }

    /// For each ticket in order, except a ticket in another bundle of the project that is not `done` (its worktree and
    /// branch are that bundle's): its worktree removed; with a base, its branch deleted when its work is on the base,
    /// else kept. Returns the branches kept.
    private func removeWork(projectID: String, bundle: BundleItem) async throws -> [String] {
        var kept: [String] = []
        var runner: BundleGit?
        for ticket in bundle.tickets {
            // Read at each ticket: a bundle created while the work is removed may take the next ones.
            let inOtherBundle = (cache[projectID] ?? [:]).values.contains { other in
                other.id != bundle.id && other.status != .done && other.tickets.contains { $0.ticketID == ticket.ticketID }
            }
            guard !inOtherBundle else { continue }
            let worktree = worktreeFolder(projectID: projectID, ticketID: ticket.ticketID)
            let hasWorktree = Self.exists(worktree)
            guard hasWorktree || bundle.base != nil else { continue }
            let git: BundleGit
            if let runner {
                git = runner
            } else {
                git = try await self.git(projectID: projectID)
                runner = git
            }
            if hasWorktree {
                try await git.removeWorktree(at: worktree)
            }
            guard let base = bundle.base else { continue }
            let branch = Self.branch(ticket.ticketID)
            guard try await git.branchExists(branch) else { continue }
            if try await git.isBroughtIn(branch: branch, base: base) {
                try await git.deleteBranch(branch)
            } else {
                kept.append(branch)
            }
        }
        return kept
    }

    /// Old branches: `BundleGit.renameOldBranch(ticketID:)` for each ticket of the bundle, in order, while
    /// `host.info` reports `gitAvailable`; a failure is logged and the method or tool goes on.
    private func renameOldBranches(projectID: String, bundle: BundleItem) async {
        guard await host.hostInfo.gitAvailable else { return }
        let git: BundleGit
        do {
            git = try await self.git(projectID: projectID)
        } catch {
            Log.host.error("Could not rename the old branches of \(bundle.id, privacy: .public): \(ProjectRegistry.protocolError(error).message)")
            return
        }
        for ticket in bundle.tickets {
            do {
                _ = try await git.renameOldBranch(ticketID: ticket.ticketID)
            } catch {
                Log.host.error("Could not rename the branch task/\(ticket.ticketID, privacy: .public): \(ProjectRegistry.protocolError(error).message)")
            }
        }
    }

    /// The project's BundleGit, only while host.info reports gitAvailable.
    private func git(projectID: String) async throws -> BundleGit {
        guard await host.hostInfo.gitAvailable else {
            throw ProtocolError(.unavailable, "git is not available on this Main.")
        }
        let project = try await host.registry.hosted(projectID)
        let codeFolder = Self.codeFolder(of: project)
        codeFolders[projectID] = codeFolder
        return BundleGit(codeFolder: codeFolder, environment: await LoginEnvironment.shared.environment())
    }

    /// Sends a message to a coordinator after the messages sent to it before; errors logged.
    private func sendToCoordinator(_ text: String, projectID: String, coordinator: UUID) {
        let previous = coordinatorMessages[coordinator]
        let host = self.host
        coordinatorMessages[coordinator] = Task {
            await previous?.value
            do {
                let mainID = await host.mesh.localDevice().id
                try await host.sessions.send(projectID: projectID, sessionID: coordinator, text: text, attachments: [],
                                             deviceID: mainID)
            } catch {
                Log.host.error("Could not send a message to the coordinator \(coordinator.uuidString, privacy: .public): \(ProjectRegistry.protocolError(error).message)")
            }
        }
    }

    /// Stores the item; emits bundle.changed when it differs from the cached one or was not cached.
    private func store(projectID: String, id: BundleID, item: BundleItem) async {
        guard cache[projectID] != nil else { return }
        let previous = cache[projectID]?[id]
        cache[projectID]?[id] = item
        if previous != item {
            await host.emit(.bundleChanged(BundleChangedPayload(projectID: projectID, bundle: item)))
        }
    }

    /// Removes a cached bundle and emits bundle.removed.
    private func remove(projectID: String, id: BundleID) async {
        guard cache[projectID]?[id] != nil else { return }
        cache[projectID]?[id] = nil
        await host.emit(.bundleRemoved(BundleRemovedPayload(projectID: projectID, bundleID: id.description)))
    }

    /// `<Application Support>/Hephaestus/Worktrees/<projectID>/<ticket id>/`
    private func worktreeFolder(projectID: String, ticketID: String) -> URL {
        host.appSupport.worktreesFolder
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent(ticketID, isDirectory: true)
    }

    /// The work folder: the code folder's place in the worktree.
    private static func workFolder(_ worktree: URL, relative: String) -> URL {
        relative.isEmpty ? worktree : worktree.appendingPathComponent(relative, isDirectory: true)
    }

    /// `ticket/<ticket id>`
    private static func branch(_ ticketID: String) -> String {
        "ticket/\(ticketID)"
    }

    /// The project's code folder: `root` + project.yml `code` (`.` is `root`).
    private static func codeFolder(of project: HostedProject) -> URL {
        let code = project.file.code
        guard code != "." else { return project.root }
        return project.root.appendingPathComponent(code, isDirectory: true).standardizedFileURL
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Mapping to BundleItem.
    private static func item(_ file: BundleFile) -> BundleItem {
        BundleItem(id: file.id, name: file.name, status: file.status, created: file.created, updated: file.updated,
                   base: file.base, coordinatorSessionID: file.coordinator,
                   tickets: file.tickets.map { BundleTicket(ticketID: $0.ticket, sessionID: $0.session) })
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}
#endif
