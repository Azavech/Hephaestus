import Foundation

// Skills: the wire types of docs/protocol/types.md, section "Skills".

/// A skill of a Main's library.
public struct SkillSummary: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var modified: Date
    public var problem: String?

    public var id: String { name }

    public init(name: String, description: String, modified: Date, problem: String? = nil) {
        self.name = name
        self.description = description
        self.modified = modified
        self.problem = problem
    }
}

/// A file of a skill folder.
public struct SkillFile: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var size: Int
    public var modified: Date

    public var id: String { path }

    public init(path: String, size: Int, modified: Date) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

/// One entry of a Main's skills index, for synchronization between Mains.
public struct SkillManifest: Codable, Sendable, Hashable {
    public var name: String
    public var modified: Date
    public var deleted: Bool

    public init(name: String, modified: Date, deleted: Bool) {
        self.name = name
        self.modified = modified
        self.deleted = deleted
    }
}
