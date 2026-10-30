import Foundation
import XCTest
@testable import HephEditor

final class GoHighlighterTests: XCTestCase {
    /// The Go example of docs/ui/editor.md (its indentation is tabs).
    private let example = [
        "//go:build darwin",
        "package main",
        "",
        "import \"fmt\"",
        "",
        "// main prints.",
        "func main() {",
        "\ts := `raw",
        "line`",
        "\tr := 'x'",
        "\tfmt.Println(len(s), r, 0x1F, 1.5e3i, nil, Version, MakeThing(), time.Duration)",
        "}",
    ].joined(separator: "\n")

    func testExample() {
        let tokens = SyntaxHighlighter.tokens(in: example, language: .go)
        let text = example as NSString
        let actual = tokens.map { Expected(text.substring(with: $0.range), $0.kind) }
        let expected = [
            Expected("//go:build darwin", .directive),
            Expected("package", .keyword),
            Expected("import", .keyword),
            Expected("\"fmt\"", .string),
            Expected("// main prints.", .comment),
            Expected("func", .keyword),
            Expected("`raw\nline`", .string),
            Expected("'x'", .string),
            Expected("len", .builtin),
            Expected("0x1F", .number),
            Expected("1.5e3i", .number),
            Expected("nil", .keyword),
            Expected("Version", .type),
            Expected("Duration", .type),
        ]
        XCTAssertEqual(actual, expected)
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
