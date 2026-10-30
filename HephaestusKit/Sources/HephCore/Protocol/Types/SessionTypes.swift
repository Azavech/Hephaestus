import Foundation

// Sessions: the wire types of docs/protocol/types.md, section "Sessions".

/// The kind of a Claude session.
public enum SessionKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Project chat.
    case project
    /// Session bound to a task.
    case task
    /// Forge feedback discussion.
    case feedback
    /// Forge regeneration.
    case regeneration
}

/// The mode of a task session.
public enum SessionMode: String, Codable, Sendable, Hashable, CaseIterable {
    case implement
    case debug
    case review
    case plan
    case custom

    /// The name shown in the UI.
    public var displayName: String {
        switch self {
        case .implement: return "Implement"
        case .debug: return "Debug"
        case .review: return "Review"
        case .plan: return "Plan"
        case .custom: return "Custom"
        }
    }
}

/// The status of a session. The session file stores only `stopped` and `failed`.
public enum SessionStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// No process: a new session, or the process was stopped, stopped when idle, or exited with code 0.
    case stopped
    /// The process was started and has not answered the initialize request yet.
    case starting
    /// A turn is in progress.
    case running
    /// The turn waits for at least one permission answer.
    case waitingPermission
    /// The process is alive between turns.
    case idle
    /// The last process failed; `error` gives the reason.
    case failed
}

/// The permission mode of a session.
public enum PermissionMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Asks for everything the user's Claude settings do not allow.
    case manual
    case acceptEdits
    case auto
    case plan
    case bypassPermissions
}

/// The type of a `SessionEvent`.
public enum SessionEventType: String, Codable, Sendable, Hashable, CaseIterable {
    case user
    case assistant
    case thinking
    case toolUse
    case toolResult
    case permission
    case permissionDecision
    case result
    case system
    case error
}

/// The answer to a permission request.
public enum PermissionDecision: String, Codable, Sendable, Hashable, CaseIterable {
    /// Allow this use.
    case allow
    /// Allow, and apply the request's suggestions.
    case allowAlways
    /// Deny.
    case deny
}

/// The kind of a streamed fragment (`session.delta`).
public enum SessionDeltaKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Assistant text.
    case text
    /// Thinking text.
    case thinking
    /// Partial JSON of a tool input.
    case toolInput
}

/// A Claude session. `statusLine`, `error` and `pendingPermissions` are kept in memory by the Main and are not stored
/// in the session file.
public struct SessionInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: SessionKind
    public var taskID: String?
    public var mode: SessionMode?
    public var title: String
    public var created: Date
    public var updated: Date
    public var permissionMode: PermissionMode
    public var model: String?
    public var status: SessionStatus
    public var statusLine: String?
    public var error: String?
    public var pendingPermissions: [PermissionRequest]

    public init(
        id: UUID,
        kind: SessionKind,
        taskID: String? = nil,
        mode: SessionMode? = nil,
        title: String,
        created: Date,
        updated: Date,
        permissionMode: PermissionMode,
        model: String? = nil,
        status: SessionStatus,
        statusLine: String? = nil,
        error: String? = nil,
        pendingPermissions: [PermissionRequest]
    ) {
        self.id = id
        self.kind = kind
        self.taskID = taskID
        self.mode = mode
        self.title = title
        self.created = created
        self.updated = updated
        self.permissionMode = permissionMode
        self.model = model
        self.status = status
        self.statusLine = statusLine
        self.error = error
        self.pendingPermissions = pendingPermissions
    }
}

/// Changes for `sessions.update`. A `nil` field leaves the value unchanged.
public struct SessionPatch: Codable, Sendable, Hashable {
    public var title: String?
    public var permissionMode: PermissionMode?
    public var model: String?

    public init(title: String? = nil, permissionMode: PermissionMode? = nil, model: String? = nil) {
        self.title = title
        self.permissionMode = permissionMode
        self.model = model
    }
}

/// One entry of a session transcript, stored as one JSON line of `.hephaestus/sessions/<id>.jsonl`. A flat struct: the
/// fields a type does not use are `nil`.
public struct SessionEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var at: Date
    public var type: SessionEventType
    public var text: String?
    public var attachments: [TaskAttachment]?
    public var deviceID: UUID?
    public var messageID: String?
    public var index: Int?
    public var toolUseID: String?
    public var name: String?
    public var input: String?
    public var isError: Bool?
    public var requestID: String?
    public var toolName: String?
    public var description: String?
    public var suggestions: String?
    public var blockedPath: String?
    public var decision: PermissionDecision?
    public var durationMS: Int?
    public var costUSD: Double?
    public var stopReason: String?

    public init(
        id: String,
        at: Date,
        type: SessionEventType,
        text: String? = nil,
        attachments: [TaskAttachment]? = nil,
        deviceID: UUID? = nil,
        messageID: String? = nil,
        index: Int? = nil,
        toolUseID: String? = nil,
        name: String? = nil,
        input: String? = nil,
        isError: Bool? = nil,
        requestID: String? = nil,
        toolName: String? = nil,
        description: String? = nil,
        suggestions: String? = nil,
        blockedPath: String? = nil,
        decision: PermissionDecision? = nil,
        durationMS: Int? = nil,
        costUSD: Double? = nil,
        stopReason: String? = nil
    ) {
        self.id = id
        self.at = at
        self.type = type
        self.text = text
        self.attachments = attachments
        self.deviceID = deviceID
        self.messageID = messageID
        self.index = index
        self.toolUseID = toolUseID
        self.name = name
        self.input = input
        self.isError = isError
        self.requestID = requestID
        self.toolName = toolName
        self.description = description
        self.suggestions = suggestions
        self.blockedPath = blockedPath
        self.decision = decision
        self.durationMS = durationMS
        self.costUSD = costUSD
        self.stopReason = stopReason
    }
}

/// A permission request of the CLI waiting for an answer.
public struct PermissionRequest: Codable, Sendable, Hashable, Identifiable {
    public var requestID: String
    public var toolName: String
    public var input: String
    public var description: String?
    public var suggestions: String
    public var blockedPath: String?

    public var id: String { requestID }

    public init(
        requestID: String,
        toolName: String,
        input: String,
        description: String? = nil,
        suggestions: String,
        blockedPath: String? = nil
    ) {
        self.requestID = requestID
        self.toolName = toolName
        self.input = input
        self.description = description
        self.suggestions = suggestions
        self.blockedPath = blockedPath
    }
}
