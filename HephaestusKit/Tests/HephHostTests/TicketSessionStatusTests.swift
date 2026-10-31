#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// The status of a ticket while its sessions work (docs/services/host.md 8.1): a TestHost with a project HEPH and the
/// tickets HEPH-1 and HEPH-2, status todo. Each case gives `TicketService.sessionChanged` the `SessionInfo` values of
/// one session id, in order, and reads the ticket; it starts no Claude CLI.
@MainActor
final class TicketSessionStatusTests: XCTestCase {
    private var testHost: TestHost!

    override func setUp() async throws {
        try await super.setUp()
        testHost = try await startTestHost()
        _ = try await testHost.perform(.projectsCreate, ProjectsCreateParams(name: "Hephaestus", identifier: "HEPH"),
                                       as: ProjectSummary.self)
        for (index, name) in ["Sidebar", "Toolbar"].enumerated() {
            let ticket = try await testHost.perform(.ticketsCreate, TicketsCreateParams(projectID: "HEPH", name: name),
                                                    as: TicketItem.self)
            XCTAssertEqual(ticket.id, "HEPH-\(index + 1)")
            XCTAssertEqual(ticket.status, .todo)
        }
    }

    override func tearDown() async throws {
        testHost = nil
        try await super.tearDown()
    }

    func testTurnSetsInProgressThenReview() async throws {
        let session = SessionChanges(self, kind: .ticket, ticketID: "HEPH-1", mode: .review)
        try await session.expect([.starting], "HEPH-1", .todo)
        try await session.expect([.running], "HEPH-1", .inProgress)
        try await session.expect([.waitingPermission, .running], "HEPH-1", .inProgress)
        try await session.expect([.idle], "HEPH-1", .review)
        // Stopped by its idle timer.
        try await session.expect([.stopped], "HEPH-1", .review)
    }

    func testStopAndFailureSetReview() async throws {
        let session = SessionChanges(self, kind: .ticket, ticketID: "HEPH-1")
        try await session.expect([.running, .stopped], "HEPH-1", .review)
        try await session.expect([.running, .failed], "HEPH-1", .review)
        try await session.expect([.starting, .failed], "HEPH-1", .review)
    }

    func testDoneTicketReopens() async throws {
        try await setStatus("HEPH-1", .done)
        let session = SessionChanges(self, kind: .ticket, ticketID: "HEPH-1")
        try await session.expect([.idle], "HEPH-1", .done)
        try await session.expect([.running], "HEPH-1", .inProgress)
        try await session.expect([.idle], "HEPH-1", .review)
    }

    func testFeedbackSession() async throws {
        let session = SessionChanges(self, kind: .feedback, ticketID: "HEPH-1")
        try await session.expect([.running], "HEPH-1", .inProgress)
        try await session.expect([.idle], "HEPH-1", .review)
    }

    func testUnknownPreviousStatus() async throws {
        let restarted = SessionChanges(self, kind: .ticket, ticketID: "HEPH-1")
        try await restarted.expect([.idle, .stopped], "HEPH-1", .todo)
        let other = SessionChanges(self, kind: .ticket, ticketID: "HEPH-1")
        try await other.expect([.running], "HEPH-1", .inProgress)
    }

    func testOtherSessionsIgnored() async throws {
        let project = SessionChanges(self, kind: .project)
        try await project.send([.running, .idle])
        let bundle = SessionChanges(self, kind: .bundle, bundleID: "HEPH-B1")
        try await bundle.send([.running, .idle])
        let one = try await status("HEPH-1")
        let two = try await status("HEPH-2")
        XCTAssertEqual(one, .todo)
        XCTAssertEqual(two, .todo)
        let missing = SessionChanges(self, kind: .ticket, ticketID: "HEPH-9")
        try await missing.send([.running, .idle])
        let tickets = try await testHost.host.tickets.list(projectID: "HEPH")
        XCTAssertEqual(tickets.map(\.id), ["HEPH-1", "HEPH-2"])
        await assertProtocolError(.notFound) {
            try await self.testHost.host.tickets.ticket(projectID: "HEPH", ticketID: "HEPH-9")
        }
    }

    func testUserStatusKeptDuringTurn() async throws {
        let session = SessionChanges(self, kind: .ticket, ticketID: "HEPH-2")
        try await session.expect([.running], "HEPH-2", .inProgress)
        try await setStatus("HEPH-2", .todo)
        try await session.expect([.waitingPermission, .running], "HEPH-2", .todo)
        try await session.expect([.idle], "HEPH-2", .review)
    }

    // MARK: - Helpers

    /// The status of a ticket, from `TicketService.ticket(projectID:ticketID:)`.
    fileprivate func status(_ ticketID: String) async throws -> TicketStatus {
        try await testHost.host.tickets.ticket(projectID: "HEPH", ticketID: ticketID).status
    }

    /// `tickets.update` of a ticket's status.
    private func setStatus(_ ticketID: String, _ status: TicketStatus) async throws {
        let ticket = try await testHost.perform(.ticketsUpdate,
                                                TicketsUpdateParams(projectID: "HEPH", ticketID: ticketID,
                                                                    patch: TicketPatch(status: status)),
                                                as: TicketItem.self)
        XCTAssertEqual(ticket.status, status)
    }

    /// The `SessionInfo` values of one session id, given to `sessionChanged` in order.
    @MainActor
    private struct SessionChanges {
        let test: TicketSessionStatusTests
        let session: SessionInfo

        init(_ test: TicketSessionStatusTests, kind: SessionKind, ticketID: String? = nil, mode: SessionMode? = nil,
             bundleID: String? = nil) {
            self.test = test
            let date = Date()
            session = SessionInfo(id: UUID(), kind: kind, ticketID: ticketID,
                                  mode: mode ?? (kind == .ticket ? .implement : nil), bundleID: bundleID,
                                  title: "Chat 1", created: date, updated: date, permissionMode: .manual,
                                  allowsAllTools: false, status: .stopped, pendingPermissions: [])
        }

        func send(_ statuses: [SessionStatus]) async throws {
            for status in statuses {
                var info = session
                info.status = status
                await test.testHost.host.tickets.sessionChanged(projectID: "HEPH", session: info)
            }
        }

        /// Sends `statuses`, then expects `ticketID` to have `expected`.
        func expect(_ statuses: [SessionStatus], _ ticketID: String, _ expected: TicketStatus,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
            try await send(statuses)
            let status = try await test.status(ticketID)
            XCTAssertEqual(status, expected, "\(statuses)", file: file, line: line)
        }
    }
}
#endif
