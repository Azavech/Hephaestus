import Foundation
import XCTest
@testable import HephEditor

final class MarkdownHighlighterTests: XCTestCase {
    /// The lines of the Markdown example of docs/ui/editor.md.
    private let lines = [
        "---",
        "name: demo",
        "---",
        "# Title",
        "- [x] **done** and `code`, see [docs](a.md)",
    ]

    /// The token table of the example.
    private let expected = [
        Expected("---", .markup),
        Expected("name", .key),
        Expected("demo", .string),
        Expected("---", .markup),
        Expected("# Title", .heading),
        Expected("-", .markup),
        Expected("[x]", .markup),
        Expected("**done**", .strong),
        Expected("`code`", .code),
        Expected("[docs](a.md)", .link),
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
        return SyntaxHighlighter.tokens(in: text, language: .markdown).map {
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
