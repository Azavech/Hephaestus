import Foundation
import XCTest
@testable import HephCore

/// The repository root: four levels above this file (HephaestusKit/Tests/HephCoreTests/CoreTestSupport.swift).
let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// The mesh credentials of the tests: mesh id 00000000-0000-4000-8000-000000000100, a key of 32 bytes 0x01.
let testCredentials = MeshCredentials(meshID: UUID(uuidString: "00000000-0000-4000-8000-000000000100")!,
                                      meshKey: Data(repeating: 0x01, count: 32))

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

/// The error thrown by `waitUntil` when the condition does not hold in time.
struct WaitTimedOut: Error {}

/// Waits until `condition` holds, polling every 10 ms; fails the test and throws after `timeout`.
func waitUntil(timeout: Duration = .seconds(5), _ condition: () async throws -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("The condition did not hold within \(timeout).", file: file, line: line)
            throw WaitTimedOut()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
