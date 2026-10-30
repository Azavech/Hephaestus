import Foundation
import XCTest
@testable import HephClient
@testable import HephCore
@testable import HephNet

@MainActor
final class EditorDocumentTests: XCTestCase {
    /// A document of `notes.txt` on the connected Main, whose `files.read` answers `content`.
    private func document(_ content: Data, after delay: Duration? = nil) async throws
        -> (document: EditorDocument, fakeMain: FakeMain) {
        let mainID = UUID()
        let projects = [TestMesh.summary("HEPH", mainID: mainID)]
        let (workspace, fakeMain, _) = try await connectedWorkspace(projects: projects, mainID: mainID) { fakeMain in
            fakeMain.answer("files.read",
                            with: FilesReadResult(data: content, revision: Revision.of(content), size: content.count),
                            after: delay)
        }
        let files = ProjectFiles(workspace: workspace, mainDeviceID: mainID, projectID: "HEPH")
        let document = EditorDocument(files: files, path: "notes.txt")
        addTeardownBlock { @MainActor in
            document.close()
        }
        return (document, fakeMain)
    }

    private func range(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    func testSelectLine() async throws {
        let (document, _) = try await document(Data("a\r\nbb\r\nccc".utf8))
        await document.load()
        XCTAssertEqual(document.content, .text)
        document.selectLine(1)
        XCTAssertEqual(document.selection, range(0, 1))
        document.selectLine(2)
        XCTAssertEqual(document.selection, range(3, 2))
        document.selectLine(3)
        XCTAssertEqual(document.selection, range(7, 3))
        document.selectLine(9)
        XCTAssertEqual(document.selection, range(7, 3))
    }

    func testTrailingNewline() async throws {
        let (document, _) = try await document(Data("x\n".utf8))
        await document.load()
        document.selectLine(2)
        XCTAssertEqual(document.selection, range(2, 0))
        document.selectLine(3)
        XCTAssertEqual(document.selection, range(2, 0))
    }

    func testSelectWhileLoading() async throws {
        let (document, fakeMain) = try await document(Data("a\nb".utf8), after: .milliseconds(300))
        let loading = Task { @MainActor in
            await document.load()
        }
        try await waitUntil { fakeMain.requests("files.read").count == 1 }
        XCTAssertEqual(document.content, .loading)
        document.selectLine(2)
        XCTAssertEqual(document.selection, range(0, 0))
        await loading.value
        XCTAssertEqual(document.content, .text)
        XCTAssertEqual(document.selection, range(2, 1))
    }

    func testNotText() async throws {
        let (document, _) = try await document(Data([0x00, 0x01]))
        await document.load()
        XCTAssertEqual(document.content, .binary(size: 2))
        document.selectLine(1)
        XCTAssertEqual(document.selection, range(0, 0))
    }
}
