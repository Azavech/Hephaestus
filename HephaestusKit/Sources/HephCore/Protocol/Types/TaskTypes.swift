import Foundation

// Tasks: the wire types of docs/protocol/types.md, section "Tasks".

/// The status of a task. `allCases` is in the order of the task list sections.
public enum TaskStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case todo = "todo"
    case inProgress = "in_progress"
    case review = "review"
    case done = "done"

    /// The name shown in the UI.
    public var displayName: String {
        switch self {
        case .todo: return "To Do"
        case .inProgress: return "In Progress"
        case .review: return "Review"
        case .done: return "Done"
        }
    }
}

/// A task. A broken task has `id` from its file name, `name` and `description` empty, `status` `todo`, `created` and
/// `updated` equal to the file's modification date, no comments, and `parseError` set to the parser's message.
public struct TaskItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var status: TaskStatus
    public var created: Date
    public var updated: Date
    public var comments: [TaskComment]
    public var parseError: String?

    public init(
        id: String,
        name: String,
        description: String,
        status: TaskStatus,
        created: Date,
        updated: Date,
        comments: [TaskComment],
        parseError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.status = status
        self.created = created
        self.updated = updated
        self.comments = comments
        self.parseError = parseError
    }
}

/// A comment of a task. A comment whose `author` is `Claude` can be deleted but not edited.
public struct TaskComment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var author: String
    public var created: Date
    public var edited: Date?
    public var body: String
    public var attachments: [TaskAttachment]

    public init(
        id: UUID,
        author: String,
        created: Date,
        edited: Date? = nil,
        body: String,
        attachments: [TaskAttachment]
    ) {
        self.id = id
        self.author = author
        self.created = created
        self.edited = edited
        self.body = body
        self.attachments = attachments
    }
}

/// A file stored in `.hephaestus/attachments/<task id>/`.
public struct TaskAttachment: Codable, Sendable, Hashable, Identifiable {
    public var file: String
    public var type: String
    public var size: Int

    public var id: String { file }

    public init(file: String, type: String, size: Int) {
        self.file = file
        self.type = type
        self.size = size
    }
}

/// Changes for `tasks.update`. A `nil` field leaves the value unchanged.
public struct TaskPatch: Codable, Sendable, Hashable {
    public var name: String?
    public var description: String?
    public var status: TaskStatus?

    public init(name: String? = nil, description: String? = nil, status: TaskStatus? = nil) {
        self.name = name
        self.description = description
        self.status = status
    }
}
