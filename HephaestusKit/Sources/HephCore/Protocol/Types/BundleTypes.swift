import Foundation

// Bundles: the wire types of docs/protocol/types.md, section "Bundles" (docs/services/bundles.md).

/// The status of a ticket bundle.
public enum BundleStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// Not being worked on.
    case draft
    /// Its coordinator and ticket sessions work on it.
    case running
    /// Every ticket is done; the coordinator waits for the user's OK.
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

/// A ticket of a bundle.
public struct BundleTicket: Codable, Sendable, Hashable, Identifiable {
    public var ticketID: String
    /// The last ticket session the bundle started for this ticket.
    public var sessionID: UUID?

    public var id: String { ticketID }

    public init(ticketID: String, sessionID: UUID? = nil) {
        self.ticketID = ticketID
        self.sessionID = sessionID
    }
}

/// A bundle: a named, ordered group of tickets of one project that Claude works on in parallel.
public struct BundleItem: Codable, Sendable, Hashable, Identifiable {
    /// Bundle id, `<projectID>-B<n>`.
    public var id: String
    public var name: String
    public var status: BundleStatus
    public var created: Date
    public var updated: Date
    /// Branch the ticket branches start from; set when first started.
    public var base: String?
    /// The coordinator session; set when first started.
    public var coordinatorSessionID: UUID?
    /// Its tickets, in order.
    public var tickets: [BundleTicket]

    public init(
        id: String,
        name: String,
        status: BundleStatus,
        created: Date,
        updated: Date,
        base: String? = nil,
        coordinatorSessionID: UUID? = nil,
        tickets: [BundleTicket]
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.created = created
        self.updated = updated
        self.base = base
        self.coordinatorSessionID = coordinatorSessionID
        self.tickets = tickets
    }
}

/// Changes for `bundles.update`. A `nil` field leaves the value unchanged.
public struct BundlePatch: Codable, Sendable, Hashable {
    /// New name, trimmed: not empty, on one line.
    public var name: String?
    /// Replaces the tickets, in order (`draft` and `done` only).
    public var ticketIDs: [String]?

    public init(name: String? = nil, ticketIDs: [String]? = nil) {
        self.name = name
        self.ticketIDs = ticketIDs
    }
}
