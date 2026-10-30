import Foundation
import XCTest
@testable import HephClient

final class ProjectPathTests: XCTestCase {
    func testSplitLineSuffix() {
        let lines: [(String, String, Int)] = [
            ("docs/a.md#L12", "docs/a.md", 12),
            ("a.swift#L007", "a.swift", 7),
            ("a#L1#L2", "a#L1", 2),
            ("#L5", "", 5),
        ]
        for (item, path, line) in lines {
            let split = ProjectPath.splitLineSuffix(item)
            XCTAssertEqual(split.path, path, item)
            XCTAssertEqual(split.line, line, item)
        }

        let plain = ["a.swift", "a.swift#L", "a.swift#L0", "a.swift#L-3", "a.swift#Lx", "a.swift#L1x",
                     "a.swift#l12", "a.swift#L99999999999999999999"]
        for item in plain {
            let split = ProjectPath.splitLineSuffix(item)
            XCTAssertEqual(split.path, item, item)
            XCTAssertNil(split.line, item)
        }
    }
}
