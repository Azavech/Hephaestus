import Foundation
import XCTest
@testable import HephCore

final class MigrationJournalTests: XCTestCase {
    func testRoundTrip() throws {
        let appSupport = AppSupport(root: try makeTemporaryDirectory())
        let now = try date("2026-10-29T21:15:00.000Z")
        let source = MigrationJournalEntry(
            migrationID: try uuid("6F1A2B3C-4D5E-4F60-8A7B-9C0D1E2F3A4B"), projectID: "HEPH",
            rootPath: "/Users/user/Developer/Hephaestus", targetDeviceID: try uuid("2D4F6A8C-1B3E-4D5F-9A7C-6E8B0D2F4A1C"),
            sourceDeviceID: nil, state: .transferring, updatedAt: try date("2026-10-29T21:12:40.512Z"))
        let received = MigrationJournalEntry(
            migrationID: try uuid("0C9D8E7F-6A5B-4C3D-9E2F-1A0B9C8D7E6F"), projectID: "API",
            rootPath: "/Users/user/Developer/API", targetDeviceID: nil,
            sourceDeviceID: try uuid("9B8A7C6D-5E4F-4A3B-8C2D-1E0F9A8B7C6D"), state: .received,
            updatedAt: try date("2026-10-20T09:03:11.007Z"))

        try MigrationJournal.save([source, received], appSupport, now: now)
        XCTAssertEqual(MigrationJournal.load(appSupport, now: now), [source, received])

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: appSupport.migrationsFile))
        let objects = try XCTUnwrap(json as? [[String: Any]])
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(Set(objects[0].keys), ["migrationID", "projectID", "rootPath", "targetDeviceID", "state", "updatedAt"])
        XCTAssertEqual(Set(objects[1].keys), ["migrationID", "projectID", "rootPath", "sourceDeviceID", "state", "updatedAt"])
        XCTAssertEqual(objects[0]["migrationID"] as? String, "6F1A2B3C-4D5E-4F60-8A7B-9C0D1E2F3A4B")
        XCTAssertEqual(objects[0]["state"] as? String, "transferring")
        XCTAssertEqual(objects[0]["updatedAt"] as? String, "2026-10-29T21:12:40.512Z")
        XCTAssertEqual(objects[1]["state"] as? String, "received")

        try MigrationJournal.save([], appSupport, now: now)
        let empty = try JSONSerialization.jsonObject(with: Data(contentsOf: appSupport.migrationsFile))
        XCTAssertEqual((empty as? [Any])?.count, 0)
    }

    func testReceivedRetention() throws {
        let appSupport = AppSupport(root: try makeTemporaryDirectory())
        let now = try date("2026-10-29T21:00:00.000Z")
        let day: TimeInterval = 86_400
        func entry(_ state: MigrationJournalState, daysAgo: Double) -> MigrationJournalEntry {
            MigrationJournalEntry(migrationID: UUID(), projectID: "HEPH", rootPath: "/Users/user/Developer/Hephaestus",
                                  targetDeviceID: state == .received ? nil : UUID(),
                                  sourceDeviceID: state == .received ? UUID() : nil, state: state,
                                  updatedAt: now.addingTimeInterval(-daysAgo * day))
        }
        let expired = entry(.received, daysAgo: 31)
        let recent = entry(.received, daysAgo: 29)
        let committing = entry(.committing, daysAgo: 40)
        try JSONFile.write([expired, recent, committing], to: appSupport.migrationsFile)

        XCTAssertEqual(MigrationJournal.load(appSupport, now: now), [recent, committing])
    }

    func testMissingOrUnreadable() throws {
        let appSupport = AppSupport(root: try makeTemporaryDirectory())
        XCTAssertEqual(MigrationJournal.load(appSupport), [])
        try Data("{".utf8).write(to: appSupport.migrationsFile)
        XCTAssertEqual(MigrationJournal.load(appSupport), [])
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(WireCoding.parseDate(text))
    }

    private func uuid(_ text: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: text))
    }
}
