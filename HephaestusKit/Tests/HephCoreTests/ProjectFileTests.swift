import Foundation
import XCTest
import Yams
@testable import HephCore

final class ProjectFileTests: XCTestCase {
    /// The project.yml example of docs/data/project-yml.md, exactly as the app writes it.
    static let example = """
        id: HEPH
        name: Hephaestus
        description: Multi-device project workbench
        created: 2026-10-29T21:00:00Z
        code: .
        docs: docs
        taskCounter: 12
        subprojects:
        - services/api
        webTabs:
        - id: 7C3A0E1B-5D2F-4C8A-9E61-0B4D2F7A9C13
          title: GitHub
          url: https://github.com/Azavech/Hephaestus
          locked: true
        - id: E4F1A2B3-C4D5-4E6F-8A9B-0C1D2E3F4A5B
          title: Actions
          url: https://github.com/Azavech/Hephaestus/actions
          locked: false
        runs:
        - name: Build
          command: ./scripts/build.sh all
        - name: Tests
          command: ./scripts/test.sh
        - name: API server
          command: go run ./cmd/api
          cwd: services/api
        skills: []
        claude:
          model: opus
          permissionMode: acceptEdits

        """

    /// The new sub project example of docs/data/project-yml.md.
    static let newSubproject = """
        id: API
        name: API
        created: 2026-10-30T09:12:45Z
        code: .
        docs: docs
        taskCounter: 0
        subprojects: []
        webTabs: []
        runs: []
        skills: []

        """

    func testDecodeExample() throws {
        let file = try ProjectFile.decode(Self.example)
        XCTAssertEqual(file.id, "HEPH")
        XCTAssertEqual(file.name, "Hephaestus")
        XCTAssertEqual(file.description, "Multi-device project workbench")
        XCTAssertEqual(file.created, try date("2026-10-29T21:00:00Z"))
        XCTAssertEqual(file.code, ".")
        XCTAssertEqual(file.docs, "docs")
        XCTAssertEqual(file.taskCounter, 12)
        XCTAssertEqual(file.subprojects, ["services/api"])
        XCTAssertEqual(file.webTabs, [
            ProjectFile.WebTabEntry(id: try uuid("7C3A0E1B-5D2F-4C8A-9E61-0B4D2F7A9C13"), title: "GitHub",
                                    url: "https://github.com/Azavech/Hephaestus", locked: true),
            ProjectFile.WebTabEntry(id: try uuid("E4F1A2B3-C4D5-4E6F-8A9B-0C1D2E3F4A5B"), title: "Actions",
                                    url: "https://github.com/Azavech/Hephaestus/actions", locked: false),
        ])
        XCTAssertEqual(file.runs, [
            ProjectFile.RunEntry(name: "Build", command: "./scripts/build.sh all", cwd: nil),
            ProjectFile.RunEntry(name: "Tests", command: "./scripts/test.sh", cwd: nil),
            ProjectFile.RunEntry(name: "API server", command: "go run ./cmd/api", cwd: "services/api"),
        ])
        XCTAssertEqual(file.skills, [])
        XCTAssertEqual(file.claude, ClaudeDefaults(model: "opus", permissionMode: .acceptEdits))
        XCTAssertEqual(file.webTabValues.map(\.title), ["GitHub", "Actions"])
        XCTAssertEqual(file.runConfigs.last, RunConfig(name: "API server", command: "go run ./cmd/api", cwd: "services/api"))
        XCTAssertEqual(file.claudeDefaults, ClaudeDefaults(model: "opus", permissionMode: .acceptEdits))
    }

    func testRoundTrip() throws {
        let file = try ProjectFile.decode(Self.example)
        let text = try file.encode(preserving: nil)
        XCTAssertEqual(try ProjectFile.decode(text), file)
        // The doc gives the exact bytes the app writes.
        XCTAssertEqual(text, Self.example)
        XCTAssertEqual(try file.encode(preserving: Self.example), Self.example)

        var subproject = ProjectFile(id: "API", name: "API", description: nil)
        subproject.created = try date("2026-10-30T09:12:45Z")
        XCTAssertEqual(try subproject.encode(preserving: nil), Self.newSubproject)
        XCTAssertEqual(try ProjectFile.decode(Self.newSubproject), subproject)
    }

    func testUnknownKeysPreserved() throws {
        let root = try makeTemporaryDirectory()
        let url = ProjectFile.url(projectRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
            id: HEPH
            name: Hephaestus
            created: 2026-10-29T21:00:00Z
            webTabs:
            - id: 7C3A0E1B-5D2F-4C8A-9E61-0B4D2F7A9C13
              title: GitHub
              url: https://github.com/Azavech/Hephaestus
              locked: true
              pinnedBy: tester
            custom: {a: 1}

            """
        try Data(text.utf8).write(to: url)

        let written = try ProjectFile.update(projectRoot: root) { $0.name = "Forge" }
        XCTAssertEqual(written.name, "Forge")

        let newText = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(try ProjectFile.decode(newText).name, "Forge")
        let node = try XCTUnwrap(try Yams.compose(yaml: newText))
        XCTAssertEqual(node["name"]?.string, "Forge")
        XCTAssertEqual(node["custom"]?["a"]?.int, 1)
        XCTAssertEqual(node["webTabs"]?.array().first?["pinnedBy"]?.string, "tester")
        XCTAssertEqual(node["webTabs"]?.array().first?["title"]?.string, "GitHub")
    }

    func testMinimalFile() throws {
        let file = try ProjectFile.decode("""
            id: HEPH
            name: Hephaestus
            created: 2026-10-29T21:00:00Z

            """)
        XCTAssertNil(file.description)
        XCTAssertEqual(file.code, ".")
        XCTAssertEqual(file.docs, "docs")
        XCTAssertEqual(file.taskCounter, 0)
        XCTAssertEqual(file.subprojects, [])
        XCTAssertEqual(file.webTabs, [])
        XCTAssertEqual(file.runs, [])
        XCTAssertEqual(file.skills, [])
        XCTAssertNil(file.claude)
        XCTAssertEqual(file.claudeDefaults, ClaudeDefaults(model: nil, permissionMode: nil))
    }

    func testInvalidFile() throws {
        // Invalid YAML: unreadable, with the parser's message (line and column).
        XCTAssertThrowsError(try ProjectFile.decode("id: HEPH\nname: [Hephaestus\ncreated: 2026-10-29T21:00:00Z\n")) { error in
            guard case .unreadable(let message)? = error as? DataError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.hasPrefix("project.yml: "), message)
            XCTAssertNotNil(message.range(of: #"\d+:\d+"#, options: .regularExpression), message)
            XCTAssertFalse(message.contains("\n"), message)
        }

        // An identifier that breaks the rule: `heph` normalizes to `HEPH`; `validate()` alone refuses it.
        var file = try ProjectFile.decode("id: heph\nname: Hephaestus\ncreated: 2026-10-29T21:00:00Z\n")
        XCTAssertEqual(file.id, "HEPH")
        file.id = "heph"
        XCTAssertThrowsError(try file.validate()) { error in
            XCTAssertEqual(error as? DataError, .invalid("the identifier must be 2 to 8 letters A to Z"))
        }
        XCTAssertThrowsError(try ProjectFile.decode("id: H1\nname: Hephaestus\ncreated: 2026-10-29T21:00:00Z\n")) { error in
            XCTAssertEqual(error as? DataError, .invalid("project.yml: the identifier must be 2 to 8 letters A to Z"))
        }

        // The other problems of the Reading table.
        let cases: [(text: String, error: DataError)] = [
            ("  \n", .unreadable("project.yml: the file is empty")),
            ("- a\n- b\n", .unreadable("project.yml: the file is not a YAML mapping")),
            ("id: HEPH\ncreated: 2026-10-29T21:00:00Z\n", .invalid("project.yml: missing key name")),
            ("id: HEPH\nname: Hephaestus\ncreated: 2026-10-29T21:00:00Z\nwebTabs:\n- id: nope\n  url: https://a.b\n",
             .invalid("project.yml: webTabs[0].id: invalid value")),
            ("id: HEPH\nname: Hephaestus\ncreated: 2026-10-29T21:00:00Z\nclaude:\n  permissionMode: always\n",
             .invalid("project.yml: claude.permissionMode: invalid value")),
            ("id: HEPH\nname: Hephaestus\ncreated: 2026-10-29T21:00:00Z\nruns:\n- name: A\n  command: a\n- name: A\n  command: b\n",
             .invalid("project.yml: runs[1].name must be unique, not empty and on one line")),
            ("id: HEPH\nname: Hephaestus\ncreated: 2026-10-29T21:00:00Z\nsubprojects:\n- ../outside\n",
             .invalid("project.yml: subprojects[0] must be a relative path inside the project")),
        ]
        for testCase in cases {
            XCTAssertThrowsError(try ProjectFile.decode(testCase.text), testCase.text) { error in
                XCTAssertEqual(error as? DataError, testCase.error, testCase.text)
            }
        }
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }

    private func uuid(_ text: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: text))
    }
}
