import Foundation
import XCTest
@testable import HephEditor

final class YAMLHighlighterTests: XCTestCase {
    /// The lines of the YAML example of docs/ui/editor.md.
    private let lines = [
        "id: HEPH   # project",
        "tags: [a, \"b\"]",
        "description: |",
        "  Multi",
        "  line",
        "count: 12",
        "on: true",
        "anchor: &x ~",
    ]

    /// The token table of the example.
    private let expected = [
        Expected("id", .key),
        Expected("HEPH", .string),
        Expected("# project", .comment),
        Expected("tags", .key),
        Expected("a", .string),
        Expected("\"b\"", .string),
        Expected("description", .key),
        Expected("|", .markup),
        Expected("Multi", .string),
        Expected("line", .string),
        Expected("count", .key),
        Expected("12", .number),
        Expected("on", .key),
        Expected("true", .keyword),
        Expected("anchor", .key),
        Expected("&x", .attribute),
        Expected("~", .keyword),
    ]

    func testExample() {
        XCTAssertEqual(tokens(of: lines.joined(separator: "\n")), expected)
    }

    func testCRLF() {
        let text = lines.joined(separator: "\r\n")
        XCTAssertEqual(tokens(of: text), expected)
        XCTAssertEqual(tokens(of: text + "\r\n"), expected)
    }

    /// The text of each token's range and its kind, in order.
    private func tokens(of text: String) -> [Expected] {
        let string = text as NSString
        return SyntaxHighlighter.tokens(in: text, language: .yaml).map {
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
