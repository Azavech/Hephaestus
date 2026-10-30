import Foundation
import SwiftUI

/// The kind of a highlighted lexical element; each kind has its color and font in `EditorTheme`.
public enum TokenKind: String, CaseIterable, Sendable {
    case keyword, type, builtin, string, number, comment, attribute, directive
    case key, heading, emphasis, strong, code, link, markup
}

/// One highlighted element of a text.
public struct HighlightToken: Equatable, Sendable {
    /// UTF-16 offsets in the highlighted text.
    public var range: NSRange
    public var kind: TokenKind

    public init(range: NSRange, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Splits a text into highlight tokens with the grammar of its language.
public enum SyntaxHighlighter {
    /// Texts with more UTF-8 bytes than this are not highlighted.
    public static let maximumLength: Int = 524_288

    /// The tokens of `text`, sorted by location, never overlapping, never empty. Text outside every token is plain.
    /// `[]` for `.plain` and for a text whose UTF-8 length is above `maximumLength`.
    public static func tokens(in text: String, language: EditorLanguage) -> [HighlightToken] {
        guard language != .plain, text.utf8.count <= maximumLength else { return [] }
        return tokens(units: Array(text.utf16), language: language)
    }

    /// Runs the grammar of `language` on the UTF-16 code units of a text, without the length check.
    static func tokens(units: [UInt16], language: EditorLanguage) -> [HighlightToken] {
        var tokens: [HighlightToken] = []
        let range = 0..<units.count
        switch language {
        case .swift: SwiftGrammar.scan(units, range: range, into: &tokens)
        case .go: GoGrammar.scan(units, range: range, into: &tokens)
        case .markdown: MarkdownGrammar.scan(units, range: range, into: &tokens)
        case .yaml: YAMLGrammar.scan(units, range: range, into: &tokens)
        case .json: JSONGrammar.scan(units, range: range, into: &tokens)
        case .plain: break
        }
        return ordered(tokens)
    }

    /// `code` with the token colors of `language` as `foregroundColor`; fonts are left to the caller. The language
    /// `plain`, and a code over `maximumLength`, give a string without attributes.
    @MainActor public static func attributedString(_ code: String, language: EditorLanguage) -> AttributedString {
        var result = AttributedString(code)
        for token in tokens(in: code, language: language) {
            guard let range = Range<AttributedString.Index>(token.range, in: result) else { continue }
            #if os(macOS)
            result[range].swiftUI.foregroundColor = Color(nsColor: EditorTheme.color(for: token.kind))
            #else
            result[range].swiftUI.foregroundColor = Color(uiColor: EditorTheme.color(for: token.kind))
            #endif
        }
        return result
    }

    /// Keeps the contract of `tokens(in:language:)`: drops empty tokens and tokens that start before the end of the
    /// previous one.
    private static func ordered(_ tokens: [HighlightToken]) -> [HighlightToken] {
        var result: [HighlightToken] = []
        result.reserveCapacity(tokens.count)
        var end = 0
        for token in tokens where token.range.length > 0 && token.range.location >= end {
            result.append(token)
            end = token.range.location + token.range.length
        }
        return result
    }
}
