import Foundation
import XCTest
@testable import HephCore

final class TaskIDAllocationTests: XCTestCase {
    func testNextNumber() throws {
        let root = try makeProject(taskCounter: 12)
        XCTAssertEqual(try TaskFile.allocateID(projectRoot: root), TaskID(projectID: "HEPH", number: 13))
        XCTAssertEqual(try ProjectFile.load(projectRoot: root).taskCounter, 13)
    }

    func testExistingFilesWin() throws {
        let root = try makeProject(taskCounter: 5)
        try writeTask(3, in: root)
        try writeTask(9, in: root)
        XCTAssertEqual(try TaskFile.allocateID(projectRoot: root), TaskID(projectID: "HEPH", number: 10))
    }

    func testNumbersNeverReused() throws {
        let root = try makeProject(taskCounter: 12)
        for number in 1...10 {
            try writeTask(number, in: root)
        }
        XCTAssertEqual(try TaskFile.allocateID(projectRoot: root), TaskID(projectID: "HEPH", number: 13))
    }

    func testBrokenFileCounts() throws {
        let root = try makeProject(taskCounter: 2)
        let broken = TaskFile.url(projectRoot: root, id: TaskID(projectID: "HEPH", number: 15))
        try Data("id: HEPH-15\nname: [broken\n".utf8).write(to: broken)
        XCTAssertEqual(TaskFile.highestNumber(projectRoot: root, projectID: "HEPH"), 15)
        XCTAssertEqual(try TaskFile.allocateID(projectRoot: root), TaskID(projectID: "HEPH", number: 16))
    }

    func testConsecutive() throws {
        let root = try makeProject(taskCounter: 0)
        let first = try TaskFile.allocateID(projectRoot: root)
        let second = try TaskFile.allocateID(projectRoot: root)
        XCTAssertEqual(first, TaskID(projectID: "HEPH", number: 1))
        XCTAssertEqual(second, TaskID(projectID: "HEPH", number: 2))
        XCTAssertEqual(try ProjectFile.load(projectRoot: root).taskCounter, 2)
    }

    func testNoNumberLeft() throws {
        let full = try makeProject(taskCounter: Int.max)
        try assertNoNumberLeft(in: full)

        let lastFile = try makeProject(taskCounter: 0)
        try writeTask(Int.max, in: lastFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TaskFile.folder(projectRoot: lastFile)
            .appendingPathComponent("HEPH-9223372036854775807.yml").path))
        try assertNoNumberLeft(in: lastFile)
    }

    /// `allocateID` throws `.invalid("no task number is left in HEPH")` and leaves project.yml unchanged.
    private func assertNoNumberLeft(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try ProjectFile.load(projectRoot: root)
        XCTAssertThrowsError(try TaskFile.allocateID(projectRoot: root), file: file, line: line) { error in
            XCTAssertEqual(error as? DataError, .invalid("no task number is left in HEPH"), file: file, line: line)
        }
        XCTAssertEqual(try ProjectFile.load(projectRoot: root), before, file: file, line: line)
    }

    /// A temporary project with `id: HEPH`, the given task counter and an empty tasks folder.
    private func makeProject(taskCounter: Int) throws -> URL {
        let root = try makeTemporaryDirectory()
        let url = ProjectFile.url(projectRoot: root)
        try FileManager.default.createDirectory(at: TaskFile.folder(projectRoot: root), withIntermediateDirectories: true)
        let text = "id: HEPH\nname: Hephaestus\ncreated: 2026-10-29T21:00:00Z\ntaskCounter: \(taskCounter)\n"
        try Data(text.utf8).write(to: url)
        return root
    }

    private func writeTask(_ number: Int, in root: URL) throws {
        let id = TaskID(projectID: "HEPH", number: number)
        try TaskFile.create(TaskFile(id: id, name: "Task \(number)", description: nil, status: .todo), projectRoot: root)
    }
}
