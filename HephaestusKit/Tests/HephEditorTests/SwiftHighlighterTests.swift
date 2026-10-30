import Foundation
import XCTest
@testable import HephEditor

final class SwiftHighlighterTests: XCTestCase {
    /// The Swift example of docs/ui/editor.md.
    private let example = ##"""
        @MainActor final class Greeter: Sendable {
            let name = "Hi \(user.first ?? "you")!" // greet
            /* outer /* inner */ still */ var n = 0x1F + 1_000.5e-3
            let raw = #"a "quoted" \#(name) text"#
        }
        """##

    func testExample() {
        let tokens = SyntaxHighlighter.tokens(in: example, language: .swift)
        let text = example as NSString
        let actual = tokens.map { Expected(text.substring(with: $0.range), $0.kind) }
        let expected = [
            Expected("@MainActor", .attribute),
            Expected("final", .keyword),
            Expected("class", .keyword),
            Expected("Greeter", .type),
            Expected("Sendable", .type),
            Expected("let", .keyword),
            Expected(#""Hi \("#, .string),
            Expected(#""you""#, .string),
            Expected(#")!""#, .string),
            Expected("// greet", .comment),
            Expected("/* outer /* inner */ still */", .comment),
            Expected("var", .keyword),
            Expected("0x1F", .number),
            Expected("1_000.5e-3", .number),
            Expected("let", .keyword),
            Expected(##"#"a "quoted" \#("##, .string),
            Expected(##") text"#"##, .string),
        ]
        XCTAssertEqual(actual, expected)
    }

    func testTooLarge() {
        let line = "let value = \"text\" // comment\n"
        let repetitions = SyntaxHighlighter.maximumLength / line.utf8.count + 1
        let text = String(repeating: line, count: repetitions)
        XCTAssertGreaterThan(text.utf8.count, SyntaxHighlighter.maximumLength)
        XCTAssertEqual(SyntaxHighlighter.tokens(in: text, language: .swift), [])
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
