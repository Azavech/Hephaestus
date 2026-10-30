import Foundation
import XCTest
@testable import HephCore

final class DocsHashTests: XCTestCase {
    private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let secondHash = "bf4d60c2ef59fbdaabdcf5b66d49771430ea42d75cdb231b066cf6f27a777c70"

    func testVectors() {
        XCTAssertEqual(DocsHash.compute([]), emptyHash)
        let files = [
            DocsHash.File(path: "docs/b/c.md", content: Data("c\n".utf8)),
            DocsHash.File(path: "docs/.DS_Store", content: Data("x".utf8)),
            DocsHash.File(path: "docs/a.md", content: Data("a\n".utf8)),
        ]
        XCTAssertEqual(DocsHash.compute(files), secondHash)
    }

    func testWorkingTree() throws {
        let repository = try makeRepository()
        XCTAssertEqual(try DocsHash.compute(repositoryRoot: repository), secondHash)
    }

    func testMatchesScript() throws {
        let repository = try makeRepository()
        let scripts = repository.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("docs-hash.sh")
        try FileManager.default.copyItem(at: repositoryRoot.appendingPathComponent("scripts/docs-hash.sh"), to: script)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = repository
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let printed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(printed, try DocsHash.compute(repositoryRoot: repository))
        XCTAssertEqual(printed, secondHash)
    }

    func testMissingDocs() throws {
        let repository = try makeTemporaryDirectory()
        XCTAssertThrowsError(try DocsHash.compute(repositoryRoot: repository))
    }

    /// A repository with docs/a.md = "a\n", docs/b/c.md = "c\n" and docs/.DS_Store = "x".
    private func makeRepository() throws -> URL {
        let repository = try makeTemporaryDirectory()
        let docs = repository.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs.appendingPathComponent("b", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data("a\n".utf8).write(to: docs.appendingPathComponent("a.md"))
        try Data("c\n".utf8).write(to: docs.appendingPathComponent("b/c.md"))
        try Data("x".utf8).write(to: docs.appendingPathComponent(".DS_Store"))
        return repository
    }
}
