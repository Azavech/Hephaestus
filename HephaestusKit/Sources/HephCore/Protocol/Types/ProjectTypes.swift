import Foundation

// Projects: the wire types of docs/protocol/types.md, section "Projects".

/// A project in a Main's project tree.
public struct ProjectSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var deviceID: UUID
    public var rootPath: String
    public var children: [ProjectSummary]
    public var migrating: Bool
    public var parseError: String?
    public var pendingPermissionCount: Int

    public init(
        id: String,
        name: String,
        description: String? = nil,
        deviceID: UUID,
        rootPath: String,
        children: [ProjectSummary],
        migrating: Bool,
        parseError: String? = nil,
        pendingPermissionCount: Int
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.deviceID = deviceID
        self.rootPath = rootPath
        self.children = children
        self.migrating = migrating
        self.parseError = parseError
        self.pendingPermissionCount = pendingPermissionCount
    }
}

/// The content of `.hephaestus/project.yml` plus where it lives.
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var created: Date
    public var code: String
    public var docs: String
    public var ticketCounter: Int
    public var feedbackCounter: Int
    public var subprojects: [String]
    public var webTabs: [WebTab]
    public var skills: [String]
    public var claude: ClaudeDefaults
    public var deviceID: UUID
    public var rootPath: String
    public var migrating: Bool
    public var parseError: String?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        created: Date,
        code: String,
        docs: String,
        ticketCounter: Int,
        feedbackCounter: Int,
        subprojects: [String],
        webTabs: [WebTab],
        skills: [String],
        claude: ClaudeDefaults,
        deviceID: UUID,
        rootPath: String,
        migrating: Bool,
        parseError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.created = created
        self.code = code
        self.docs = docs
        self.ticketCounter = ticketCounter
        self.feedbackCounter = feedbackCounter
        self.subprojects = subprojects
        self.webTabs = webTabs
        self.skills = skills
        self.claude = claude
        self.deviceID = deviceID
        self.rootPath = rootPath
        self.migrating = migrating
        self.parseError = parseError
    }
}

/// The `claude` block of project.yml. An absent block is a `ClaudeDefaults` with both fields `nil`.
public struct ClaudeDefaults: Codable, Sendable, Hashable {
    public var model: String?
    public var permissionMode: PermissionMode?

    public init(model: String? = nil, permissionMode: PermissionMode? = nil) {
        self.model = model
        self.permissionMode = permissionMode
    }
}

/// Changes for `projects.update`. A `nil` field leaves the value unchanged.
public struct ProjectPatch: Codable, Sendable, Hashable {
    public var name: String?
    public var description: String?
    public var skills: [String]?
    public var claude: ClaudeDefaults?

    public init(
        name: String? = nil,
        description: String? = nil,
        skills: [String]? = nil,
        claude: ClaudeDefaults? = nil
    ) {
        self.name = name
        self.description = description
        self.skills = skills
        self.claude = claude
    }
}

/// A web tab of a project.
public struct WebTab: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: String
    public var locked: Bool

    public init(id: UUID, title: String, url: String, locked: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.locked = locked
    }
}

/// Changes for `tabs.update`. A `nil` field leaves the value unchanged.
public struct WebTabPatch: Codable, Sendable, Hashable {
    public var url: String?
    public var title: String?
    public var locked: Bool?

    public init(url: String? = nil, title: String? = nil, locked: Bool? = nil) {
        self.url = url
        self.title = title
        self.locked = locked
    }
}
