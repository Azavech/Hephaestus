#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// A real Claude session (docs/claude/cli.md): runs the Claude CLI, which uses the network. Skipped unless the
/// environment variable HEPH_LIVE_CLAUDE is 1; never run in CI.
@MainActor
final class LiveClaudeTests: XCTestCase {
    func testProjectSession() async throws {
        guard ProcessInfo.processInfo.environment["HEPH_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("Set HEPH_LIVE_CLAUDE=1 to run the live Claude test.")
        }
        let testHost = try await startTestHost()
        _ = try await testHost.perform(.projectsCreate, ProjectsCreateParams(name: "Fixture", identifier: "FIX"),
                                       as: ProjectSummary.self)
        let sessions = testHost.host.sessions
        let device = await testHost.host.mesh.localDevice()
        let session = try await sessions.start(SessionStart(projectID: "FIX", kind: .project,
                                                            message: "Reply with exactly: OK", model: "haiku",
                                                            deviceID: device.id))
        XCTAssertNotEqual(session.status, .failed, session.error ?? "")

        try await waitUntil(timeout: .seconds(120)) {
            let history = try await sessions.history(projectID: "FIX", sessionID: session.id, before: nil, limit: nil)
            let answered = history.events.contains { $0.type == .assistant && ($0.text ?? "").contains("OK") }
            let finished = history.events.contains { $0.type == .result && $0.isError == false }
            return answered && finished
        }
        try await sessions.stop(projectID: "FIX", sessionID: session.id)
        let stopped = try await sessions.sessions(projectID: "FIX").first { $0.id == session.id }
        XCTAssertEqual(stopped?.status, .stopped)
    }
}
#endif
