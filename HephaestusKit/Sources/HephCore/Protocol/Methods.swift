import Foundation

// The methods of docs/protocol/methods.md: their names, callers, write flag, limits, params and results.

/// A method of the protocol; raw value = method name. (A type named `Method` would be ambiguous with
/// `ObjectiveC.Method` in every file that imports Foundation.)
public enum RPCMethod: String, CaseIterable, Sendable {
    case hello = "hello"
    case meshSnapshot = "mesh.snapshot"
    case meshSync = "mesh.sync"
    case meshRenameDevice = "mesh.renameDevice"
    case meshRevokeDevice = "mesh.revokeDevice"
    case meshRekey = "mesh.rekey"
    case meshSetAddresses = "mesh.setAddresses"
    case pairingOpen = "pairing.open"
    case pairingClose = "pairing.close"
    case hostInfo = "host.info"
    case hostListDirectories = "host.listDirectories"
    case subscribe = "subscribe"
    case unsubscribe = "unsubscribe"
    case projectsList = "projects.list"
    case projectsSnapshot = "projects.snapshot"
    case projectsCreate = "projects.create"
    case projectsImport = "projects.import"
    case projectsUpdate = "projects.update"
    case projectsRemove = "projects.remove"
    case projectsMigrate = "projects.migrate"
    case uploadsBegin = "uploads.begin"
    case uploadsChunk = "uploads.chunk"
    case uploadsCancel = "uploads.cancel"
    case tasksCreate = "tasks.create"
    case tasksUpdate = "tasks.update"
    case tasksDelete = "tasks.delete"
    case tasksAddComment = "tasks.addComment"
    case tasksUpdateComment = "tasks.updateComment"
    case tasksDeleteComment = "tasks.deleteComment"
    case attachmentsRead = "attachments.read"
    case bundlesCreate = "bundles.create"
    case bundlesUpdate = "bundles.update"
    case bundlesDelete = "bundles.delete"
    case bundlesStart = "bundles.start"
    case bundlesStop = "bundles.stop"
    case filesList = "files.list"
    case filesRead = "files.read"
    case filesWrite = "files.write"
    case filesCreate = "files.create"
    case filesRename = "files.rename"
    case filesDelete = "files.delete"
    case tabsOpen = "tabs.open"
    case tabsUpdate = "tabs.update"
    case tabsClose = "tabs.close"
    case tabsMove = "tabs.move"
    case sessionsStart = "sessions.start"
    case sessionsHistory = "sessions.history"
    case sessionsReadAttachment = "sessions.readAttachment"
    case sessionsSend = "sessions.send"
    case sessionsInterrupt = "sessions.interrupt"
    case sessionsStop = "sessions.stop"
    case sessionsRespond = "sessions.respond"
    case sessionsUpdate = "sessions.update"
    case sessionsDelete = "sessions.delete"
    case runsStart = "runs.start"
    case runsStop = "runs.stop"
    case runsOutput = "runs.output"
    case searchQuery = "search.query"
    case skillsList = "skills.list"
    case skillsCreate = "skills.create"
    case skillsFiles = "skills.files"
    case skillsReadFile = "skills.readFile"
    case skillsWriteFile = "skills.writeFile"
    case skillsDeleteFile = "skills.deleteFile"
    case skillsRename = "skills.rename"
    case skillsDelete = "skills.delete"
    case skillsManifest = "skills.manifest"
    case migrationBegin = "migration.begin"
    case migrationChunk = "migration.chunk"
    case migrationCommit = "migration.commit"
    case migrationAbort = "migration.abort"
    case migrationStatus = "migration.status"
    case forgeFeedback = "forge.feedback"
    case forgeStatus = "forge.status"
    case forgeRegenerate = "forge.regenerate"
    case forgeRetry = "forge.retry"

    /// Who may call the method (the Callers column).
    public var callers: MethodCallers {
        switch self {
        case .meshSync, .skillsManifest, .migrationBegin, .migrationChunk, .migrationCommit, .migrationAbort,
             .migrationStatus:
            return .mainPeers
        case .meshRekey:
            return .servingMain
        default:
            return .anyDevice
        }
    }

    /// The method changes a project (the W column): refused with `locked` while the project migrates.
    public var writesProject: Bool {
        switch self {
        case .projectsCreate, .projectsUpdate, .projectsRemove, .projectsMigrate,
             .tasksCreate, .tasksUpdate, .tasksDelete, .tasksAddComment, .tasksUpdateComment, .tasksDeleteComment,
             .bundlesCreate, .bundlesUpdate, .bundlesDelete, .bundlesStart, .bundlesStop,
             .filesWrite, .filesCreate, .filesRename, .filesDelete,
             .tabsOpen, .tabsUpdate, .tabsClose, .tabsMove,
             .sessionsStart, .sessionsSend, .sessionsRespond, .sessionsUpdate, .sessionsDelete,
             .runsStart:
            return true
        default:
            return false
        }
    }
}

public enum MethodCallers: Sendable {
    /// Served by Mains; any authenticated connection: remotes, peer links, the Main's own loopback connection.
    case anyDevice
    /// Served by Mains; peer links only (connections whose `hello` had `device.isMain == true`).
    case mainPeers
    /// Served by every device; the Main at the other end of a connection this device opened.
    case servingMain
}

public enum MethodLimits {
    /// 4 MiB: `uploads.chunk` data; the length of `attachments.read`, `sessions.readAttachment` and a ranged
    /// `files.read`.
    public static let maxChunkSize = 4_194_304
    /// 10 MiB: whole `files.read`, `files.write`, `skills.readFile`, `skills.writeFile`.
    public static let maxFileSize = 10_485_760
    /// 256 KiB: every chunk of a `migration.chunk` file except the last.
    public static let migrationChunkSize = 262_144
    /// `search.query` `limit`: default and maximum.
    public static let maxSearchResults = 200
}

// MARK: - Params and results

/// `hello`: the first request of every connection.
public struct HelloParams: Codable, Sendable, Hashable {
    public var device: DeviceInfo
    public var protocolVersion: Int

    public init(device: DeviceInfo, protocolVersion: Int) {
        self.device = device
        self.protocolVersion = protocolVersion
    }
}

/// `hello` result: the serving Main and its registry and presence report.
public struct HelloResult: Codable, Sendable, Hashable {
    public var device: DeviceInfo
    public var mesh: MeshSnapshot

    public init(device: DeviceInfo, mesh: MeshSnapshot) {
        self.device = device
        self.mesh = mesh
    }
}

/// `mesh.sync` params: the caller's whole registry and its direct presence entries.
public struct MeshSyncParams: Codable, Sendable, Hashable {
    public var devices: [DeviceRecord]
    public var presence: [Presence]

    public init(devices: [DeviceRecord], presence: [Presence]) {
        self.devices = devices
        self.presence = presence
    }
}

/// `mesh.sync` result: the callee's registry after the merge and its direct presence entries.
public struct MeshSyncResult: Codable, Sendable, Hashable {
    public var devices: [DeviceRecord]
    public var presence: [Presence]

    public init(devices: [DeviceRecord], presence: [Presence]) {
        self.devices = devices
        self.presence = presence
    }
}

/// `mesh.renameDevice` params.
public struct MeshRenameDeviceParams: Codable, Sendable, Hashable {
    public var deviceID: UUID
    public var name: String

    public init(deviceID: UUID, name: String) {
        self.deviceID = deviceID
        self.name = name
    }
}

/// `mesh.revokeDevice` params.
public struct MeshRevokeDeviceParams: Codable, Sendable, Hashable {
    public var deviceID: UUID

    public init(deviceID: UUID) {
        self.deviceID = deviceID
    }
}

/// `mesh.rekey` params: the new mesh key, 32 bytes.
public struct MeshRekeyParams: Codable, Sendable, Hashable {
    public var meshKey: Data

    public init(meshKey: Data) {
        self.meshKey = meshKey
    }
}

/// `mesh.setAddresses` params: the user-entered additional addresses.
public struct MeshSetAddressesParams: Codable, Sendable, Hashable {
    public var addresses: [String]

    public init(addresses: [String]) {
        self.addresses = addresses
    }
}

/// `pairing.open` result.
public struct PairingOpenResult: Codable, Sendable, Hashable {
    public var code: String
    public var expiresAt: Date
    public var port: Int

    public init(code: String, expiresAt: Date, port: Int) {
        self.code = code
        self.expiresAt = expiresAt
        self.port = port
    }
}

/// `host.info` result.
public struct HostInfoResult: Codable, Sendable, Hashable {
    public var device: DeviceInfo
    public var projectsFolder: String
    public var claudeAvailable: Bool
    public var claudePath: String
    public var gitAvailable: Bool
    public var forge: ForgeConfig?

    public init(
        device: DeviceInfo,
        projectsFolder: String,
        claudeAvailable: Bool,
        claudePath: String,
        gitAvailable: Bool,
        forge: ForgeConfig? = nil
    ) {
        self.device = device
        self.projectsFolder = projectsFolder
        self.claudeAvailable = claudeAvailable
        self.claudePath = claudePath
        self.gitAvailable = gitAvailable
        self.forge = forge
    }
}

/// `host.listDirectories` params: an absolute path inside the home folder, a leading `~` allowed; `""`: the home
/// folder.
public struct HostListDirectoriesParams: Codable, Sendable, Hashable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

/// `host.listDirectories` result.
public struct HostListDirectoriesResult: Codable, Sendable, Hashable {
    public var path: String
    public var entries: [DirectoryEntry]

    public init(path: String, entries: [DirectoryEntry]) {
        self.path = path
        self.entries = entries
    }
}

/// A subfolder listed by `host.listDirectories`.
public struct DirectoryEntry: Codable, Sendable, Hashable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// `subscribe` params: topics to add to this connection's subscriptions.
public struct SubscribeParams: Codable, Sendable, Hashable {
    public var topics: [String]

    public init(topics: [String]) {
        self.topics = topics
    }
}

/// `unsubscribe` params: topics to remove from this connection's subscriptions.
public struct UnsubscribeParams: Codable, Sendable, Hashable {
    public var topics: [String]

    public init(topics: [String]) {
        self.topics = topics
    }
}

/// `projects.list` result: the top-level projects ordered by name, each with its sub projects.
public struct ProjectsListResult: Codable, Sendable, Hashable {
    public var projects: [ProjectSummary]

    public init(projects: [ProjectSummary]) {
        self.projects = projects
    }
}

/// `projects.snapshot` params.
public struct ProjectsSnapshotParams: Codable, Sendable, Hashable {
    public var projectID: String

    public init(projectID: String) {
        self.projectID = projectID
    }
}

/// `projects.snapshot` result: everything a client mirrors for one project.
public struct ProjectsSnapshotResult: Codable, Sendable, Hashable {
    public var project: Project
    public var tasks: [TaskItem]
    public var bundles: [BundleItem]
    public var sessions: [SessionInfo]
    public var runs: [RunInfo]

    public init(project: Project, tasks: [TaskItem], bundles: [BundleItem], sessions: [SessionInfo], runs: [RunInfo]) {
        self.project = project
        self.tasks = tasks
        self.bundles = bundles
        self.sessions = sessions
        self.runs = runs
    }
}

/// `projects.create` params; a sub project when `parentID` is set.
public struct ProjectsCreateParams: Codable, Sendable, Hashable {
    public var name: String
    public var identifier: String
    public var parentID: String?
    public var folderName: String?
    public var description: String?

    public init(
        name: String,
        identifier: String,
        parentID: String? = nil,
        folderName: String? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.identifier = identifier
        self.parentID = parentID
        self.folderName = folderName
        self.description = description
    }
}

/// `projects.import` params.
public struct ProjectsImportParams: Codable, Sendable, Hashable {
    public var path: String
    public var name: String?
    public var identifier: String?

    public init(path: String, name: String? = nil, identifier: String? = nil) {
        self.path = path
        self.name = name
        self.identifier = identifier
    }
}

/// `projects.update` params.
public struct ProjectsUpdateParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var patch: ProjectPatch

    public init(projectID: String, patch: ProjectPatch) {
        self.projectID = projectID
        self.patch = patch
    }
}

/// `projects.remove` params.
public struct ProjectsRemoveParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var moveToTrash: Bool

    public init(projectID: String, moveToTrash: Bool) {
        self.projectID = projectID
        self.moveToTrash = moveToTrash
    }
}

/// `projects.migrate` params.
public struct ProjectsMigrateParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var targetDeviceID: UUID

    public init(projectID: String, targetDeviceID: UUID) {
        self.projectID = projectID
        self.targetDeviceID = targetDeviceID
    }
}

/// `projects.migrate` result: the id used by the `migration.*` methods and `migration.progress`.
public struct ProjectsMigrateResult: Codable, Sendable, Hashable {
    public var migrationID: UUID

    public init(migrationID: UUID) {
        self.migrationID = migrationID
    }
}

/// `uploads.begin` params.
public struct UploadsBeginParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var fileName: String
    public var size: Int

    public init(projectID: String, fileName: String, size: Int) {
        self.projectID = projectID
        self.fileName = fileName
        self.size = size
    }
}

/// `uploads.begin` result.
public struct UploadsBeginResult: Codable, Sendable, Hashable {
    public var uploadID: UUID

    public init(uploadID: UUID) {
        self.uploadID = uploadID
    }
}

/// `uploads.chunk` params.
public struct UploadsChunkParams: Codable, Sendable, Hashable {
    public var uploadID: UUID
    public var offset: Int
    public var data: Data

    public init(uploadID: UUID, offset: Int, data: Data) {
        self.uploadID = uploadID
        self.offset = offset
        self.data = data
    }
}

/// `uploads.cancel` params.
public struct UploadsCancelParams: Codable, Sendable, Hashable {
    public var uploadID: UUID

    public init(uploadID: UUID) {
        self.uploadID = uploadID
    }
}

/// `tasks.create` params.
public struct TasksCreateParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var name: String
    public var description: String?
    public var status: TaskStatus?

    public init(projectID: String, name: String, description: String? = nil, status: TaskStatus? = nil) {
        self.projectID = projectID
        self.name = name
        self.description = description
        self.status = status
    }
}

/// `tasks.update` params.
public struct TasksUpdateParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var taskID: String
    public var patch: TaskPatch

    public init(projectID: String, taskID: String, patch: TaskPatch) {
        self.projectID = projectID
        self.taskID = taskID
        self.patch = patch
    }
}

/// `tasks.delete` params.
public struct TasksDeleteParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var taskID: String

    public init(projectID: String, taskID: String) {
        self.projectID = projectID
        self.taskID = taskID
    }
}

/// `tasks.addComment` params.
public struct TasksAddCommentParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var taskID: String
    public var body: String
    public var attachments: [UploadRef]
    public var author: String?

    public init(projectID: String, taskID: String, body: String, attachments: [UploadRef], author: String? = nil) {
        self.projectID = projectID
        self.taskID = taskID
        self.body = body
        self.attachments = attachments
        self.author = author
    }
}

/// `tasks.updateComment` params.
public struct TasksUpdateCommentParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var taskID: String
    public var commentID: UUID
    public var body: String

    public init(projectID: String, taskID: String, commentID: UUID, body: String) {
        self.projectID = projectID
        self.taskID = taskID
        self.commentID = commentID
        self.body = body
    }
}

/// `tasks.deleteComment` params.
public struct TasksDeleteCommentParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var taskID: String
    public var commentID: UUID

    public init(projectID: String, taskID: String, commentID: UUID) {
        self.projectID = projectID
        self.taskID = taskID
        self.commentID = commentID
    }
}

/// `attachments.read` params.
public struct AttachmentsReadParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var taskID: String
    public var fileName: String
    public var offset: Int?
    public var length: Int?

    public init(projectID: String, taskID: String, fileName: String, offset: Int? = nil, length: Int? = nil) {
        self.projectID = projectID
        self.taskID = taskID
        self.fileName = fileName
        self.offset = offset
        self.length = length
    }
}

/// `attachments.read` and `sessions.readAttachment` result.
public struct AttachmentsReadResult: Codable, Sendable, Hashable {
    public var data: Data
    public var size: Int
    public var mimeType: String

    public init(data: Data, size: Int, mimeType: String) {
        self.data = data
        self.size = size
        self.mimeType = mimeType
    }
}

/// `bundles.create` params.
public struct BundlesCreateParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var name: String
    public var taskIDs: [String]

    public init(projectID: String, name: String, taskIDs: [String]) {
        self.projectID = projectID
        self.name = name
        self.taskIDs = taskIDs
    }
}

/// `bundles.update` params.
public struct BundlesUpdateParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var bundleID: String
    public var patch: BundlePatch

    public init(projectID: String, bundleID: String, patch: BundlePatch) {
        self.projectID = projectID
        self.bundleID = bundleID
        self.patch = patch
    }
}

/// `bundles.delete` params.
public struct BundlesDeleteParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var bundleID: String

    public init(projectID: String, bundleID: String) {
        self.projectID = projectID
        self.bundleID = bundleID
    }
}

/// `bundles.start` params.
public struct BundlesStartParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var bundleID: String

    public init(projectID: String, bundleID: String) {
        self.projectID = projectID
        self.bundleID = bundleID
    }
}

/// `bundles.stop` params.
public struct BundlesStopParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var bundleID: String

    public init(projectID: String, bundleID: String) {
        self.projectID = projectID
        self.bundleID = bundleID
    }
}

/// `files.list` params.
public struct FilesListParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var path: String

    public init(projectID: String, path: String) {
        self.projectID = projectID
        self.path = path
    }
}

/// `files.list` result.
public struct FilesListResult: Codable, Sendable, Hashable {
    public var entries: [FileEntry]

    public init(entries: [FileEntry]) {
        self.entries = entries
    }
}

/// `files.read` params.
public struct FilesReadParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var path: String
    public var offset: Int?
    public var length: Int?

    public init(projectID: String, path: String, offset: Int? = nil, length: Int? = nil) {
        self.projectID = projectID
        self.path = path
        self.offset = offset
        self.length = length
    }
}

/// `files.read` result.
public struct FilesReadResult: Codable, Sendable, Hashable {
    public var data: Data
    public var revision: String
    public var size: Int

    public init(data: Data, revision: String, size: Int) {
        self.data = data
        self.revision = revision
        self.size = size
    }
}

/// `files.write` params.
public struct FilesWriteParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var path: String
    public var data: Data
    public var baseRevision: String?

    public init(projectID: String, path: String, data: Data, baseRevision: String? = nil) {
        self.projectID = projectID
        self.path = path
        self.data = data
        self.baseRevision = baseRevision
    }
}

/// `files.write` result.
public struct FilesWriteResult: Codable, Sendable, Hashable {
    public var revision: String

    public init(revision: String) {
        self.revision = revision
    }
}

/// `files.create` params.
public struct FilesCreateParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var path: String
    public var isDirectory: Bool

    public init(projectID: String, path: String, isDirectory: Bool) {
        self.projectID = projectID
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// `files.rename` params.
public struct FilesRenameParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var from: String
    public var to: String

    public init(projectID: String, from: String, to: String) {
        self.projectID = projectID
        self.from = from
        self.to = to
    }
}

/// `files.delete` params.
public struct FilesDeleteParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var path: String

    public init(projectID: String, path: String) {
        self.projectID = projectID
        self.path = path
    }
}

/// `tabs.open` params.
public struct TabsOpenParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var url: String
    public var title: String?
    public var locked: Bool?

    public init(projectID: String, url: String, title: String? = nil, locked: Bool? = nil) {
        self.projectID = projectID
        self.url = url
        self.title = title
        self.locked = locked
    }
}

/// `tabs.update` params.
public struct TabsUpdateParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var tabID: UUID
    public var patch: WebTabPatch

    public init(projectID: String, tabID: UUID, patch: WebTabPatch) {
        self.projectID = projectID
        self.tabID = tabID
        self.patch = patch
    }
}

/// `tabs.close` params.
public struct TabsCloseParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var tabID: UUID

    public init(projectID: String, tabID: UUID) {
        self.projectID = projectID
        self.tabID = tabID
    }
}

/// `tabs.move` params.
public struct TabsMoveParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var tabID: UUID
    public var toIndex: Int

    public init(projectID: String, tabID: UUID, toIndex: Int) {
        self.projectID = projectID
        self.tabID = tabID
        self.toIndex = toIndex
    }
}

/// `sessions.start` params.
public struct SessionsStartParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var kind: SessionKind
    public var taskID: String?
    public var mode: SessionMode?
    public var title: String?
    public var message: String?
    public var attachments: [UploadRef]?
    public var permissionMode: PermissionMode?
    public var model: String?

    public init(
        projectID: String,
        kind: SessionKind,
        taskID: String? = nil,
        mode: SessionMode? = nil,
        title: String? = nil,
        message: String? = nil,
        attachments: [UploadRef]? = nil,
        permissionMode: PermissionMode? = nil,
        model: String? = nil
    ) {
        self.projectID = projectID
        self.kind = kind
        self.taskID = taskID
        self.mode = mode
        self.title = title
        self.message = message
        self.attachments = attachments
        self.permissionMode = permissionMode
        self.model = model
    }
}

/// `sessions.history` params.
public struct SessionsHistoryParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID
    public var before: Int?
    public var limit: Int?

    public init(projectID: String, sessionID: UUID, before: Int? = nil, limit: Int? = nil) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.before = before
        self.limit = limit
    }
}

/// `sessions.history` result: one page of a session's transcript.
public struct SessionsHistoryResult: Codable, Sendable, Hashable {
    public var events: [SessionEvent]
    public var firstIndex: Int
    public var total: Int

    public init(events: [SessionEvent], firstIndex: Int, total: Int) {
        self.events = events
        self.firstIndex = firstIndex
        self.total = total
    }
}

/// `sessions.readAttachment` params.
public struct SessionsReadAttachmentParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID
    public var fileName: String
    public var offset: Int?
    public var length: Int?

    public init(projectID: String, sessionID: UUID, fileName: String, offset: Int? = nil, length: Int? = nil) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.fileName = fileName
        self.offset = offset
        self.length = length
    }
}

/// `sessions.send` params.
public struct SessionsSendParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID
    public var text: String
    public var attachments: [UploadRef]

    public init(projectID: String, sessionID: UUID, text: String, attachments: [UploadRef]) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.text = text
        self.attachments = attachments
    }
}

/// `sessions.interrupt` params.
public struct SessionsInterruptParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID

    public init(projectID: String, sessionID: UUID) {
        self.projectID = projectID
        self.sessionID = sessionID
    }
}

/// `sessions.stop` params.
public struct SessionsStopParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID

    public init(projectID: String, sessionID: UUID) {
        self.projectID = projectID
        self.sessionID = sessionID
    }
}

/// `sessions.respond` params.
public struct SessionsRespondParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID
    public var requestID: String
    public var decision: PermissionDecision
    public var message: String?

    public init(
        projectID: String,
        sessionID: UUID,
        requestID: String,
        decision: PermissionDecision,
        message: String? = nil
    ) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.requestID = requestID
        self.decision = decision
        self.message = message
    }
}

/// `sessions.update` params.
public struct SessionsUpdateParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID
    public var patch: SessionPatch

    public init(projectID: String, sessionID: UUID, patch: SessionPatch) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.patch = patch
    }
}

/// `sessions.delete` params.
public struct SessionsDeleteParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID

    public init(projectID: String, sessionID: UUID) {
        self.projectID = projectID
        self.sessionID = sessionID
    }
}

/// `runs.start` params.
public struct RunsStartParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var name: String

    public init(projectID: String, name: String) {
        self.projectID = projectID
        self.name = name
    }
}

/// `runs.stop` params.
public struct RunsStopParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var runID: UUID

    public init(projectID: String, runID: UUID) {
        self.projectID = projectID
        self.runID = runID
    }
}

/// `runs.output` params.
public struct RunsOutputParams: Codable, Sendable, Hashable {
    public var projectID: String
    public var runID: UUID

    public init(projectID: String, runID: UUID) {
        self.projectID = projectID
        self.runID = runID
    }
}

/// `runs.output` result.
public struct RunsOutputResult: Codable, Sendable, Hashable {
    public var text: String
    public var seq: Int

    public init(text: String, seq: Int) {
        self.text = text
        self.seq = seq
    }
}

/// `search.query` params.
public struct SearchQueryParams: Codable, Sendable, Hashable {
    public var query: String
    public var scopes: [SearchScope]?
    public var projectID: String?
    public var limit: Int?

    public init(query: String, scopes: [SearchScope]? = nil, projectID: String? = nil, limit: Int? = nil) {
        self.query = query
        self.scopes = scopes
        self.projectID = projectID
        self.limit = limit
    }
}

/// `search.query` result, best first.
public struct SearchQueryResult: Codable, Sendable, Hashable {
    public var results: [SearchResult]

    public init(results: [SearchResult]) {
        self.results = results
    }
}

/// `skills.list` result.
public struct SkillsListResult: Codable, Sendable, Hashable {
    public var skills: [SkillSummary]

    public init(skills: [SkillSummary]) {
        self.skills = skills
    }
}

/// `skills.create` params.
public struct SkillsCreateParams: Codable, Sendable, Hashable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// `skills.files` params.
public struct SkillsFilesParams: Codable, Sendable, Hashable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// `skills.files` result.
public struct SkillsFilesResult: Codable, Sendable, Hashable {
    public var files: [SkillFile]

    public init(files: [SkillFile]) {
        self.files = files
    }
}

/// `skills.readFile` params.
public struct SkillsReadFileParams: Codable, Sendable, Hashable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// `skills.readFile` result.
public struct SkillsReadFileResult: Codable, Sendable, Hashable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}

/// `skills.writeFile` params.
public struct SkillsWriteFileParams: Codable, Sendable, Hashable {
    public var name: String
    public var path: String
    public var data: Data

    public init(name: String, path: String, data: Data) {
        self.name = name
        self.path = path
        self.data = data
    }
}

/// `skills.deleteFile` params.
public struct SkillsDeleteFileParams: Codable, Sendable, Hashable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// `skills.rename` params.
public struct SkillsRenameParams: Codable, Sendable, Hashable {
    public var name: String
    public var newName: String

    public init(name: String, newName: String) {
        self.name = name
        self.newName = newName
    }
}

/// `skills.delete` params.
public struct SkillsDeleteParams: Codable, Sendable, Hashable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// `skills.manifest` result.
public struct SkillsManifestResult: Codable, Sendable, Hashable {
    public var skills: [SkillManifest]

    public init(skills: [SkillManifest]) {
        self.skills = skills
    }
}

/// `migration.begin` params.
public struct MigrationBeginParams: Codable, Sendable, Hashable {
    public var migrationID: UUID
    public var project: ProjectSummary
    public var folderName: String
    public var manifest: [ManifestEntry]
    public var claudeFiles: [ManifestEntry]

    public init(
        migrationID: UUID,
        project: ProjectSummary,
        folderName: String,
        manifest: [ManifestEntry],
        claudeFiles: [ManifestEntry]
    ) {
        self.migrationID = migrationID
        self.project = project
        self.folderName = folderName
        self.manifest = manifest
        self.claudeFiles = claudeFiles
    }
}

/// `migration.begin` result: the absolute path of the new project root on the destination.
public struct MigrationBeginResult: Codable, Sendable, Hashable {
    public var destinationPath: String

    public init(destinationPath: String) {
        self.destinationPath = destinationPath
    }
}

/// `migration.chunk` params.
public struct MigrationChunkParams: Codable, Sendable, Hashable {
    public var migrationID: UUID
    public var path: String
    public var offset: Int
    public var data: Data
    public var transcript: Bool

    public init(migrationID: UUID, path: String, offset: Int, data: Data, transcript: Bool) {
        self.migrationID = migrationID
        self.path = path
        self.offset = offset
        self.data = data
        self.transcript = transcript
    }
}

/// `migration.commit` params.
public struct MigrationCommitParams: Codable, Sendable, Hashable {
    public var migrationID: UUID

    public init(migrationID: UUID) {
        self.migrationID = migrationID
    }
}

/// `migration.abort` params.
public struct MigrationAbortParams: Codable, Sendable, Hashable {
    public var migrationID: UUID

    public init(migrationID: UUID) {
        self.migrationID = migrationID
    }
}

/// `migration.status` params.
public struct MigrationStatusParams: Codable, Sendable, Hashable {
    public var migrationID: UUID

    public init(migrationID: UUID) {
        self.migrationID = migrationID
    }
}

/// `migration.status` result.
public struct MigrationStatusResult: Codable, Sendable, Hashable {
    public var state: MigrationOutcome

    public init(state: MigrationOutcome) {
        self.state = state
    }
}

/// `forge.feedback` params.
public struct ForgeFeedbackParams: Codable, Sendable, Hashable {
    public var screenshot: UploadRef?
    public var comment: String
    public var context: FeedbackContext

    public init(screenshot: UploadRef? = nil, comment: String, context: FeedbackContext) {
        self.screenshot = screenshot
        self.comment = comment
        self.context = context
    }
}

/// `forge.feedback` result.
public struct ForgeFeedbackResult: Codable, Sendable, Hashable {
    public var projectID: String
    public var taskID: String
    public var sessionID: UUID

    public init(projectID: String, taskID: String, sessionID: UUID) {
        self.projectID = projectID
        self.taskID = taskID
        self.sessionID = sessionID
    }
}

/// `forge.retry` params: the `taskID` of a failed Forge item.
public struct ForgeRetryParams: Codable, Sendable, Hashable {
    public var itemTaskID: String

    public init(itemTaskID: String) {
        self.itemTaskID = itemTaskID
    }
}
