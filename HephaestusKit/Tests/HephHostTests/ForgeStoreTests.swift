#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// The renaming of the old members of forge.json (docs/forge/pipeline.md, "forge.json"):
/// `ForgeService.renameTaskMembers(_:)` alone.
final class ForgeStoreTests: XCTestCase {
    func testRenamesTaskMembers() throws {
        var object = try jsonObject(#"{"version": 1, "cycle": {"itemTaskIDs": ["HEPH-F14"]}, "items": [{"taskID": "HEPH-F14"}]}"#)
        XCTAssertTrue(ForgeService.renameTaskMembers(&object))
        let cycle = try XCTUnwrap(object["cycle"] as? [String: Any])
        XCTAssertEqual(cycle["itemTicketIDs"] as? [String], ["HEPH-F14"])
        XCTAssertNil(cycle["itemTaskIDs"])
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["ticketID"] as? String, "HEPH-F14")
        XCTAssertNil(items.first?["taskID"])
    }

    func testNewNamesKept() throws {
        var object = try jsonObject(#"{"version": 1, "items": [{"taskID": "HEPH-F1", "ticketID": "HEPH-F2"}]}"#)
        XCTAssertTrue(ForgeService.renameTaskMembers(&object))
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["ticketID"] as? String, "HEPH-F2")
        XCTAssertNil(items.first?["taskID"])
    }

    func testNothingToRename() throws {
        // The forge.json example of docs/forge/pipeline.md.
        let example = """
            {
              "version": 1,
              "cycle": {"id": "5D0E…", "trigger": "tool", "state": "building", "started": "2026-10-29T21:20:00.000Z", "…": "…"},
              "items": [{"ticketID": "HEPH-F14", "projectID": "HEPH", "title": "Feedback: Sidebar breaks on iPad", "state": "building", "…": "…"}],
              "latestRelease": {"tag": "build-41", "build": 41, "url": "https://github.com/Azavech/Hephaestus/releases/tag/build-41", "publishedAt": "2026-10-28T10:02:11.000Z"},
              "trustedHead": "9c1e…"
            }
            """
        for text in [example, #"{"version": 1, "trustedHead": "9c1e…"}"#] {
            var object = try jsonObject(text)
            XCTAssertFalse(ForgeService.renameTaskMembers(&object), text)
            XCTAssertEqual(object as NSDictionary, try jsonObject(text) as NSDictionary, text)
        }
    }

    // MARK: - Helpers

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
#endif
