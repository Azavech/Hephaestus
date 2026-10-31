import Foundation
import XCTest
@testable import HephCore

final class SearchMatcherTests: XCTestCase {
    func testInsensitive() {
        XCTAssertTrue(SearchMatcher.contains("cafe", in: "Caf\u{E9}"))
        XCTAssertTrue(SearchMatcher.contains("IPAD", in: "iPad"))
        XCTAssertTrue(SearchMatcher.contains("heph-12", in: "Fixes HEPH-12"))
        XCTAssertFalse(SearchMatcher.contains("ipad", in: "iPhone"))
    }

    func testWords() {
        let query = SearchQuery("  sidebar   ipad sidebar ")
        XCTAssertEqual(query.text, "sidebar   ipad sidebar")
        XCTAssertEqual(query.words, ["sidebar", "ipad"])
        XCTAssertFalse(query.isEmpty)
        XCTAssertEqual(SearchQuery("Caf\u{E9} cafe CAFE").words, ["Caf\u{E9}"])
        XCTAssertTrue(SearchQuery("").isEmpty)
        XCTAssertTrue(SearchQuery(" \n\t ").isEmpty)
    }

    func testAllWordsMatch() {
        let query = SearchQuery("sidebar ipad")
        XCTAssertNotNil(SearchMatcher.rank(query, id: nil, title: "Sidebar breaks on iPad", fields: []))
        XCTAssertNil(SearchMatcher.rank(query, id: nil, title: "Sidebar fix", fields: ["The split view collapses."]))
        // Different words may occur in different fields.
        XCTAssertEqual(SearchMatcher.rank(query, id: nil, title: "Sidebar fix", fields: ["", "Seen on the iPad"]), 2)
    }

    func testRanking() throws {
        let query = SearchQuery("HEPH-12")
        XCTAssertEqual(SearchMatcher.rank(query, id: "HEPH-12", title: "Sidebar breaks on iPad", fields: []), 0)
        XCTAssertEqual(SearchMatcher.rank(query, id: "HEPH-30", title: "Follow-up of heph-12", fields: []), 1)
        XCTAssertEqual(SearchMatcher.rank(query, id: "HEPH-31", title: "Other", fields: ["Related to HEPH-12."]), 2)
        XCTAssertNil(SearchMatcher.rank(query, id: "HEPH-32", title: "Other", fields: ["Unrelated."]))
        // The id is searched as content: "HEPH" matches every ticket of HEPH.
        XCTAssertEqual(SearchMatcher.rank(SearchQuery("HEPH"), id: "HEPH-32", title: "Other", fields: []), 2)

        let device = UUID()
        let older = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-28T10:00:00Z"))
        let newer = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-29T10:00:00Z"))
        func result(_ itemID: String, rank: Int, date: Date?, title: String = "Title") -> SearchResult {
            SearchResult(kind: .tickets, deviceID: device, projectID: "HEPH", itemID: itemID, ticketID: itemID, title: title,
                         snippet: "", rank: rank, date: date)
        }
        let idMatch = result("HEPH-12", rank: 0, date: older)
        let titleMatch = result("HEPH-30", rank: 1, date: newer)
        let contentOld = result("HEPH-31", rank: 2, date: older)
        let contentNew = result("HEPH-33", rank: 2, date: newer)
        let contentUndated = result("HEPH-34", rank: 2, date: nil)
        let shuffled = [contentUndated, contentOld, titleMatch, contentNew, idMatch]
        let sorted = shuffled.sorted(by: SearchMatcher.precedes)
        XCTAssertEqual(sorted.map(\.itemID), ["HEPH-12", "HEPH-30", "HEPH-33", "HEPH-31", "HEPH-34"])

        // Equal rank and date: title with localizedStandardCompare, then the item id.
        let titled2 = result("A", rank: 2, date: nil, title: "Ticket 2")
        let titled10 = result("B", rank: 2, date: nil, title: "Ticket 10")
        XCTAssertTrue(SearchMatcher.precedes(titled2, titled10))
        XCTAssertFalse(SearchMatcher.precedes(titled10, titled2))
        XCTAssertFalse(SearchMatcher.precedes(titled2, titled2))
    }

    func testSnippet() throws {
        let query = SearchQuery("sidebar ipad")
        let text = "First line\n   The iPad sidebar covers the list.  \nThird line"
        let snippet = try XCTUnwrap(SearchMatcher.snippet(query, in: text))
        XCTAssertEqual(snippet.text, "The iPad sidebar covers the list.")
        XCTAssertEqual(snippet.line, 2)
        XCTAssertNil(SearchMatcher.snippet(query, in: "Nothing to see here"))

        // A long line is cut to a 160-character window starting 40 characters before the occurrence.
        let long = String(repeating: "a", count: 100) + "sidebar" + String(repeating: "b", count: 200)
        let cut = try XCTUnwrap(SearchMatcher.snippet(query, in: long))
        XCTAssertEqual(cut.line, 1)
        XCTAssertEqual(cut.text, "…" + String(repeating: "a", count: 40) + "sidebar" + String(repeating: "b", count: 113) + "…")
        // Moved left when it would pass the line end.
        let nearEnd = String(repeating: "a", count: 200) + "sidebar"
        XCTAssertEqual(try XCTUnwrap(SearchMatcher.snippet(query, in: nearEnd)).text,
                       "…" + String(repeating: "a", count: 153) + "sidebar")

        // Highlights: every occurrence of every word, merged and sorted.
        let title = "iPad sidebar, ipadsidebar"
        let ranges = SearchMatcher.highlights(query, in: title)
        XCTAssertEqual(ranges.map { String(title[$0]) }, ["iPad", "sidebar", "ipadsidebar"])
    }
}
