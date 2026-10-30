import Foundation

/// The YAML grammar, read line by line, with two states carried between lines: an open block scalar and an open
/// quoted scalar. Lines end as in Markdown: a `\r` just before the `\n` or the end of the text is not part of the
/// line.
enum YAMLGrammar {
    static func scan(_ units: [UInt16], range: Range<Int>, into tokens: inout [HighlightToken]) {
        var scanner = YAMLScanner(s: CodeScanner(units: units, range: range))
        var lineStart = scanner.s.start
        while lineStart < scanner.s.end {
            let lineBreak = scanner.s.lineEnd(from: lineStart)
            let lineEnd = lineBreak > lineStart && units[lineBreak - 1] == Unit.carriageReturn
                ? lineBreak - 1 : lineBreak
            scanner.scanLine(lineStart, lineEnd, into: &tokens)
            lineStart = lineBreak + 1
        }
    }
}

private struct YAMLScanner {
    let s: CodeScanner
    /// The indentation of the line that opened the block scalar still open.
    var blockScalarIndent: Int?
    /// The quote of the quoted scalar still open at the end of the previous line, and the indices of its tokens.
    var openQuote: UInt16?
    var openQuoteTokens: [Int] = []

    init(s: CodeScanner) {
        self.s = s
    }

    var units: [UInt16] { s.units }

    mutating func scanLine(_ lineStart: Int, _ lineEnd: Int, into tokens: inout [HighlightToken]) {
        let contentStart = s.index(from: lineStart, while: CodeScanner.isBlank)
        let indent = contentStart - lineStart

        // 1. Block scalar content.
        if let openIndent = blockScalarIndent {
            if contentStart == lineEnd { return }
            if indent > openIndent {
                tokens.emit(.string, contentStart, lineEnd)
                return
            }
            blockScalarIndent = nil
        }

        var line = LineState(start: lineStart, end: lineEnd, indent: indent)
        if let quote = openQuote {
            // 2. A quoted scalar open at the end of the previous line continues from the start of the line.
            let (end, closed) = quotedEnd(from: lineStart, quote: quote, lineEnd)
            appendQuoteToken(lineStart, end, into: &tokens)
            guard closed else { return }
            if isKey(after: end, lineEnd) {
                for index in openQuoteTokens { tokens[index].kind = .key }
            }
            openQuote = nil
            openQuoteTokens = []
            line.position = end
            line.isAtValue = false
        } else if lineStart < lineEnd, units[lineStart] == Unit.percent {
            // 3. A directive line.
            tokens.emit(.directive, lineStart, lineEnd)
            return
        } else if s.matches(Self.dashes, at: lineStart) || s.matches(Self.dots, at: lineStart),
                  lineStart + 3 == lineEnd || CodeScanner.isBlank(units[lineStart + 3]) {
            // 3. A document marker; the rest of the line follows rule 4.
            tokens.emit(.directive, lineStart, lineStart + 3)
            line.position = lineStart + 3
        } else {
            line.position = contentStart
        }
        scanRest(&line, into: &tokens)
    }

    private struct LineState {
        let start: Int
        let end: Int
        let indent: Int
        var position = 0
        var flowDepth = 0
        /// First on the line, or after `: ` or `- `: where `|` and `>` open a block scalar.
        var isAtValue = true

        init(start: Int, end: Int, indent: Int) {
            self.start = start
            self.end = end
            self.indent = indent
        }
    }

    /// 4. From the position to the end of the line, left to right.
    private mutating func scanRest(_ line: inout LineState, into tokens: inout [HighlightToken]) {
        let lineEnd = line.end
        while line.position < lineEnd {
            let i = line.position
            let unit = units[i]
            if CodeScanner.isBlank(unit) {
                line.position += 1
                continue
            }
            // A comment.
            if unit == Unit.hash, i == line.start || CodeScanner.isBlank(units[i - 1]) {
                tokens.emit(.comment, i, lineEnd)
                return
            }
            // A sequence entry.
            if unit == Unit.minus, i + 1 == lineEnd || CodeScanner.isBlank(units[i + 1]) {
                tokens.emit(.markup, i, i + 1)
                line.position = i + 1
                line.isAtValue = true
                continue
            }
            // A quoted scalar.
            if unit == Unit.quote || unit == Unit.apostrophe {
                let (end, closed) = quotedEnd(from: i + 1, quote: unit, lineEnd)
                guard closed else {
                    openQuote = unit
                    openQuoteTokens = []
                    appendQuoteToken(i, lineEnd, into: &tokens)
                    return
                }
                tokens.emit(isKey(after: end, lineEnd) ? .key : .string, i, end)
                line.position = end
                line.isAtValue = false
                continue
            }
            // An anchor, an alias or a tag.
            if unit == Unit.ampersand || unit == Unit.asterisk || unit == Unit.exclamation,
               i + 1 < lineEnd, !CodeScanner.isBlank(units[i + 1]) {
                var end = i + 1
                while end < lineEnd, !CodeScanner.isBlank(units[end]) { end += 1 }
                tokens.emit(.attribute, i, end)
                line.position = end
                line.isAtValue = false
                continue
            }
            // A block scalar indicator.
            if unit == Unit.pipe || unit == Unit.greater, line.isAtValue {
                var end = i + 1
                while end < lineEnd,
                      units[end] == Unit.plus || units[end] == Unit.minus || CodeScanner.isDigit(units[end]) {
                    end += 1
                }
                if end == lineEnd || CodeScanner.isBlank(units[end]) || units[end] == Unit.hash {
                    tokens.emit(.markup, i, end)
                    blockScalarIndent = line.indent
                    line.position = end
                    line.isAtValue = false
                    continue
                }
            }
            // Flow indicators: no token.
            if unit == Unit.leftBracket || unit == Unit.leftBrace {
                line.flowDepth += 1
                line.position += 1
                line.isAtValue = false
                continue
            }
            if unit == Unit.rightBracket || unit == Unit.rightBrace {
                line.flowDepth = max(0, line.flowDepth - 1)
                line.position += 1
                line.isAtValue = false
                continue
            }
            if unit == Unit.comma {
                line.position += 1
                line.isAtValue = false
                continue
            }
            if unit == Unit.colon {
                line.position += 1
                line.isAtValue = line.position == lineEnd || CodeScanner.isBlank(units[line.position])
                continue
            }
            // A plain scalar.
            let end = plainScalarEnd(from: i, line)
            var trimmed = end
            while trimmed > i, CodeScanner.isBlank(units[trimmed - 1]) { trimmed -= 1 }
            let kind: TokenKind = isKey(after: trimmed, lineEnd) ? .key : plainKind(units[i..<trimmed])
            tokens.emit(kind, i, trimmed)
            line.position = end
            line.isAtValue = false
        }
    }

    /// Records a token of the open quoted scalar, whose kind is decided when the scalar closes.
    private mutating func appendQuoteToken(_ start: Int, _ end: Int, into tokens: inout [HighlightToken]) {
        let count = tokens.count
        tokens.emit(.string, start, end)
        if tokens.count > count { openQuoteTokens.append(count) }
    }

    /// The end of a quoted scalar whose text starts at `start`: after the closing quote, or the end of the line when
    /// it stays open. In `"`, `\` escapes the next code unit; in `'`, `''` is an escaped quote.
    private func quotedEnd(from start: Int, quote: UInt16, _ lineEnd: Int) -> (end: Int, closed: Bool) {
        var i = start
        while i < lineEnd {
            let unit = units[i]
            if quote == Unit.quote, unit == Unit.backslash {
                i += 2
                continue
            }
            if unit == quote {
                if quote == Unit.apostrophe, i + 1 < lineEnd, units[i + 1] == Unit.apostrophe {
                    i += 2
                    continue
                }
                return (i + 1, true)
            }
            i += 1
        }
        return (lineEnd, false)
    }

    /// Up to the first of: the end of the line, ` #`, a `:` followed by a blank or the end of the line, and, in a
    /// flow collection, `,`, `]` or `}`.
    private func plainScalarEnd(from start: Int, _ line: LineState) -> Int {
        var i = start
        while i < line.end {
            let unit = units[i]
            if CodeScanner.isBlank(unit), i + 1 < line.end, units[i + 1] == Unit.hash { break }
            if unit == Unit.colon, i + 1 == line.end || CodeScanner.isBlank(units[i + 1]) { break }
            if line.flowDepth > 0, unit == Unit.comma || unit == Unit.rightBracket || unit == Unit.rightBrace { break }
            i += 1
        }
        return max(i, start + 1)
    }

    /// Whether, after blanks, `:` follows, then a blank, the end of the line, `,`, `]` or `}`.
    private func isKey(after end: Int, _ lineEnd: Int) -> Bool {
        var i = end
        while i < lineEnd, CodeScanner.isBlank(units[i]) { i += 1 }
        guard i < lineEnd, units[i] == Unit.colon else { return false }
        let next = i + 1
        guard next < lineEnd else { return true }
        let unit = units[next]
        return CodeScanner.isBlank(unit) || unit == Unit.comma || unit == Unit.rightBracket || unit == Unit.rightBrace
    }

    // MARK: Plain scalar kinds

    private func plainKind(_ text: ArraySlice<UInt16>) -> TokenKind {
        if Self.keywords.contains(text) { return .keyword }
        return Self.isNumber(text) ? .number : .string
    }

    /// `[-+]?[0-9][0-9_]*(\.[0-9_]*)?([eE][-+]?[0-9]+)?`, `0x[0-9a-fA-F_]+`, `0o[0-7_]+`, `[-+]?\.(inf|Inf|INF)` or
    /// `\.(nan|NaN|NAN)`.
    private static func isNumber(_ text: ArraySlice<UInt16>) -> Bool {
        let units = Array(text)
        let count = units.count
        guard count > 0 else { return false }
        if count > 2, units[0] == Unit.zero, units[1] == Unit.lowerX {
            return units[2...].allSatisfy { CodeScanner.isHexDigit($0) || $0 == Unit.underscore }
        }
        if count > 2, units[0] == Unit.zero, units[1] == Unit.lowerO {
            return units[2...].allSatisfy { ($0 >= Unit.zero && $0 <= Unit.seven) || $0 == Unit.underscore }
        }
        if nan.contains(text) { return true }
        var i = 0
        if units[i] == Unit.plus || units[i] == Unit.minus { i += 1 }
        if i < count, units[i] == Unit.dot {
            return infinity.contains(units[(i + 1)...])
        }
        guard i < count, CodeScanner.isDigit(units[i]) else { return false }
        i += 1
        while i < count, CodeScanner.isDigit(units[i]) || units[i] == Unit.underscore { i += 1 }
        if i < count, units[i] == Unit.dot {
            i += 1
            while i < count, CodeScanner.isDigit(units[i]) || units[i] == Unit.underscore { i += 1 }
        }
        if i < count, units[i] == Unit.lowerE || units[i] == Unit.upperE {
            i += 1
            if i < count, units[i] == Unit.plus || units[i] == Unit.minus { i += 1 }
            guard i < count, CodeScanner.isDigit(units[i]) else { return false }
            while i < count, CodeScanner.isDigit(units[i]) { i += 1 }
        }
        return i == count
    }

    private static let dashes = CodeScanner.literal("---")
    private static let dots = CodeScanner.literal("...")
    private static let keywords = CodeScanner.wordSet("true True TRUE false False FALSE null Null NULL ~")
    private static let infinity = CodeScanner.wordSet("inf Inf INF")
    private static let nan = CodeScanner.wordSet(".nan .NaN .NAN")
}
