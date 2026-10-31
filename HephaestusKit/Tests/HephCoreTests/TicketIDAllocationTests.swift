import Foundation
import XCTest
@testable import HephCore

final class TicketIDAllocationTests: XCTestCase {
    func testNextNumber() throws {
        let root = try makeProject(ticketCounter: 12)
        XCTAssertEqual(try TicketFile.allocateID(projectRoot: root), TicketID(projectID: "HEPH", number: 13))
        XCTAssertEqual(try ProjectFile.load(projectRoot: root).ticketCounter, 13)
    }

    func testExistingFilesWin() throws {
        let root = try makeProject(ticketCounter: 5)
        try writeTicket(3, in: root)
        try writeTicket(9, in: root)
        XCTAssertEqual(try TicketFile.allocateID(projectRoot: root), TicketID(projectID: "HEPH", number: 10))
    }

    func testNumbersNeverReused() throws {
        let root = try makeProject(ticketCounter: 12)
        for number in 1...10 {
            try writeTicket(number, in: root)
        }
        XCTAssertEqual(try TicketFile.allocateID(projectRoot: root), TicketID(projectID: "HEPH", number: 13))
    }

    func testBrokenFileCounts() throws {
        let root = try makeProject(ticketCounter: 2)
        let broken = TicketFile.url(projectRoot: root, id: TicketID(projectID: "HEPH", number: 15))
        try Data("id: HEPH-15\nname: [broken\n".utf8).write(to: broken)
        XCTAssertEqual(TicketFile.highestNumber(projectRoot: root, projectID: "HEPH", feedback: false), 15)
        XCTAssertEqual(try TicketFile.allocateID(projectRoot: root), TicketID(projectID: "HEPH", number: 16))
    }

    func testFeedbackSeries() throws {
        let root = try makeProject(ticketCounter: 12, feedbackCounter: 2)
        try writeTicket(3, in: root)
        try writeTicket(5, feedback: true, in: root)
        XCTAssertEqual(try TicketFile.allocateID(projectRoot: root, feedback: true),
                       TicketID(projectID: "HEPH", number: 6, feedback: true))
        let project = try ProjectFile.load(projectRoot: root)
        XCTAssertEqual(project.feedbackCounter, 6)
        XCTAssertEqual(project.ticketCounter, 12)
        XCTAssertEqual(try TicketFile.allocateID(projectRoot: root), TicketID(projectID: "HEPH", number: 13))
    }

    func testConsecutive() throws {
        let root = try makeProject(ticketCounter: 0)
        let first = try TicketFile.allocateID(projectRoot: root)
        let second = try TicketFile.allocateID(projectRoot: root)
        XCTAssertEqual(first, TicketID(projectID: "HEPH", number: 1))
        XCTAssertEqual(second, TicketID(projectID: "HEPH", number: 2))
        XCTAssertEqual(try ProjectFile.load(projectRoot: root).ticketCounter, 2)
    }

    func testNoNumberLeft() throws {
        let full = try makeProject(ticketCounter: Int.max)
        try assertNoNumberLeft(in: full)

        let lastFile = try makeProject(ticketCounter: 0)
        try writeTicket(Int.max, in: lastFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TicketFile.folder(projectRoot: lastFile)
            .appendingPathComponent("HEPH-9223372036854775807.yml").path))
        try assertNoNumberLeft(in: lastFile)
    }

    func testNoFeedbackNumberLeft() throws {
        let root = try makeProject(ticketCounter: 0, feedbackCounter: Int.max)
        let before = try ProjectFile.load(projectRoot: root)
        XCTAssertThrowsError(try TicketFile.allocateID(projectRoot: root, feedback: true)) { error in
            XCTAssertEqual(error as? DataError, .invalid("no feedback number is left in HEPH"))
        }
        XCTAssertEqual(try ProjectFile.load(projectRoot: root), before)
        XCTAssertEqual(try TicketFile.allocateID(projectRoot: root), TicketID(projectID: "HEPH", number: 1))
    }

    /// `allocateID` throws `.invalid("no ticket number is left in HEPH")` and leaves project.yml unchanged.
    private func assertNoNumberLeft(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try ProjectFile.load(projectRoot: root)
        XCTAssertThrowsError(try TicketFile.allocateID(projectRoot: root), file: file, line: line) { error in
            XCTAssertEqual(error as? DataError, .invalid("no ticket number is left in HEPH"), file: file, line: line)
        }
        XCTAssertEqual(try ProjectFile.load(projectRoot: root), before, file: file, line: line)
    }

    /// A temporary project with `id: HEPH`, the given counters and an empty tickets folder.
    private func makeProject(ticketCounter: Int, feedbackCounter: Int = 0) throws -> URL {
        let root = try makeTemporaryDirectory()
        let url = ProjectFile.url(projectRoot: root)
        try FileManager.default.createDirectory(at: TicketFile.folder(projectRoot: root), withIntermediateDirectories: true)
        let text = "id: HEPH\nname: Hephaestus\ncreated: 2026-10-29T21:00:00Z\nticketCounter: \(ticketCounter)\n"
            + "feedbackCounter: \(feedbackCounter)\n"
        try Data(text.utf8).write(to: url)
        return root
    }

    private func writeTicket(_ number: Int, feedback: Bool = false, in root: URL) throws {
        let id = TicketID(projectID: "HEPH", number: number, feedback: feedback)
        try TicketFile.create(TicketFile(id: id, name: "Ticket \(number)", description: nil, status: .todo),
                              projectRoot: root)
    }
}
