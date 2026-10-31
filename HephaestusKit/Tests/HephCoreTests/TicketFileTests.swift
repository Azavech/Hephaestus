import Foundation
import XCTest
import Yams
@testable import HephCore

final class TicketFileTests: XCTestCase {
    /// `.hephaestus/tickets/HEPH-12.yml` of docs/data/ticket-yml.md, exactly as the app writes it.
    static let example = """
        id: HEPH-12
        name: Sidebar breaks on iPad
        description: |-
          When the iPad rotates to portrait, the sidebar covers the ticket list.

          Steps:
          1. Open a project.
          2. Rotate the iPad.
        status: in_progress
        created: 2026-10-29T21:04:00Z
        updated: 2026-10-29T22:10:00Z
        comments:
        - id: 0B1E5C2A-7F3D-4E9B-8A61-2C4D6E8F0A1B
          author: Sam's iPad
          created: 2026-10-29T21:05:00Z
          edited: 2026-10-29T21:06:00Z
          body: Screenshot of the overlap.
          attachments:
          - file: screenshot.png
            type: image/png
            size: 123456
        - id: 5D9A3C7E-1B2F-4A6D-9C8E-7F0A1B2C3D4E
          author: Claude
          created: 2026-10-29T22:10:00Z
          body: |-
            Fixed in `SidebarView.swift`: the split view collapses below 700 pt.
            Status set to review.

        """

    /// The new ticket example of docs/data/ticket-yml.md.
    static let newTicket = """
        id: HEPH-13
        name: Add a Skills shortcut
        status: todo
        created: 2026-10-30T08:00:00Z
        updated: 2026-10-30T08:00:00Z
        comments: []

        """

    private let id12 = TicketID(projectID: "HEPH", number: 12)

    func testDecodeExample() throws {
        let file = try TicketFile.decode(Self.example, fileID: id12)
        XCTAssertEqual(file.id, "HEPH-12")
        XCTAssertEqual(file.name, "Sidebar breaks on iPad")
        XCTAssertEqual(file.description, """
            When the iPad rotates to portrait, the sidebar covers the ticket list.

            Steps:
            1. Open a project.
            2. Rotate the iPad.
            """)
        XCTAssertEqual(file.status, .inProgress)
        XCTAssertEqual(file.created, try date("2026-10-29T21:04:00Z"))
        XCTAssertEqual(file.updated, try date("2026-10-29T22:10:00Z"))
        XCTAssertEqual(file.comments.count, 2)

        let first = file.comments[0]
        XCTAssertEqual(first.id, UUID(uuidString: "0B1E5C2A-7F3D-4E9B-8A61-2C4D6E8F0A1B"))
        XCTAssertEqual(first.author, "Sam's iPad")
        XCTAssertEqual(first.created, try date("2026-10-29T21:05:00Z"))
        XCTAssertEqual(first.edited, try date("2026-10-29T21:06:00Z"))
        XCTAssertEqual(first.body, "Screenshot of the overlap.")
        XCTAssertEqual(first.attachments, [TicketAttachment(file: "screenshot.png", type: "image/png", size: 123456)])

        let second = file.comments[1]
        XCTAssertEqual(second.id, UUID(uuidString: "5D9A3C7E-1B2F-4A6D-9C8E-7F0A1B2C3D4E"))
        XCTAssertEqual(second.author, "Claude")
        XCTAssertNil(second.edited)
        XCTAssertEqual(second.body, """
            Fixed in `SidebarView.swift`: the split view collapses below 700 pt.
            Status set to review.
            """)
        XCTAssertNil(second.attachments)
    }

    func testRoundTrip() throws {
        let file = try TicketFile.decode(Self.example, fileID: id12)
        let text = try file.encode(preserving: nil)
        XCTAssertEqual(try TicketFile.decode(text, fileID: id12), file)
        // The doc gives the exact bytes the app writes.
        XCTAssertEqual(text, Self.example)

        let id13 = TicketID(projectID: "HEPH", number: 13)
        var newTicket = TicketFile(id: id13, name: "Add a Skills shortcut", description: nil, status: .todo)
        newTicket.created = try date("2026-10-30T08:00:00Z")
        newTicket.updated = newTicket.created
        XCTAssertEqual(try newTicket.encode(preserving: nil), Self.newTicket)
        XCTAssertEqual(try TicketFile.decode(Self.newTicket, fileID: id13), newTicket)
    }

    func testUnknownKeysPreserved() throws {
        let root = try makeTemporaryDirectory()
        let url = TicketFile.url(projectRoot: root, id: id12)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
            id: HEPH-12
            name: Sidebar breaks on iPad
            status: todo
            created: 2026-10-29T21:04:00Z
            updated: 2026-10-29T22:10:00Z
            comments:
            - id: 0B1E5C2A-7F3D-4E9B-8A61-2C4D6E8F0A1B
              author: Sam's iPad
              created: 2026-10-29T21:05:00Z
              body: Screenshot of the overlap.
              reactions: [thumbsUp, eyes]
            priority: high

            """
        try Data(text.utf8).write(to: url)

        let written = try TicketFile.update(projectRoot: root, id: id12) { $0.status = .review }
        XCTAssertEqual(written.status, .review)

        let newText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(try TicketFile.decode(newText, fileID: id12).status, .review)
        let node = try XCTUnwrap(try Yams.compose(yaml: newText))
        XCTAssertEqual(node["status"]?.string, "review")
        XCTAssertEqual(node["priority"]?.string, "high")
        XCTAssertEqual(node["comments"]?.array().first?["reactions"]?.array().compactMap(\.string), ["thumbsUp", "eyes"])
    }

    func testBrokenTicket() throws {
        let root = try makeTemporaryDirectory()
        let id7 = TicketID(projectID: "HEPH", number: 7)
        let url = TicketFile.url(projectRoot: root, id: id7)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("id: HEPH-7\nname: [Broken\nstatus: todo\n".utf8)
        try invalid.write(to: url)
        let parserMessage: String
        do {
            _ = try Yams.compose(yaml: String(decoding: invalid, as: UTF8.self))
            return XCTFail("the text should not parse")
        } catch {
            parserMessage = YAMLCoding.problem(of: error)
        }

        let results = TicketFile.loadAll(projectRoot: root, projectID: "HEPH")
        XCTAssertEqual(results.count, 1)
        guard case .broken(let id, let message, _)? = results.first else {
            return XCTFail("expected a broken ticket, got \(results)")
        }
        XCTAssertEqual(id, id7)
        XCTAssertEqual(message, "HEPH-7.yml: \(parserMessage)")

        // The app never writes a broken ticket file.
        XCTAssertThrowsError(try TicketFile.update(projectRoot: root, id: id7) { $0.status = .done }) { error in
            XCTAssertEqual(error as? DataError, .refused("The file is invalid: HEPH-7.yml: \(parserMessage)"))
        }
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    func testStatusRawValues() throws {
        let expected: [(TicketStatus, String)] = [(.todo, "todo"), (.inProgress, "in_progress"), (.review, "review"),
                                                (.done, "done")]
        XCTAssertEqual(TicketStatus.allCases, expected.map(\.0))
        for (status, raw) in expected {
            XCTAssertEqual(status.rawValue, raw)
            let json = try WireCoding.encodeJSON(status)
            XCTAssertEqual(String(decoding: json, as: UTF8.self), "\"\(raw)\"")
            XCTAssertEqual(try WireCoding.decodeJSON(TicketStatus.self, from: json), status)
            XCTAssertEqual(try YAMLDecoder().decode(TicketStatus.self, from: try YAMLEncoder().encode(status)), status)
        }
    }

    func testMigrateFromTasks() throws {
        let root = try makeTemporaryDirectory()
        let hephaestus = root.appendingPathComponent(".hephaestus", isDirectory: true)
        let fileManager = FileManager.default
        for folder in ["tasks", "sessions", "bundles"] {
            try fileManager.createDirectory(at: hephaestus.appendingPathComponent(folder, isDirectory: true),
                                            withIntermediateDirectories: true)
        }
        let ticketBytes = Data(Self.newTicket.replacingOccurrences(of: "HEPH-13", with: "HEPH-1").utf8)
        try ticketBytes.write(to: hephaestus.appendingPathComponent("tasks/HEPH-1.yml"))
        let projectURL = ProjectFile.url(projectRoot: root)
        try Data("id: HEPH\nname: Hephaestus\ncreated: 2026-10-29T21:00:00Z\ntaskCounter: 1\n".utf8).write(to: projectURL)
        let sessionURL = hephaestus.appendingPathComponent("sessions/3f2b8c1e-9a4d-4f6b-8e2a-1c5d7e9f0a2b.yml")
        try Data("""
            id: 3F2B8C1E-9A4D-4F6B-8E2A-1C5D7E9F0A2B
            kind: task
            taskID: HEPH-1
            mode: implement
            title: Implement HEPH-1
            created: 2026-10-29T22:01:00Z
            updated: 2026-10-29T22:09:41Z
            permissionMode: acceptEdits
            status: stopped

            """.utf8).write(to: sessionURL)
        let bundleURL = hephaestus.appendingPathComponent("bundles/HEPH-B1.yml")
        try Data("""
            id: HEPH-B1
            name: Sidebar polish
            status: draft
            created: 2026-10-30T08:00:00Z
            updated: 2026-10-30T09:12:00Z
            tasks:
            - task: HEPH-1

            """.utf8).write(to: bundleURL)

        TicketFile.migrateFromTasks(projectRoot: root)

        XCTAssertFalse(fileManager.fileExists(atPath: hephaestus.appendingPathComponent("tasks").path))
        XCTAssertEqual(try Data(contentsOf: hephaestus.appendingPathComponent("tickets/HEPH-1.yml")), ticketBytes)
        let project = try XCTUnwrap(try Yams.compose(yaml: try String(contentsOf: projectURL, encoding: .utf8)))
        XCTAssertEqual(project["ticketCounter"]?.int, 1)
        XCTAssertNil(project["taskCounter"])
        let session = try XCTUnwrap(try Yams.compose(yaml: try String(contentsOf: sessionURL, encoding: .utf8)))
        XCTAssertEqual(session["kind"]?.string, "ticket")
        XCTAssertEqual(session["ticketID"]?.string, "HEPH-1")
        XCTAssertNil(session["taskID"])
        let bundle = try XCTUnwrap(try Yams.compose(yaml: try String(contentsOf: bundleURL, encoding: .utf8)))
        XCTAssertEqual(bundle["tickets"]?.array().first?["ticket"]?.string, "HEPH-1")
        XCTAssertNil(bundle["tasks"])

        // A second call changes no file.
        let urls = [hephaestus.appendingPathComponent("tickets/HEPH-1.yml"), projectURL, sessionURL, bundleURL]
        let before = try urls.map { try Data(contentsOf: $0) }
        TicketFile.migrateFromTasks(projectRoot: root)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
    }

    func testMigrateBothFolders() throws {
        let root = try makeTemporaryDirectory()
        let hephaestus = root.appendingPathComponent(".hephaestus", isDirectory: true)
        let tasks = hephaestus.appendingPathComponent("tasks", isDirectory: true)
        let tickets = hephaestus.appendingPathComponent("tickets", isDirectory: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tickets, withIntermediateDirectories: true)
        let one = Data("one".utf8)
        let oldTwo = Data("old two".utf8)
        let newTwo = Data("new two".utf8)
        try one.write(to: tasks.appendingPathComponent("HEPH-1.yml"))
        try oldTwo.write(to: tasks.appendingPathComponent("HEPH-2.yml"))
        try newTwo.write(to: tickets.appendingPathComponent("HEPH-2.yml"))

        TicketFile.migrateFromTasks(projectRoot: root)

        XCTAssertEqual(try Data(contentsOf: tickets.appendingPathComponent("HEPH-1.yml")), one)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tasks.appendingPathComponent("HEPH-1.yml").path))
        XCTAssertEqual(try Data(contentsOf: tickets.appendingPathComponent("HEPH-2.yml")), newTwo)
        XCTAssertEqual(try Data(contentsOf: tasks.appendingPathComponent("HEPH-2.yml")), oldTwo)
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }
}
