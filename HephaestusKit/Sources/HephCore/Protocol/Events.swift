import Foundation

// The events of docs/protocol/events.md: their names, delivery and payloads.

/// An event of the protocol; raw value = event name.
public enum EventName: String, CaseIterable, Sendable {
    case meshChanged = "mesh.changed"
    case projectsChanged = "projects.changed"
    case projectChanged = "project.changed"
    case taskChanged = "task.changed"
    case taskRemoved = "task.removed"
    case filesChanged = "files.changed"
    case sessionChanged = "session.changed"
    case sessionRemoved = "session.removed"
    case sessionEvent = "session.event"
    case sessionDelta = "session.delta"
    case permissionRequested = "permission.requested"
    case permissionResolved = "permission.resolved"
    case runChanged = "run.changed"
    case runOutput = "run.output"
    case skillsChanged = "skills.changed"
    case migrationProgress = "migration.progress"
    case forgeChanged = "forge.changed"

    /// Who receives the event (the Delivery column).
    public var delivery: EventDelivery {
        switch self {
        case .sessionEvent, .sessionDelta, .runOutput:
            return .subscribers
        default:
            return .broadcast
        }
    }
}

public enum EventDelivery: Sendable {
    /// Every authenticated connection of the emitting Main.
    case broadcast
    /// The connections subscribed to the event's topic.
    case subscribers
}

/// An event with its payload.
public enum ServerEvent: Sendable, Hashable {
    case meshChanged(MeshChangedPayload)
    case projectsChanged(ProjectsChangedPayload)
    case projectChanged(ProjectChangedPayload)
    case taskChanged(TaskChangedPayload)
    case taskRemoved(TaskRemovedPayload)
    case filesChanged(FilesChangedPayload)
    case sessionChanged(SessionChangedPayload)
    case sessionRemoved(SessionRemovedPayload)
    case sessionEvent(SessionEventPayload)
    case sessionDelta(SessionDeltaPayload)
    case permissionRequested(PermissionRequestedPayload)
    case permissionResolved(PermissionResolvedPayload)
    case runChanged(RunChangedPayload)
    case runOutput(RunOutputPayload)
    case skillsChanged(SkillsChangedPayload)
    case migrationProgress(MigrationProgressPayload)
    case forgeChanged(ForgeChangedPayload)

    public var name: EventName {
        switch self {
        case .meshChanged: return .meshChanged
        case .projectsChanged: return .projectsChanged
        case .projectChanged: return .projectChanged
        case .taskChanged: return .taskChanged
        case .taskRemoved: return .taskRemoved
        case .filesChanged: return .filesChanged
        case .sessionChanged: return .sessionChanged
        case .sessionRemoved: return .sessionRemoved
        case .sessionEvent: return .sessionEvent
        case .sessionDelta: return .sessionDelta
        case .permissionRequested: return .permissionRequested
        case .permissionResolved: return .permissionResolved
        case .runChanged: return .runChanged
        case .runOutput: return .runOutput
        case .skillsChanged: return .skillsChanged
        case .migrationProgress: return .migrationProgress
        case .forgeChanged: return .forgeChanged
        }
    }

    /// The topic of a subscriber event (`session.event`, `session.delta`: `.session(sessionID)`;
    /// `run.output`: `.run(runID)`); `nil` for broadcast events.
    public var topic: Topic? {
        switch self {
        case .sessionEvent(let payload): return .session(payload.sessionID)
        case .sessionDelta(let payload): return .session(payload.sessionID)
        case .runOutput(let payload): return .run(payload.runID)
        default: return nil
        }
    }

    /// The complete event frame (`WireCoding.encodeEvent(name: name.rawValue, params: payload)`).
    public func encodeFrame() throws -> Data {
        let name = name.rawValue
        switch self {
        case .meshChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .projectsChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .projectChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .taskChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .taskRemoved(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .filesChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .sessionChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .sessionRemoved(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .sessionEvent(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .sessionDelta(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .permissionRequested(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .permissionResolved(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .runChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .runOutput(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .skillsChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .migrationProgress(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .forgeChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        }
    }

    /// Decodes a received event. Returns `nil` for an event name this build does not know; throws
    /// `ProtocolError(.badRequest, …)` when the payload does not decode.
    public static func decode(_ event: InboundEvent) throws -> ServerEvent? {
        guard let name = EventName(rawValue: event.name) else { return nil }
        switch name {
        case .meshChanged: return .meshChanged(try event.decodeParams())
        case .projectsChanged: return .projectsChanged(try event.decodeParams())
        case .projectChanged: return .projectChanged(try event.decodeParams())
        case .taskChanged: return .taskChanged(try event.decodeParams())
        case .taskRemoved: return .taskRemoved(try event.decodeParams())
        case .filesChanged: return .filesChanged(try event.decodeParams())
        case .sessionChanged: return .sessionChanged(try event.decodeParams())
        case .sessionRemoved: return .sessionRemoved(try event.decodeParams())
        case .sessionEvent: return .sessionEvent(try event.decodeParams())
        case .sessionDelta: return .sessionDelta(try event.decodeParams())
        case .permissionRequested: return .permissionRequested(try event.decodeParams())
        case .permissionResolved: return .permissionResolved(try event.decodeParams())
        case .runChanged: return .runChanged(try event.decodeParams())
        case .runOutput: return .runOutput(try event.decodeParams())
        case .skillsChanged: return .skillsChanged(try event.decodeParams())
        case .migrationProgress: return .migrationProgress(try event.decodeParams())
        case .forgeChanged: return .forgeChanged(try event.decodeParams())
        }
    }
}

// MARK: - Payloads

/// `mesh.changed`: the Main's registry and presence report.
public struct MeshChangedPayload: Codable, Sendable, Hashable {
    public var snapshot: MeshSnapshot

    public init(snapshot: MeshSnapshot) {
        self.snapshot = snapshot
    }
}

/// `projects.changed`: the Main's top-level projects, as `projects.list` returns them.
public struct ProjectsChangedPayload: Codable, Sendable, Hashable {
    public var deviceID: UUID
    public var projects: [ProjectSummary]

    public init(deviceID: UUID, projects: [ProjectSummary]) {
        self.deviceID = deviceID
        self.projects = projects
    }
}

/// `project.changed`: the project after the change.
public struct ProjectChangedPayload: Codable, Sendable, Hashable {
    public var project: Project

    public init(project: Project) {
        self.project = project
    }
}

/// `task.changed`: the task after the change.
public struct TaskChangedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var task: TaskItem

    public init(projectID: String, task: TaskItem) {
        self.projectID = projectID
        self.task = task
    }
}

/// `task.removed`.
public struct TaskRemovedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var taskID: String

    public init(projectID: String, taskID: String) {
        self.projectID = projectID
        self.taskID = taskID
    }
}

/// `files.changed`: project-relative paths of the changed files and folders, each listed once.
public struct FilesChangedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var paths: [String]

    public init(projectID: String, paths: [String]) {
        self.projectID = projectID
        self.paths = paths
    }
}

/// `session.changed`: the session after the change.
public struct SessionChangedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var session: SessionInfo

    public init(projectID: String, session: SessionInfo) {
        self.projectID = projectID
        self.session = session
    }
}

/// `session.removed`.
public struct SessionRemovedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID

    public init(projectID: String, sessionID: UUID) {
        self.projectID = projectID
        self.sessionID = sessionID
    }
}

/// `session.event`: the event appended to the transcript.
public struct SessionEventPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID
    public var event: SessionEvent

    public init(projectID: String, sessionID: UUID, event: SessionEvent) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.event = event
    }
}

/// `session.delta`: a streamed fragment to append to the block `messageID`, `index`.
public struct SessionDeltaPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID
    public var messageID: String
    public var index: Int
    public var kind: SessionDeltaKind
    public var text: String

    public init(
        projectID: String,
        sessionID: UUID,
        messageID: String,
        index: Int,
        kind: SessionDeltaKind,
        text: String
    ) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.messageID = messageID
        self.index = index
        self.kind = kind
        self.text = text
    }
}

/// `permission.requested`.
public struct PermissionRequestedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID
    public var request: PermissionRequest

    public init(projectID: String, sessionID: UUID, request: PermissionRequest) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.request = request
    }
}

/// `permission.resolved`: the first answer to a request, or its cancellation (`deny` from the Main itself).
public struct PermissionResolvedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var sessionID: UUID
    public var requestID: String
    public var decision: PermissionDecision
    public var deviceID: UUID

    public init(projectID: String, sessionID: UUID, requestID: String, decision: PermissionDecision, deviceID: UUID) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.requestID = requestID
        self.decision = decision
        self.deviceID = deviceID
    }
}

/// `run.changed`: the run after the change.
public struct RunChangedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var run: RunInfo

    public init(projectID: String, run: RunInfo) {
        self.projectID = projectID
        self.run = run
    }
}

/// `run.output`: output text to append; `seq` numbers the batches of the run from 1.
public struct RunOutputPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var runID: UUID
    public var text: String
    public var seq: Int

    public init(projectID: String, runID: UUID, text: String, seq: Int) {
        self.projectID = projectID
        self.runID = runID
        self.text = text
        self.seq = seq
    }
}

/// `skills.changed`: the Main's whole library after the change, as `skills.list` returns it.
public struct SkillsChangedPayload: Codable, Sendable, Hashable {
    public var skills: [SkillSummary]

    public init(skills: [SkillSummary]) {
        self.skills = skills
    }
}

/// `migration.progress`.
public struct MigrationProgressPayload: Codable, Sendable, Hashable {
    public var migrationID: UUID
    public var projectID: String
    public var fromDeviceID: UUID
    public var toDeviceID: UUID
    public var state: MigrationState
    public var bytesDone: Int
    public var bytesTotal: Int
    public var error: String?

    public init(
        migrationID: UUID,
        projectID: String,
        fromDeviceID: UUID,
        toDeviceID: UUID,
        state: MigrationState,
        bytesDone: Int,
        bytesTotal: Int,
        error: String? = nil
    ) {
        self.migrationID = migrationID
        self.projectID = projectID
        self.fromDeviceID = fromDeviceID
        self.toDeviceID = toDeviceID
        self.state = state
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.error = error
    }
}

/// `forge.changed`: the Forge state after the change.
public struct ForgeChangedPayload: Codable, Sendable, Hashable {
    public var state: ForgeState

    public init(state: ForgeState) {
        self.state = state
    }
}
