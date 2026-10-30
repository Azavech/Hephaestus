#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// Comments and their authors (docs/protocol/methods.md, "tasks.updateComment"): a TestHost with a project HEPH and a
/// task HEPH-1.
@MainActor
final class TaskCommentTests: XCTestCase {
    private var testHost: TestHost!

    override func setUp() async throws {
        try await super.setUp()
        testHost = try await startTestHost()
        _ = try await testHost.perform(.projectsCreate, ProjectsCreateParams(name: "Hephaestus", identifier: "HEPH"),
                                       as: ProjectSummary.self)
        let task = try await testHost.perform(.tasksCreate,
                                              TasksCreateParams(projectID: "HEPH", name: "Sidebar breaks on iPad"),
                                              as: TaskItem.self)
        XCTAssertEqual(task.id, "HEPH-1")
    }

    override func tearDown() async throws {
        testHost = nil
        try await super.tearDown()
    }

    func testClaudeCommentCannotBeEdited() async throws {
        let comment = try await addComment("Claude's analysis.", context: testHost.claudeContext)
        XCTAssertEqual(comment.author, "Claude")
        let before = try await taskFile()
        await assertProtocolError(.badRequest, "Claude's comments cannot be edited.") {
            try await self.testHost.perform(.tasksUpdateComment,
                                            TasksUpdateCommentParams(projectID: "HEPH", taskID: "HEPH-1",
                                                                     commentID: comment.id, body: "Edited."),
                                            as: TaskItem.self)
        }
        let after = try await taskFile()
        XCTAssertEqual(after, before)
    }

    func testClaudeCommentCanBeDeleted() async throws {
        let comment = try await addComment("Claude's analysis.", context: testHost.claudeContext)
        let task = try await testHost.perform(.tasksDeleteComment,
                                              TasksDeleteCommentParams(projectID: "HEPH", taskID: "HEPH-1",
                                                                       commentID: comment.id),
                                              as: TaskItem.self)
        XCTAssertTrue(task.comments.isEmpty)
        let file = try await taskFile()
        XCTAssertTrue(file.comments.isEmpty)
    }

    func testDeviceCommentEditable() async throws {
        let comment = try await addComment("First body.", context: testHost.deviceContext)
        XCTAssertNil(comment.edited)
        let task = try await testHost.perform(.tasksUpdateComment,
                                              TasksUpdateCommentParams(projectID: "HEPH", taskID: "HEPH-1",
                                                                       commentID: comment.id, body: "Second body."),
                                              as: TaskItem.self)
        let updated = try XCTUnwrap(task.comments.first { $0.id == comment.id })
        XCTAssertEqual(updated.body, "Second body.")
        XCTAssertNotNil(updated.edited)
        let file = try await taskFile()
        XCTAssertEqual(file.comments.first?.body, "Second body.")
    }

    // MARK: - Helpers

    /// `tasks.addComment` on HEPH-1; the new comment.
    private func addComment(_ body: String, context: RequestContext) async throws -> TaskComment {
        let task = try await testHost.perform(.tasksAddComment,
                                              TasksAddCommentParams(projectID: "HEPH", taskID: "HEPH-1", body: body,
                                                                    attachments: []),
                                              as: TaskItem.self, context: context)
        return try XCTUnwrap(task.comments.last)
    }

    /// The task file of HEPH-1 on disk, decoded.
    private func taskFile() async throws -> TaskFile {
        let root = try await testHost.host.registry.hosted("HEPH").root
        let id = try XCTUnwrap(TaskID("HEPH-1"))
        let text = try String(contentsOf: TaskFile.url(projectRoot: root, id: id), encoding: .utf8)
        return try TaskFile.decode(text, fileID: id)
    }
}
#endif
