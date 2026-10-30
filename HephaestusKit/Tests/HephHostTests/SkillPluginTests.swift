#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// The session plugin folder (docs/claude/skills.md §6) and skill names (§2): a SkillsService whose library holds the
/// valid skills alpha, beta and gamma.
final class SkillPluginTests: XCTestCase {
    private var appSupport: AppSupport!
    private var service: SkillsService!

    override func setUp() async throws {
        try await super.setUp()
        let root = try makeTemporaryDirectory()
        appSupport = AppSupport(root: root, trashItem: { url in
            try FileManager.default.removeItem(at: url)
        })
        for name in ["alpha", "beta", "gamma"] {
            try writeSkill(name, SkillFrontMatter.template(name: name, description: "The \(name) skill."))
        }
        service = SkillsService(host: TestSkillsHost(support: appSupport))
        await service.start()
    }

    override func tearDown() async throws {
        await service?.stop()
        service = nil
        appSupport = nil
        try await super.tearDown()
    }

    func testEnabledSkills() async throws {
        let sessionID = UUID()
        let folder = try await service.buildPluginFolder(sessionID: sessionID, enabled: ["alpha", "gamma"])
        XCTAssertEqual(folder.standardizedFileURL, appSupport.sessionPluginsFolder
            .appendingPathComponent(SessionFile.fileStem(sessionID), isDirectory: true)
            .appendingPathComponent("hephaestus", isDirectory: true).standardizedFileURL)
        let manifest = try Data(contentsOf: folder.appendingPathComponent(".claude-plugin/plugin.json"))
        XCTAssertEqual(manifest,
                       Data(#"{"name":"hephaestus","version":"1.0.0","description":"Skills managed by Hephaestus"}"#.utf8))
        XCTAssertEqual(try links(in: folder), ["alpha": libraryPath("alpha"), "gamma": libraryPath("gamma")])
    }

    func testAllSkills() async throws {
        let folder = try await service.buildPluginFolder(sessionID: UUID(), enabled: [])
        XCTAssertEqual(try links(in: folder), ["alpha": libraryPath("alpha"), "beta": libraryPath("beta"),
                                               "gamma": libraryPath("gamma")])
    }

    func testSkipped() async throws {
        try writeSkill("delta", "---\nname: other\ndescription: A skill whose front matter has a problem.\n---\n")
        let folder = try await service.buildPluginFolder(sessionID: UUID(), enabled: ["alpha", "missing", "delta"])
        XCTAssertEqual(try links(in: folder), ["alpha": libraryPath("alpha")])
        let every = try await service.buildPluginFolder(sessionID: UUID(), enabled: [])
        XCTAssertEqual(Set(try links(in: every).keys), ["alpha", "beta", "gamma"])
    }

    func testRebuild() async throws {
        let sessionID = UUID()
        let first = try await service.buildPluginFolder(sessionID: sessionID, enabled: ["alpha"])
        try Data("left over".utf8).write(to: first.deletingLastPathComponent().appendingPathComponent("extra.txt"))
        let second = try await service.buildPluginFolder(sessionID: sessionID, enabled: ["beta"])
        XCTAssertEqual(first, second)
        XCTAssertEqual(try links(in: second), ["beta": libraryPath("beta")])
        let session = second.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: session.path), ["hephaestus"])
    }

    func testSkillNames() {
        for name in ["a", "my-skill-2", String(repeating: "a", count: 64)] {
            XCTAssertTrue(SkillName.isValid(name), name)
        }
        for name in ["", String(repeating: "a", count: 65), "My", "a_b", "a b"] {
            XCTAssertFalse(SkillName.isValid(name), name)
        }
    }

    // MARK: - Helpers

    private func writeSkill(_ name: String, _ content: String) throws {
        let folder = appSupport.skillsFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
    }

    private func libraryPath(_ name: String) -> String {
        appSupport.skillsFolder.appendingPathComponent(name, isDirectory: true).path
    }

    /// The entries of `skills/`: each must be a symbolic link; its name and its target.
    private func links(in pluginFolder: URL) throws -> [String: String] {
        let skills = pluginFolder.appendingPathComponent("skills", isDirectory: true)
        var links: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: skills.path) {
            let path = skills.appendingPathComponent(name).path
            let type = try FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType
            XCTAssertEqual(type, .typeSymbolicLink, name)
            links[name] = try FileManager.default.destinationOfSymbolicLink(atPath: path)
        }
        return links
    }
}

/// A SkillsHost on a temporary Application Support folder: broadcasts do nothing and there is no peer link.
private struct TestSkillsHost: SkillsHost {
    let support: AppSupport

    func appSupport() async -> AppSupport {
        support
    }

    func broadcastSkillsChanged(_ skills: [SkillSummary]) async {}

    func requestPeer(_ deviceID: UUID, method: String, params: Data) async throws -> Data {
        throw ProtocolError(.unavailable, "No peer link in this test.")
    }
}
#endif
