import Foundation
import XCTest
import Yams
@testable import HephCore

final class TaskFileTests: XCTestCase {
    /// `.hephaestus/tasks/HEPH-12.yml` of docs/data/task-yml.md, exactly as the app writes it.
    static let example = """
        id: HEPH-12
        name: Sidebar breaks on iPad
        description: |-
          When the iPad rotates to portrait, the sidebar covers the task list.

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

    /// The new task example of docs/data/task-yml.md.
    static let newTask = """
        id: HEPH-13
        name: Add a Runs shortcut
        status: todo
        created: 2026-10-30T08:00:00Z
        updated: 2026-10-30T08:00:00Z
        comments: []

        """

    private let id12 = TaskID(projectID: "HEPH", number: 12)

    func testDecodeExample() throws {
        let file = try TaskFile.decode(Self.example, fileID: id12)
        XCTAssertEqual(file.id, "HEPH-12")
        XCTAssertEqual(file.name, "Sidebar breaks on iPad")
        XCTAssertEqual(file.description, """
            When the iPad rotates to portrait, the sidebar covers the task list.

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
        XCTAssertEqual(first.attachments, [TaskAttachment(file: "screenshot.png", type: "image/png", size: 123456)])

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
        let file = try TaskFile.decode(Self.example, fileID: id12)
        let text = try file.encode(preserving: nil)
        XCTAssertEqual(try TaskFile.decode(text, fileID: id12), file)
        // The doc gives the exact bytes the app writes.
        XCTAssertEqual(text, Self.example)

        let id13 = TaskID(projectID: "HEPH", number: 13)
        var newTask = TaskFile(id: id13, name: "Add a Runs shortcut", description: nil, status: .todo)
        newTask.created = try date("2026-10-30T08:00:00Z")
        newTask.updated = newTask.created
        XCTAssertEqual(try newTask.encode(preserving: nil), Self.newTask)
        XCTAssertEqual(try TaskFile.decode(Self.newTask, fileID: id13), newTask)
    }

    func testUnknownKeysPreserved() throws {
        let root = try makeTemporaryDirectory()
        let url = TaskFile.url(projectRoot: root, id: id12)
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

        let written = try TaskFile.update(projectRoot: root, id: id12) { $0.status = .review }
        XCTAssertEqual(written.status, .review)

        let newText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(try TaskFile.decode(newText, fileID: id12).status, .review)
        let node = try XCTUnwrap(try Yams.compose(yaml: newText))
        XCTAssertEqual(node["status"]?.string, "review")
        XCTAssertEqual(node["priority"]?.string, "high")
        XCTAssertEqual(node["comments"]?.array().first?["reactions"]?.array().compactMap(\.string), ["thumbsUp", "eyes"])
    }

    func testBrokenTask() throws {
        let root = try makeTemporaryDirectory()
        let id7 = TaskID(projectID: "HEPH", number: 7)
        let url = TaskFile.url(projectRoot: root, id: id7)
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

        let results = TaskFile.loadAll(projectRoot: root, projectID: "HEPH")
        XCTAssertEqual(results.count, 1)
        guard case .broken(let id, let message, _)? = results.first else {
            return XCTFail("expected a broken task, got \(results)")
        }
        XCTAssertEqual(id, id7)
        XCTAssertEqual(message, "HEPH-7.yml: \(parserMessage)")

        // The app never writes a broken task file.
        XCTAssertThrowsError(try TaskFile.update(projectRoot: root, id: id7) { $0.status = .done }) { error in
            XCTAssertEqual(error as? DataError, .refused("The file is invalid: HEPH-7.yml: \(parserMessage)"))
        }
        XCTAssertEqual(try Data(contentsOf: url), invalid)
    }

    func testStatusRawValues() throws {
        let expected: [(TaskStatus, String)] = [(.todo, "todo"), (.inProgress, "in_progress"), (.review, "review"),
                                                (.done, "done")]
        XCTAssertEqual(TaskStatus.allCases, expected.map(\.0))
        for (status, raw) in expected {
            XCTAssertEqual(status.rawValue, raw)
            let json = try WireCoding.encodeJSON(status)
            XCTAssertEqual(String(decoding: json, as: UTF8.self), "\"\(raw)\"")
            XCTAssertEqual(try WireCoding.decodeJSON(TaskStatus.self, from: json), status)
            XCTAssertEqual(try YAMLDecoder().decode(TaskStatus.self, from: try YAMLEncoder().encode(status)), status)
        }
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }
}
