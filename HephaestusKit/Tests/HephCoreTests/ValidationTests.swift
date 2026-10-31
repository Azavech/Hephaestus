import Foundation
import XCTest
import Yams
@testable import HephCore

final class ValidationTests: XCTestCase {
    func testProjectIdentifiers() throws {
        for valid in ["HE", "HEPH", "ABCDEFGH"] {
            XCTAssertTrue(ProjectIdentifier.isValid(valid), valid)
        }
        for invalid in ["H", "ABCDEFGHI", "heph", "HE1", "H\u{C9}", ""] {
            XCTAssertFalse(ProjectIdentifier.isValid(invalid), invalid)
        }
        // Trims, maps ASCII a–z to A–Z and nothing else.
        XCTAssertEqual(ProjectIdentifier.normalize("  heph \n"), "HEPH")
        XCTAssertEqual(ProjectIdentifier.normalize("Api"), "API")
        XCTAssertEqual(ProjectIdentifier.normalize("stra\u{DF}e"), "STRA\u{DF}E")
        XCTAssertEqual(ProjectIdentifier.normalize("h\u{E9}"), "H\u{E9}")
        XCTAssertEqual(try ProjectIdentifier.validated(" heph "), "HEPH")
        XCTAssertThrowsError(try ProjectIdentifier.validated("h\u{E9}")) { error in
            XCTAssertEqual(error as? DataError, .invalid("the identifier must be 2 to 8 letters A to Z"))
        }
    }

    func testTicketIDs() throws {
        let id = try XCTUnwrap(TicketID("HEPH-12"))
        XCTAssertEqual(id.projectID, "HEPH")
        XCTAssertEqual(id.number, 12)
        XCTAssertEqual(id.description, "HEPH-12")
        XCTAssertEqual(id.fileName, "HEPH-12.yml")
        XCTAssertEqual(TicketID(fileName: "HEPH-12.yml"), id)
        for invalid in ["HEPH12", "HEPH-x", "HEPH-", "HEPH-0", "HEPH-012", "H-1", "-1"] {
            XCTAssertNil(TicketID(invalid), invalid)
            XCTAssertNil(TicketID(fileName: invalid + ".yml"), invalid)
        }
        // `TicketID(_:)` trims and maps ASCII a–z to A–Z; `TicketID(fileName:)` matches the file name exactly.
        XCTAssertEqual(TicketID(" heph-1 "), TicketID(projectID: "HEPH", number: 1))
        XCTAssertNil(TicketID(fileName: "heph-1.yml"))
        XCTAssertNil(TicketID(fileName: "HEPH-1.yaml"))
        // Compared as (projectID, feedback, number).
        XCTAssertLessThan(TicketID(projectID: "HEPH", number: 9), TicketID(projectID: "HEPH", number: 10))
        // Coded as one string.
        XCTAssertEqual(String(decoding: try WireCoding.encodeJSON(id), as: UTF8.self), "\"HEPH-12\"")
        XCTAssertEqual(try WireCoding.decodeJSON(TicketID.self, from: Data("\"HEPH-12\"".utf8)), id)

        // Feedback ticket ids.
        let feedback = try XCTUnwrap(TicketID(" heph-f3 "))
        XCTAssertEqual(feedback.description, "HEPH-F3")
        XCTAssertEqual(feedback.projectID, "HEPH")
        XCTAssertEqual(feedback.number, 3)
        XCTAssertTrue(feedback.feedback)
        XCTAssertEqual(feedback.fileName, "HEPH-F3.yml")
        XCTAssertEqual(TicketID(fileName: "HEPH-F3.yml"), feedback)
        for invalid in ["HEPH-F", "HEPH-F0", "HEPH-F03", "HEPH-FF3", "HEPH-G3"] {
            XCTAssertNil(TicketID(invalid), invalid)
        }
        XCTAssertLessThan(TicketID(projectID: "HEPH", number: 10), TicketID(projectID: "HEPH", number: 1, feedback: true))
        XCTAssertLessThan(TicketID(projectID: "HEPH", number: 2, feedback: true),
                          TicketID(projectID: "HEPH", number: 10, feedback: true))
        XCTAssertNotEqual(TicketID(projectID: "HEPH", number: 3), TicketID(projectID: "HEPH", number: 3, feedback: true))
        XCTAssertEqual(String(decoding: try WireCoding.encodeJSON(feedback), as: UTF8.self), "\"HEPH-F3\"")
    }

    func testNames() throws {
        let nameMessage = "the name must not be empty and must be on one line"
        let longName = String(repeating: "n", count: 1_000)
        let broken = ["", "   ", " \n\t ", "a\nb", "a\rb", "a\u{2028}b"]

        // Project names.
        XCTAssertEqual(try ProjectFile.validatedName("  Hephaestus \n"), "Hephaestus")
        XCTAssertEqual(try ProjectFile.validatedName(longName), longName)
        for name in broken {
            XCTAssertThrowsError(try ProjectFile.validatedName(name), name.debugDescription) { error in
                XCTAssertEqual(error as? DataError, .invalid(nameMessage))
            }
        }

        // Ticket names.
        let ticketID = TicketID(projectID: "HEPH", number: 1)
        func validatedTicket(_ name: String) throws -> TicketFile {
            var ticket = TicketFile(id: ticketID, name: name, description: nil, status: .todo)
            ticket.normalize()
            try ticket.validate(fileID: ticketID)
            return ticket
        }
        XCTAssertEqual(try validatedTicket("  Fix the sidebar \n").name, "Fix the sidebar")
        XCTAssertEqual(try validatedTicket(longName).name, longName)
        for name in broken {
            XCTAssertThrowsError(try validatedTicket(name), name.debugDescription) { error in
                XCTAssertEqual(error as? DataError, .invalid(nameMessage))
            }
        }

        // Session titles.
        let sessionID = UUID()
        let fileName = SessionFile.fileStem(sessionID) + ".yml"
        func validatedSession(_ title: String) throws -> SessionFile {
            var session = SessionFile(id: sessionID, kind: .project, ticketID: nil, mode: nil, bundleID: nil,
                                      title: title, created: Date(), updated: Date(), permissionMode: .acceptEdits,
                                      model: nil, status: .stopped)
            session.normalize()
            try session.validate(fileName: fileName)
            return session
        }
        XCTAssertEqual(try validatedSession("  Plan the Skills screen \n").title, "Plan the Skills screen")
        XCTAssertEqual(try validatedSession(longName).title, longName)
        for title in broken {
            XCTAssertThrowsError(try validatedSession(title), title.debugDescription) { error in
                XCTAssertEqual(error as? DataError, .invalid("the title must not be empty and must be on one line"))
            }
        }
    }

    func testRenamedKeys() throws {
        // Session file: kind task and taskID.
        let fileName = "3f2b8c1e-9a4d-4f6b-8e2a-1c5d7e9f0a2b.yml"
        let oldSession = """
            id: 3F2B8C1E-9A4D-4F6B-8E2A-1C5D7E9F0A2B
            kind: task
            taskID: HEPH-12
            mode: implement
            title: Implement HEPH-12
            created: 2026-10-29T22:01:00Z
            updated: 2026-10-29T22:09:41Z
            permissionMode: acceptEdits
            model: opus
            status: stopped

            """
        let session = try SessionFile.decode(oldSession, fileName: fileName)
        XCTAssertEqual(session.kind, .ticket)
        XCTAssertEqual(session.ticketID, "HEPH-12")
        let sessionNode = try XCTUnwrap(try Yams.compose(yaml: try session.encode(preserving: oldSession)))
        XCTAssertEqual(sessionNode["kind"]?.string, "ticket")
        XCTAssertEqual(sessionNode["ticketID"]?.string, "HEPH-12")
        XCTAssertNil(sessionNode["taskID"])

        // project.yml: taskCounter.
        let root = try makeTemporaryDirectory()
        let projectURL = ProjectFile.url(projectRoot: root)
        try FileManager.default.createDirectory(at: projectURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("id: HEPH\nname: Hephaestus\ncreated: 2026-10-29T21:00:00Z\ntaskCounter: 12\n".utf8).write(to: projectURL)
        XCTAssertEqual(try ProjectFile.load(projectRoot: root).ticketCounter, 12)
        try ProjectFile.update(projectRoot: root) { _ in }
        let projectNode = try XCTUnwrap(try Yams.compose(yaml: try String(contentsOf: projectURL, encoding: .utf8)))
        XCTAssertEqual(projectNode["ticketCounter"]?.int, 12)
        XCTAssertNil(projectNode["taskCounter"])

        // Bundle file: tasks and task.
        let oldBundle = """
            id: HEPH-B1
            name: Sidebar polish
            status: draft
            created: 2026-10-30T08:00:00Z
            updated: 2026-10-30T09:12:00Z
            tasks:
            - task: HEPH-2

            """
        let bundle = try BundleFile.decode(oldBundle, fileID: BundleID(projectID: "HEPH", number: 1))
        XCTAssertEqual(bundle.tickets, [BundleFile.Item(ticket: "HEPH-2", session: nil)])
        let bundleText = try bundle.encode(preserving: oldBundle)
        let bundleNode = try XCTUnwrap(try Yams.compose(yaml: bundleText))
        XCTAssertEqual(bundleNode["tickets"]?.array().first?["ticket"]?.string, "HEPH-2")
        XCTAssertNil(bundleNode["tasks"])
        XCTAssertFalse(bundleText.contains("task:"))
    }
}
