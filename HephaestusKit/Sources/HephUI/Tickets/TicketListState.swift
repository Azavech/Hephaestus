import Foundation
import HephCore
import Observation

/// A section of the ticket list: the tickets of one status, or the broken tickets (docs/ui/tickets.md, "Sections").
struct TicketListSection: Identifiable {
    enum Kind: Hashable {
        case status(TicketStatus)
        case broken
    }

    let kind: Kind
    let tickets: [TicketItem]

    var id: Kind { kind }
}

/// The filter and sort settings of the ticket list of one window (docs/ui/tickets.md, "Filter and sort") and the selection
/// of its rows ("Multi-selection"), in the state of its `TicketsView`: they are kept while the Tickets section of the same
/// project is shown, and reset when the window shows another section or selects another project (the shell gives every
/// project its own `TicketsView`).
@MainActor @Observable
final class TicketListState {
    enum Sort: Hashable, CaseIterable {
        case number
        case lastUpdated

        var title: String {
            switch self {
            case .number:
                return "Number"
            case .lastUpdated:
                return "Last Updated"
            }
        }
    }

    /// The statuses shown; broken tickets ignore it.
    var statuses: Set<TicketStatus> = Set(TicketStatus.allCases)
    var sort: Sort = .number
    /// The text of the search field.
    var text = ""
    /// The selected rows: ticket ids, or one bundle id.
    var selectedIDs: Set<String> = []
    /// Compact width: the Select mode (`EditMode.active`) is on.
    var isSelecting = false

    /// Every setting has its default value.
    var isDefault: Bool {
        statuses == Set(TicketStatus.allCases) && sort == .number && text.isEmpty
    }

    /// Restores the defaults (Clear Filter).
    func reset() {
        statuses = Set(TicketStatus.allCases)
        sort = .number
        text = ""
    }

    /// The sections of `tickets` (in the order of `store.tickets`) after filtering and sorting: the statuses in
    /// `TicketStatus.allCases` order, then Broken; a section without ticket is left out. A broken ticket is only in Broken.
    func sections(of tickets: [TicketItem]) -> [TicketListSection] {
        let words = SearchQuery(text).words
        let shown = sorted(tickets.filter { matches($0, words: words) })
        var sections: [TicketListSection] = []
        for status in TicketStatus.allCases {
            let items = shown.filter { $0.parseError == nil && $0.status == status }
            if !items.isEmpty {
                sections.append(TicketListSection(kind: .status(status), tickets: items))
            }
        }
        let broken = shown.filter { $0.parseError != nil }
        if !broken.isEmpty {
            sections.append(TicketListSection(kind: .broken, tickets: broken))
        }
        return sections
    }

    /// The bundles of `bundles` whose id or name holds every word of the text, most recently updated first
    /// (`byLastUpdate`); the status filter and the sort do not apply.
    func shownBundles(of bundles: [BundleItem], tickets: [TicketItem]) -> [BundleItem] {
        let words = SearchQuery(text).words
        return Self.byLastUpdate(bundles, tickets: tickets).filter { bundle in
            words.allSatisfy { word in
                [bundle.id, bundle.name].contains { SearchMatcher.contains(word, in: $0) }
            }
        }
    }

    /// The order of the Bundles section, whatever the Sort setting: update time descending, ties by number descending.
    /// A bundle's update time is the latest of its own `updated` and the `updated` of its tickets found in `tickets`
    /// (a deleted ticket does not count).
    nonisolated static func byLastUpdate(_ bundles: [BundleItem], tickets: [TicketItem]) -> [BundleItem] {
        let ticketUpdates = Dictionary(tickets.map { ($0.id, $0.updated) }, uniquingKeysWith: max)
        func updateTime(_ bundle: BundleItem) -> Date {
            bundle.tickets.compactMap { ticketUpdates[$0.ticketID] }.reduce(bundle.updated, max)
        }
        return bundles
            .map { (bundle: $0, updated: updateTime($0), number: BundleID($0.id)?.number ?? 0) }
            .sorted { lhs, rhs in
                if lhs.updated != rhs.updated {
                    return lhs.updated > rhs.updated
                }
                if lhs.number != rhs.number {
                    return lhs.number > rhs.number
                }
                return lhs.bundle.id > rhs.bundle.id
            }
            .map(\.bundle)
    }

    /// The tickets of `tickets` whose id, name or description holds every word of `text`, the text rule of the filter;
    /// the Add Tickets sheet of a bundle uses it.
    static func tickets(_ tickets: [TicketItem], matching text: String) -> [TicketItem] {
        let words = SearchQuery(text).words
        return tickets.filter { ticket in
            words.allSatisfy { word in
                [ticket.id, ticket.name, ticket.description].contains { SearchMatcher.contains(word, in: $0) }
            }
        }
    }

    // MARK: - Selection

    /// The `selection.item` that `selectedIDs` gives: the id when one is selected, else nil.
    var selectedItem: String? {
        selectedIDs.count == 1 ? selectedIDs.first : nil
    }

    /// Applies a change of the list's selection and returns the new `selection.item`. Only tickets are selected
    /// together: a change that adds a bundle id leaves that bundle id alone, and a selection of several rows holds
    /// neither a bundle nor a broken ticket.
    func select(_ ids: Set<String>, isBroken: (String) -> Bool) -> String? {
        let added = ids.subtracting(selectedIDs)
        if let bundleID = added.sorted().first(where: Self.isBundleID) {
            selectedIDs = [bundleID]
        } else if ids.count > 1 {
            selectedIDs = ids.filter { !Self.isBundleID($0) && !isBroken($0) }
        } else {
            selectedIDs = ids
        }
        return selectedItem
    }

    /// `selection.item` was set from elsewhere: the selection becomes that id alone.
    func follow(item: String?) {
        guard item != selectedItem else { return }
        selectedIDs = item.map { [$0] } ?? []
    }

    /// The selected ticket ids among `tickets`, broken tickets left out, by ticket number.
    func selectedTicketIDs(in tickets: [TicketItem]) -> [String] {
        tickets.filter { selectedIDs.contains($0.id) && $0.parseError == nil }.map(\.id)
    }

    /// A bundle id never looks like a ticket id (docs/services/bundles.md, "Bundle id").
    nonisolated static func isBundleID(_ id: String) -> Bool {
        BundleID(id) != nil
    }

    /// Every word of the query occurs, case- and diacritic-insensitive, in the ticket's id, name or description; a broken
    /// ticket ignores the status filter and is matched on its id and parse error.
    private func matches(_ ticket: TicketItem, words: [String]) -> Bool {
        let fields: [String]
        if let parseError = ticket.parseError {
            fields = [ticket.id, parseError]
        } else {
            guard statuses.contains(ticket.status) else { return false }
            fields = [ticket.id, ticket.name, ticket.description]
        }
        return words.allSatisfy { word in
            fields.contains { SearchMatcher.contains(word, in: $0) }
        }
    }

    /// Number: the order of `store.tickets` (ascending ticket number). Last Updated: `updated` descending, ties by number
    /// descending.
    private func sorted(_ tickets: [TicketItem]) -> [TicketItem] {
        switch sort {
        case .number:
            return tickets
        case .lastUpdated:
            return tickets.sorted { lhs, rhs in
                if lhs.updated != rhs.updated {
                    return lhs.updated > rhs.updated
                }
                let lhsNumber = Self.number(of: lhs.id)
                let rhsNumber = Self.number(of: rhs.id)
                if lhsNumber != rhsNumber {
                    return lhsNumber > rhsNumber
                }
                return lhs.id > rhs.id
            }
        }
    }

    /// Ticket ids by ticket number, ascending.
    nonisolated static func sortedByNumber(_ ticketIDs: [String]) -> [String] {
        ticketIDs.sorted { lhs, rhs in
            let lhsNumber = number(of: lhs)
            let rhsNumber = number(of: rhs)
            return lhsNumber != rhsNumber ? lhsNumber < rhsNumber : lhs < rhs
        }
    }

    /// The integer after the last `-` of a ticket id; 0 when there is none.
    private nonisolated static func number(of ticketID: String) -> Int {
        guard let dash = ticketID.lastIndex(of: "-") else { return 0 }
        return Int(ticketID[ticketID.index(after: dash)...]) ?? 0
    }
}
