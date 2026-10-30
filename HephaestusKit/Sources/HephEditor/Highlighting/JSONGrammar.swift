import Foundation

/// The JSON grammar: keys, strings, numbers and the literals `true`, `false` and `null`.
enum JSONGrammar {
    static func scan(_ units: [UInt16], range: Range<Int>, into tokens: inout [HighlightToken]) {
        var s = CodeScanner(units: units, range: range)
        while !s.isAtEnd {
            let start = s.position
            let unit = s.units[start]
            // 1. A string: a key when the next code unit that is neither a blank, a `\r` nor a line break is `:`.
            if unit == Unit.quote {
                s.position = stringEnd(s, from: start)
                let next = s.index(from: s.position) {
                    CodeScanner.isBlank($0) || $0 == Unit.lineFeed || $0 == Unit.carriageReturn
                }
                tokens.emit(s.unit(at: next) == Unit.colon ? .key : .string, start, s.position)
                continue
            }
            // 2. A number: an optional `-` and a digit.
            if CodeScanner.isDigit(unit)
                || (unit == Unit.minus && s.unit(at: start + 1).map(CodeScanner.isDigit) == true) {
                s.position = numberEnd(s, from: start)
                tokens.emit(.number, start, s.position)
                continue
            }
            // 3 and 4. A run of letters: `true`, `false` and `null` are keywords.
            if CodeScanner.isASCIILetter(unit) {
                s.position = s.index(from: start, while: CodeScanner.isASCIILetter)
                if literals.contains(s.units[start..<s.position]) {
                    tokens.emit(.keyword, start, s.position)
                }
                continue
            }
            s.position += 1
        }
    }

    /// After the closing `"`; before the line break, or at the end of the text, when unterminated. `\` escapes the
    /// next code unit, but not a line break.
    private static func stringEnd(_ s: CodeScanner, from start: Int) -> Int {
        var i = start + 1
        while i < s.end {
            let unit = s.units[i]
            if unit == Unit.lineFeed { return i }
            if unit == Unit.backslash {
                i += (s.unit(at: i + 1) == Unit.lineFeed) ? 1 : 2
                continue
            }
            if unit == Unit.quote { return i + 1 }
            i += 1
        }
        return s.end
    }

    /// An optional `-`; `0` or a digit 1–9 followed by digits; optionally `.` and digits; optionally `e` or `E`, an
    /// optional sign and digits.
    private static func numberEnd(_ s: CodeScanner, from start: Int) -> Int {
        var i = start
        if s.units[i] == Unit.minus { i += 1 }
        if s.unit(at: i) == Unit.zero {
            i += 1
        } else {
            i = s.index(from: i, while: CodeScanner.isDigit)
        }
        if s.unit(at: i) == Unit.dot, let next = s.unit(at: i + 1), CodeScanner.isDigit(next) {
            i = s.index(from: i + 1, while: CodeScanner.isDigit)
        }
        if let e = s.unit(at: i), e == Unit.lowerE || e == Unit.upperE {
            var j = i + 1
            if let sign = s.unit(at: j), sign == Unit.plus || sign == Unit.minus { j += 1 }
            if let digit = s.unit(at: j), CodeScanner.isDigit(digit) {
                i = s.index(from: j, while: CodeScanner.isDigit)
            }
        }
        return i
    }

    private static let literals = CodeScanner.wordSet("true false null")
}
