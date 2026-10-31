import Foundation

// Forge: the wire types of docs/protocol/types.md, section "Forge", filled as docs/forge/pipeline.md says.

/// The state of a feedback item or of a cycle, in pipeline order. Items use every value; cycles use `regenerating` to
/// `failed`.
public enum ForgeStage: String, Codable, Sendable, Hashable, CaseIterable {
    case discussing
    case docsPushed
    case regenerating
    case regenPushed
    case building
    case released
    case done
    case failed
}

/// What started a Forge cycle.
public enum ForgeTrigger: String, Codable, Sendable, Hashable, CaseIterable {
    /// `forge_push_docs` pushed the commits of a ticket or bundle session.
    case tool
    /// `forge.regenerate`.
    case manual
    /// A check found the docs ahead of the code.
    case automatic
}

/// Where a feedback was sent from.
public struct FeedbackContext: Codable, Sendable, Hashable {
    public var deviceID: UUID
    public var deviceName: String
    public var platform: DevicePlatform
    public var appVersion: String
    public var build: Int
    public var docsHash: String
    public var selection: FeedbackSelection

    public init(
        deviceID: UUID,
        deviceName: String,
        platform: DevicePlatform,
        appVersion: String,
        build: Int,
        docsHash: String,
        selection: FeedbackSelection
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.appVersion = appVersion
        self.build = build
        self.docsHash = docsHash
        self.selection = selection
    }
}

/// What the window showed when a feedback was sent.
public struct FeedbackSelection: Codable, Sendable, Hashable {
    public var mainDeviceID: UUID?
    public var projectID: String?
    public var section: String?
    public var item: String?

    public init(mainDeviceID: UUID? = nil, projectID: String? = nil, section: String? = nil, item: String? = nil) {
        self.mainDeviceID = mainDeviceID
        self.projectID = projectID
        self.section = section
        self.item = item
    }
}

/// The Forge settings of the Forge host, with the GitHub repository.
public struct ForgeConfig: Codable, Sendable, Hashable {
    /// The GitHub repository of Hephaestus, `owner/name`: a constant that no setting changes. Every `ForgeConfig` the
    /// Forge host builds has it as `repository`.
    public static let publicRepository = "Azavech/Hephaestus"

    public var sourceProjectID: String
    public var repository: String
    public var branch: String
    public var autoRegenerate: Bool

    public init(sourceProjectID: String, repository: String, branch: String, autoRegenerate: Bool) {
        self.sourceProjectID = sourceProjectID
        self.repository = repository
        self.branch = branch
        self.autoRegenerate = autoRegenerate
    }
}

/// The result of the Forge's last successful check of the repository.
public struct ForgeHead: Codable, Sendable, Hashable {
    public var commit: String
    public var docsHash: String
    public var codeDocsHash: String
    public var checkedAt: Date

    public init(commit: String, docsHash: String, codeDocsHash: String, checkedAt: Date) {
        self.commit = commit
        self.docsHash = docsHash
        self.codeDocsHash = codeDocsHash
        self.checkedAt = checkedAt
    }
}

/// A GitHub Actions run watched by the Forge.
public struct ForgeRun: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var number: Int
    public var url: String
    public var status: String
    public var conclusion: String?
    public var headSHA: String
    public var foundAt: Date
    public var completedAt: Date?

    public init(
        id: Int,
        number: Int,
        url: String,
        status: String,
        conclusion: String? = nil,
        headSHA: String,
        foundAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.number = number
        self.url = url
        self.status = status
        self.conclusion = conclusion
        self.headSHA = headSHA
        self.foundAt = foundAt
        self.completedAt = completedAt
    }
}

/// A release published by CI.
public struct ForgeRelease: Codable, Sendable, Hashable {
    public var tag: String
    public var build: Int
    public var url: String
    public var publishedAt: Date

    public init(tag: String, build: Int, url: String, publishedAt: Date) {
        self.tag = tag
        self.build = build
        self.url = url
        self.publishedAt = publishedAt
    }
}

/// One pass of regeneration, CI and release.
public struct ForgeCycle: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var trigger: ForgeTrigger
    public var state: ForgeStage
    public var failedState: ForgeStage?
    public var error: String?
    public var started: Date
    public var updated: Date
    public var targetCommit: String
    public var sessionID: UUID?
    public var attempts: Int
    public var regenCommit: String?
    public var pushedAt: Date?
    public var run: ForgeRun?
    public var release: ForgeRelease?
    public var itemTicketIDs: [String]

    public init(
        id: UUID,
        trigger: ForgeTrigger,
        state: ForgeStage,
        failedState: ForgeStage? = nil,
        error: String? = nil,
        started: Date,
        updated: Date,
        targetCommit: String,
        sessionID: UUID? = nil,
        attempts: Int,
        regenCommit: String? = nil,
        pushedAt: Date? = nil,
        run: ForgeRun? = nil,
        release: ForgeRelease? = nil,
        itemTicketIDs: [String]
    ) {
        self.id = id
        self.trigger = trigger
        self.state = state
        self.failedState = failedState
        self.error = error
        self.started = started
        self.updated = updated
        self.targetCommit = targetCommit
        self.sessionID = sessionID
        self.attempts = attempts
        self.regenCommit = regenCommit
        self.pushedAt = pushedAt
        self.run = run
        self.release = release
        self.itemTicketIDs = itemTicketIDs
    }
}

/// The pipeline state of one feedback ticket.
public struct ForgeItem: Codable, Sendable, Hashable, Identifiable {
    public var ticketID: String
    public var projectID: String
    public var title: String
    public var state: ForgeStage
    public var feedbackSessionID: UUID
    public var docsCommit: String?
    public var cycleID: UUID?
    public var error: String?
    public var created: Date
    public var updated: Date

    public var id: String { ticketID }

    public init(
        ticketID: String,
        projectID: String,
        title: String,
        state: ForgeStage,
        feedbackSessionID: UUID,
        docsCommit: String? = nil,
        cycleID: UUID? = nil,
        error: String? = nil,
        created: Date,
        updated: Date
    ) {
        self.ticketID = ticketID
        self.projectID = projectID
        self.title = title
        self.state = state
        self.feedbackSessionID = feedbackSessionID
        self.docsCommit = docsCommit
        self.cycleID = cycleID
        self.error = error
        self.created = created
        self.updated = updated
    }
}

/// The result of `forge.status` and the payload of `forge.changed`. When not enabled: `config`, `head`, `cycle`,
/// `latestRelease` and `lastError` are `nil` and `items` is empty.
public struct ForgeState: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var hostDeviceID: UUID
    public var config: ForgeConfig?
    public var appDocsHash: String
    public var head: ForgeHead?
    public var cycle: ForgeCycle?
    public var items: [ForgeItem]
    public var latestRelease: ForgeRelease?
    public var lastError: String?

    public init(
        enabled: Bool,
        hostDeviceID: UUID,
        config: ForgeConfig? = nil,
        appDocsHash: String,
        head: ForgeHead? = nil,
        cycle: ForgeCycle? = nil,
        items: [ForgeItem],
        latestRelease: ForgeRelease? = nil,
        lastError: String? = nil
    ) {
        self.enabled = enabled
        self.hostDeviceID = hostDeviceID
        self.config = config
        self.appDocsHash = appDocsHash
        self.head = head
        self.cycle = cycle
        self.items = items
        self.latestRelease = latestRelease
        self.lastError = lastError
    }
}
