import Foundation

/// The Swift grammar: comments, string literals with interpolations, attributes, directives, numbers, keywords and
/// capitalized types.
enum SwiftGrammar {
    static func scan(_ units: [UInt16], range: Range<Int>, into tokens: inout [HighlightToken]) {
        var scanner = CodeScanner(units: units, range: range)
        // Literals and interpolations nest; an explicit stack keeps any nesting depth off the call stack.
        var frames: [Frame] = []
        while !scanner.isAtEnd {
            if case .string(let hashes, let multiline)? = frames.last {
                // Inside a literal: its text continues at the position (the `)` that closed an interpolation).
                let outcome = scanStringContent(
                    &scanner, tokenStart: scanner.position, hashes: hashes, multiline: multiline, tokens: &tokens
                )
                apply(outcome, to: &frames)
                continue
            }
            if scanRule(&scanner, frames: &frames, tokens: &tokens) { continue }
            // No rule matched: the parentheses of an interpolation are counted, then the position moves by one.
            let unit = scanner.units[scanner.position]
            if case .interpolation(let depth)? = frames.last {
                if unit == Unit.leftParen {
                    frames[frames.count - 1] = .interpolation(depth: depth + 1)
                } else if unit == Unit.rightParen {
                    if depth == 0 {
                        // This `)` closes the interpolation and starts the next string token of the literal.
                        frames.removeLast()
                        continue
                    }
                    frames[frames.count - 1] = .interpolation(depth: depth - 1)
                }
            }
            scanner.position += 1
        }
    }

    private enum Frame {
        /// The expression of `\(…)`, with the number of `(` open inside it.
        case interpolation(depth: Int)
        /// A string literal opened with `hashes` `#`.
        case string(hashes: Int, multiline: Bool)
    }

    private enum StringOutcome {
        /// The literal closed, or ended unterminated.
        case ended
        /// An interpolation opened; the literal continues after it.
        case interpolation
    }

    private static func apply(_ outcome: StringOutcome, to frames: inout [Frame]) {
        switch outcome {
        case .ended: frames.removeLast()
        case .interpolation: frames.append(.interpolation(depth: 0))
        }
    }

    // MARK: Rules

    /// Rules 1 to 8, tried in order at the position. Returns false when none matched.
    private static func scanRule(
        _ s: inout CodeScanner, frames: inout [Frame], tokens: inout [HighlightToken]
    ) -> Bool {
        let start = s.position
        let unit = s.units[start]

        // 1. `//` up to the line break.
        if s.matches(lineCommentOpener, at: start) {
            s.position = s.lineEnd(from: start)
            tokens.emit(.comment, start, s.position)
            return true
        }
        // 2. `/*` up to the matching `*/`, nested.
        if s.matches(blockCommentOpener, at: start) {
            s.position = blockCommentEnd(s, from: start)
            tokens.emit(.comment, start, s.position)
            return true
        }
        // 3. A string literal: `n` `#` then `"`.
        if unit == Unit.hash || unit == Unit.quote {
            let quote = s.index(from: start) { $0 == Unit.hash }
            if s.unit(at: quote) == Unit.quote {
                let hashes = quote - start
                let multiline = s.unit(at: quote + 1) == Unit.quote && s.unit(at: quote + 2) == Unit.quote
                s.position = quote + (multiline ? 3 : 1)
                frames.append(.string(hashes: hashes, multiline: multiline))
                let outcome = scanStringContent(
                    &s, tokenStart: start, hashes: hashes, multiline: multiline, tokens: &tokens
                )
                apply(outcome, to: &frames)
                return true
            }
        }
        // 4. `@` and an identifier.
        if unit == Unit.at, let next = s.unit(at: start + 1),
           CodeScanner.isIdentifierStart(next, allowsDollar: true) {
            s.position = identifierEnd(s, from: start + 1)
            tokens.emit(.attribute, start, s.position)
            return true
        }
        // 5. `#` and an identifier.
        if unit == Unit.hash, let next = s.unit(at: start + 1),
           CodeScanner.isIdentifierStart(next, allowsDollar: true) {
            s.position = identifierEnd(s, from: start + 1)
            tokens.emit(.directive, start, s.position)
            return true
        }
        // 6. A number.
        if CodeScanner.isDigit(unit) {
            s.position = numberEnd(s, from: start)
            tokens.emit(.number, start, s.position)
            return true
        }
        // 7. An escaped identifier: `` ` ``, identifier parts, `` ` ``. No token.
        if unit == Unit.backtick {
            let partsEnd = s.index(from: start + 1) { CodeScanner.isIdentifierPart($0, allowsDollar: true) }
            if partsEnd > start + 1, s.unit(at: partsEnd) == Unit.backtick {
                s.position = partsEnd + 1
                return true
            }
        }
        // 8. An identifier.
        if CodeScanner.isIdentifierStart(unit, allowsDollar: true) {
            let end = identifierEnd(s, from: start)
            s.position = end
            if let kind = identifierKind(s, start: start, end: end) {
                tokens.emit(kind, start, end)
            }
            return true
        }
        return false
    }

    /// The end of a nested block comment starting at `start`; the end of the range when unterminated.
    private static func blockCommentEnd(_ s: CodeScanner, from start: Int) -> Int {
        var depth = 0
        var i = start
        while i < s.end {
            if s.matches(blockCommentOpener, at: i) {
                depth += 1
                i += 2
            } else if s.matches(blockCommentCloser, at: i) {
                depth -= 1
                i += 2
                if depth == 0 { return i }
            } else {
                i += 1
            }
        }
        return s.end
    }

    private static func identifierEnd(_ s: CodeScanner, from start: Int) -> Int {
        s.index(from: start) { CodeScanner.isIdentifierPart($0, allowsDollar: true) }
    }

    private static func identifierKind(_ s: CodeScanner, start: Int, end: Int) -> TokenKind? {
        let word = s.units[start..<end]
        let capitalized = CodeScanner.isUppercaseASCII(s.units[start])
        if s.unit(at: start - 1) == Unit.dot {
            if word == selfWord || word == initWord { return .keyword }
            return capitalized ? .type : nil
        }
        if keywords.contains(word) { return .keyword }
        return capitalized ? .type : nil
    }

    /// The end of a number starting with a digit at `start`.
    private static func numberEnd(_ s: CodeScanner, from start: Int) -> Int {
        let isDigitOrUnderscore: (UInt16) -> Bool = { CodeScanner.isDigit($0) || $0 == Unit.underscore }
        if s.units[start] == Unit.zero, let prefix = s.unit(at: start + 1) {
            if prefix == Unit.lowerX {
                let isHexOrUnderscore: (UInt16) -> Bool = { CodeScanner.isHexDigit($0) || $0 == Unit.underscore }
                var i = s.index(from: start + 2, while: isHexOrUnderscore)
                if s.unit(at: i) == Unit.dot, let next = s.unit(at: i + 1), CodeScanner.isHexDigit(next) {
                    i = s.index(from: i + 1, while: isHexOrUnderscore)
                }
                if let p = s.unit(at: i), p == Unit.lowerP || p == Unit.upperP {
                    i += 1
                    if let sign = s.unit(at: i), sign == Unit.plus || sign == Unit.minus { i += 1 }
                    i = s.index(from: i, while: isDigitOrUnderscore)
                }
                return i
            }
            if prefix == Unit.lowerO {
                return s.index(from: start + 2) { ($0 >= Unit.zero && $0 <= Unit.seven) || $0 == Unit.underscore }
            }
            if prefix == Unit.lowerB {
                return s.index(from: start + 2) { $0 == Unit.zero || $0 == Unit.one || $0 == Unit.underscore }
            }
        }
        var i = s.index(from: start, while: isDigitOrUnderscore)
        if s.unit(at: i) == Unit.dot, let next = s.unit(at: i + 1), CodeScanner.isDigit(next) {
            i = s.index(from: i + 1, while: isDigitOrUnderscore)
        }
        if let e = s.unit(at: i), e == Unit.lowerE || e == Unit.upperE {
            var j = i + 1
            if let sign = s.unit(at: j), sign == Unit.plus || sign == Unit.minus { j += 1 }
            if let digit = s.unit(at: j), CodeScanner.isDigit(digit) {
                i = s.index(from: j + 1, while: isDigitOrUnderscore)
            }
        }
        return i
    }

    // MARK: String literals

    /// Scans the text of a string literal from the position, emitting one string token from `tokenStart`: up to the
    /// closing delimiter, up to the `(` of an interpolation, or, unterminated, before the line break (single-line) or
    /// to the end of the text (multi-line).
    private static func scanStringContent(
        _ s: inout CodeScanner, tokenStart: Int, hashes: Int, multiline: Bool, tokens: inout [HighlightToken]
    ) -> StringOutcome {
        let units = s.units
        var i = s.position
        while i < s.end {
            let unit = units[i]
            if unit == Unit.lineFeed && !multiline {
                return finish(&s, tokenStart: tokenStart, end: i, tokens: &tokens, outcome: .ended)
            }
            if unit == Unit.backslash && hasHashes(s, at: i + 1, count: hashes) {
                // An escape: `\` followed by `n` `#`, then `(` opens an interpolation; any other code unit is part
                // of the escape, except the line break that ends a single-line literal.
                let next = i + 1 + hashes
                guard let escaped = s.unit(at: next) else {
                    i = next
                    break
                }
                if escaped == Unit.leftParen {
                    return finish(&s, tokenStart: tokenStart, end: next + 1, tokens: &tokens, outcome: .interpolation)
                }
                if escaped == Unit.lineFeed && !multiline {
                    return finish(&s, tokenStart: tokenStart, end: next, tokens: &tokens, outcome: .ended)
                }
                i = next + 1
                continue
            }
            if unit == Unit.quote {
                if multiline {
                    if s.unit(at: i + 1) == Unit.quote, s.unit(at: i + 2) == Unit.quote,
                       hasHashes(s, at: i + 3, count: hashes) {
                        return finish(&s, tokenStart: tokenStart, end: i + 3 + hashes, tokens: &tokens, outcome: .ended)
                    }
                } else if hasHashes(s, at: i + 1, count: hashes) {
                    return finish(&s, tokenStart: tokenStart, end: i + 1 + hashes, tokens: &tokens, outcome: .ended)
                }
            }
            i += 1
        }
        return finish(&s, tokenStart: tokenStart, end: s.end, tokens: &tokens, outcome: .ended)
    }

    private static func finish(
        _ s: inout CodeScanner, tokenStart: Int, end: Int, tokens: inout [HighlightToken], outcome: StringOutcome
    ) -> StringOutcome {
        let end = min(end, s.end)
        tokens.emit(.string, tokenStart, end)
        s.position = end
        return outcome
    }

    /// Whether `count` `#` are at `index`.
    private static func hasHashes(_ s: CodeScanner, at index: Int, count: Int) -> Bool {
        guard index + count <= s.end else { return false }
        var i = index
        while i < index + count {
            if s.units[i] != Unit.hash { return false }
            i += 1
        }
        return true
    }

    // MARK: Words

    private static let lineCommentOpener = CodeScanner.literal("//")
    private static let blockCommentOpener = CodeScanner.literal("/*")
    private static let blockCommentCloser = CodeScanner.literal("*/")
    private static let selfWord = ArraySlice(CodeScanner.literal("self"))
    private static let initWord = ArraySlice(CodeScanner.literal("init"))

    private static let keywords = CodeScanner.wordSet("""
        actor any as associatedtype async await borrowing break case catch class consuming continue convenience default
        defer deinit didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import
        in indirect infix init inout internal is isolated lazy let macro mutating nil nonisolated nonmutating open operator
        override postfix precedencegroup prefix private protocol public repeat required rethrows return self Self sending set
        some static struct subscript super switch throw throws true try typealias unowned var weak where while willSet Any
        """)
}
