import Foundation
import XCTest

/// The repository root: four levels above this file (HephaestusKit/Tests/HephCoreTests/CoreTestSupport.swift).
let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

extension XCTestCase {
    /// A new folder under the temporary directory, with a UUID in its name, removed at teardown.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
