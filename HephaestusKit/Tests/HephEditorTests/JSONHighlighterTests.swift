import Foundation
import XCTest
@testable import HephEditor

final class JSONHighlighterTests: XCTestCase {
    /// The JSON example of docs/ui/editor.md.
    private let example = #"{"name": "Hephaestus", "build": 12, "ok": true, "x": null, "v": -1.5e3}"#

    func testExample() {
        let expected = [
            Expected(#""name""#, .key),
            Expected(#""Hephaestus""#, .string),
            Expected(#""build""#, .key),
            Expected("12", .number),
            Expected(#""ok""#, .key),
            Expected("true", .keyword),
            Expected(#""x""#, .key),
            Expected("null", .keyword),
            Expected(#""v""#, .key),
            Expected("-1.5e3", .number),
        ]
        XCTAssertEqual(tokens(of: example), expected)
    }

    func testKeyBeforeCRLF() {
        XCTAssertEqual(tokens(of: "{\"a\"\r\n: 1}"), [Expected(#""a""#, .key), Expected("1", .number)])
    }

    /// The text of each token's range and its kind, in order.
    private func tokens(of text: String) -> [Expected] {
        let string = text as NSString
        return SyntaxHighlighter.tokens(in: text, language: .json).map {
            Expected(string.substring(with: $0.range), $0.kind)
        }
    }

    private struct Expected: Equatable, CustomStringConvertible {
        let text: String
        let kind: TokenKind

        init(_ text: String, _ kind: TokenKind) {
            self.text = text
            self.kind = kind
        }

        var description: String { "\(text) (\(kind.rawValue))" }
    }
}
