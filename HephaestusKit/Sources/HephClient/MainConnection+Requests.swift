import Foundation
import HephCore
import HephNet

/// The request API: one async function per protocol method the UI calls (docs/client/workspace.md, "Request API").
/// Each sends one request on the connection's peer and returns the decoded result; a connection that is not connected
/// throws `ProtocolError(.unavailable, "<name> is offline.")` and sends nothing. In a preview workspace,
/// `PreviewData.respond` answers instead of a peer.
extension MainConnection {
    /// The timeout of the requests that carry or return file content, or attach uploads.
    static let contentTimeout: Duration = .seconds(120)

    // MARK: - Mesh

    public func meshSnapshot() async throws -> MeshSnapshot {
        let snapshot = try await send(.meshSnapshot, EmptyPayload(), as: MeshSnapshot.self)
        workspace?.receiveSnapshot(snapshot, from: self)
        return snapshot
    }

    public func renameDevice(_ deviceID: UUID, to name: String) async throws -> DeviceRecord {
        let record = try await send(.meshRenameDevice, MeshRenameDeviceParams(deviceID: deviceID, name: name),
                                    as: DeviceRecord.self)
        workspace?.mergeRecords([record])
        return record
    }

    public func revokeDevice(_ deviceID: UUID) async throws {
        _ = try await send(.meshRevokeDevice, MeshRevokeDeviceParams(deviceID: deviceID), as: EmptyPayload.self)
    }

    public func setAddresses(_ addresses: [String]) async throws -> DeviceRecord {
        let record = try await send(.meshSetAddresses, MeshSetAddressesParams(addresses: addresses),
                                    as: DeviceRecord.self)
        workspace?.mergeRecords([record])
        return record
    }

    // MARK: - Pairing

    public func openPairing() async throws -> PairingOpenResult {
        try await send(.pairingOpen, EmptyPayload(), as: PairingOpenResult.self)
    }

    public func closePairing() async throws {
        _ = try await send(.pairingClose, EmptyPayload(), as: EmptyPayload.self)
    }

    // MARK: - Host

    /// Sets `hostInfo`.
    public func hostInfo() async throws -> HostInfoResult {
        let info = try await send(.hostInfo, EmptyPayload(), as: HostInfoResult.self)
        setHostInfo(info)
        return info
    }

    public func listDirectories(path: String) async throws -> HostListDirectoriesResult {
        try await send(.hostListDirectories, HostListDirectoriesParams(path: path), as: HostListDirectoriesResult.self)
    }

    // MARK: - Projects

    /// Replaces `projects`; the `projects.changed` events received meanwhile are applied after the result.
    public func listProjects() async throws -> [ProjectSummary] {
        projectsListsInFlight += 1
        do {
            let result = try await send(.projectsList, EmptyPayload(), as: ProjectsListResult.self)
            projectsListsInFlight -= 1
            workspace?.replaceProjects(result.projects, of: self)
            flushQueuedProjectsEvents()
            return result.projects
        } catch {
            projectsListsInFlight -= 1
            flushQueuedProjectsEvents()
            throw error
        }
    }

    public func projectSnapshot(projectID: String) async throws -> ProjectsSnapshotResult {
        try await send(.projectsSnapshot, ProjectsSnapshotParams(projectID: projectID), as: ProjectsSnapshotResult.self)
    }

    public func createProject(name: String, identifier: String, parentID: String? = nil, folderName: String? = nil,
                              description: String? = nil) async throws -> ProjectSummary {
        try await send(.projectsCreate,
                       ProjectsCreateParams(name: name, identifier: identifier, parentID: parentID,
                                            folderName: folderName, description: description),
                       as: ProjectSummary.self)
    }

    public func importProject(path: String, name: String? = nil, identifier: String? = nil) async throws
        -> ProjectSummary {
        try await send(.projectsImport, ProjectsImportParams(path: path, name: name, identifier: identifier),
                       as: ProjectSummary.self)
    }

    public func updateProject(projectID: String, patch: ProjectPatch) async throws -> Project {
        try await send(.projectsUpdate, ProjectsUpdateParams(projectID: projectID, patch: patch), as: Project.self)
    }

    public func removeProject(projectID: String, moveToTrash: Bool) async throws {
        _ = try await send(.projectsRemove, ProjectsRemoveParams(projectID: projectID, moveToTrash: moveToTrash),
                           as: EmptyPayload.self)
    }

    /// Returns the migration id.
    public func migrateProject(projectID: String, to targetDeviceID: UUID) async throws -> UUID {
        try await send(.projectsMigrate, ProjectsMigrateParams(projectID: projectID, targetDeviceID: targetDeviceID),
                       as: ProjectsMigrateResult.self).migrationID
    }

    // MARK: - Tasks

    public func createTask(projectID: String, name: String, description: String? = nil,
                           status: TaskStatus? = nil) async throws -> TaskItem {
        let task = try await send(.tasksCreate,
                                  TasksCreateParams(projectID: projectID, name: name, description: description,
                                                    status: status),
                                  as: TaskItem.self)
        insertIfAbsent(task, projectID: projectID)
        return task
    }

    public func updateTask(projectID: String, taskID: String, patch: TaskPatch) async throws -> TaskItem {
        let task = try await send(.tasksUpdate, TasksUpdateParams(projectID: projectID, taskID: taskID, patch: patch),
                                  as: TaskItem.self)
        insertIfAbsent(task, projectID: projectID)
        return task
    }

    public func deleteTask(projectID: String, taskID: String) async throws {
        _ = try await send(.tasksDelete, TasksDeleteParams(projectID: projectID, taskID: taskID),
                           as: EmptyPayload.self)
    }

    // MARK: - Uploads

    /// Returns the upload id.
    public func beginUpload(projectID: String, fileName: String, size: Int) async throws -> UUID {
        try await send(.uploadsBegin, UploadsBeginParams(projectID: projectID, fileName: fileName, size: size),
                       as: UploadsBeginResult.self).uploadID
    }

    public func uploadChunk(uploadID: UUID, offset: Int, data: Data) async throws {
        _ = try await send(.uploadsChunk, UploadsChunkParams(uploadID: uploadID, offset: offset, data: data),
                           as: EmptyPayload.self, timeout: Self.contentTimeout)
    }

    public func cancelUpload(uploadID: UUID) async throws {
        _ = try await send(.uploadsCancel, UploadsCancelParams(uploadID: uploadID), as: EmptyPayload.self)
    }

    // MARK: - Comments and attachments

    public func addComment(projectID: String, taskID: String, body: String,
                           attachments: [UploadRef] = []) async throws -> TaskItem {
        let task = try await send(.tasksAddComment,
                                  TasksAddCommentParams(projectID: projectID, taskID: taskID, body: body,
                                                        attachments: attachments),
                                  as: TaskItem.self, timeout: Self.contentTimeout)
        insertIfAbsent(task, projectID: projectID)
        return task
    }

    public func updateComment(projectID: String, taskID: String, commentID: UUID, body: String) async throws
        -> TaskItem {
        let task = try await send(.tasksUpdateComment,
                                  TasksUpdateCommentParams(projectID: projectID, taskID: taskID, commentID: commentID,
                                                           body: body),
                                  as: TaskItem.self)
        insertIfAbsent(task, projectID: projectID)
        return task
    }

    public func deleteComment(projectID: String, taskID: String, commentID: UUID) async throws -> TaskItem {
        let task = try await send(.tasksDeleteComment,
                                  TasksDeleteCommentParams(projectID: projectID, taskID: taskID, commentID: commentID),
                                  as: TaskItem.self)
        insertIfAbsent(task, projectID: projectID)
        return task
    }

    public func readAttachment(projectID: String, taskID: String, fileName: String, offset: Int? = nil,
                               length: Int? = nil) async throws -> AttachmentsReadResult {
        try await send(.attachmentsRead,
                       AttachmentsReadParams(projectID: projectID, taskID: taskID, fileName: fileName, offset: offset,
                                             length: length),
                       as: AttachmentsReadResult.self, timeout: Self.contentTimeout)
    }

    // MARK: - Bundles

    public func createBundle(projectID: String, name: String, taskIDs: [String]) async throws -> BundleItem {
        try await send(.bundlesCreate, BundlesCreateParams(projectID: projectID, name: name, taskIDs: taskIDs),
                       as: BundleItem.self)
    }

    public func updateBundle(projectID: String, bundleID: String, patch: BundlePatch) async throws -> BundleItem {
        try await send(.bundlesUpdate, BundlesUpdateParams(projectID: projectID, bundleID: bundleID, patch: patch),
                       as: BundleItem.self)
    }

    public func deleteBundle(projectID: String, bundleID: String) async throws {
        _ = try await send(.bundlesDelete, BundlesDeleteParams(projectID: projectID, bundleID: bundleID),
                           as: EmptyPayload.self)
    }

    public func startBundle(projectID: String, bundleID: String) async throws -> BundleItem {
        try await send(.bundlesStart, BundlesStartParams(projectID: projectID, bundleID: bundleID),
                       as: BundleItem.self)
    }

    public func stopBundle(projectID: String, bundleID: String) async throws -> BundleItem {
        try await send(.bundlesStop, BundlesStopParams(projectID: projectID, bundleID: bundleID),
                       as: BundleItem.self)
    }

    // MARK: - Files

    public func listFiles(projectID: String, path: String) async throws -> [FileEntry] {
        try await send(.filesList, FilesListParams(projectID: projectID, path: path), as: FilesListResult.self).entries
    }

    /// A whole read when `offset` and `length` are both nil.
    public func readFile(projectID: String, path: String, offset: Int? = nil, length: Int? = nil) async throws
        -> FilesReadResult {
        try await send(.filesRead, FilesReadParams(projectID: projectID, path: path, offset: offset, length: length),
                       as: FilesReadResult.self, timeout: Self.contentTimeout)
    }

    /// Returns the new revision.
    public func writeFile(projectID: String, path: String, data: Data, baseRevision: String? = nil) async throws
        -> String {
        try await send(.filesWrite,
                       FilesWriteParams(projectID: projectID, path: path, data: data, baseRevision: baseRevision),
                       as: FilesWriteResult.self, timeout: Self.contentTimeout).revision
    }

    public func createFile(projectID: String, path: String, isDirectory: Bool) async throws -> FileEntry {
        try await send(.filesCreate, FilesCreateParams(projectID: projectID, path: path, isDirectory: isDirectory),
                       as: FileEntry.self)
    }

    public func renameFile(projectID: String, from: String, to: String) async throws {
        _ = try await send(.filesRename, FilesRenameParams(projectID: projectID, from: from, to: to),
                           as: EmptyPayload.self)
    }

    public func deleteFile(projectID: String, path: String) async throws {
        _ = try await send(.filesDelete, FilesDeleteParams(projectID: projectID, path: path), as: EmptyPayload.self)
    }

    // MARK: - Web tabs

    public func openTab(projectID: String, url: String, title: String? = nil, locked: Bool? = nil) async throws
        -> WebTab {
        try await send(.tabsOpen, TabsOpenParams(projectID: projectID, url: url, title: title, locked: locked),
                       as: WebTab.self)
    }

    public func updateTab(projectID: String, tabID: UUID, patch: WebTabPatch) async throws -> WebTab {
        try await send(.tabsUpdate, TabsUpdateParams(projectID: projectID, tabID: tabID, patch: patch),
                       as: WebTab.self)
    }

    public func closeTab(projectID: String, tabID: UUID) async throws {
        _ = try await send(.tabsClose, TabsCloseParams(projectID: projectID, tabID: tabID), as: EmptyPayload.self)
    }

    public func moveTab(projectID: String, tabID: UUID, toIndex: Int) async throws {
        _ = try await send(.tabsMove, TabsMoveParams(projectID: projectID, tabID: tabID, toIndex: toIndex),
                           as: EmptyPayload.self)
    }

    // MARK: - Sessions

    public func startSession(projectID: String, kind: SessionKind, taskID: String? = nil, mode: SessionMode? = nil,
                             title: String? = nil, message: String? = nil, attachments: [UploadRef] = [],
                             permissionMode: PermissionMode? = nil, model: String? = nil) async throws
        -> SessionInfo {
        let params = SessionsStartParams(projectID: projectID, kind: kind, taskID: taskID, mode: mode, title: title,
                                         message: message, attachments: attachments.isEmpty ? nil : attachments,
                                         permissionMode: permissionMode, model: model)
        let session = try await send(.sessionsStart, params, as: SessionInfo.self, timeout: Self.contentTimeout)
        workspace?.existingStore(mainDeviceID: id, projectID: projectID)?.insertIfAbsent(session)
        return session
    }

    /// One page of the session's log: `events`, `firstIndex`, `total`.
    public func sessionHistory(projectID: String, sessionID: UUID, before: Int? = nil, limit: Int? = nil)
        async throws -> SessionsHistoryResult {
        try await send(.sessionsHistory,
                       SessionsHistoryParams(projectID: projectID, sessionID: sessionID, before: before, limit: limit),
                       as: SessionsHistoryResult.self)
    }

    public func readSessionAttachment(projectID: String, sessionID: UUID, fileName: String, offset: Int? = nil,
                                      length: Int? = nil) async throws -> AttachmentsReadResult {
        try await send(.sessionsReadAttachment,
                       SessionsReadAttachmentParams(projectID: projectID, sessionID: sessionID, fileName: fileName,
                                                    offset: offset, length: length),
                       as: AttachmentsReadResult.self, timeout: Self.contentTimeout)
    }

    public func sendMessage(projectID: String, sessionID: UUID, text: String,
                            attachments: [UploadRef] = []) async throws {
        _ = try await send(.sessionsSend,
                           SessionsSendParams(projectID: projectID, sessionID: sessionID, text: text,
                                              attachments: attachments),
                           as: EmptyPayload.self, timeout: Self.contentTimeout)
    }

    public func interruptSession(projectID: String, sessionID: UUID) async throws {
        _ = try await send(.sessionsInterrupt, SessionsInterruptParams(projectID: projectID, sessionID: sessionID),
                           as: EmptyPayload.self)
    }

    public func stopSession(projectID: String, sessionID: UUID) async throws {
        _ = try await send(.sessionsStop, SessionsStopParams(projectID: projectID, sessionID: sessionID),
                           as: EmptyPayload.self)
    }

    public func respondToPermission(projectID: String, sessionID: UUID, requestID: String,
                                    decision: PermissionDecision, message: String? = nil) async throws {
        _ = try await send(.sessionsRespond,
                           SessionsRespondParams(projectID: projectID, sessionID: sessionID, requestID: requestID,
                                                 decision: decision, message: message),
                           as: EmptyPayload.self)
    }

    public func updateSession(projectID: String, sessionID: UUID, patch: SessionPatch) async throws -> SessionInfo {
        let session = try await send(.sessionsUpdate,
                                     SessionsUpdateParams(projectID: projectID, sessionID: sessionID, patch: patch),
                                     as: SessionInfo.self)
        workspace?.existingStore(mainDeviceID: id, projectID: projectID)?.insertIfAbsent(session)
        return session
    }

    public func deleteSession(projectID: String, sessionID: UUID) async throws {
        _ = try await send(.sessionsDelete, SessionsDeleteParams(projectID: projectID, sessionID: sessionID),
                           as: EmptyPayload.self)
    }

    // MARK: - Runs

    public func startRun(projectID: String, name: String) async throws -> RunInfo {
        let run = try await send(.runsStart, RunsStartParams(projectID: projectID, name: name), as: RunInfo.self)
        workspace?.existingStore(mainDeviceID: id, projectID: projectID)?.insertIfAbsent(run)
        return run
    }

    public func stopRun(projectID: String, runID: UUID) async throws {
        _ = try await send(.runsStop, RunsStopParams(projectID: projectID, runID: runID), as: EmptyPayload.self)
    }

    public func runOutput(projectID: String, runID: UUID) async throws -> RunsOutputResult {
        try await send(.runsOutput, RunsOutputParams(projectID: projectID, runID: runID), as: RunsOutputResult.self)
    }

    // MARK: - Search

    public func search(query: String, scopes: [SearchScope]? = nil, projectID: String? = nil,
                       limit: Int? = nil) async throws -> [SearchResult] {
        try await send(.searchQuery,
                       SearchQueryParams(query: query, scopes: scopes, projectID: projectID, limit: limit),
                       as: SearchQueryResult.self).results
    }

    // MARK: - Skills

    /// Replaces `skills`; the `skills.changed` events received meanwhile are applied after the result.
    public func listSkills() async throws -> [SkillSummary] {
        skillsListsInFlight += 1
        do {
            let result = try await send(.skillsList, EmptyPayload(), as: SkillsListResult.self)
            skillsListsInFlight -= 1
            setSkills(result.skills)
            flushQueuedSkillsEvents()
            return result.skills
        } catch {
            skillsListsInFlight -= 1
            flushQueuedSkillsEvents()
            throw error
        }
    }

    public func createSkill(name: String, description: String) async throws -> SkillSummary {
        try await send(.skillsCreate, SkillsCreateParams(name: name, description: description),
                       as: SkillSummary.self)
    }

    public func skillFiles(name: String) async throws -> [SkillFile] {
        try await send(.skillsFiles, SkillsFilesParams(name: name), as: SkillsFilesResult.self).files
    }

    public func readSkillFile(name: String, path: String) async throws -> Data {
        try await send(.skillsReadFile, SkillsReadFileParams(name: name, path: path), as: SkillsReadFileResult.self,
                       timeout: Self.contentTimeout).data
    }

    public func writeSkillFile(name: String, path: String, data: Data) async throws {
        _ = try await send(.skillsWriteFile, SkillsWriteFileParams(name: name, path: path, data: data),
                           as: EmptyPayload.self, timeout: Self.contentTimeout)
    }

    public func deleteSkillFile(name: String, path: String) async throws {
        _ = try await send(.skillsDeleteFile, SkillsDeleteFileParams(name: name, path: path), as: EmptyPayload.self)
    }

    public func renameSkill(name: String, to newName: String) async throws -> SkillSummary {
        try await send(.skillsRename, SkillsRenameParams(name: name, newName: newName), as: SkillSummary.self)
    }

    public func deleteSkill(name: String) async throws {
        _ = try await send(.skillsDelete, SkillsDeleteParams(name: name), as: EmptyPayload.self)
    }

    // MARK: - Forge

    public func sendFeedback(screenshot: UploadRef? = nil, comment: String, context: FeedbackContext) async throws
        -> ForgeFeedbackResult {
        try await send(.forgeFeedback, ForgeFeedbackParams(screenshot: screenshot, comment: comment, context: context),
                       as: ForgeFeedbackResult.self, timeout: Self.contentTimeout)
    }

    public func forgeStatus() async throws -> ForgeState {
        try await send(.forgeStatus, EmptyPayload(), as: ForgeState.self)
    }

    public func regenerate() async throws {
        _ = try await send(.forgeRegenerate, EmptyPayload(), as: EmptyPayload.self)
    }

    public func retryForge(itemTaskID: String) async throws {
        _ = try await send(.forgeRetry, ForgeRetryParams(itemTaskID: itemTaskID), as: EmptyPayload.self)
    }

    // MARK: - Subscriptions (Workspace)

    func subscribeTopics(_ topics: [Topic]) async throws {
        _ = try await send(.subscribe, SubscribeParams(topics: topics.map(\.rawValue)), as: EmptyPayload.self)
    }

    func unsubscribeTopics(_ topics: [Topic]) async throws {
        _ = try await send(.unsubscribe, UnsubscribeParams(topics: topics.map(\.rawValue)), as: EmptyPayload.self)
    }

    // MARK: - Sending

    /// Sends one request: through `PreviewData.respond` in a preview workspace, else on the peer when connected.
    func send<R: Decodable & Sendable>(_ method: RPCMethod, _ params: some Encodable & Sendable, as resultType: R.Type,
                                       timeout: Duration? = nil) async throws -> R {
        if workspace?.isPreview == true {
            let paramsJSON: Data
            do {
                paramsJSON = try WireCoding.encodeJSON(params)
            } catch {
                throw ProtocolError(error)
            }
            let resultJSON = try PreviewData.respond(mainDeviceID: id, method: method.rawValue, params: paramsJSON)
            do {
                return try WireCoding.decodeJSON(R.self, from: resultJSON)
            } catch {
                throw ProtocolError(.internal, "Invalid response to \(method.rawValue).")
            }
        }
        guard isConnected, let peer else {
            throw ProtocolError(.unavailable, "\(name) is offline.")
        }
        return try await peer.request(method, params, as: R.self, timeout: timeout)
    }

    /// A task returned for a project whose store does not contain it yet is inserted into the store.
    private func insertIfAbsent(_ task: TaskItem, projectID: String) {
        workspace?.existingStore(mainDeviceID: id, projectID: projectID)?.insertIfAbsent(task)
    }
}
