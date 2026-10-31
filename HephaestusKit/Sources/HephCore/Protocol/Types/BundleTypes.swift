import Foundation

// Bundles: the wire types of docs/protocol/types.md, section "Bundles" (docs/services/bundles.md).

/// The status of a task bundle.
public enum BundleStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// Not being worked on.
    case draft
    /// Its coordinator and task sessions work on it.
    case running
    /// Every task is done; the coordinator waits for the user's OK.
    case review
    /// Its work was brought in and its worktrees removed.
    case done

    /// The name shown in the UI.
    public var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .running: return "Running"
        case .review: return "Review"
        case .done: return "Done"
        }
    }
}

/// A task of a bundle.
public struct BundleTask: Codable, Sendable, Hashable, Identifiable {
    public var taskID: String
    /// The last task session the bundle started for this task.
    public var sessionID: UUID?

    public var id: String { taskID }

    public init(taskID: String, sessionID: UUID? = nil) {
        self.taskID = taskID
        self.sessionID = sessionID
    }
}

/// A bundle: a named, ordered group of tasks of one project that Claude works on in parallel.
public struct BundleItem: Codable, Sendable, Hashable, Identifiable {
    /// Bundle id, `<projectID>-B<n>`.
    public var id: String
    public var name: String
    public var status: BundleStatus
    public var created: Date
    public var updated: Date
    /// Branch the task branches start from; set when first started.
    public var base: String?
    /// The coordinator session; set when first started.
    public var coordinatorSessionID: UUID?
    /// Its tasks, in order.
    public var tasks: [BundleTask]

    public init(
        id: String,
        name: String,
        status: BundleStatus,
        created: Date,
        updated: Date,
        base: String? = nil,
        coordinatorSessionID: UUID? = nil,
        tasks: [BundleTask]
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.created = created
        self.updated = updated
        self.base = base
        self.coordinatorSessionID = coordinatorSessionID
        self.tasks = tasks
    }
}

/// Changes for `bundles.update`. A `nil` field leaves the value unchanged.
public struct BundlePatch: Codable, Sendable, Hashable {
    /// New name, trimmed: not empty, on one line.
    public var name: String?
    /// Replaces the tasks, in order (`draft` and `done` only).
    public var taskIDs: [String]?

    public init(name: String? = nil, taskIDs: [String]? = nil) {
        self.name = name
        self.taskIDs = taskIDs
    }
}
