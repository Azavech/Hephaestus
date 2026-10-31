#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// Comments and their authors (docs/protocol/methods.md, "tickets.updateComment"): a TestHost with a project HEPH and
/// a ticket HEPH-1.
@MainActor
final class TicketCommentTests: XCTestCase {
    private var testHost: TestHost!

    override func setUp() async throws {
        try await super.setUp()
        testHost = try await startTestHost()
        _ = try await testHost.perform(.projectsCreate, ProjectsCreateParams(name: "Hephaestus", identifier: "HEPH"),
                                       as: ProjectSummary.self)
        let ticket = try await testHost.perform(.ticketsCreate,
                                                TicketsCreateParams(projectID: "HEPH", name: "Sidebar breaks on iPad"),
                                                as: TicketItem.self)
        XCTAssertEqual(ticket.id, "HEPH-1")
    }

    override func tearDown() async throws {
        testHost = nil
        try await super.tearDown()
    }

    func testClaudeCommentCannotBeEdited() async throws {
        let comment = try await addComment("Claude's analysis.", context: testHost.claudeContext)
        XCTAssertEqual(comment.author, "Claude")
        let before = try await ticketFile()
        await assertProtocolError(.badRequest, "Claude's comments cannot be edited.") {
            try await self.testHost.perform(.ticketsUpdateComment,
                                            TicketsUpdateCommentParams(projectID: "HEPH", ticketID: "HEPH-1",
                                                                       commentID: comment.id, body: "Edited."),
                                            as: TicketItem.self)
        }
        let after = try await ticketFile()
        XCTAssertEqual(after, before)
    }

    func testClaudeCommentCanBeDeleted() async throws {
        let comment = try await addComment("Claude's analysis.", context: testHost.claudeContext)
        let ticket = try await testHost.perform(.ticketsDeleteComment,
                                                TicketsDeleteCommentParams(projectID: "HEPH", ticketID: "HEPH-1",
                                                                           commentID: comment.id),
                                                as: TicketItem.self)
        XCTAssertTrue(ticket.comments.isEmpty)
        let file = try await ticketFile()
        XCTAssertTrue(file.comments.isEmpty)
    }

    func testDeviceCommentEditable() async throws {
        let comment = try await addComment("First body.", context: testHost.deviceContext)
        XCTAssertNil(comment.edited)
        let ticket = try await testHost.perform(.ticketsUpdateComment,
                                                TicketsUpdateCommentParams(projectID: "HEPH", ticketID: "HEPH-1",
                                                                           commentID: comment.id, body: "Second body."),
                                                as: TicketItem.self)
        let updated = try XCTUnwrap(ticket.comments.first { $0.id == comment.id })
        XCTAssertEqual(updated.body, "Second body.")
        XCTAssertNotNil(updated.edited)
        let file = try await ticketFile()
        XCTAssertEqual(file.comments.first?.body, "Second body.")
    }

    // MARK: - Helpers

    /// `tickets.addComment` on HEPH-1; the new comment.
    private func addComment(_ body: String, context: RequestContext) async throws -> TicketComment {
        let ticket = try await testHost.perform(.ticketsAddComment,
                                                TicketsAddCommentParams(projectID: "HEPH", ticketID: "HEPH-1", body: body,
                                                                        attachments: []),
                                                as: TicketItem.self, context: context)
        return try XCTUnwrap(ticket.comments.last)
    }

    /// The ticket file of HEPH-1 on disk, decoded.
    private func ticketFile() async throws -> TicketFile {
        let root = try await testHost.host.registry.hosted("HEPH").root
        let id = try XCTUnwrap(TicketID("HEPH-1"))
        let text = try String(contentsOf: TicketFile.url(projectRoot: root, id: id), encoding: .utf8)
        return try TicketFile.decode(text, fileID: id)
    }
}
#endif
