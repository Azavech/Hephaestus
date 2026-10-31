import Foundation
import XCTest
@testable import HephCore

final class BundleFileTests: XCTestCase {
    /// The bundle file example of docs/services/bundles.md.
    static let example = """
        id: HEPH-B1
        name: Sidebar polish
        status: running
        created: 2026-10-30T08:00:00Z
        updated: 2026-10-30T09:12:00Z
        base: main
        coordinator: 6A1F0C2E-3B4D-4E5F-8A9B-0C1D2E3F4A5B
        tasks:
        - task: HEPH-12
          session: 0B1E5C6A-2F3D-4E5F-8A9B-0C1D2E3F4A5B
        - task: HEPH-14

        """

    private let b1 = BundleID(projectID: "HEPH", number: 1)

    func testDecodeExample() throws {
        let file = try BundleFile.decode(Self.example, fileID: b1)
        XCTAssertEqual(file.id, "HEPH-B1")
        XCTAssertEqual(file.name, "Sidebar polish")
        XCTAssertEqual(file.status, .running)
        XCTAssertEqual(file.created, try date("2026-10-30T08:00:00Z"))
        XCTAssertEqual(file.updated, try date("2026-10-30T09:12:00Z"))
        XCTAssertEqual(file.base, "main")
        XCTAssertEqual(file.coordinator, try uuid("6A1F0C2E-3B4D-4E5F-8A9B-0C1D2E3F4A5B"))
        XCTAssertEqual(file.tasks, [
            BundleFile.Item(task: "HEPH-12", session: try uuid("0B1E5C6A-2F3D-4E5F-8A9B-0C1D2E3F4A5B")),
            BundleFile.Item(task: "HEPH-14", session: nil),
        ])
    }

    func testRoundTrip() throws {
        let file = try BundleFile.decode(Self.example, fileID: b1)
        let text = try file.encode(preserving: nil)
        XCTAssertEqual(try BundleFile.decode(text, fileID: b1), file)
    }

    func testBundleID() {
        XCTAssertEqual(BundleID("heph-b3")?.description, "HEPH-B3")
        XCTAssertEqual(BundleID("heph-b3"), BundleID(projectID: "HEPH", number: 3))
        XCTAssertNil(BundleID("HEPH-3"))
        XCTAssertNil(BundleID("HEPH-B0"))
        XCTAssertNil(TaskID("HEPH-B3"))
    }

    func testAllocateID() throws {
        let root = try makeTemporaryDirectory()
        XCTAssertEqual(try BundleFile.allocateID(projectRoot: root, projectID: "HEPH").description, "HEPH-B1")

        let folder = BundleFile.folder(projectRoot: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["HEPH-B1.yml", "HEPH-B4.yml"] {
            try Data().write(to: folder.appendingPathComponent(name, isDirectory: false))
        }
        XCTAssertEqual(try BundleFile.allocateID(projectRoot: root, projectID: "HEPH").description, "HEPH-B5")
    }

    func testRepeatedTask() {
        let text = """
            id: HEPH-B1
            name: Sidebar polish
            created: 2026-10-30T08:00:00Z
            updated: 2026-10-30T08:00:00Z
            tasks:
            - task: HEPH-2
            - task: HEPH-2

            """
        XCTAssertThrowsError(try BundleFile.decode(text, fileID: b1)) { error in
            XCTAssertEqual(error as? DataError,
                           .invalid("HEPH-B1.yml: tasks[1].task must be a task of HEPH listed once"))
        }
    }

    func testBaseOption() throws {
        let text = """
            id: HEPH-B1
            name: Sidebar polish
            created: 2026-10-30T08:00:00Z
            updated: 2026-10-30T08:00:00Z
            base: --detach
            tasks:
            - task: HEPH-2

            """
        XCTAssertThrowsError(try BundleFile.decode(text, fileID: b1)) { error in
            XCTAssertEqual(error as? DataError, .invalid("HEPH-B1.yml: base must be a branch name"))
        }
        let file = try BundleFile.decode(text.replacingOccurrences(of: "base: --detach", with: "base: fix-1"),
                                         fileID: b1)
        XCTAssertEqual(file.base, "fix-1")
    }

    func testBrokenSkipped() throws {
        let root = try makeTemporaryDirectory()
        let folder = BundleFile.folder(projectRoot: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.example.utf8).write(to: BundleFile.url(projectRoot: root, id: b1))
        try Data("id: HEPH-B2\nname: [Broken\n".utf8)
            .write(to: BundleFile.url(projectRoot: root, id: BundleID(projectID: "HEPH", number: 2)))

        let files = BundleFile.loadAll(projectRoot: root, projectID: "HEPH")
        XCTAssertEqual(files.map(\.id), ["HEPH-B1"])
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }

    private func uuid(_ text: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: text))
    }
}
