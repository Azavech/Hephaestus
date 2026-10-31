import Foundation
import HephCore
import Observation

/// The mirror of one opened project of one Main: the project, its tasks, bundles, sessions and runs
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
    /// By task number, ascending.
    public private(set) var tasks: [TaskItem] = []
    /// By bundle number, ascending.
    public private(set) var bundles: [BundleItem] = []
    /// By `created`, then id.
    public private(set) var sessions: [SessionInfo] = []
    /// By `startedAt`, then id; trimmed to 20 (running runs stay).
    public private(set) var runs: [RunInfo] = []
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
            tasks = Self.sortedTasks(snapshot.tasks)
            bundles = Self.sortedBundles(snapshot.bundles)
            sessions = Self.sortedSessions(snapshot.sessions)
            runs = Self.trimmedRuns(Self.sortedRuns(snapshot.runs))
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

    public func task(_ id: String) -> TaskItem? {
        tasks.first { $0.id == id }
    }

    public func bundle(_ id: String) -> BundleItem? {
        bundles.first { $0.id == id }
    }

    public func session(_ id: UUID) -> SessionInfo? {
        sessions.first { $0.id == id }
    }

    public func run(_ id: UUID) -> RunInfo? {
        runs.first { $0.id == id }
    }

    // MARK: - Workspace

    /// Applies a store event (`project.changed`, `task.changed`, `task.removed`, `bundle.changed`, `bundle.removed`,
    /// `session.changed`, `session.removed`, `run.changed`); queued while a load runs.
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

    /// The store is loaded and lacks this run: it reloads.
    func reloadIfUnknown(runID: UUID) {
        guard phase == .loaded, run(runID) == nil else { return }
        Task { await reload() }
    }

    /// A result of the request API for this project: inserted when the store does not contain that id yet; an
    /// existing element is never replaced (events bring updates).
    func insertIfAbsent(_ task: TaskItem) {
        guard self.task(task.id) == nil else { return }
        tasks = Self.sortedTasks(tasks + [task])
    }

    func insertIfAbsent(_ session: SessionInfo) {
        guard self.session(session.id) == nil else { return }
        sessions = Self.sortedSessions(sessions + [session])
    }

    func insertIfAbsent(_ run: RunInfo) {
        guard self.run(run.id) == nil else { return }
        runs = Self.trimmedRuns(Self.sortedRuns(runs + [run]))
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
        tasks = Self.sortedTasks(snapshot.tasks)
        bundles = Self.sortedBundles(snapshot.bundles)
        sessions = Self.sortedSessions(snapshot.sessions)
        runs = Self.trimmedRuns(Self.sortedRuns(snapshot.runs))
        phase = .loaded
    }

    // MARK: - Applying events

    private func apply(_ event: ServerEvent) {
        switch event {
        case .projectChanged(let payload):
            project = payload.project
        case .taskChanged(let payload):
            tasks = Self.upsert(payload.task, into: tasks, sorted: Self.sortedTasks)
        case .taskRemoved(let payload):
            tasks.removeAll { $0.id == payload.taskID }
        case .bundleChanged(let payload):
            bundles = Self.upsert(payload.bundle, into: bundles, sorted: Self.sortedBundles)
        case .bundleRemoved(let payload):
            bundles.removeAll { $0.id == payload.bundleID }
        case .sessionChanged(let payload):
            sessions = Self.upsert(payload.session, into: sessions, sorted: Self.sortedSessions)
        case .sessionRemoved(let payload):
            sessions.removeAll { $0.id == payload.sessionID }
        case .runChanged(let payload):
            runs = Self.trimmedRuns(Self.upsert(payload.run, into: runs, sorted: Self.sortedRuns))
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
    static func sortedTasks(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted { lhs, rhs in
            switch (taskNumber(lhs.id), taskNumber(rhs.id)) {
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

    /// By `startedAt`, then id.
    static func sortedRuns(_ runs: [RunInfo]) -> [RunInfo] {
        runs.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt < rhs.startedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The runs trim of a sorted list: while more than 20 runs are kept, the oldest run whose state is not `running`
    /// is dropped; a `running` run is never dropped, so more than 20 can stay.
    static func trimmedRuns(_ runs: [RunInfo]) -> [RunInfo] {
        var runs = runs
        while runs.count > maximumRuns, let index = runs.firstIndex(where: { $0.state != .running }) {
            runs.remove(at: index)
        }
        return runs
    }

    private static let maximumRuns = 20

    /// The number after the last `-` of a task id; nil when there is none.
    private static func taskNumber(_ id: String) -> Int? {
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
