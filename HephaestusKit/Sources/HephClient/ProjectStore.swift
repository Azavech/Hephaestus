import Foundation
import HephCore
import Observation

/// The mirror of one opened project of one Main: the project, its tickets, bundles and sessions
/// (docs/client/workspace.md, "ProjectStore"). The Workspace creates it with `projectStore(mainDeviceID:projectID:)`
/// and keeps it current from the events of its Main.
@MainActor @Observable
public final class ProjectStore {
    public enum Phase: Equatable, Sendable {
        case idle, loading, loaded, failed(String)
    }

    public let mainDeviceID: UUID
    public let projectID: String
    public private(set) var phase: Phase = .idle
    public private(set) var project: Project?
    /// By ticket number, ascending.
    public private(set) var tickets: [TicketItem] = []
    /// By bundle number, ascending.
    public private(set) var bundles: [BundleItem] = []
    /// By `created`, then id.
    public private(set) var sessions: [SessionInfo] = []
    public private(set) var isRemoved = false

    @ObservationIgnored weak var workspace: Workspace?
    /// True while a `projects.snapshot` request runs.
    @ObservationIgnored private var isLoading = false
    /// The store events that arrived during the load, applied after its result.
    @ObservationIgnored private var queuedEvents: [ServerEvent] = []

    init(workspace: Workspace, mainDeviceID: UUID, projectID: String) {
        self.workspace = workspace
        self.mainDeviceID = mainDeviceID
        self.projectID = projectID
    }

    /// The connection of the project's Main.
    public var connection: MainConnection? {
        workspace?.connection(mainDeviceID)
    }

    /// Loads the project again with `projects.snapshot`; returns at once while a load runs. The data stays visible
    /// while it loads.
    public func reload() async {
        guard !isLoading, !isRemoved else { return }
        isLoading = true
        queuedEvents = []
        phase = .loading
        do {
            guard let connection else {
                throw ProtocolError(.unavailable, "\(workspace?.mainName(mainDeviceID) ?? "Main") is offline.")
            }
            let snapshot = try await connection.projectSnapshot(projectID: projectID)
            isLoading = false
            guard !isRemoved else { return }
            project = snapshot.project
            tickets = Self.sortedTickets(snapshot.tickets)
            bundles = Self.sortedBundles(snapshot.bundles)
            sessions = Self.sortedSessions(snapshot.sessions)
            let queued = queuedEvents
            queuedEvents = []
            for event in queued {
                apply(event)
            }
            phase = .loaded
            workspace?.sessionCenter.handleSessions(mainDeviceID: mainDeviceID, projectID: projectID,
                                                    sessions: sessions)
        } catch {
            isLoading = false
            queuedEvents = []
            guard !isRemoved else { return }
            if error is CancellationError {
                phase = project == nil ? .idle : .loaded
                return
            }
            let message = Workspace.message(of: error)
            if (error as? ProtocolError)?.code == .notFound {
                isRemoved = true
                workspace?.dropStore(self)
            } else if project == nil {
                phase = .failed(message)
            } else {
                phase = .loaded
                workspace?.report("Could not refresh \(projectID): \(message)")
            }
        }
    }

    public func ticket(_ id: String) -> TicketItem? {
        tickets.first { $0.id == id }
    }

    public func bundle(_ id: String) -> BundleItem? {
        bundles.first { $0.id == id }
    }

    public func session(_ id: UUID) -> SessionInfo? {
        sessions.first { $0.id == id }
    }

    // MARK: - Workspace

    /// Applies a store event (`project.changed`, `ticket.changed`, `ticket.removed`, `bundle.changed`,
    /// `bundle.removed`, `session.changed`, `session.removed`); queued while a load runs.
    func receive(_ event: ServerEvent) {
        if isLoading {
            queuedEvents.append(event)
        } else {
            apply(event)
        }
    }

    /// The store is loaded and lacks this session: it reloads.
    func reloadIfUnknown(sessionID: UUID) {
        guard phase == .loaded, session(sessionID) == nil else { return }
        Task { await reload() }
    }

    /// A result of the request API for this project: inserted when the store does not contain that id yet; an
    /// existing element is never replaced (events bring updates).
    func insertIfAbsent(_ ticket: TicketItem) {
        guard self.ticket(ticket.id) == nil else { return }
        tickets = Self.sortedTickets(tickets + [ticket])
    }

    func insertIfAbsent(_ session: SessionInfo) {
        guard self.session(session.id) == nil else { return }
        sessions = Self.sortedSessions(sessions + [session])
    }

    /// The project left its Main's tree, or its Main left the registry, or the Workspace was reset.
    func markRemoved() {
        isRemoved = true
        isLoading = false
        queuedEvents = []
    }

    /// The sample data of `Workspace.preview()`, applied as a loaded snapshot.
    func applyPreview(_ snapshot: ProjectsSnapshotResult) {
        project = snapshot.project
        tickets = Self.sortedTickets(snapshot.tickets)
        bundles = Self.sortedBundles(snapshot.bundles)
        sessions = Self.sortedSessions(snapshot.sessions)
        phase = .loaded
    }

    // MARK: - Applying events

    private func apply(_ event: ServerEvent) {
        switch event {
        case .projectChanged(let payload):
            project = payload.project
        case .ticketChanged(let payload):
            tickets = Self.upsert(payload.ticket, into: tickets, sorted: Self.sortedTickets)
        case .ticketRemoved(let payload):
            tickets.removeAll { $0.id == payload.ticketID }
        case .bundleChanged(let payload):
            bundles = Self.upsert(payload.bundle, into: bundles, sorted: Self.sortedBundles)
        case .bundleRemoved(let payload):
            bundles.removeAll { $0.id == payload.bundleID }
        case .sessionChanged(let payload):
            sessions = Self.upsert(payload.session, into: sessions, sorted: Self.sortedSessions)
        case .sessionRemoved(let payload):
            sessions.removeAll { $0.id == payload.sessionID }
        default:
            break
        }
    }

    // MARK: - Sorting

    /// Replaces the element with the same id, or inserts it at its sorted position.
    private static func upsert<Element: Identifiable>(_ element: Element, into list: [Element],
                                                      sorted: ([Element]) -> [Element]) -> [Element] {
        var list = list
        if let index = list.firstIndex(where: { $0.id == element.id }) {
            list[index] = element
        } else {
            list.append(element)
        }
        return sorted(list)
    }

    /// By the number after the last `-` of the id; ids without a number last, by id.
    static func sortedTickets(_ tickets: [TicketItem]) -> [TicketItem] {
        tickets.sorted { lhs, rhs in
            switch (ticketNumber(lhs.id), ticketNumber(rhs.id)) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }

    /// By the number after the last `-B` of the id; ids without a number last, by id.
    static func sortedBundles(_ bundles: [BundleItem]) -> [BundleItem] {
        bundles.sorted { lhs, rhs in
            switch (bundleNumber(lhs.id), bundleNumber(rhs.id)) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }

    /// By `created`, then id.
    static func sortedSessions(_ sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.sorted { lhs, rhs in
            if lhs.created != rhs.created {
                return lhs.created < rhs.created
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The number after the last `-` of a ticket id; nil when there is none.
    private static func ticketNumber(_ id: String) -> Int? {
        guard let dash = id.lastIndex(of: "-") else { return nil }
        return number(id[id.index(after: dash)...])
    }

    /// The number after the last `-B` of a bundle id; nil when there is none.
    private static func bundleNumber(_ id: String) -> Int? {
        guard let marker = id.range(of: "-B", options: .backwards) else { return nil }
        return number(id[marker.upperBound...])
    }

    /// Decimal digits as a number; nil when empty or not only digits.
    private static func number(_ digits: Substring) -> Int? {
        guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits)
    }
}
