import Foundation

/// The Go grammar: build directives, comments, raw and interpreted strings, runes, numbers, keywords, predeclared
/// types and functions, and capitalized types.
enum GoGrammar {
    static func scan(_ units: [UInt16], range: Range<Int>, into tokens: inout [HighlightToken]) {
        var s = CodeScanner(units: units, range: range)
        while !s.isAtEnd {
            let start = s.position
            let unit = s.units[start]

            // 1. `//go:` up to the line break.
            if s.matches(directiveOpener, at: start) {
                s.position = s.lineEnd(from: start)
                tokens.emit(.directive, start, s.position)
                continue
            }
            // 2. `//` up to the line break.
            if s.matches(lineCommentOpener, at: start) {
                s.position = s.lineEnd(from: start)
                tokens.emit(.comment, start, s.position)
                continue
            }
            // 3. `/*` up to the first `*/`; unterminated: to the end of the text.
            if s.matches(blockCommentOpener, at: start) {
                var i = start + 2
                while i < s.end, !s.matches(blockCommentCloser, at: i) { i += 1 }
                s.position = min(i + 2, s.end)
                tokens.emit(.comment, start, s.position)
                continue
            }
            // 4. A raw string up to the next `` ` ``; unterminated: to the end of the text.
            if unit == Unit.backtick {
                let close = s.index(from: start + 1) { $0 != Unit.backtick }
                s.position = min(close + 1, s.end)
                tokens.emit(.string, start, s.position)
                continue
            }
            // 5 and 6. An interpreted string or a rune; unterminated: ends before the line break.
            if unit == Unit.quote || unit == Unit.apostrophe {
                s.position = quotedEnd(s, from: start, quote: unit)
                tokens.emit(.string, start, s.position)
                continue
            }
            // 7. A number: a digit, or `.` followed by a digit.
            if CodeScanner.isDigit(unit)
                || (unit == Unit.dot && s.unit(at: start + 1).map(CodeScanner.isDigit) == true) {
                s.position = numberEnd(s, from: start)
                tokens.emit(.number, start, s.position)
                continue
            }
            // 8. An identifier.
            if CodeScanner.isIdentifierStart(unit) {
                let end = s.index(from: start) { CodeScanner.isIdentifierPart($0) }
                s.position = end
                if let kind = identifierKind(s, start: start, end: end) {
                    tokens.emit(kind, start, end)
                }
                continue
            }
            s.position += 1
        }
    }

    /// The end of a `"` string or a `'` rune starting at `start`: after the closing quote; before the line break, or
    /// at the end of the text, when unterminated. `\` escapes the next code unit, but not a line break.
    private static func quotedEnd(_ s: CodeScanner, from start: Int, quote: UInt16) -> Int {
        var i = start + 1
        while i < s.end {
            let unit = s.units[i]
            if unit == Unit.lineFeed { return i }
            if unit == Unit.backslash {
                i += (s.unit(at: i + 1) == Unit.lineFeed) ? 1 : 2
                continue
            }
            if unit == quote { return i + 1 }
            i += 1
        }
        return s.end
    }

    private static func numberEnd(_ s: CodeScanner, from start: Int) -> Int {
        let isDigitOrUnderscore: (UInt16) -> Bool = { CodeScanner.isDigit($0) || $0 == Unit.underscore }
        var i: Int
        let first = s.units[start]
        let prefix = s.unit(at: start + 1)
        if first == Unit.dot {
            i = s.index(from: start + 1, while: isDigitOrUnderscore)
            i = exponentEnd(s, from: i)
        } else if first == Unit.zero, let prefix, prefix == Unit.lowerX || prefix == Unit.upperX {
            let isHexOrUnderscore: (UInt16) -> Bool = { CodeScanner.isHexDigit($0) || $0 == Unit.underscore }
            i = s.index(from: start + 2, while: isHexOrUnderscore)
            if s.unit(at: i) == Unit.dot {
                i = s.index(from: i + 1, while: isHexOrUnderscore)
            }
            if let p = s.unit(at: i), p == Unit.lowerP || p == Unit.upperP {
                i += 1
                if let sign = s.unit(at: i), sign == Unit.plus || sign == Unit.minus { i += 1 }
                i = s.index(from: i, while: isDigitOrUnderscore)
            }
        } else if first == Unit.zero, let prefix, prefix == Unit.lowerB || prefix == Unit.upperB {
            i = s.index(from: start + 2) { $0 == Unit.zero || $0 == Unit.one || $0 == Unit.underscore }
        } else if first == Unit.zero, let prefix, prefix == Unit.lowerO || prefix == Unit.upperO {
            i = s.index(from: start + 2) { ($0 >= Unit.zero && $0 <= Unit.seven) || $0 == Unit.underscore }
        } else {
            i = s.index(from: start, while: isDigitOrUnderscore)
            if s.unit(at: i) == Unit.dot, let next = s.unit(at: i + 1), CodeScanner.isDigit(next) {
                i = s.index(from: i + 1, while: isDigitOrUnderscore)
            }
            i = exponentEnd(s, from: i)
        }
        // A final `i` (imaginary literal) belongs to the number.
        if s.unit(at: i) == Unit.lowerI { i += 1 }
        return i
    }

    /// After an optional `e` or `E` exponent: an optional sign, a digit, then digits and `_`.
    private static func exponentEnd(_ s: CodeScanner, from index: Int) -> Int {
        guard let e = s.unit(at: index), e == Unit.lowerE || e == Unit.upperE else { return index }
        var j = index + 1
        if let sign = s.unit(at: j), sign == Unit.plus || sign == Unit.minus { j += 1 }
        guard let digit = s.unit(at: j), CodeScanner.isDigit(digit) else { return index }
        return s.index(from: j + 1) { CodeScanner.isDigit($0) || $0 == Unit.underscore }
    }

    private static func identifierKind(_ s: CodeScanner, start: Int, end: Int) -> TokenKind? {
        let word = s.units[start..<end]
        let capitalized = CodeScanner.isUppercaseASCII(s.units[start])
        if s.unit(at: start - 1) == Unit.dot {
            return capitalized && !isFollowedByParenthesis(s, end) ? .type : nil
        }
        if keywords.contains(word) { return .keyword }
        if types.contains(word) { return .type }
        if functions.contains(word) { return .builtin }
        return capitalized && !isFollowedByParenthesis(s, end) ? .type : nil
    }

    /// Whether the next code unit after `index`, blanks skipped, on the same line, is `(`.
    private static func isFollowedByParenthesis(_ s: CodeScanner, _ index: Int) -> Bool {
        s.unit(at: s.index(from: index, while: CodeScanner.isBlank)) == Unit.leftParen
    }

    // MARK: Words

    private static let directiveOpener = CodeScanner.literal("//go:")
    private static let lineCommentOpener = CodeScanner.literal("//")
    private static let blockCommentOpener = CodeScanner.literal("/*")
    private static let blockCommentCloser = CodeScanner.literal("*/")

    /// The keywords, and `true`, `false`, `iota`, `nil`.
    private static let keywords = CodeScanner.wordSet("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map
        package range return select struct switch type var true false iota nil
        """)

    private static let types = CodeScanner.wordSet("""
        any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string
        uint uint8 uint16 uint32 uint64 uintptr
        """)

    private static let functions = CodeScanner.wordSet("""
        append cap clear close complex copy delete imag len make max min new panic print println real recover
        """)
}
