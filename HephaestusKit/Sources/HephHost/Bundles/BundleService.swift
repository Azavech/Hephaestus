#if os(macOS)
import Foundation
import HephCore

/// The result of the MCP tool `get_bundle` (docs/services/bundles.md, "Swift API").
struct BundleDetails: Codable, Sendable {
    /// One task of the bundle.
    struct Entry: Codable, Sendable {
        /// Absent for a deleted task.
        var task: TaskItem?
        /// Absent without one.
        var session: SessionInfo?
        /// `task/<id>`
        var branch: String
        /// Absent while the worktree does not exist.
        var workFolder: String?
    }

    var bundle: BundleItem
    var maxParallel: Int
    /// One per task, in order.
    var tasks: [Entry]
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
    /// The last status seen of each task session of a bundle (Observing the task sessions).
    private var sessionStatuses: [UUID: SessionStatus] = [:]
    /// The last message sent to each coordinator: its messages are sent one after the other, in order.
    private var coordinatorMessages: [UUID: Task<Void, Never>] = [:]
    /// The bundles one of whose methods or tools runs, and the calls waiting for each, in order: the methods and tools
    /// of a bundle run one after the other, so that each finds the status the one before left (two `bundles.start` of
    /// a draft never start two coordinators, a `bundles.stop` stops the task session a `start_bundle_task` started).
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

    /// The working directory of a task session of a bundle: `<worktree folder>/<rel>`.
    func workFolder(projectID: String, taskID: String) async throws -> URL {
        let id = TaskID(taskID)?.description ?? taskID
        // SessionService adds "Could not start Claude: " to the message (claude/cli.md 5.3).
        let removed = ProtocolError(.notFound, "the worktree of \(id) was removed with its bundle.")
        let worktree = worktreeFolder(projectID: projectID, taskID: id)
        guard Self.exists(worktree) else { throw removed }
        let folder = Self.workFolder(worktree, relative: try await git(projectID: projectID).repository().relative)
        guard Self.exists(folder) else { throw removed }
        return folder
    }

    /// Observing the task sessions: a status change of a task session of a bundle in `running` or `review` sends one
    /// message to the bundle's coordinator.
    func sessionChanged(projectID: String, session: SessionInfo) async {
        guard session.kind == .task, let bundleText = session.bundleID, let taskID = session.taskID else { return }
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
            text = "\(taskID) is waiting for a permission answer in its session."
        case .idle, .stopped:
            guard previous == .running || previous == .waitingPermission,
                  let task = try? await host.tasks.task(projectID: projectID, taskID: taskID)
            else { return }
            text = "\(taskID) ended its turn. Task status: \(task.status.rawValue)."
        case .failed:
            text = "The session of \(taskID) failed: \(session.error ?? "")"
        case .starting, .running:
            return
        }
        sendToCoordinator(text, projectID: projectID, coordinator: coordinator)
    }

    // MARK: - Methods

    /// bundles.create: a new draft with the tasks in the given order, repeats removed (first kept).
    func create(projectID: String, name: String, taskIDs: [String]) async throws -> BundleItem {
        let validName = try Self.validatedName(name)
        let host = self.host
        return try await host.registry.write(projectID) { project in
            guard !taskIDs.isEmpty else { throw Self.noTask }
            var ids: [String] = []
            for taskID in taskIDs {
                let id = try await self.checkedTask(taskID, projectID: projectID).id
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
                                      tasks: ids.map { BundleFile.Item(task: $0, session: nil) })
                try BundleFile.create(file, projectRoot: project.root)
                let item = Self.item(file)
                await self.store(projectID: projectID, id: id, item: item)
                return item
            } catch {
                throw ProjectRegistry.protocolError(error)
            }
        }
    }

    /// bundles.update: `name` in any status; `taskIDs` in `draft` and `done`, keeping the session of a task that stays
    /// (a `done` bundle becomes `draft`).
    func update(projectID: String, bundleID: String, patch: BundlePatch) async throws -> BundleItem {
        let name = try patch.name.map(Self.validatedName)
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        let host = self.host
        return try await host.registry.write(projectID) { project in
            let (id, bundle) = try await self.existing(bundleID, projectID: projectID)
            var taskIDs: [String]?
            if let requested = patch.taskIDs {
                guard !Self.isActive(bundle.status) else { throw Self.stopFirst(id) }
                guard !requested.isEmpty else { throw Self.noTask }
                var ids: [String] = []
                for taskID in requested {
                    ids.append(try await self.checkedTask(taskID, projectID: projectID).id)
                }
                try await self.checkNotInOtherBundle(ids, projectID: projectID, except: id)
                taskIDs = ids
            }
            do {
                let file = try BundleFile.update(projectRoot: project.root, id: id) { file in
                    if let name {
                        file.name = name
                    }
                    if let taskIDs {
                        let sessions = Dictionary(file.tasks.map { ($0.task, $0.session) },
                                                  uniquingKeysWith: { first, _ in first })
                        file.tasks = taskIDs.map { BundleFile.Item(task: $0, session: sessions[$0] ?? nil) }
                        if file.status == .done {
                            file.status = .draft
                        }
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

    /// bundles.delete: the worktrees of its tasks removed, the branches whose work is on `base` deleted, the file
    /// deleted.
    func delete(projectID: String, bundleID: String) async throws {
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        try await host.registry.checkWritable(projectID)
        let (id, bundle) = try existing(bundleID, projectID: projectID)
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
        switch bundle.status {
        case .draft:
            break
        case .running, .review:
            throw Self.stopFirst(id)
        case .done:
            throw ProtocolError(.conflict, "\(id) is done.")
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
                let text = "Resume work on \(id): check the state of its tasks with get_bundle."
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

    /// bundles.stop: `sessions.stop` of the coordinator and of every task session of the bundle; status `draft`.
    func stop(projectID: String, bundleID: String) async throws -> BundleItem {
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        try await host.registry.checkWritable(projectID)
        let (id, bundle) = try existing(bundleID, projectID: projectID)
        guard Self.isActive(bundle.status) else { throw Self.notRunning(id) }
        let sessions = try await host.sessions.sessions(projectID: projectID)
        let stopped = sessions.filter { session in
            session.id == bundle.coordinatorSessionID || (session.kind == .task && session.bundleID == id.description)
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
        let sessions = try await host.sessions.sessions(projectID: projectID)
        var relative: String?
        var entries: [BundleDetails.Entry] = []
        for task in bundle.tasks {
            let worktree = worktreeFolder(projectID: projectID, taskID: task.taskID)
            var workFolder: String?
            if Self.exists(worktree) {
                if relative == nil {
                    relative = try await git(projectID: projectID).repository().relative
                }
                workFolder = Self.workFolder(worktree, relative: relative ?? "").path
            }
            entries.append(BundleDetails.Entry(
                task: try? await host.tasks.task(projectID: projectID, taskID: task.taskID),
                session: task.sessionID.flatMap { sessionID in sessions.first { $0.id == sessionID } },
                branch: Self.branch(task.taskID),
                workFolder: workFolder))
        }
        return BundleDetails(bundle: bundle, maxParallel: await host.settings().bundles.maxParallel, tasks: entries)
    }

    /// start_bundle_task: instructions for the task's existing session, else a new task session in the task's
    /// worktree.
    func startTask(projectID: String, bundleID: String, taskID: String, instructions: String?) async throws
        -> SessionInfo {
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        let (id, bundle) = try existing(bundleID, projectID: projectID)
        // 1. The task is in the bundle, which runs.
        let taskText = TaskID(taskID)?.description ?? taskID
        guard let entry = bundle.tasks.first(where: { $0.taskID == taskText }) else {
            throw ProtocolError(.badRequest, "\(taskText) is not in \(id).")
        }
        guard Self.isActive(bundle.status) else { throw Self.notRunning(id) }
        _ = try await checkedTask(taskText, projectID: projectID)
        let mainID = await host.mesh.localDevice().id
        let sessions = try await host.sessions.sessions(projectID: projectID)
        // 2. The task's session gets the instructions.
        if let sessionID = entry.sessionID, let existing = sessions.first(where: { $0.id == sessionID }) {
            guard let instructions else {
                throw ProtocolError(.badRequest, "\(taskText) already has a session: give instructions for it.")
            }
            try await host.sessions.send(projectID: projectID, sessionID: sessionID, text: instructions,
                                         attachments: [], deviceID: mainID)
            return try await host.sessions.sessions(projectID: projectID).first { $0.id == sessionID } ?? existing
        }
        // 3. The limit of parallel task sessions.
        let busy: Set<SessionStatus> = [.starting, .running, .waitingPermission]
        let running = sessions.filter { session in
            session.kind == .task && session.bundleID == id.description && busy.contains(session.status)
        }.count
        let maxParallel = await host.settings().bundles.maxParallel
        guard running < maxParallel else {
            throw ProtocolError(.conflict, "\(running) task sessions of \(id) are running, the limit of this Main "
                                + "(Settings ▸ Claude ▸ Bundles). Start \(taskText) when one of them ends its turn.")
        }
        // 4. The worktree.
        let git = try await git(projectID: projectID)
        let worktree = worktreeFolder(projectID: projectID, taskID: taskText)
        if !Self.exists(worktree) {
            let base: String
            if let current = bundle.base {
                base = current
            } else {
                base = try await git.currentBranch()
            }
            try await git.createWorktree(at: worktree, branch: Self.branch(taskText), base: base)
        }
        // 5. The task session.
        let session = try await host.sessions.start(SessionStart(projectID: projectID, kind: .task, taskID: taskText,
                                                                 mode: .implement, message: instructions,
                                                                 deviceID: mainID, bundleID: id.description))
        _ = try await change(projectID: projectID, id: id) { file in
            for index in file.tasks.indices where file.tasks[index].task == taskText {
                file.tasks[index].session = session.id
            }
        }
        if let task = try? await host.tasks.task(projectID: projectID, taskID: taskText), task.status == .todo {
            do {
                _ = try await host.tasks.update(projectID: projectID, taskID: taskText,
                                                patch: TaskPatch(status: .inProgress))
            } catch {
                Log.host.error("Could not set \(taskText, privacy: .public) in progress: \(ProjectRegistry.protocolError(error).message)")
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
    /// `base` deleted, the bundle `done`; outside the Forge source project, the tasks whose branch was deleted become
    /// `done`.
    func finish(projectID: String, bundleID: String) async throws -> BundleFinishResult {
        let operation = await beginOperation(bundleID, projectID: projectID)
        defer { endOperation(operation) }
        let (id, bundle) = try existing(bundleID, projectID: projectID)
        guard Self.isActive(bundle.status) else { throw Self.notRunning(id) }
        let work = try await removeWork(projectID: projectID, bundle: bundle)
        let item = try await change(projectID: projectID, id: id) { file in
            file.status = .done
        }
        let settings = await host.settings()
        let isForgeSource = settings.forge.enabled && settings.forge.sourceProjectID == projectID
        if !isForgeSource {
            for taskID in work.deleted {
                do {
                    _ = try await host.tasks.update(projectID: projectID, taskID: taskID,
                                                    patch: TaskPatch(status: .done))
                } catch {
                    Log.host.error("Could not set \(taskID, privacy: .public) done: \(ProjectRegistry.protocolError(error).message)")
                }
            }
        }
        return BundleFinishResult(bundle: item, keptBranches: work.kept)
    }

    // MARK: - HostMethodHandler

    func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .bundlesCreate:
                let request = try Self.decode(BundlesCreateParams.self, params, method)
                return try WireCoding.encodeJSON(try await create(projectID: request.projectID, name: request.name,
                                                                  taskIDs: request.taskIDs))
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

    private static let noTask = ProtocolError(.badRequest, "A bundle needs at least one task.")

    private static func stopFirst(_ id: BundleID) -> ProtocolError {
        ProtocolError(.conflict, "Stop \(id) first.")
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

    /// A task id given to a method: a task of the project that is not broken.
    private func checkedTask(_ taskID: String, projectID: String) async throws -> TaskItem {
        let task = try await host.tasks.task(projectID: projectID, taskID: taskID)
        if let parseError = task.parseError {
            throw ProtocolError(.conflict, "The file is invalid: \(parseError)")
        }
        return task
    }

    /// A task is in at most one bundle that is not `done`: the first of `taskIDs` that is in another such bundle of
    /// the project (by number) fails with conflict "<task id> is in <bundle id>.".
    private func checkNotInOtherBundle(_ taskIDs: [String], projectID: String, except: BundleID?) throws {
        let others = (cache[projectID] ?? [:])
            .filter { $0.key != except && $0.value.status != .done }
            .sorted { $0.key.number < $1.key.number }
        for taskID in taskIDs {
            if let other = others.first(where: { $0.value.tasks.contains { $0.taskID == taskID } }) {
                throw ProtocolError(.conflict, "\(taskID) is in \(other.key).")
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

    /// For each task in order, except a task in another bundle of the project that is not `done` (its worktree and
    /// branch are that bundle's): its worktree removed; with a base, its branch deleted when its work is on the base,
    /// else kept. Returns the tasks whose branch was deleted and the branches kept.
    private func removeWork(projectID: String, bundle: BundleItem) async throws
        -> (deleted: [String], kept: [String]) {
        var deleted: [String] = []
        var kept: [String] = []
        var runner: BundleGit?
        for task in bundle.tasks {
            // Read at each task: a bundle created while the work is removed may take the next ones.
            let inOtherBundle = (cache[projectID] ?? [:]).values.contains { other in
                other.id != bundle.id && other.status != .done && other.tasks.contains { $0.taskID == task.taskID }
            }
            guard !inOtherBundle else { continue }
            let worktree = worktreeFolder(projectID: projectID, taskID: task.taskID)
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
            let branch = Self.branch(task.taskID)
            guard try await git.branchExists(branch) else { continue }
            if try await git.isBroughtIn(branch: branch, base: base) {
                try await git.deleteBranch(branch)
                deleted.append(task.taskID)
            } else {
                kept.append(branch)
            }
        }
        return (deleted, kept)
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

    /// `<Application Support>/Hephaestus/Worktrees/<projectID>/<task id>/`
    private func worktreeFolder(projectID: String, taskID: String) -> URL {
        host.appSupport.worktreesFolder
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
    }

    /// The work folder: the code folder's place in the worktree.
    private static func workFolder(_ worktree: URL, relative: String) -> URL {
        relative.isEmpty ? worktree : worktree.appendingPathComponent(relative, isDirectory: true)
    }

    /// `task/<task id>`
    private static func branch(_ taskID: String) -> String {
        "task/\(taskID)"
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
                   tasks: file.tasks.map { BundleTask(taskID: $0.task, sessionID: $0.session) })
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}
#endif
