import Foundation

/// A search query (docs/services/search.md §2).
public struct SearchQuery: Sendable, Equatable {
    public let text: String            // the query, white space and newlines trimmed at both ends
    public let words: [String]         // `text` split on white space and newlines; duplicates removed

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var words: [String] = []
        for word in trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        where !words.contains(where: { $0.compare(word, options: SearchMatcher.options) == .orderedSame }) {
            words.append(word)
        }
        self.text = trimmed
        self.words = words
    }

    /// No words.
    public var isEmpty: Bool { words.isEmpty }
}

/// The matcher shared by every platform: matching, ranking, snippets, highlights and the order of results
/// (docs/services/search.md §2).
public enum SearchMatcher {
    /// [.caseInsensitive, .diacriticInsensitive]
    public static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    public static func contains(_ word: String, in text: String) -> Bool {
        text.range(of: word, options: options) != nil
    }

    /// The item's SearchResult.rank (§2.2): 0 exact id match, 1 title match, 2 content match; nil when it does not
    /// match. A query without words matches nothing.
    public static func rank(_ query: SearchQuery, id: String?, title: String, fields: [String]) -> Int? {
        guard !query.isEmpty else { return nil }
        if let id, query.text.compare(id, options: options) == .orderedSame {
            return 0
        }
        if query.words.allSatisfy({ contains($0, in: title) }) {
            return 1
        }
        let texts = [title] + (id.map { [$0] } ?? []) + fields
        if query.words.allSatisfy({ word in texts.contains { contains(word, in: $0) } }) {
            return 2
        }
        return nil
    }

    /// One line around the first match in `text`, with its 1-based line number; nil when no word occurs.
    public static func snippet(_ query: SearchQuery, in text: String) -> (text: String, line: Int)? {
        // 1. The earliest occurrence of any word.
        var earliest: Range<String.Index>?
        for word in query.words {
            if let range = text.range(of: word, options: options),
               earliest.map({ range.lowerBound < $0.lowerBound }) ?? true {
                earliest = range
            }
        }
        guard let match = earliest else { return nil }

        // 2. Its line, from after the previous "\n" to before the next one, and the line number. Line breaks are
        // searched among the Unicode scalars, so that a "\r\n" pair counts as "\n".
        let scalars = text.unicodeScalars
        let before = scalars[..<match.lowerBound]
        let lineStart = before.lastIndex(of: "\n").map { scalars.index(after: $0) } ?? scalars.startIndex
        let lineEnd = scalars[match.lowerBound...].firstIndex(of: "\n") ?? scalars.endIndex
        let lineNumber = 1 + before.filter { $0 == "\n" }.count

        // 3. Trimmed of white space at both ends.
        let characters = Array(String(scalars[lineStart..<lineEnd]))
        var first = 0
        var last = characters.count
        while first < last, characters[first].isWhitespace { first += 1 }
        while last > first, characters[last - 1].isWhitespace { last -= 1 }
        let trimmed = Array(characters[first..<last])

        // 4. At most 160 characters: a window starting 40 characters before the occurrence, not before the line start,
        // and moved left when it would pass the line end.
        guard trimmed.count > snippetLength else { return (String(trimmed), lineNumber) }
        let occurrence = max(0, String(scalars[lineStart..<match.lowerBound]).count - first)
        var windowStart = max(0, occurrence - snippetLead)
        if windowStart + snippetLength > trimmed.count {
            windowStart = trimmed.count - snippetLength
        }
        let windowEnd = windowStart + snippetLength
        var snippet = String(trimmed[windowStart..<windowEnd])
        if windowStart > 0 { snippet = "…" + snippet }
        if windowEnd < trimmed.count { snippet += "…" }
        return (snippet, lineNumber)
    }

    /// Ranges of every occurrence of every word in `text`, merged and sorted.
    public static func highlights(_ query: SearchQuery, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for word in query.words {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: word, options: options, range: searchStart..<text.endIndex) {
                ranges.append(range)
                searchStart = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let previous = merged.last, range.lowerBound <= previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Result order: true when `a` comes before `b` (§2.5).
    public static func precedes(_ a: SearchResult, _ b: SearchResult) -> Bool {
        if a.rank != b.rank {
            return a.rank < b.rank
        }
        switch (a.date, b.date) {
        case let (dateA?, dateB?) where dateA != dateB:
            return dateA > dateB
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            break
        }
        let titleOrder = a.title.localizedStandardCompare(b.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        let keysA = [a.deviceID.uuidString, a.kind.rawValue, a.projectID ?? "", a.itemID, a.ticketID ?? "", a.path ?? ""]
        let keysB = [b.deviceID.uuidString, b.kind.rawValue, b.projectID ?? "", b.itemID, b.ticketID ?? "", b.path ?? ""]
        for (keyA, keyB) in zip(keysA, keysB) where keyA != keyB {
            return keyA < keyB
        }
        return (a.line ?? 0) < (b.line ?? 0)
    }

    private static let snippetLength = 160
    private static let snippetLead = 40
}
