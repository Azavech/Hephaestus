#if os(macOS)
import Foundation
import HephCore

/// Implemented by HostService.
public protocol SessionHost: Sendable {
    func localDevice() async -> DeviceInfo
    /// Non-revoked devices of the registry.
    func devices() async -> [DeviceRecord]
    func settings() async -> DeviceSettings
    /// Throws ProtocolError notFound when the project is not hosted on this Main.
    func claudeProject(_ projectID: String) async throws -> ClaudeProjectContext
    /// Throws ProtocolError notFound when the task does not exist.
    func claudeTask(projectID: String, taskID: String) async throws -> ClaudeTaskContext
    /// Throws ProtocolError notFound when the bundle does not exist (services/bundles.md).
    func claudeBundle(projectID: String, bundleID: String) async throws -> ClaudeBundleContext
    /// BundleService.workFolder: the working directory of a task session of a bundle.
    func bundleWorkFolder(projectID: String, taskID: String) async throws -> URL
    /// ProjectRegistry.checkWritable: throws locked when the project or an ancestor is migrating.
    func checkWritable(_ projectID: String) async throws
    /// The project's SessionArchive (data/sessions.md).
    func sessionArchive(_ projectID: String) async throws -> SessionArchive
    var mcp: MCPServer { get }
    var skills: SkillsService { get }
    /// The upload store: claims the uploads that sessions.start and sessions.send attach (services/files.md §7).
    var uploads: UploadService { get }
    // Events: sent with EventHub; sessionChanged and sessionRemoved also notify ForgeService.
    func sessionChanged(projectID: String, session: SessionInfo) async               // session.changed
    func sessionRemoved(projectID: String, sessionID: UUID) async                   // session.removed
    func sessionEvent(projectID: String, sessionID: UUID, event: SessionEvent) async // session.event, topic session:<id>
    func sessionDelta(projectID: String, sessionID: UUID, messageID: String, index: Int,
                      kind: SessionDeltaKind, text: String) async                   // session.delta, topic session:<id>
    func permissionRequested(projectID: String, sessionID: UUID, request: PermissionRequest) async
    func permissionResolved(projectID: String, sessionID: UUID, requestID: String,
                            decision: PermissionDecision, deviceID: UUID) async
}

/// A request to start a session: the params of `sessions.start`, or the Forge's in-process start.
public struct SessionStart: Sendable {
    public var projectID: String
    public var kind: SessionKind
    public var taskID: String?
    public var mode: SessionMode?
    public var title: String?
    public var message: String?
    public var attachments: [UploadRef] = []         // project sessions: files of the first message; [] otherwise
    public var permissionMode: PermissionMode?
    public var model: String?
    public var deviceID: UUID                        // requesting device; this Main's id for the Forge
    public var bundleID: String?                     // bundle sessions, and the task sessions a bundle starts
    public var regeneration: RegenerationContext?    // regeneration sessions (prompts.md)

    public init(projectID: String, kind: SessionKind, taskID: String? = nil, mode: SessionMode? = nil,
                title: String? = nil, message: String? = nil, attachments: [UploadRef] = [],
                permissionMode: PermissionMode? = nil, model: String? = nil, deviceID: UUID,
                bundleID: String? = nil, regeneration: RegenerationContext? = nil) {
        self.projectID = projectID
        self.kind = kind
        self.taskID = taskID
        self.mode = mode
        self.title = title
        self.message = message
        self.attachments = attachments
        self.permissionMode = permissionMode
        self.model = model
        self.deviceID = deviceID
        self.bundleID = bundleID
        self.regeneration = regeneration
    }
}

/// The `sessions` service of the host (docs/claude/cli.md §5): runs every Claude session of this Main as a `claude`
/// process, turns its output into session events and keeps the live statuses.
public actor SessionService: HostMethodHandler {
    private let host: any SessionHost
    private var running = false
    private var broker = PermissionBroker()
    /// The sessions of the projects loaded so far: project id, then session id.
    private var projects: [String: [UUID: Session]] = [:]
    /// The process lifecycle operations of each session (deliveries, stops, restarts, deletion), one at a time.
    private var lifecycles: [UUID: Task<Void, Never>] = [:]
    private var nextGeneration = 0

    public init(host: any SessionHost) {
        self.host = host
    }

    // MARK: - Host lifecycle (services/host.md §3)

    /// start() step 6: marks the service running.
    public func start() {
        running = true
    }

    /// stop() step 4: terminates every process, waits.
    public func stopAll() async {
        running = false
        let keys = projects.flatMap { projectID, sessions in sessions.keys.map { (projectID, $0) } }
        await terminateAll(keys)
        projects.removeAll()
        lifecycles.removeAll()
    }

    /// Project removed or moved away (called per sub project too): terminates its processes in parallel and forgets its
    /// cached sessions.
    public func stopAll(projectID: String) async {
        let keys = (projects[projectID] ?? [:]).keys.map { (projectID, $0) }
        await terminateAll(keys)
        for (_, sessionID) in keys {
            lifecycles[sessionID] = nil
        }
        projects[projectID] = nil
    }

    // MARK: - sessions.* methods

    public func start(_ request: SessionStart) async throws -> SessionInfo {
        do {
            return try await startSession(request, overWire: false)
        } catch {
            throw Self.protocolError(error)
        }
    }

    public func history(projectID: String, sessionID: UUID, before: Int?, limit: Int?) async throws
        -> SessionsHistoryResult {
        let archive = try await host.sessionArchive(projectID)
        let limit = min(max(limit ?? 1_000, 1), 5_000)
        return try await archive.history(sessionID, before: before, limit: limit)
    }

    public func send(projectID: String, sessionID: UUID, text: String, attachments: [UploadRef],
                     deviceID: UUID) async throws {
        // 1. Checks.
        let session = try await session(projectID, sessionID)
        try await host.checkWritable(projectID)
        guard !text.isEmpty || !attachments.isEmpty else {
            throw ProtocolError(.badRequest, "The message is empty.")
        }
        if session.process == nil {
            _ = try await preflight()
        }
        let archive = try await host.sessionArchive(projectID)
        let claimed = attachments.isEmpty ? [] : try await host.uploads.claim(attachments, projectID: projectID)

        try await serialized(session) {
            // 2. The files, then 4. the user event.
            var stored: [TaskAttachment] = []
            var moved: [(upload: ClaimedUpload, url: URL)] = []
            let event: SessionEvent
            do {
                for upload in claimed {
                    let attachment = try await archive.saveAttachment(fileAt: upload.url, originalName: upload.fileName,
                                                                      to: sessionID)
                    stored.append(attachment)
                    moved.append((upload, archive.attachmentURL(sessionID, file: attachment.file)))
                }
                event = try await archive.append(Self.event(.user, text: text,
                                                            attachments: stored.isEmpty ? nil : stored,
                                                            deviceID: deviceID),
                                                 to: sessionID)
            } catch {
                Self.moveBack(moved)
                if !claimed.isEmpty {
                    await self.host.uploads.release(claimed)
                }
                throw error
            }
            if !claimed.isEmpty {
                await self.host.uploads.finish(claimed)
            }
            await self.host.sessionEvent(projectID: projectID, sessionID: sessionID, event: event)
            await self.writeFile(session) { _ in }
            // 3. The CLI text, then 5. the delivery.
            try await self.deliver(Self.cliText(text, attachments: stored, archive: archive, sessionID: sessionID),
                                   to: session, firstStart: nil)
        }
    }

    /// sessions.readAttachment: a range of a file of SessionArchive.attachmentURL (5.4).
    public func readAttachment(projectID: String, sessionID: UUID, fileName: String, offset: Int?,
                               length: Int?) async throws -> AttachmentsReadResult {
        guard !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != ".." else {
            throw ProtocolError(.badRequest, "invalid attachment name")
        }
        let archive = try await host.sessionArchive(projectID)
        let url = archive.attachmentURL(sessionID, file: fileName)
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ProtocolError(.notFound, "No attachment \(fileName) in this session.")
        }
        let size = Int(info.st_size)
        let start = offset ?? 0
        guard start >= 0, start <= size else {
            throw ProtocolError(.badRequest, "Invalid offset \(start) for \(fileName).")
        }
        let requested = length ?? MethodLimits.maxChunkSize
        guard requested >= 1 else {
            throw ProtocolError(.badRequest, "Invalid length.")
        }
        let count = min(min(requested, MethodLimits.maxChunkSize), size - start)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            let data = count > 0 ? try handle.read(upToCount: count) ?? Data() : Data()
            return AttachmentsReadResult(data: data, size: size,
                                         mimeType: AttachmentNaming.mimeType(forFileName: fileName))
        } catch {
            throw ProtocolError(.internal, "\(fileName): \(error.localizedDescription)")
        }
    }

    public func interrupt(projectID: String, sessionID: UUID) async throws {
        let session = try await session(projectID, sessionID)
        guard let live = session.process, live.stopReason == nil,
              [.starting, .running, .waitingPermission].contains(session.status)
        else { return }
        do {
            try live.process.send(.interrupt(requestID: UUID().uuidString.lowercased()))
            live.interrupted = true
            Log.host.info("Interrupted the turn of session \(sessionID.uuidString, privacy: .public)")
        } catch {
            Log.host.error("Could not write the interrupt of session \(sessionID.uuidString, privacy: .public): \(String(describing: error))")
        }
    }

    public func stop(projectID: String, sessionID: UUID) async throws {
        let session = try await session(projectID, sessionID)
        try await serialized(session) {
            guard let live = session.process else { return }
            let duringTurn = [.starting, .running, .waitingPermission].contains(session.status)
            await self.terminate(session, live, reason: .stop, duringTurn: duringTurn)
        }
    }

    public func respond(projectID: String, sessionID: UUID, requestID: String, decision: PermissionDecision,
                        message: String?, device: DeviceInfo) async throws {
        let session = try await session(projectID, sessionID)
        try await host.checkWritable(projectID)
        // Only the Main records allowAll (4.4).
        if decision == .allowAll {
            throw ProtocolError(.badRequest, "Use sessions.update to allow all tools.")
        }
        let request = try broker.take(sessionID: sessionID, requestID: requestID)
        if let live = session.process {
            let answer = PermissionBroker.answer(to: request, decision: decision, message: message,
                                                 deviceName: device.name)
            do {
                try live.process.send(.permission(answer: answer))
            } catch {
                Log.host.error("Could not write a permission answer of session \(sessionID.uuidString, privacy: .public): \(String(describing: error))")
            }
        }
        await resolved(session, requestID: requestID, decision: decision, deviceID: device.id)
        if session.status == .waitingPermission, broker.pending(sessionID: sessionID).isEmpty {
            setStatus(.running, session)
        }
        await changed(session)
    }

    public func update(projectID: String, sessionID: UUID, patch: SessionPatch) async throws -> SessionInfo {
        let session = try await session(projectID, sessionID)
        try await host.checkWritable(projectID)
        let title = try patch.title.map(Self.validTitle)
        let archive = try await host.sessionArchive(projectID)
        let previous = session.file
        let model = patch.model
        let permissionMode = patch.permissionMode
        let allowsAllTools = patch.allowsAllTools
        session.file = try await archive.update(sessionID) { file in
            if let title {
                file.title = title
            }
            if let permissionMode {
                file.permissionMode = permissionMode
            }
            if let allowsAllTools {
                file.allowsAllTools = allowsAllTools
            }
            if let model {
                file.model = model.isEmpty ? nil : model
            }
        }
        // Allow All Tools applies at once: the pending requests are answered after the file is saved (4.4).
        if session.file.allowsAllTools, !previous.allowsAllTools {
            await allowPending(session)
        }
        await changed(session)
        // A new permission mode or model applies at the next process start.
        if session.file.permissionMode != previous.permissionMode || session.file.model != previous.model,
           session.process != nil {
            session.restartPending = true
            if session.status == .idle {
                scheduleRestart(session)
            }
        }
        return info(session)
    }

    public func delete(projectID: String, sessionID: UUID) async throws {
        let session = try await session(projectID, sessionID)
        try await host.checkWritable(projectID)
        let archive = try await host.sessionArchive(projectID)
        try await serialized(session) {
            if let live = session.process {
                await self.terminate(session, live, reason: .delete)
            }
            self.broker.reset(sessionID: sessionID)
            do {
                try await archive.delete(sessionID)
            } catch DataError.notFound {
                // The files are gone already.
            }
            await self.host.skills.removePluginFolder(sessionID: sessionID)
            session.statusTimer?.cancel()
            self.projects[projectID]?[sessionID] = nil
            Log.host.info("Deleted session \(sessionID.uuidString, privacy: .public)")
            await self.host.sessionRemoved(projectID: projectID, sessionID: sessionID)
        }
        lifecycles[sessionID] = nil
    }

    // MARK: - Other areas

    /// projects.snapshot, Forge: the project's sessions, newest `updated` first.
    public func sessions(projectID: String) async throws -> [SessionInfo] {
        try await sessions(of: projectID).values.map { info($0) }.sorted { $0.updated > $1.updated }
    }

    /// Migration precondition: a session of the project has a process.
    public func hasProcess(projectID: String) -> Bool {
        projects[projectID]?.values.contains { $0.process != nil } ?? false
    }

    /// Self-update: a session is starting, running or waitingPermission.
    public func isRunningTurn() -> Bool {
        projects.values.contains { sessions in
            sessions.values.contains { [.starting, .running, .waitingPermission].contains($0.status) }
        }
    }

    // MARK: - HostMethodHandler

    public func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .sessionsStart:
                let request = try Self.decode(SessionsStartParams.self, params, method)
                let start = SessionStart(projectID: request.projectID, kind: request.kind, taskID: request.taskID,
                                         mode: request.mode, title: request.title, message: request.message,
                                         attachments: request.attachments ?? [],
                                         permissionMode: request.permissionMode, model: request.model,
                                         deviceID: context.device.id, bundleID: nil, regeneration: nil)
                return try WireCoding.encodeJSON(try await startSession(start, overWire: true))
            case .sessionsHistory:
                let request = try Self.decode(SessionsHistoryParams.self, params, method)
                return try WireCoding.encodeJSON(try await history(projectID: request.projectID,
                                                                   sessionID: request.sessionID,
                                                                   before: request.before, limit: request.limit))
            case .sessionsReadAttachment:
                let request = try Self.decode(SessionsReadAttachmentParams.self, params, method)
                return try WireCoding.encodeJSON(try await readAttachment(projectID: request.projectID,
                                                                          sessionID: request.sessionID,
                                                                          fileName: request.fileName,
                                                                          offset: request.offset,
                                                                          length: request.length))
            case .sessionsSend:
                let request = try Self.decode(SessionsSendParams.self, params, method)
                try await send(projectID: request.projectID, sessionID: request.sessionID, text: request.text,
                               attachments: request.attachments, deviceID: context.device.id)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .sessionsInterrupt:
                let request = try Self.decode(SessionsInterruptParams.self, params, method)
                try await interrupt(projectID: request.projectID, sessionID: request.sessionID)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .sessionsStop:
                let request = try Self.decode(SessionsStopParams.self, params, method)
                try await stop(projectID: request.projectID, sessionID: request.sessionID)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .sessionsRespond:
                let request = try Self.decode(SessionsRespondParams.self, params, method)
                try await respond(projectID: request.projectID, sessionID: request.sessionID,
                                  requestID: request.requestID, decision: request.decision, message: request.message,
                                  device: context.device)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .sessionsUpdate:
                let request = try Self.decode(SessionsUpdateParams.self, params, method)
                return try WireCoding.encodeJSON(try await update(projectID: request.projectID,
                                                                  sessionID: request.sessionID, patch: request.patch))
            case .sessionsDelete:
                let request = try Self.decode(SessionsDeleteParams.self, params, method)
                try await delete(projectID: request.projectID, sessionID: request.sessionID)
                return try WireCoding.encodeJSON(EmptyPayload())
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw Self.protocolError(error)
        }
    }

    // MARK: - 5.2 Starting a session

    private func startSession(_ request: SessionStart, overWire: Bool) async throws -> SessionInfo {
        let projectID = request.projectID
        // 1. Hosted and writable.
        let project = try await host.claudeProject(projectID)
        try await host.checkWritable(projectID)
        // 2. Over the wire, project and task sessions only: the Forge starts feedback and regeneration sessions, and
        // BundleService bundle sessions and the task sessions of a bundle, in process.
        if overWire, request.kind == .bundle {
            throw ProtocolError(.badRequest, "Bundle sessions are started with bundles.start.")
        }
        if overWire, request.kind != .project, request.kind != .task {
            throw ProtocolError(.badRequest, "Only the Forge starts feedback and regeneration sessions.")
        }
        // 3 to 5. The kind's fields.
        var task: ClaudeTaskContext?
        var bundle: ClaudeBundleContext?
        switch request.kind {
        case .project:
            guard request.taskID == nil, request.mode == nil else {
                throw ProtocolError(.badRequest, "A project session has no task and no mode.")
            }
        case .task:
            guard let taskID = request.taskID, let mode = request.mode else {
                throw ProtocolError(.badRequest, "A task session needs a task and a mode.")
            }
            task = try await existingTask(projectID: projectID, taskID: taskID)
            if mode == .custom, (request.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ProtocolError(.badRequest, "Mode custom needs instructions.")
            }
        case .feedback:
            guard let taskID = request.taskID else {
                throw ProtocolError(.badRequest, "A feedback session needs a task.")
            }
            task = try await existingTask(projectID: projectID, taskID: taskID)
        case .regeneration:
            guard request.taskID == nil else {
                throw ProtocolError(.badRequest, "A regeneration session has no task.")
            }
        case .bundle:
            bundle = try await host.claudeBundle(projectID: projectID, bundleID: request.bundleID ?? "")
            guard request.taskID == nil, request.mode == nil else {
                throw ProtocolError(.badRequest, "A bundle session has no task and no mode.")
            }
        }
        if request.bundleID != nil, request.kind != .bundle, request.kind != .task {
            throw ProtocolError(.badRequest, "Only bundle and task sessions belong to a bundle.")
        }
        // 6. Title and model.
        let title = try request.title.map(Self.validTitle)
        var model: String?
        if let given = request.model {
            model = given.trimmingCharacters(in: .whitespacesAndNewlines)
            guard model?.isEmpty == false else {
                throw ProtocolError(.badRequest, "The model must not be empty.")
            }
        }
        // 7. Attachments: project sessions only.
        guard request.attachments.isEmpty || request.kind == .project else {
            throw ProtocolError(.badRequest, "Only the first message of a project session has attachments.")
        }
        // 8. A process starts when there is a first message.
        let hasFirstMessage = request.kind != .project
            || !(request.message ?? "").isEmpty || !request.attachments.isEmpty
        if hasFirstMessage {
            _ = try await preflight()
        }
        let archive = try await host.sessionArchive(projectID)
        let existing = try await sessions(of: projectID)
        // 9. Last, the uploads.
        let claimed = request.attachments.isEmpty
            ? [] : try await host.uploads.claim(request.attachments, projectID: projectID)

        // Creation.
        let settings = await host.settings()
        let id = UUID()
        let defaultTitle: String
        switch request.kind {
        case .project:
            defaultTitle = "Chat \(1 + existing.values.filter { $0.file.kind == .project }.count)"
        case .task:
            defaultTitle = "\(request.mode?.displayName ?? "") \(task?.id ?? request.taskID ?? "")"
        case .feedback:
            defaultTitle = "Feedback \(task?.id ?? request.taskID ?? "")"
        case .regeneration:
            defaultTitle = "Regeneration"
        case .bundle:
            defaultTitle = "Bundle \(bundle?.id ?? request.bundleID ?? "")"
        }
        let bundleID = bundle?.id ?? request.bundleID.map { BundleID($0)?.description ?? $0 }
        let permissionMode: PermissionMode
        if request.kind == .feedback || request.kind == .regeneration {
            permissionMode = .acceptEdits
        } else if Self.belongsToBundle(request.kind, bundleID: bundleID),
                  await isPublicRepositorySession(request.kind, project: project, settings: settings) {
            // Bundle sessions and the task sessions of a bundle that are sessions of 3.5 work without waiting for
            // the user.
            permissionMode = .acceptEdits
        } else {
            permissionMode = request.permissionMode ?? project.claude.permissionMode ?? settings.defaultPermissionMode
        }
        if model == nil {
            model = project.claude.model ?? (settings.defaultModel.isEmpty ? nil : settings.defaultModel)
        }
        let now = YAMLCoding.now()
        let file = SessionFile(id: id, kind: request.kind, taskID: task?.id ?? request.taskID, mode: request.mode,
                               bundleID: bundleID, title: title ?? defaultTitle, created: now, updated: now,
                               permissionMode: permissionMode, model: model, status: .stopped)

        // The first message's files are moved in before the session file is created.
        var stored: [TaskAttachment] = []
        var moved: [(upload: ClaimedUpload, url: URL)] = []
        do {
            for upload in claimed {
                let attachment = try await archive.saveAttachment(fileAt: upload.url, originalName: upload.fileName,
                                                                  to: id)
                stored.append(attachment)
                moved.append((upload, archive.attachmentURL(id, file: attachment.file)))
            }
            try await archive.create(file)
        } catch {
            Self.moveBack(moved)
            if !claimed.isEmpty {
                try? FileManager.default.removeItem(at: SessionFile.folder(projectRoot: archive.projectRoot)
                    .appendingPathComponent(SessionFile.fileStem(id), isDirectory: true))
            }
            if !claimed.isEmpty {
                await host.uploads.release(claimed)
            }
            throw error
        }
        if !claimed.isEmpty {
            await host.uploads.finish(claimed)
        }
        let session = Session(projectID: projectID, file: (try? await archive.load(id)) ?? file)
        projects[projectID, default: [:]][id] = session
        Log.host.info("Created session \(id.uuidString, privacy: .public) (\(request.kind.rawValue, privacy: .public)) in \(projectID, privacy: .public)")
        await changed(session)

        // The first message, delivered as by sessions.send.
        guard hasFirstMessage else { return info(session) }
        let text: String
        let attachments: [TaskAttachment]
        if request.kind == .project {
            text = request.message ?? ""
            attachments = stored
        } else {
            attachments = []
            let publicRepository = await isPublicRepositorySession(request.kind, project: project, settings: settings)
            let context = PromptContext(kind: request.kind, publicRepository: publicRepository, mainName: "",
                                        devices: [], project: project, task: task, mode: request.mode,
                                        instructions: request.message, regeneration: request.regeneration,
                                        bundle: bundle, workFolder: nil, branch: settings.forge.branch)
            text = Prompts.firstMessage(context) ?? ""
        }
        let firstStart = FirstStart(instructions: request.kind == .task ? request.message : nil,
                                    regeneration: request.regeneration)
        do {
            try await serialized(session) {
                await self.record(Self.event(.user, text: text, attachments: attachments.isEmpty ? nil : attachments,
                                             deviceID: request.deviceID),
                                  in: session)
                await self.writeFile(session) { _ in }
                try await self.deliver(Self.cliText(text, attachments: attachments, archive: archive, sessionID: id),
                                       to: session, firstStart: firstStart)
            }
        } catch {
            // The session is returned with status failed.
            Log.host.notice("Session \(id.uuidString, privacy: .public) could not start its process")
        }
        return info(session)
    }

    /// An existing task that is not broken (notFound, conflict).
    private func existingTask(projectID: String, taskID: String) async throws -> ClaudeTaskContext {
        let task = try await host.claudeTask(projectID: projectID, taskID: taskID)
        if let parseError = task.parseError {
            throw ProtocolError(.conflict, "The file is invalid: \(parseError)")
        }
        return task
    }

    // MARK: - 5.3 Starting the process

    /// What only the first start of a session knows (5.3 step 4).
    private struct FirstStart: Sendable {
        var instructions: String?
        var regeneration: RegenerationContext?
    }

    private struct LaunchFailure: Error {
        let message: String
    }

    /// Steps 1 and 2 of 5.3 without the token: the CLI path, and the MCP server running. Throws unavailable.
    private func preflight() async throws -> String {
        guard running else {
            throw ProtocolError(.unavailable, "Hephaestus tools are not available.")
        }
        let settings = await host.settings()
        guard let path = await ClaudeLocator.shared.current(configured: settings.claudeURL) else {
            throw ProtocolError(.unavailable, "Claude CLI not found. Set its path in Settings → Claude.")
        }
        do {
            try await host.mcp.start()
        } catch {
            throw ProtocolError(.unavailable, "Hephaestus tools are not available.")
        }
        return path
    }

    /// 5.3: starts the process of a session that has none, then writes `message` after the initialize request. A
    /// failure sets the status `failed` with an `error` event and throws `unavailable` with its message. Runs inside
    /// the session's lifecycle operation.
    private func launch(_ session: Session, message: String?, firstStart: FirstStart?) async throws {
        let sessionID = session.file.id
        let projectID = session.projectID
        var token: String?
        do {
            // 1, 2.
            let executable = try await preflight()
            let registered = await host.mcp.register(MCPSessionContext(sessionID: sessionID, projectID: projectID,
                                                                       kind: session.file.kind,
                                                                       taskID: session.file.taskID,
                                                                       bundleID: session.file.bundleID))
            token = registered
            // The project, read for steps 3 and 4.
            let project: ClaudeProjectContext
            do {
                project = try await host.claudeProject(projectID)
            } catch {
                throw LaunchFailure(message: "Could not start Claude: \(Self.protocolError(error).message)")
            }
            // 3. The plugin folder.
            let pluginFolder: URL
            do {
                pluginFolder = try await host.skills.buildPluginFolder(sessionID: sessionID, enabled: project.skills)
            } catch {
                throw LaunchFailure(message: "Could not start Claude: \(Self.protocolError(error).message)")
            }
            // 4. The system prompt, rendered from the data read now; whether the session is a session of 3.5. A task
            // session of a bundle works in its task's work folder.
            let settings = await host.settings()
            let kind = session.file.kind
            let publicRepository = await isPublicRepositorySession(kind, project: project, settings: settings)
            let promptFile = pluginFolder.deletingLastPathComponent()
                .appendingPathComponent("system-prompt.md", isDirectory: false)
            var workFolder: URL?
            do {
                if kind == .task, session.file.bundleID != nil, let taskID = session.file.taskID {
                    workFolder = try await host.bundleWorkFolder(projectID: projectID, taskID: taskID)
                }
                let context = try await promptContext(session, project: project, settings: settings,
                                                      publicRepository: publicRepository, workFolder: workFolder,
                                                      firstStart: firstStart)
                try AtomicFile.write(Data(Prompts.systemPrompt(context).utf8), to: promptFile)
            } catch {
                throw LaunchFailure(message: "Could not start Claude: \(Self.protocolError(error).message)")
            }
            // 5. The transcript is in the CLI's folder of the session's working directory.
            let workingDirectory = workFolder ?? project.root
            let loginEnvironment = await LoginEnvironment.shared.environment()
            let transcript = ClaudeLocator.transcriptURL(projectRoot: workingDirectory, sessionID: sessionID,
                                                         environment: loginEnvironment)
            let resume = FileManager.default.fileExists(atPath: transcript.path)
            // 6. The rules of 3.1: those of 3.5 for its sessions, which also get its environment.
            let allowedTools: [String]
            switch kind {
            case .feedback:
                allowedTools = ForgeSessionRules.allowedTools(.feedback, branch: settings.forge.branch)
            case .regeneration:
                allowedTools = ForgeSessionRules.allowedTools(.regeneration, branch: settings.forge.branch)
            case .bundle where publicRepository:
                allowedTools = ForgeSessionRules.allowedTools(.bundle, branch: settings.forge.branch)
            case .task where publicRepository && session.file.bundleID != nil:
                allowedTools = ForgeSessionRules.allowedTools(.feedback, branch: settings.forge.branch)
            case .project, .task, .bundle:
                allowedTools = ["mcp__hephaestus"]
            }
            let disallowedTools = publicRepository ? ForgeSessionRules.disallowedTools : ["Edit(**/.hephaestus/**)"]
            let options = ClaudeProcess.Options(
                executable: executable,
                sessionID: sessionID,
                resume: resume,
                permissionMode: session.file.permissionMode,
                model: session.file.model,
                mcpConfig: await host.mcp.configJSON(token: registered),
                allowedTools: allowedTools,
                disallowedTools: disallowedTools,
                pluginFolder: pluginFolder,
                systemPromptFile: promptFile,
                title: session.file.title,
                workingDirectory: workingDirectory,
                environment: publicRepository ? ForgeSessionRules.environment(loginEnvironment) : loginEnvironment)
            let process: ClaudeProcess
            do {
                process = try ClaudeProcess.launch(options)
            } catch {
                let code: Int32
                switch error as? ChildProcessError {
                case .spawnFailed(let value)?, .writeFailed(let value)?: code = value
                default: code = EIO
                }
                throw LaunchFailure(message: "Could not start Claude: \(String(cString: strerror(code)))")
            }
            // 7.
            broker.reset(sessionID: sessionID)
            nextGeneration += 1
            let live = LiveProcess(process: process, generation: nextGeneration, token: registered,
                                   publicRepository: publicRepository)
            session.process = live
            session.restartPending = false
            session.error = nil
            session.statusLine = nil
            setStatus(.starting, session)
            if let message {
                do {
                    try process.send(.user(text: message))
                    live.userMessageWritten = true
                } catch {
                    // The process is gone already: its end is handled when its output ends.
                    Log.host.error("Could not write the first message of session \(sessionID.uuidString, privacy: .public): \(String(describing: error))")
                }
            }
            Log.host.info("Started the process of session \(sessionID.uuidString, privacy: .public) (resume: \(resume, privacy: .public))")
            await changed(session)
            // 8. The messages in order, then the exit.
            live.task = Task {
                for await message in process.messages {
                    await self.received(message, live, session)
                }
                let termination = await process.waitForExit()
                await self.ended(live, session, termination)
            }
        } catch {
            if let token {
                await host.mcp.unregister(token: token)
            }
            let message = (error as? LaunchFailure)?.message ?? Self.protocolError(error).message
            Log.host.error("Session \(sessionID.uuidString, privacy: .public) could not start Claude")
            session.error = message
            session.statusLine = nil
            setStatus(.failed, session)
            await record(Self.event(.error, text: message), in: session)
            await writeFile(session) { $0.status = .failed }
            await changed(session)
            throw ProtocolError(.unavailable, message)
        }
    }

    /// The prompt context of 5.3 step 4. `workFolder`: the work folder of a task session of a bundle.
    private func promptContext(_ session: Session, project: ClaudeProjectContext, settings: DeviceSettings,
                               publicRepository: Bool, workFolder: URL?,
                               firstStart: FirstStart?) async throws -> PromptContext {
        let local = await host.localDevice()
        let devices = await host.devices().map { record in
            PromptDevice(name: record.name, platform: record.platform.rawValue, isMain: record.isMain,
                         isThisMac: record.id == local.id)
        }
        var task: ClaudeTaskContext?
        if session.file.kind == .task || session.file.kind == .feedback, let taskID = session.file.taskID {
            task = try await host.claudeTask(projectID: session.projectID, taskID: taskID)
        }
        var bundle: ClaudeBundleContext?
        if let bundleID = session.file.bundleID, Self.belongsToBundle(session.file.kind, bundleID: bundleID) {
            bundle = try await host.claudeBundle(projectID: session.projectID, bundleID: bundleID)
            bundle?.maxParallel = settings.bundles.maxParallel
        }
        var instructions: String?
        if session.file.kind == .task {
            if let firstStart {
                instructions = firstStart.instructions
            } else {
                instructions = await firstUserInstructions(session)
            }
        }
        return PromptContext(kind: session.file.kind, publicRepository: publicRepository, mainName: local.name,
                             devices: devices, project: project, task: task, mode: session.file.mode,
                             instructions: instructions, regeneration: firstStart?.regeneration, bundle: bundle,
                             workFolder: workFolder, branch: settings.forge.branch)
    }

    /// A bundle session, or a task session of a bundle.
    private static func belongsToBundle(_ kind: SessionKind, bundleID: String?) -> Bool {
        bundleID != nil && (kind == .bundle || kind == .task)
    }

    /// The permission mode that sessions.update cannot change: that of feedback and regeneration sessions, and of
    /// the bundle sessions and task sessions of a bundle that are sessions of 3.5 (5.2), as read now.
    /// A session of 3.5, which works in the public repository: a feedback or regeneration session, or, while the
    /// setting forge.enabled is true, a session whose project, or an ancestor reached through claudeProject(_:) of each
    /// parent, is forge.sourceProjectID, or one of whose ancestors cannot be read (claudeProject(_:) throws, which ends
    /// the walk). A parent already visited (a cycle) ends the walk with false.
    private func isPublicRepositorySession(_ kind: SessionKind, project: ClaudeProjectContext,
                                           settings: DeviceSettings) async -> Bool {
        if kind == .feedback || kind == .regeneration {
            return true
        }
        guard settings.forge.enabled else { return false }
        let source = settings.forge.sourceProjectID
        var current = project
        var visited: Set<String> = [current.id]
        while current.id != source {
            guard let parent = current.parent else { return false }
            if parent.id == source {
                return true
            }
            guard visited.insert(parent.id).inserted else { return false }
            do {
                current = try await host.claudeProject(parent.id)
            } catch {
                return true
            }
        }
        return true
    }

    /// The text after the first blank line of the session's first `user` event; nil when there is none.
    private func firstUserInstructions(_ session: Session) async -> String? {
        guard let archive = try? await host.sessionArchive(session.projectID) else { return nil }
        var first = (try? await archive.history(session.file.id, before: 1, limit: 1))?.events
            .first { $0.type == .user }
        if first == nil {
            first = (try? await archive.history(session.file.id, before: nil, limit: nil))?.events
                .first { $0.type == .user }
        }
        guard let text = first?.text, let blank = text.range(of: "\n\n") else { return nil }
        return String(text[blank.upperBound...])
    }

    // MARK: - 5.4 Delivery

    /// Step 5 of 5.4, inside the session's lifecycle operation: with a process, the user message is written; without
    /// one, the process starts with it. When the write fails, the process is terminated and a new one is started with
    /// the message.
    private func deliver(_ text: String, to session: Session, firstStart: FirstStart?) async throws {
        // A process that is ending (an initialize error) ends before a new one starts.
        if let live = session.process, live.stopReason != nil {
            await live.process.terminate()
            await live.task?.value
        }
        guard let live = session.process else {
            try await launch(session, message: text, firstStart: firstStart)
            return
        }
        do {
            try live.process.send(.user(text: text))
        } catch {
            Log.host.error("Could not write a message of session \(session.file.id.uuidString, privacy: .public): \(String(describing: error))")
            await terminate(session, live, reason: .writeFailure)
            try await launch(session, message: text, firstStart: nil)
            return
        }
        live.userMessageWritten = true
        session.statusLine = nil
        if session.status == .idle {
            setStatus(.running, session)
        }
        await changed(session)
    }

    /// The text sent to the CLI: the message, then the absolute paths of its files.
    private static func cliText(_ text: String, attachments: [TaskAttachment], archive: SessionArchive,
                                sessionID: UUID) -> String {
        guard !attachments.isEmpty else { return text }
        let lines = attachments.map { "- " + archive.attachmentURL(sessionID, file: $0.file).path }
        return (text.isEmpty ? "" : text + "\n\n") + "Attached files:\n" + lines.joined(separator: "\n")
    }

    /// Files already moved into a session go back to their uploads; a file that cannot be moved back is deleted.
    private static func moveBack(_ moved: [(upload: ClaimedUpload, url: URL)]) {
        for entry in moved {
            do {
                try FileManager.default.moveItem(at: entry.url, to: entry.upload.url)
            } catch {
                // The error's description names the file: only its domain and code are logged.
                let nsError = error as NSError
                Log.host.error("Could not move the file of upload \(entry.upload.uploadID.uuidString, privacy: .public) back: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - 3.3 The messages of a process

    private func received(_ message: CLIMessage, _ live: LiveProcess, _ session: Session) async {
        guard session.process === live else { return }
        let sessionID = session.file.id
        let projectID = session.projectID
        switch message {
        case .controlResponse(let requestID, let error):
            if requestID == "init" {
                if let error {
                    // The process is terminated; its end sets `failed`.
                    if live.stopReason == nil {
                        live.stopReason = .initializeError
                        live.initializeError = error
                    }
                    let process = live.process
                    Task { await process.terminate() }
                } else if session.status == .starting {
                    setStatus(live.userMessageWritten ? .running : .idle, session)
                    await changed(session)
                    becameIdle(session)
                }
            } else if let error {
                Log.host.error("The CLI of session \(sessionID.uuidString, privacy: .public) refused request \(requestID, privacy: .public): \(error)")
            }
        case .permissionRequest(var request):
            // A session of 3.5 gets no permission suggestion (4.1): its "Always allow" keeps nothing.
            if live.publicRepository {
                request.suggestions = "[]"
            }
            let started = turnStarted(session)
            if session.file.allowsAllTools {
                // Allow All Tools (4.4): answered at once, never pending; the status stays running.
                await record(SessionEvent(id: UUID().uuidString, at: Date(), type: .permission, input: request.input,
                                          requestID: request.requestID, toolName: request.toolName,
                                          description: request.description, suggestions: request.suggestions,
                                          blockedPath: request.blockedPath),
                             in: session)
                await allow(request, in: session, live: live)
                if started {
                    await changed(session)
                }
                return
            }
            broker.add(sessionID: sessionID, request: request)
            setStatus(.waitingPermission, session)
            await host.permissionRequested(projectID: projectID, sessionID: sessionID, request: request)
            await record(SessionEvent(id: UUID().uuidString, at: Date(), type: .permission, input: request.input,
                                      requestID: request.requestID, toolName: request.toolName,
                                      description: request.description, suggestions: request.suggestions,
                                      blockedPath: request.blockedPath),
                         in: session)
            await changed(session)
        case .unsupportedControlRequest(let requestID):
            do {
                try live.process.send(.refuse(requestID: requestID))
            } catch {
                Log.host.error("Could not refuse a request of session \(sessionID.uuidString, privacy: .public): \(String(describing: error))")
            }
        case .controlCancel(let requestID):
            guard (try? broker.take(sessionID: sessionID, requestID: requestID)) != nil else { return }
            await resolved(session, requestID: requestID, decision: .deny, deviceID: await host.localDevice().id)
            if session.status == .waitingPermission, broker.pending(sessionID: sessionID).isEmpty {
                setStatus(.running, session)
            }
            await changed(session)
        case .initialized(let initInfo):
            let started = turnStarted(session)
            if !live.initialized || live.hephaestusStatus != initInfo.hephaestusStatus {
                live.initialized = true
                live.hephaestusStatus = initInfo.hephaestusStatus
                let text = "Claude Code \(initInfo.version ?? "") · \(initInfo.model ?? "") · "
                    + "\(initInfo.permissionMode ?? "") mode · \(initInfo.toolCount) tools · "
                    + "Hephaestus tools \(initInfo.hephaestusStatus ?? "missing")"
                await record(Self.event(.system, text: text), in: session)
            }
            if started {
                await changed(session)
            }
        case .statusLine(let text):
            session.statusLine = text
            await statusLineChanged(session)
        case .turnActivity:
            if turnStarted(session) {
                await changed(session)
            }
        case .delta(let messageID, let index, let kind, let text):
            if turnStarted(session) {
                await changed(session)
            }
            await host.sessionDelta(projectID: projectID, sessionID: sessionID, messageID: messageID, index: index,
                                    kind: kind, text: text)
        case .block(let messageID, let index, let block):
            if turnStarted(session) {
                await changed(session)
            }
            switch block {
            case .text(let text):
                guard !text.isEmpty else { return }
                await record(SessionEvent(id: UUID().uuidString, at: Date(), type: .assistant, text: text,
                                          messageID: messageID, index: index),
                             in: session)
            case .thinking(let text):
                guard !text.isEmpty else { return }
                await record(SessionEvent(id: UUID().uuidString, at: Date(), type: .thinking, text: text,
                                          messageID: messageID, index: index),
                             in: session)
            case .toolUse(let id, let name, let input):
                await record(SessionEvent(id: UUID().uuidString, at: Date(), type: .toolUse, messageID: messageID,
                                          index: index, toolUseID: id, name: name, input: input),
                             in: session)
            }
        case .toolResult(let toolUseID, let text, let isError):
            if turnStarted(session) {
                await changed(session)
            }
            await record(SessionEvent(id: UUID().uuidString, at: Date(), type: .toolResult, text: text,
                                      toolUseID: toolUseID, isError: isError),
                         in: session)
        case .result(let result):
            await cancelPending(session)
            if live.interrupted, result.isError {
                await record(Self.event(.system, text: "Interrupted"), in: session)
                await record(Self.resultEvent(result, isError: false), in: session)
            } else {
                if let errorText = result.errorText {
                    await record(Self.event(.error, text: errorText), in: session)
                }
                await record(Self.resultEvent(result, isError: result.isError), in: session)
            }
            live.interrupted = false
            await writeFile(session) { _ in }
            guard session.process === live else { return }
            setStatus(.idle, session)
            await changed(session)
            becameIdle(session)
        }
    }

    /// A turn message received in status `idle` first sets `running`: a queued message started its own turn. Returns
    /// whether the status changed.
    @discardableResult
    private func turnStarted(_ session: Session) -> Bool {
        guard session.status == .idle else { return false }
        setStatus(.running, session)
        return true
    }

    /// The status became `idle`: a pending restart runs now.
    private func becameIdle(_ session: Session) {
        if session.restartPending {
            scheduleRestart(session)
        }
    }

    // MARK: - 4.3 Permission resolution

    /// Records an answer or a cancellation: `permission.resolved`, then the `permissionDecision` event.
    private func resolved(_ session: Session, requestID: String, decision: PermissionDecision,
                          deviceID: UUID) async {
        await host.permissionResolved(projectID: session.projectID, sessionID: session.file.id, requestID: requestID,
                                      decision: decision, deviceID: deviceID)
        await record(SessionEvent(id: UUID().uuidString, at: Date(), type: .permissionDecision, deviceID: deviceID,
                                  requestID: requestID, decision: decision),
                     in: session)
    }

    /// Cancels every pending request of the session: nothing is written to the CLI; each is recorded as a `deny` of
    /// this Main.
    private func cancelPending(_ session: Session) async {
        let pending = broker.takeAll(sessionID: session.file.id)
        guard !pending.isEmpty else { return }
        let localID = await host.localDevice().id
        for request in pending {
            await resolved(session, requestID: request.requestID, decision: .deny, deviceID: localID)
        }
    }

    // MARK: - 4.4 Allow All Tools

    /// Answers a request with the allow answer and records it as allowAll of this Main.
    private func allow(_ request: PermissionRequest, in session: Session, live: LiveProcess?) async {
        let local = await host.localDevice()
        if let live {
            let answer = PermissionBroker.answer(to: request, decision: .allowAll, message: nil, deviceName: local.name)
            do {
                try live.process.send(.permission(answer: answer))
            } catch {
                Log.host.error("Could not write a permission answer of session \(session.file.id.uuidString, privacy: .public): \(String(describing: error))")
            }
        }
        await resolved(session, requestID: request.requestID, decision: .allowAll, deviceID: local.id)
    }

    /// Allow All Tools was turned on: every pending request, oldest first, is answered; the status becomes running.
    private func allowPending(_ session: Session) async {
        let pending = broker.takeAll(sessionID: session.file.id)
        for request in pending {
            await allow(request, in: session, live: session.process)
        }
        if session.status == .waitingPermission {
            setStatus(.running, session)
        }
    }

    // MARK: - 5.6 Stop, idle stop, restarts

    private enum StopReason {
        case stop, idleStop, restart, stopAll, delete, writeFailure, initializeError
    }

    /// Terminates the process (SIGTERM to its group, SIGKILL after 5 s) and returns once its end is handled.
    private func terminate(_ session: Session, _ live: LiveProcess, reason: StopReason, duringTurn: Bool = false) async {
        if live.stopReason == nil {
            live.stopReason = reason
            live.stopDuringTurn = duringTurn
        }
        await live.process.terminate()
        await live.task?.value
    }

    /// A restart for an option change, as its own lifecycle operation: when the session is still idle, the process is
    /// terminated, then started without a message.
    private func scheduleRestart(_ session: Session) {
        Task {
            try? await self.serialized(session) {
                guard session.restartPending, let live = session.process else { return }
                guard session.status == .idle else { return }
                await self.terminate(session, live, reason: .restart)
                guard self.isCurrent(session) else { return }
                try await self.launch(session, message: nil, firstStart: nil)
            }
        }
    }

    /// The idle stop: in status `idle`, the process is terminated after `sessionIdleMinutes` without activity.
    private func startIdleTimer(_ session: Session) {
        session.idleTimer?.cancel()
        guard let live = session.process else { return }
        let process = live.process
        session.idleTimer = Task {
            let minutes = await self.host.settings().sessionIdleMinutes
            let limit = Duration.seconds(minutes * 60)
            while true {
                let elapsed = ContinuousClock.now - process.lastActivity
                if elapsed >= limit { break }
                do {
                    try await Task.sleep(for: limit - elapsed)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            try? await self.serialized(session) {
                guard session.process === live, session.status == .idle else { return }
                Log.host.info("Stopping idle session \(session.file.id.uuidString, privacy: .public)")
                await self.terminate(session, live, reason: .idleStop)
            }
        }
    }

    /// Terminates the processes of these sessions in parallel and waits for them.
    private func terminateAll(_ keys: [(String, UUID)]) async {
        await withTaskGroup(of: Void.self) { group in
            for (projectID, sessionID) in keys {
                group.addTask {
                    await self.terminateForShutdown(projectID: projectID, sessionID: sessionID)
                }
            }
        }
    }

    private func terminateForShutdown(projectID: String, sessionID: UUID) async {
        guard let session = projects[projectID]?[sessionID], session.process != nil else { return }
        try? await serialized(session) {
            guard let live = session.process else { return }
            await self.terminate(session, live, reason: .stopAll)
        }
    }

    // MARK: - 5.7 The end of a process

    private func ended(_ live: LiveProcess, _ session: Session, _ termination: ChildTermination) async {
        guard session.process === live else { return }
        let sessionID = session.file.id
        await cancelPending(session)
        await host.mcp.unregister(token: live.token)
        session.statusLine = nil
        live.interrupted = false
        if live.stopReason == .stop, live.stopDuringTurn {
            await record(Self.event(.system, text: "Stopped"), in: session)
        }
        let status: SessionStatus
        var errorText: String?
        if let error = live.initializeError {
            status = .failed
            errorText = "Claude could not start: \(error)"
        } else if live.stopReason != nil {
            status = .stopped
        } else {
            let tail = live.process.standardErrorTail
            let details = tail.isEmpty ? "" : "\n\n" + tail
            switch termination {
            case .exited(0):
                status = .stopped
            case .exited(let code):
                status = .failed
                errorText = "Claude exited with code \(code)." + details
            case .signaled(let signal):
                status = .failed
                errorText = "Claude was terminated by signal \(signal)." + details
            }
        }
        session.process = nil
        session.restartPending = false
        session.error = errorText
        setStatus(status, session)
        if let errorText {
            await record(Self.event(.error, text: errorText), in: session)
        }
        Log.host.info("The process of session \(sessionID.uuidString, privacy: .public) ended: \(status.rawValue, privacy: .public)")
        await writeFile(session) { $0.status = status }
        await changed(session)
    }

    // MARK: - Statuses and events

    /// Sets the status; the idle timer runs exactly while the status is `idle`.
    private func setStatus(_ status: SessionStatus, _ session: Session) {
        session.status = status
        if status == .idle {
            startIdleTimer(session)
        } else {
            session.idleTimer?.cancel()
            session.idleTimer = nil
        }
    }

    /// `session.changed` with the session as it is now.
    private func changed(_ session: Session) async {
        guard isCurrent(session) else { return }
        await host.sessionChanged(projectID: session.projectID, session: info(session))
    }

    /// Status line changes: at most one `session.changed` per second per session, the latest value sent at the end of
    /// the second.
    private func statusLineChanged(_ session: Session) async {
        guard session.statusTimer == nil else { return }
        if let last = session.lastStatusLine, ContinuousClock.now - last < .seconds(1) {
            let delay = Duration.seconds(1) - (ContinuousClock.now - last)
            session.statusTimer = Task {
                try? await Task.sleep(for: delay)
                session.statusTimer = nil
                session.lastStatusLine = ContinuousClock.now
                await self.changed(session)
            }
            return
        }
        session.lastStatusLine = ContinuousClock.now
        await changed(session)
    }

    /// Appends the event and sends the event as stored; when the append fails (the archive logs it), the event as
    /// built is sent and the session goes on.
    private func record(_ event: SessionEvent, in session: Session) async {
        var stored = event
        do {
            let archive = try await host.sessionArchive(session.projectID)
            stored = try await archive.append(event, to: session.file.id)
        } catch {
            // The archive logs a failed append as a fault.
        }
        await host.sessionEvent(projectID: session.projectID, sessionID: session.file.id, event: stored)
    }

    /// A read-modify-write of the session file; the cached file follows. A failure is logged.
    private func writeFile(_ session: Session, _ change: @escaping @Sendable (inout SessionFile) -> Void) async {
        do {
            let archive = try await host.sessionArchive(session.projectID)
            session.file = try await archive.update(session.file.id) { change(&$0) }
        } catch {
            Log.host.error("Could not write the file of session \(session.file.id.uuidString, privacy: .public): \(Self.protocolError(error).message)")
        }
    }

    private func info(_ session: Session) -> SessionInfo {
        let file = session.file
        return SessionInfo(id: file.id, kind: file.kind, taskID: file.taskID, mode: file.mode,
                           bundleID: file.bundleID, title: file.title, created: file.created, updated: file.updated,
                           permissionMode: file.permissionMode, allowsAllTools: file.allowsAllTools,
                           model: file.model, status: session.status,
                           statusLine: session.statusLine,
                           error: session.status == .failed ? session.error : nil,
                           pendingPermissions: session.process == nil ? [] : broker.pending(sessionID: file.id))
    }

    private static func event(_ type: SessionEventType, text: String, attachments: [TaskAttachment]? = nil,
                              deviceID: UUID? = nil) -> SessionEvent {
        SessionEvent(id: UUID().uuidString, at: Date(), type: type, text: text, attachments: attachments,
                     deviceID: deviceID)
    }

    private static func resultEvent(_ result: ResultInfo, isError: Bool) -> SessionEvent {
        SessionEvent(id: UUID().uuidString, at: Date(), type: .result, isError: isError,
                     durationMS: result.durationMS, costUSD: result.costUSD, stopReason: result.stopReason)
    }

    // MARK: - Sessions

    /// The sessions of a hosted project, loaded on first use (SessionArchive.list).
    private func sessions(of projectID: String) async throws -> [UUID: Session] {
        let archive = try await host.sessionArchive(projectID)
        if let sessions = projects[projectID] {
            return sessions
        }
        let files = await archive.list()
        if let sessions = projects[projectID] {
            return sessions
        }
        var sessions: [UUID: Session] = [:]
        for file in files {
            sessions[file.id] = Session(projectID: projectID, file: file)
        }
        projects[projectID] = sessions
        return sessions
    }

    private func session(_ projectID: String, _ sessionID: UUID) async throws -> Session {
        guard let session = try await sessions(of: projectID)[sessionID] else {
            throw ProtocolError(.notFound, "session \(sessionID.uuidString) not found")
        }
        return session
    }

    /// The session is still the cached one (not deleted, its project not forgotten).
    private func isCurrent(_ session: Session) -> Bool {
        projects[session.projectID]?[session.file.id] === session
    }

    /// Runs `body` after the lifecycle operations of the session already requested, and before the next ones.
    private func serialized(_ session: Session, _ body: @escaping () async throws -> Void) async throws {
        let sessionID = session.file.id
        let previous = lifecycles[sessionID]
        let operation = Task {
            await previous?.value
            try await body()
        }
        lifecycles[sessionID] = Task {
            _ = try? await operation.value
        }
        try await operation.value
    }

    // MARK: - Helpers

    /// A title trimmed, not empty and on one line (badRequest).
    private static func validTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isNewline }) else {
            throw ProtocolError(.badRequest, "the title must not be empty and must be on one line")
        }
        return trimmed
    }

    /// ProtocolError as it is; a DataError mapped as the host maps it (services/host.md §6.9).
    private static func protocolError(_ error: any Error) -> ProtocolError {
        guard let dataError = error as? DataError else { return ProtocolError(error) }
        switch dataError {
        case .notFound(let message): return ProtocolError(.notFound, message)
        case .invalid(let message): return ProtocolError(.badRequest, message)
        case .refused(let message): return ProtocolError(.conflict, message)
        case .unreadable(let message): return ProtocolError(.unavailable, message)
        case .io(let message): return ProtocolError(.internal, message)
        }
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }

    // MARK: - State

    /// A session of a loaded project, confined to the actor.
    private final class Session {
        let projectID: String
        var file: SessionFile
        /// The live status while a process exists; the file's status otherwise.
        var status: SessionStatus
        var statusLine: String?
        var error: String?
        var process: LiveProcess?
        var restartPending = false
        var idleTimer: Task<Void, Never>?
        /// The throttle of status line changes.
        var lastStatusLine: ContinuousClock.Instant?
        var statusTimer: Task<Void, Never>?

        init(projectID: String, file: SessionFile) {
            self.projectID = projectID
            self.file = file
            status = file.status
        }
    }

    /// The process of a session, confined to the actor.
    private final class LiveProcess {
        let process: ClaudeProcess
        let generation: Int
        let token: String
        /// A session of 3.5, as found when the process started (5.3 step 4).
        let publicRepository: Bool
        /// Handles the messages in order, then the exit.
        var task: Task<Void, Never>?
        var userMessageWritten = false
        var interrupted = false
        /// Set when the app terminates the process.
        var stopReason: StopReason?
        var stopDuringTurn = false
        var initializeError: String?
        var initialized = false
        var hephaestusStatus: String?

        init(process: ClaudeProcess, generation: Int, token: String, publicRepository: Bool) {
            self.process = process
            self.generation = generation
            self.token = token
            self.publicRepository = publicRepository
        }
    }
}
#endif
