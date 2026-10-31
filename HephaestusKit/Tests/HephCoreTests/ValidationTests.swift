import Foundation
import XCTest
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

    func testTaskIDs() throws {
        let id = try XCTUnwrap(TaskID("HEPH-12"))
        XCTAssertEqual(id.projectID, "HEPH")
        XCTAssertEqual(id.number, 12)
        XCTAssertEqual(id.description, "HEPH-12")
        XCTAssertEqual(id.fileName, "HEPH-12.yml")
        XCTAssertEqual(TaskID(fileName: "HEPH-12.yml"), id)
        for invalid in ["HEPH12", "HEPH-x", "HEPH-", "HEPH-0", "HEPH-012", "H-1", "-1"] {
            XCTAssertNil(TaskID(invalid), invalid)
            XCTAssertNil(TaskID(fileName: invalid + ".yml"), invalid)
        }
        // `TaskID(_:)` trims and maps ASCII a–z to A–Z; `TaskID(fileName:)` matches the file name exactly.
        XCTAssertEqual(TaskID(" heph-1 "), TaskID(projectID: "HEPH", number: 1))
        XCTAssertNil(TaskID(fileName: "heph-1.yml"))
        XCTAssertNil(TaskID(fileName: "HEPH-1.yaml"))
        // Compared as (projectID, number).
        XCTAssertLessThan(TaskID(projectID: "HEPH", number: 9), TaskID(projectID: "HEPH", number: 10))
        // Coded as one string.
        XCTAssertEqual(String(decoding: try WireCoding.encodeJSON(id), as: UTF8.self), "\"HEPH-12\"")
        XCTAssertEqual(try WireCoding.decodeJSON(TaskID.self, from: Data("\"HEPH-12\"".utf8)), id)
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

        // Task names.
        let taskID = TaskID(projectID: "HEPH", number: 1)
        func validatedTask(_ name: String) throws -> TaskFile {
            var task = TaskFile(id: taskID, name: name, description: nil, status: .todo)
            task.normalize()
            try task.validate(fileID: taskID)
            return task
        }
        XCTAssertEqual(try validatedTask("  Fix the sidebar \n").name, "Fix the sidebar")
        XCTAssertEqual(try validatedTask(longName).name, longName)
        for name in broken {
            XCTAssertThrowsError(try validatedTask(name), name.debugDescription) { error in
                XCTAssertEqual(error as? DataError, .invalid(nameMessage))
            }
        }

        // Run configuration names.
        func validatedRun(_ name: String) throws -> ProjectFile {
            var project = ProjectFile(id: "HEPH", name: "Hephaestus", description: nil)
            project.runs = [ProjectFile.RunEntry(name: name, command: "make", cwd: nil)]
            project.normalize()
            try project.validate()
            return project
        }
        XCTAssertEqual(try validatedRun("  Build \n").runs.first?.name, "Build")
        XCTAssertEqual(try validatedRun(longName).runs.first?.name, longName)
        for name in broken {
            XCTAssertThrowsError(try validatedRun(name), name.debugDescription) { error in
                XCTAssertEqual(error as? DataError, .invalid("runs[0].name must be unique, not empty and on one line"))
            }
        }

        // Session titles.
        let sessionID = UUID()
        let fileName = SessionFile.fileStem(sessionID) + ".yml"
        func validatedSession(_ title: String) throws -> SessionFile {
            var session = SessionFile(id: sessionID, kind: .project, taskID: nil, mode: nil, bundleID: nil,
                                      title: title, created: Date(), updated: Date(), permissionMode: .acceptEdits,
                                      model: nil, status: .stopped)
            session.normalize()
            try session.validate(fileName: fileName)
            return session
        }
        XCTAssertEqual(try validatedSession("  Plan the Runs screen \n").title, "Plan the Runs screen")
        XCTAssertEqual(try validatedSession(longName).title, longName)
        for title in broken {
            XCTAssertThrowsError(try validatedSession(title), title.debugDescription) { error in
                XCTAssertEqual(error as? DataError, .invalid("the title must not be empty and must be on one line"))
            }
        }
    }
}
