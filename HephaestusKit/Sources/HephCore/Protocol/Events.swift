import Foundation

// The events of docs/protocol/events.md: their names, delivery and payloads.

/// An event of the protocol; raw value = event name.
public enum EventName: String, CaseIterable, Sendable {
    case meshChanged = "mesh.changed"
    case projectsChanged = "projects.changed"
    case projectChanged = "project.changed"
    case ticketChanged = "ticket.changed"
    case ticketRemoved = "ticket.removed"
    case bundleChanged = "bundle.changed"
    case bundleRemoved = "bundle.removed"
    case filesChanged = "files.changed"
    case sessionChanged = "session.changed"
    case sessionRemoved = "session.removed"
    case sessionEvent = "session.event"
    case sessionDelta = "session.delta"
    case permissionRequested = "permission.requested"
    case permissionResolved = "permission.resolved"
    case skillsChanged = "skills.changed"
    case migrationProgress = "migration.progress"
    case forgeChanged = "forge.changed"

    /// Who receives the event (the Delivery column).
    public var delivery: EventDelivery {
        switch self {
        case .sessionEvent, .sessionDelta:
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
    case ticketChanged(TicketChangedPayload)
    case ticketRemoved(TicketRemovedPayload)
    case bundleChanged(BundleChangedPayload)
    case bundleRemoved(BundleRemovedPayload)
    case filesChanged(FilesChangedPayload)
    case sessionChanged(SessionChangedPayload)
    case sessionRemoved(SessionRemovedPayload)
    case sessionEvent(SessionEventPayload)
    case sessionDelta(SessionDeltaPayload)
    case permissionRequested(PermissionRequestedPayload)
    case permissionResolved(PermissionResolvedPayload)
    case skillsChanged(SkillsChangedPayload)
    case migrationProgress(MigrationProgressPayload)
    case forgeChanged(ForgeChangedPayload)

    public var name: EventName {
        switch self {
        case .meshChanged: return .meshChanged
        case .projectsChanged: return .projectsChanged
        case .projectChanged: return .projectChanged
        case .ticketChanged: return .ticketChanged
        case .ticketRemoved: return .ticketRemoved
        case .bundleChanged: return .bundleChanged
        case .bundleRemoved: return .bundleRemoved
        case .filesChanged: return .filesChanged
        case .sessionChanged: return .sessionChanged
        case .sessionRemoved: return .sessionRemoved
        case .sessionEvent: return .sessionEvent
        case .sessionDelta: return .sessionDelta
        case .permissionRequested: return .permissionRequested
        case .permissionResolved: return .permissionResolved
        case .skillsChanged: return .skillsChanged
        case .migrationProgress: return .migrationProgress
        case .forgeChanged: return .forgeChanged
        }
    }

    /// The topic of a subscriber event (`session.event`, `session.delta`: `.session(sessionID)`); `nil` for
    /// broadcast events.
    public var topic: Topic? {
        switch self {
        case .sessionEvent(let payload): return .session(payload.sessionID)
        case .sessionDelta(let payload): return .session(payload.sessionID)
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
        case .ticketChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .ticketRemoved(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .bundleChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .bundleRemoved(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .filesChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .sessionChanged(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .sessionRemoved(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .sessionEvent(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .sessionDelta(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .permissionRequested(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
        case .permissionResolved(let payload): return try WireCoding.encodeEvent(name: name, params: payload)
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
        case .ticketChanged: return .ticketChanged(try event.decodeParams())
        case .ticketRemoved: return .ticketRemoved(try event.decodeParams())
        case .bundleChanged: return .bundleChanged(try event.decodeParams())
        case .bundleRemoved: return .bundleRemoved(try event.decodeParams())
        case .filesChanged: return .filesChanged(try event.decodeParams())
        case .sessionChanged: return .sessionChanged(try event.decodeParams())
        case .sessionRemoved: return .sessionRemoved(try event.decodeParams())
        case .sessionEvent: return .sessionEvent(try event.decodeParams())
        case .sessionDelta: return .sessionDelta(try event.decodeParams())
        case .permissionRequested: return .permissionRequested(try event.decodeParams())
        case .permissionResolved: return .permissionResolved(try event.decodeParams())
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

/// `ticket.changed`: the ticket after the change.
public struct TicketChangedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var ticket: TicketItem

    public init(projectID: String, ticket: TicketItem) {
        self.projectID = projectID
        self.ticket = ticket
    }
}

/// `ticket.removed`.
public struct TicketRemovedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var ticketID: String

    public init(projectID: String, ticketID: String) {
        self.projectID = projectID
        self.ticketID = ticketID
    }
}

/// `bundle.changed`: the bundle after the change.
public struct BundleChangedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var bundle: BundleItem

    public init(projectID: String, bundle: BundleItem) {
        self.projectID = projectID
        self.bundle = bundle
    }
}

/// `bundle.removed`.
public struct BundleRemovedPayload: Codable, Sendable, Hashable {
    public var projectID: String
    public var bundleID: String

    public init(projectID: String, bundleID: String) {
        self.projectID = projectID
        self.bundleID = bundleID
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

/// `permission.resolved`: the first answer to a request, its cancellation (`deny` from the Main itself), or the Main's
/// automatic answer when the session allows all tools (`allowAll`).
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
