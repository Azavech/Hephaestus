import Foundation
import XCTest
@testable import HephClient

final class ANSIStripperTests: XCTestCase {
    private func strip(_ chunks: String...) -> [String] {
        var stripper = ANSIStripper()
        return chunks.map { stripper.strip($0) }
    }

    func testCSI() {
        XCTAssertEqual(strip("a\u{1B}[31mred\u{1B}[0m b\u{1B}[1;32;40m!\u{1B}[?25l"), ["ared b!"])
    }

    func testOSC() {
        XCTAssertEqual(strip("\u{1B}]0;Title\u{07}after"), ["after"])
        XCTAssertEqual(strip("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\"), ["link"])
    }

    func testStrings() {
        XCTAssertEqual(strip("\u{1B}Pq#0;2;0;0;0\u{1B}\\after"), ["after"])
        XCTAssertEqual(strip("\u{1B}X sos \u{1B}\\a\u{1B}^ pm \u{1B}\\b\u{1B}_ apc \u{1B}\\c"), ["abc"])
        // A BEL does not end a DCS string.
        XCTAssertEqual(strip("\u{1B}Pdata\u{07}more\u{1B}\\after"), ["after"])
    }

    func testTwoCharacterEscapes() {
        XCTAssertEqual(strip("\u{1B}7saved\u{1B}8"), ["saved"])
        XCTAssertEqual(strip("\u{1B}(Bcharset\u{1B}=x"), ["charsetx"])
    }

    func testControlCharacters() {
        XCTAssertEqual(strip("a\tb\nc"), ["a\tb\nc"])
        XCTAssertEqual(strip("one\r\ntwo\rthree\n"), ["one\ntwo\nthree\n"])
        XCTAssertEqual(strip("\u{07}x\u{00}y\u{7F}z\u{08}"), ["xyz"])
    }

    func testSplitAcrossChunks() {
        XCTAssertEqual(strip("ab\u{1B}[3", "1mcd"), ["ab", "cd"])
        XCTAssertEqual(strip("ab\u{1B}", "]0;title", "\u{07}cd"), ["ab", "", "cd"])
        XCTAssertEqual(strip("line\r", "\nnext"), ["line", "\nnext"])
        XCTAssertEqual(strip("line\r", "next"), ["line", "\nnext"])
    }

    func testLongPendingSequenceDropped() {
        let long = "\u{1B}]" + String(repeating: "a", count: 300)
        XCTAssertEqual(strip(long, "visible"), ["", "visible"])

        let short = "\u{1B}]" + String(repeating: "a", count: 100)
        XCTAssertEqual(strip(short, "b\u{07}visible"), ["", "visible"])
    }
}
