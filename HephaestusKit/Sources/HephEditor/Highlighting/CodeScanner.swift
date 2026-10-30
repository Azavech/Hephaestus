import Foundation

/// The code units of a text and a position in a range of them, with the helpers the grammars share: peek, match a
/// literal, consume while a class matches, find the line end. It never reads outside its range.
struct CodeScanner {
    let units: [UInt16]
    /// The first code unit of the scanned range.
    let start: Int
    /// The end of the scanned range (exclusive).
    let end: Int
    var position: Int

    init(units: [UInt16], range: Range<Int>) {
        self.units = units
        start = max(0, range.lowerBound)
        end = min(units.count, range.upperBound)
        position = start
    }

    var isAtEnd: Bool { position >= end }

    /// The code unit at `position + offset`, nil outside the range.
    func peek(_ offset: Int = 0) -> UInt16? {
        unit(at: position + offset)
    }

    /// The code unit at `index`, nil outside the range.
    func unit(at index: Int) -> UInt16? {
        index >= start && index < end ? units[index] : nil
    }

    /// Whether `literal` is at `index`, entirely inside the range.
    func matches(_ literal: [UInt16], at index: Int) -> Bool {
        guard index >= start, index + literal.count <= end else { return false }
        var offset = 0
        while offset < literal.count {
            if units[index + offset] != literal[offset] { return false }
            offset += 1
        }
        return true
    }

    /// Moves past `literal` when it is at the position.
    mutating func match(_ literal: [UInt16]) -> Bool {
        guard matches(literal, at: position) else { return false }
        position += literal.count
        return true
    }

    /// The first index at or after `index` whose code unit does not satisfy `predicate` (the range end at most).
    func index(from index: Int, while predicate: (UInt16) -> Bool) -> Int {
        var i = max(index, start)
        while i < end, predicate(units[i]) { i += 1 }
        return i
    }

    /// Moves the position past the code units that satisfy `predicate`.
    mutating func consume(while predicate: (UInt16) -> Bool) {
        position = index(from: position, while: predicate)
    }

    /// The index of the next line break at or after `index`, or the range end: "up to the line break".
    func lineEnd(from index: Int) -> Int {
        self.index(from: index) { $0 != Unit.lineFeed }
    }

    // MARK: Character classes

    /// `A`–`Z`, `a`–`z`, `_`, any code unit ≥ 0x80; with `allowsDollar` (Swift) also `$`.
    static func isIdentifierStart(_ unit: UInt16, allowsDollar: Bool = false) -> Bool {
        isASCIILetter(unit) || unit == Unit.underscore || unit >= 0x80 || (allowsDollar && unit == Unit.dollar)
    }

    /// An identifier start or `0`–`9`.
    static func isIdentifierPart(_ unit: UInt16, allowsDollar: Bool = false) -> Bool {
        isIdentifierStart(unit, allowsDollar: allowsDollar) || isDigit(unit)
    }

    static func isDigit(_ unit: UInt16) -> Bool {
        unit >= Unit.zero && unit <= Unit.nine
    }

    static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x61 && unit <= 0x66) || (unit >= 0x41 && unit <= 0x46)
    }

    static func isASCIILetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    /// Space or tab.
    static func isBlank(_ unit: UInt16) -> Bool {
        unit == Unit.space || unit == Unit.tab
    }

    /// `A`–`Z`: the first code unit of a "capitalized" identifier.
    static func isUppercaseASCII(_ unit: UInt16) -> Bool {
        unit >= 0x41 && unit <= 0x5A
    }

    /// A letter (Unicode general category L) or a decimal digit. Surrogate halves are neither.
    static func isLetterOrDigit(_ unit: UInt16) -> Bool {
        if unit < 0x80 { return isASCIILetter(unit) || isDigit(unit) }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
            return true
        default:
            return false
        }
    }

    /// `!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`
    static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (unit >= 0x21 && unit <= 0x2F) || (unit >= 0x3A && unit <= 0x40) || (unit >= 0x5B && unit <= 0x60)
            || (unit >= 0x7B && unit <= 0x7E)
    }

    /// The code units of an ASCII literal.
    static func literal(_ text: StaticString) -> [UInt16] {
        text.withUTF8Buffer { $0.map { UInt16($0) } }
    }

    /// A set of words for lookups by slice of the code units.
    static func wordSet(_ words: String) -> Set<ArraySlice<UInt16>> {
        Set(words.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { ArraySlice(Array($0.utf16)) })
    }
}

/// The code units the grammars test, by name.
enum Unit {
    static let tab: UInt16 = 0x09
    static let lineFeed: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let exclamation: UInt16 = 0x21
    static let quote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let dollar: UInt16 = 0x24
    static let percent: UInt16 = 0x25
    static let ampersand: UInt16 = 0x26
    static let apostrophe: UInt16 = 0x27
    static let leftParen: UInt16 = 0x28
    static let rightParen: UInt16 = 0x29
    static let asterisk: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let comma: UInt16 = 0x2C
    static let minus: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let zero: UInt16 = 0x30
    static let one: UInt16 = 0x31
    static let seven: UInt16 = 0x37
    static let nine: UInt16 = 0x39
    static let colon: UInt16 = 0x3A
    static let semicolon: UInt16 = 0x3B
    static let less: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let greater: UInt16 = 0x3E
    static let question: UInt16 = 0x3F
    static let at: UInt16 = 0x40
    static let upperB: UInt16 = 0x42
    static let upperE: UInt16 = 0x45
    static let upperO: UInt16 = 0x4F
    static let upperP: UInt16 = 0x50
    static let upperX: UInt16 = 0x58
    static let leftBracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let rightBracket: UInt16 = 0x5D
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let lowerB: UInt16 = 0x62
    static let lowerE: UInt16 = 0x65
    static let lowerH: UInt16 = 0x68
    static let lowerI: UInt16 = 0x69
    static let lowerO: UInt16 = 0x6F
    static let lowerP: UInt16 = 0x70
    static let lowerX: UInt16 = 0x78
    static let leftBrace: UInt16 = 0x7B
    static let pipe: UInt16 = 0x7C
    static let rightBrace: UInt16 = 0x7D
    static let tilde: UInt16 = 0x7E
}

extension Array where Element == HighlightToken {
    /// Appends a token for the code units `start..<end`; an empty range gives no token.
    mutating func emit(_ kind: TokenKind, _ start: Int, _ end: Int) {
        guard end > start else { return }
        append(HighlightToken(range: NSRange(location: start, length: end - start), kind: kind))
    }
}
