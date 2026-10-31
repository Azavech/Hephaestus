import Foundation

// Search: the wire types of docs/protocol/types.md, section "Search".

/// A kind of searched item.
public enum SearchScope: String, Codable, Sendable, Hashable, CaseIterable {
    case projects
    case tickets
    case comments
    case docs
    case code
    case skills
    case webTabs
    case sessions
    case devices
}

/// One search hit, as produced by a Main.
public struct SearchResult: Codable, Sendable, Hashable {
    public var kind: SearchScope
    public var deviceID: UUID
    public var projectID: String?
    public var itemID: String
    public var ticketID: String?
    public var path: String?
    public var line: Int?
    public var title: String
    public var snippet: String
    public var rank: Int
    public var date: Date?

    public init(
        kind: SearchScope,
        deviceID: UUID,
        projectID: String? = nil,
        itemID: String,
        ticketID: String? = nil,
        path: String? = nil,
        line: Int? = nil,
        title: String,
        snippet: String,
        rank: Int,
        date: Date? = nil
    ) {
        self.kind = kind
        self.deviceID = deviceID
        self.projectID = projectID
        self.itemID = itemID
        self.ticketID = ticketID
        self.path = path
        self.line = line
        self.title = title
        self.snippet = snippet
        self.rank = rank
        self.date = date
    }
}
