import Foundation

/// The Markdown grammar, read line by line: front matter (YAML), fenced code blocks, headings, thematic breaks, block
/// markers and inline elements. A line ends before its `\n`, or at the end of the text, and a `\r` just before that end
/// is not part of the line: the line ending is never part of a token, and no rule sees it.
enum MarkdownGrammar {
    static func scan(_ units: [UInt16], range: Range<Int>, into tokens: inout [HighlightToken]) {
        var scanner = MarkdownScanner(s: CodeScanner(units: units, range: range))
        scanner.run(into: &tokens)
    }
}

private struct MarkdownScanner {
    let s: CodeScanner
    /// The fence character and length of the open fenced code block.
    var fence: (unit: UInt16, count: Int)?

    init(s: CodeScanner) {
        self.s = s
    }

    var units: [UInt16] { s.units }

    mutating func run(into tokens: inout [HighlightToken]) {
        var lineStart = scanFrontMatter(into: &tokens) ?? s.start
        while lineStart < s.end {
            let line = line(from: lineStart)
            scanLine(line.start, line.end, into: &tokens)
            lineStart = line.next
        }
    }

    /// A line of the text, without its line ending.
    private struct Line {
        let start: Int
        /// Before the `\n` that ends the line, or the end of the text, and before a `\r` just ahead of that end.
        let end: Int
        /// The start of the next line.
        let next: Int
    }

    /// The line that starts at `start`.
    private func line(from start: Int) -> Line {
        let lineBreak = s.lineEnd(from: start)
        let end = lineBreak > start && units[lineBreak - 1] == Unit.carriageReturn ? lineBreak - 1 : lineBreak
        return Line(start: start, end: end, next: lineBreak + 1)
    }

    // MARK: 1. Front matter

    /// When the first line is `---` (trailing blanks allowed) and a later line is `---` or `...`: both delimiter lines
    /// are `markup` and the lines between them are tokenized with the YAML grammar. Returns the start of the line after
    /// the closing one, nil when the text has no front matter.
    private func scanFrontMatter(into tokens: inout [HighlightToken]) -> Int? {
        let opening = line(from: s.start)
        guard s.matches(Self.dashes, at: opening.start),
              s.index(from: opening.start + 3, while: CodeScanner.isBlank) == opening.end
        else { return nil }
        var lineStart = opening.next
        while lineStart < s.end {
            let closing = line(from: lineStart)
            if closing.end - closing.start == 3,
               s.matches(Self.dashes, at: closing.start) || s.matches(Self.dots, at: closing.start) {
                tokens.emit(.markup, opening.start, opening.end)
                scanYAML(from: opening.next, to: closing.start, into: &tokens)
                tokens.emit(.markup, closing.start, closing.end)
                return closing.next
            }
            lineStart = closing.next
        }
        return nil
    }

    /// The lines from `start` to `end` tokenized with the YAML grammar. The grammar reads the lines alone, each
    /// followed by a `\n`, so no `\r` of a line ending reaches it; its token offsets are moved back to the text.
    private func scanYAML(from start: Int, to end: Int, into tokens: inout [HighlightToken]) {
        var yaml: [UInt16] = []
        /// The index in the text of each code unit of `yaml`.
        var origin: [Int] = []
        var lineStart = start
        while lineStart < end {
            let line = line(from: lineStart)
            yaml.append(contentsOf: units[line.start..<line.end])
            origin.append(contentsOf: line.start..<line.end)
            yaml.append(Unit.lineFeed)
            origin.append(line.end)
            lineStart = line.next
        }
        var yamlTokens: [HighlightToken] = []
        YAMLGrammar.scan(yaml, range: 0..<yaml.count, into: &yamlTokens)
        for token in yamlTokens where token.range.length > 0 && NSMaxRange(token.range) <= origin.count {
            tokens.emit(token.kind, origin[token.range.location], origin[NSMaxRange(token.range) - 1] + 1)
        }
    }

    // MARK: Lines

    private mutating func scanLine(_ lineStart: Int, _ lineEnd: Int, into tokens: inout [HighlightToken]) {
        // 2. Inside a fenced code block: every non-empty line is one code token; the closing fence ends the block.
        if let open = fence {
            tokens.emit(.code, lineStart, lineEnd)
            if isClosingFence(lineStart, lineEnd, open) { fence = nil }
            return
        }
        // 3. An opening fence.
        if let opening = openingFence(lineStart, lineEnd) {
            tokens.emit(.code, lineStart, lineEnd)
            fence = opening
            return
        }
        // 4. An ATX heading.
        if isATXHeading(from: lineStart, to: lineEnd, maximumIndent: 3) {
            tokens.emit(.heading, lineStart, lineEnd)
            return
        }
        // 5. A thematic break or a setext underline.
        if isThematicBreak(lineStart, lineEnd) {
            tokens.emit(.markup, lineStart, lineEnd)
            return
        }
        // 6. Block markers.
        var position = lineStart
        var hasMarker = false
        while true {
            let quote = indexAfterSpaces(from: position, to: lineEnd, maximum: 3)
            guard quote < lineEnd, units[quote] == Unit.greater else { break }
            tokens.emit(.markup, quote, quote + 1)
            position = quote + 1
            if position < lineEnd, CodeScanner.isBlank(units[position]) { position += 1 }
            hasMarker = true
        }
        let marker = s.index(from: position, while: CodeScanner.isBlank)
        if let markerEnd = listMarkerEnd(marker, lineEnd) {
            tokens.emit(.markup, marker, markerEnd)
            position = markerEnd
            hasMarker = true
            if let box = taskBoxEnd(after: markerEnd, lineEnd) {
                tokens.emit(.markup, markerEnd + 1, box)
                position = box
            }
        }
        if hasMarker, isATXHeading(from: position, to: lineEnd, maximumIndent: nil) {
            tokens.emit(.heading, position, lineEnd)
            return
        }
        // 7. Inline elements.
        scanInlines(from: position, lineStart: lineStart, lineEnd: lineEnd, into: &tokens)
    }

    private func indexAfterSpaces(from index: Int, to lineEnd: Int, maximum: Int) -> Int {
        var i = index
        while i < lineEnd, i - index < maximum, units[i] == Unit.space { i += 1 }
        return i
    }

    private func openingFence(_ lineStart: Int, _ lineEnd: Int) -> (unit: UInt16, count: Int)? {
        let first = indexAfterSpaces(from: lineStart, to: lineEnd, maximum: 3)
        guard first < lineEnd else { return nil }
        let unit = units[first]
        guard unit == Unit.backtick || unit == Unit.tilde else { return nil }
        var runEnd = first
        while runEnd < lineEnd, units[runEnd] == unit { runEnd += 1 }
        guard runEnd - first >= 3 else { return nil }
        if unit == Unit.backtick {
            var i = runEnd
            while i < lineEnd {
                if units[i] == Unit.backtick { return nil }
                i += 1
            }
        }
        return (unit, runEnd - first)
    }

    private func isClosingFence(_ lineStart: Int, _ lineEnd: Int, _ open: (unit: UInt16, count: Int)) -> Bool {
        let first = indexAfterSpaces(from: lineStart, to: lineEnd, maximum: 3)
        var runEnd = first
        while runEnd < lineEnd, units[runEnd] == open.unit { runEnd += 1 }
        guard runEnd - first >= open.count else { return false }
        var i = runEnd
        while i < lineEnd, CodeScanner.isBlank(units[i]) { i += 1 }
        return i == lineEnd
    }

    /// Up to `maximumIndent` spaces (any number when nil), 1 to 6 `#`, then a blank or the end of the line.
    private func isATXHeading(from start: Int, to lineEnd: Int, maximumIndent: Int?) -> Bool {
        let first = indexAfterSpaces(from: start, to: lineEnd, maximum: maximumIndent ?? Int.max)
        var i = first
        while i < lineEnd, i - first < 7, units[i] == Unit.hash { i += 1 }
        let count = i - first
        guard count >= 1, count <= 6 else { return false }
        return i == lineEnd || CodeScanner.isBlank(units[i])
    }

    /// With its blanks removed, the line is at least 3 times the same character among `-`, `*`, `_`, `=`.
    private func isThematicBreak(_ lineStart: Int, _ lineEnd: Int) -> Bool {
        var character: UInt16?
        var count = 0
        var i = lineStart
        while i < lineEnd {
            let unit = units[i]
            i += 1
            if CodeScanner.isBlank(unit) { continue }
            guard unit == Unit.minus || unit == Unit.asterisk || unit == Unit.underscore || unit == Unit.equals else {
                return false
            }
            if let character, character != unit { return false }
            character = unit
            count += 1
        }
        return count >= 3
    }

    /// `-`, `*` or `+`, or 1 to 9 digits followed by `.` or `)`, then a blank or the end of the line.
    private func listMarkerEnd(_ start: Int, _ lineEnd: Int) -> Int? {
        guard start < lineEnd else { return nil }
        let unit = units[start]
        var end: Int
        if unit == Unit.minus || unit == Unit.asterisk || unit == Unit.plus {
            end = start + 1
        } else {
            var i = start
            while i < lineEnd, i - start < 9, CodeScanner.isDigit(units[i]) { i += 1 }
            guard i > start, i < lineEnd, units[i] == Unit.dot || units[i] == Unit.rightParen else { return nil }
            end = i + 1
        }
        guard end == lineEnd || CodeScanner.isBlank(units[end]) else { return nil }
        return end
    }

    /// After a list marker and one blank: `[ ]`, `[x]` or `[X]` followed by a blank or the end of the line.
    private func taskBoxEnd(after markerEnd: Int, _ lineEnd: Int) -> Int? {
        let open = markerEnd + 1
        guard open + 3 <= lineEnd, CodeScanner.isBlank(units[markerEnd]), units[open] == Unit.leftBracket,
              units[open + 1] == Unit.space || units[open + 1] == Unit.lowerX || units[open + 1] == Unit.upperX,
              units[open + 2] == Unit.rightBracket else { return nil }
        let end = open + 3
        guard end == lineEnd || CodeScanner.isBlank(units[end]) else { return nil }
        return end
    }

    // MARK: 7. Inline elements

    private func scanInlines(from start: Int, lineStart: Int, lineEnd: Int, into tokens: inout [HighlightToken]) {
        var i = start
        while i < lineEnd {
            let unit = units[i]
            // `\` and an ASCII punctuation character: skipped.
            if unit == Unit.backslash, i + 1 < lineEnd, CodeScanner.isASCIIPunctuation(units[i + 1]) {
                i += 2
                continue
            }
            // A link reference definition: the whole line.
            if i == lineStart, unit == Unit.leftBracket,
               let close = closing(from: i, open: Unit.leftBracket, close: Unit.rightBracket, lineEnd),
               close + 1 < lineEnd, units[close + 1] == Unit.colon {
                tokens.emit(.link, lineStart, lineEnd)
                return
            }
            // A code span.
            if unit == Unit.backtick {
                var runEnd = i
                while runEnd < lineEnd, units[runEnd] == Unit.backtick { runEnd += 1 }
                let count = runEnd - i
                if let closeStart = closingCodeRun(from: runEnd, count: count, lineEnd) {
                    tokens.emit(.code, i, closeStart + count)
                    i = closeStart + count
                } else {
                    i = runEnd
                }
                continue
            }
            // A link or an image.
            if unit == Unit.exclamation || unit == Unit.leftBracket, let end = linkEnd(from: i, lineEnd) {
                tokens.emit(.link, i, end)
                i = end
                continue
            }
            // An autolink.
            if unit == Unit.less, let end = autolinkEnd(from: i, lineEnd) {
                tokens.emit(.link, i, end)
                i = end
                continue
            }
            // A bare URL.
            if unit == Unit.lowerH, i == lineStart || !CodeScanner.isLetterOrDigit(units[i - 1]),
               let end = bareURLEnd(from: i, lineEnd) {
                tokens.emit(.link, i, end)
                i = end
                continue
            }
            if unit == Unit.asterisk || unit == Unit.underscore {
                if let end = strongEnd(from: i, lineStart: lineStart, lineEnd: lineEnd) {
                    tokens.emit(.strong, i, end)
                    i = end
                    continue
                }
                if let end = emphasisEnd(from: i, lineStart: lineStart, lineEnd: lineEnd) {
                    tokens.emit(.emphasis, i, end)
                    i = end
                    continue
                }
            }
            i += 1
        }
    }

    /// The start of the next run of exactly `count` backticks on the line.
    private func closingCodeRun(from start: Int, count: Int, _ lineEnd: Int) -> Int? {
        var i = start
        while i < lineEnd {
            guard units[i] == Unit.backtick else {
                i += 1
                continue
            }
            var runEnd = i
            while runEnd < lineEnd, units[runEnd] == Unit.backtick { runEnd += 1 }
            if runEnd - i == count { return i }
            i = runEnd
        }
        return nil
    }

    /// The index of the `close` that balances the `open` at `start`, on the line; escaped characters do not count.
    private func closing(from start: Int, open: UInt16, close: UInt16, _ lineEnd: Int) -> Int? {
        var depth = 0
        var i = start
        while i < lineEnd {
            let unit = units[i]
            if unit == Unit.backslash, i + 1 < lineEnd, CodeScanner.isASCIIPunctuation(units[i + 1]) {
                i += 2
                continue
            }
            if unit == open {
                depth += 1
            } else if unit == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// An optional `!`, then `[` text `]` followed by `(` destination `)` or by `[` label `]`.
    private func linkEnd(from start: Int, _ lineEnd: Int) -> Int? {
        var i = start
        if units[i] == Unit.exclamation { i += 1 }
        guard i < lineEnd, units[i] == Unit.leftBracket,
              let textClose = closing(from: i, open: Unit.leftBracket, close: Unit.rightBracket, lineEnd),
              textClose + 1 < lineEnd else { return nil }
        let next = textClose + 1
        if units[next] == Unit.leftParen,
           let close = closing(from: next, open: Unit.leftParen, close: Unit.rightParen, lineEnd) {
            return close + 1
        }
        if units[next] == Unit.leftBracket,
           let close = closing(from: next, open: Unit.leftBracket, close: Unit.rightBracket, lineEnd) {
            return close + 1
        }
        return nil
    }

    /// `<` followed by `http://`, `https://` or `mailto:`, up to `>`, with no blank inside.
    private func autolinkEnd(from start: Int, _ lineEnd: Int) -> Int? {
        let next = start + 1
        guard s.matches(Self.http, at: next) || s.matches(Self.https, at: next) || s.matches(Self.mailto, at: next)
        else { return nil }
        var i = next
        while i < lineEnd, units[i] != Unit.greater {
            if CodeScanner.isBlank(units[i]) { return nil }
            i += 1
        }
        return i < lineEnd ? i + 1 : nil
    }

    /// `http://` or `https://` up to a blank or `<`, trailing punctuation left out.
    private func bareURLEnd(from start: Int, _ lineEnd: Int) -> Int? {
        guard s.matches(Self.http, at: start) || s.matches(Self.https, at: start) else { return nil }
        var end = start
        while end < lineEnd, !CodeScanner.isBlank(units[end]), units[end] != Unit.less { end += 1 }
        while end > start, Self.trailingURLUnits.contains(units[end - 1]) { end -= 1 }
        return end
    }

    /// `**` or `__` followed by a non-blank, up to the next same pair on the line that follows a non-blank. A `__`
    /// opens only when the code unit before it is neither a letter nor a digit.
    private func strongEnd(from start: Int, lineStart: Int, lineEnd: Int) -> Int? {
        let unit = units[start]
        guard start + 2 < lineEnd, units[start + 1] == unit, !CodeScanner.isBlank(units[start + 2]) else { return nil }
        if unit == Unit.underscore, start > lineStart, CodeScanner.isLetterOrDigit(units[start - 1]) { return nil }
        var i = start + 3
        while i + 1 < lineEnd {
            if units[i] == unit, units[i + 1] == unit, !CodeScanner.isBlank(units[i - 1]) { return i + 2 }
            i += 1
        }
        return nil
    }

    /// A single `*` or `_` followed by a non-blank, up to the next single same character on the line that follows a
    /// non-blank. With `_`, the code unit before the opening and the one after the closing are neither letters nor
    /// digits.
    private func emphasisEnd(from start: Int, lineStart: Int, lineEnd: Int) -> Int? {
        let unit = units[start]
        guard start + 1 < lineEnd else { return nil }
        let next = units[start + 1]
        guard next != unit, !CodeScanner.isBlank(next) else { return nil }
        if start > lineStart {
            let previous = units[start - 1]
            if previous == unit { return nil }
            if unit == Unit.underscore, CodeScanner.isLetterOrDigit(previous) { return nil }
        }
        var i = start + 2
        while i < lineEnd {
            if units[i] == unit {
                let previous = units[i - 1]
                let isSingle = previous != unit && (i + 1 == lineEnd || units[i + 1] != unit)
                if isSingle, !CodeScanner.isBlank(previous) {
                    let isWordBoundary = unit != Unit.underscore || i + 1 == lineEnd
                        || !CodeScanner.isLetterOrDigit(units[i + 1])
                    if isWordBoundary { return i + 1 }
                }
            }
            i += 1
        }
        return nil
    }

    // MARK: Literals

    private static let dashes = CodeScanner.literal("---")
    private static let dots = CodeScanner.literal("...")
    private static let http = CodeScanner.literal("http://")
    private static let https = CodeScanner.literal("https://")
    private static let mailto = CodeScanner.literal("mailto:")
    /// Left out at the end of a bare URL: `.`, `,`, `:`, `;`, `!`, `?`, `)`, `'`, `"`.
    private static let trailingURLUnits: Set<UInt16> = [
        Unit.dot, Unit.comma, Unit.colon, Unit.semicolon, Unit.exclamation, Unit.question, Unit.rightParen,
        Unit.apostrophe, Unit.quote,
    ]
}
