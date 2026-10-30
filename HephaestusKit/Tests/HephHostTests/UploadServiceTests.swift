#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// Uploads and ranged reads (docs/services/files.md §7, docs/protocol/methods.md "Uploads"): a TestHost with a
/// project HEPH and a task HEPH-1, every request through `host.perform(_:params:context: deviceContext)`.
@MainActor
final class UploadServiceTests: XCTestCase {
    private static let mebibytes4 = 4_194_304
    private static let bigSize = 10_485_760

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

    func testChunksInOrder() async throws {
        let id = try await begin(fileName: "big.zip", size: Self.bigSize)
        let file = uploadURL(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
        let bytes = Self.bytes(Self.bigSize)
        for offset in [0, Self.mebibytes4, 2 * Self.mebibytes4] {
            let end = min(offset + Self.mebibytes4, bytes.count)
            let result = try await testHost.host.perform(
                RPCMethod.uploadsChunk.rawValue,
                params: WireCoding.encodeJSON(UploadsChunkParams(uploadID: id, offset: offset,
                                                                 data: bytes.subdata(in: offset..<end))),
                context: testHost.deviceContext)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: result) as? [String: Int], [:])
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testChunkErrors() async throws {
        let id = try await begin(fileName: "big.zip", size: Self.bigSize)
        await assertProtocolError(.badRequest) {
            try await self.chunk(id, offset: 1, data: Data([1, 2, 3]))
        }
        await assertProtocolError(.tooLarge) {
            try await self.chunk(id, offset: 0, data: Data(count: Self.mebibytes4 + 1))
        }
        await assertProtocolError(.badRequest) {
            try await self.chunk(id, offset: 0, data: Data())
        }
        let small = try await begin(fileName: "small.bin", size: 10)
        await assertProtocolError(.badRequest) {
            try await self.chunk(small, offset: 0, data: Data(count: 11))
        }
        await assertProtocolError(.notFound) {
            try await self.chunk(UUID(), offset: 0, data: Data([1]))
        }
    }

    func testAttachToComment() async throws {
        let bytes = Self.bytes(Self.bigSize)
        let id = try await upload(bytes, fileName: "big.zip")
        let task = try await addComment(UploadRef(uploadID: id, fileName: "big.zip"))
        let attachment = try XCTUnwrap(task.comments.last?.attachments.first)
        XCTAssertEqual(attachment.file, "big.zip")
        XCTAssertEqual(attachment.size, Self.bigSize)
        XCTAssertEqual(attachment.type, "application/zip")
        let root = try await testHost.host.registry.hosted("HEPH").root
        let stored = root.appendingPathComponent(".hephaestus/attachments/HEPH-1/big.zip", isDirectory: false)
        XCTAssertEqual(try Data(contentsOf: stored), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploadURL(id).path))
        await assertProtocolError(.notFound) {
            try await self.addComment(UploadRef(uploadID: id, fileName: "big.zip"))
        }
    }

    func testIncompleteUpload() async throws {
        let id = try await begin(fileName: "part.bin", size: 10)
        try await chunk(id, offset: 0, data: Data([1, 2, 3, 4]))
        await assertProtocolError(.badRequest, "Upload \(id.uuidString) is incomplete.") {
            try await self.addComment(UploadRef(uploadID: id, fileName: "part.bin"))
        }
        let task = try await testHost.host.tasks.task(projectID: "HEPH", taskID: "HEPH-1")
        XCTAssertTrue(task.comments.isEmpty)
    }

    func testFailedRequestKeepsUpload() async throws {
        let bytes = Self.bytes(1_000)
        let id = try await upload(bytes, fileName: "notes.txt")
        let ref = UploadRef(uploadID: id, fileName: "notes.txt")
        await assertProtocolError(.notFound) {
            try await self.addComment(ref, taskID: "HEPH-99")
        }
        let task = try await addComment(ref)
        XCTAssertEqual(task.comments.last?.attachments.first?.file, "notes.txt")
        let root = try await testHost.host.registry.hosted("HEPH").root
        let stored = root.appendingPathComponent(".hephaestus/attachments/HEPH-1/notes.txt", isDirectory: false)
        XCTAssertEqual(try Data(contentsOf: stored), bytes)
    }

    func testOtherProject() async throws {
        _ = try await testHost.perform(.projectsCreate, ProjectsCreateParams(name: "Atlas", identifier: "ATLAS"),
                                       as: ProjectSummary.self)
        _ = try await testHost.perform(.tasksCreate, TasksCreateParams(projectID: "ATLAS", name: "Map"),
                                       as: TaskItem.self)
        let id = try await upload(Self.bytes(100), fileName: "map.png")
        await assertProtocolError(.badRequest, "Upload \(id.uuidString) belongs to another project.") {
            try await self.testHost.perform(.tasksAddComment,
                                            TasksAddCommentParams(projectID: "ATLAS", taskID: "ATLAS-1", body: "Map",
                                                                  attachments: [UploadRef(uploadID: id,
                                                                                          fileName: "map.png")]),
                                            as: TaskItem.self)
        }
    }

    func testCancel() async throws {
        let id = try await begin(fileName: "big.zip", size: Self.bigSize)
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploadURL(id).path))
        try await cancel(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploadURL(id).path))
        await assertProtocolError(.notFound) {
            try await self.chunk(id, offset: 0, data: Data([1]))
        }
        try await cancel(id)
    }

    func testExpiry() async throws {
        let id = try await begin(fileName: "big.zip", size: Self.bigSize)
        let now = Date()
        await testHost.host.uploads.sweep(now: now.addingTimeInterval(3_500))
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploadURL(id).path))
        await testHost.host.uploads.sweep(now: now.addingTimeInterval(3_601))
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploadURL(id).path))
        await assertProtocolError(.notFound) {
            try await self.chunk(id, offset: 0, data: Data([1]))
        }
    }

    func testRangedAttachmentReads() async throws {
        let bytes = Self.bytes(Self.bigSize)
        let id = try await upload(bytes, fileName: "big.zip")
        _ = try await addComment(UploadRef(uploadID: id, fileName: "big.zip"))
        var read = Data()
        for (offset, expected) in [(0, Self.mebibytes4), (Self.mebibytes4, Self.mebibytes4),
                                   (2 * Self.mebibytes4, Self.bigSize - 2 * Self.mebibytes4)] {
            let result = try await readAttachment(offset: offset, length: nil)
            XCTAssertEqual(result.data.count, expected)
            XCTAssertEqual(result.size, Self.bigSize)
            read.append(result.data)
        }
        XCTAssertEqual(read, bytes)
        let end = try await readAttachment(offset: Self.bigSize, length: nil)
        XCTAssertTrue(end.data.isEmpty)
        await assertProtocolError(.badRequest) {
            try await self.readAttachment(offset: Self.bigSize + 1, length: nil)
        }
        let long = try await readAttachment(offset: 0, length: 2 * Self.mebibytes4)
        XCTAssertEqual(long.data.count, Self.mebibytes4)
    }

    func testRangedFileRead() async throws {
        let size = 12_582_912
        let root = try await testHost.host.registry.hosted("HEPH").root
        let bytes = Self.bytes(size)
        try bytes.write(to: root.appendingPathComponent("big.bin", isDirectory: false))
        await assertProtocolError(.tooLarge) {
            try await self.testHost.perform(.filesRead, FilesReadParams(projectID: "HEPH", path: "big.bin"),
                                            as: FilesReadResult.self)
        }
        let result = try await testHost.perform(.filesRead,
                                                FilesReadParams(projectID: "HEPH", path: "big.bin", offset: 0),
                                                as: FilesReadResult.self)
        XCTAssertEqual(result.data, bytes.subdata(in: 0..<Self.mebibytes4))
        XCTAssertEqual(result.revision, "")
        XCTAssertEqual(result.size, size)
    }

    func testSessionAttachment() async throws {
        let sessionID = UUID()
        let root = try await testHost.host.registry.hosted("HEPH").root
        let folder = root.appendingPathComponent(".hephaestus/sessions/\(sessionID.uuidString.lowercased())",
                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Self.bytes(2_048)
        try bytes.write(to: folder.appendingPathComponent("shot.png", isDirectory: false))
        let result = try await testHost.perform(.sessionsReadAttachment,
                                                SessionsReadAttachmentParams(projectID: "HEPH", sessionID: sessionID,
                                                                             fileName: "shot.png"),
                                                as: AttachmentsReadResult.self)
        XCTAssertEqual(result.data, bytes)
        XCTAssertEqual(result.size, bytes.count)
        XCTAssertEqual(result.mimeType, "image/png")
        await assertProtocolError(.notFound) {
            try await self.testHost.perform(.sessionsReadAttachment,
                                            SessionsReadAttachmentParams(projectID: "HEPH", sessionID: sessionID,
                                                                         fileName: "other.png"),
                                            as: AttachmentsReadResult.self)
        }
    }

    // MARK: - Helpers

    /// Bytes of a repeating pattern that is not a multiple of the chunk size.
    private static func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<count {
                buffer[index] = UInt8(truncatingIfNeeded: index % 251)
            }
        }
        return data
    }

    /// `Uploads/<id>`.
    private func uploadURL(_ id: UUID) -> URL {
        testHost.appSupport.uploadsFolder.appendingPathComponent(id.uuidString, isDirectory: false)
    }

    private func begin(fileName: String, size: Int) async throws -> UUID {
        try await testHost.perform(.uploadsBegin, UploadsBeginParams(projectID: "HEPH", fileName: fileName, size: size),
                                   as: UploadsBeginResult.self).uploadID
    }

    private func chunk(_ id: UUID, offset: Int, data: Data) async throws {
        _ = try await testHost.perform(.uploadsChunk, UploadsChunkParams(uploadID: id, offset: offset, data: data),
                                       as: EmptyPayload.self)
    }

    /// `uploads.cancel`, whose result must be `{}`.
    private func cancel(_ id: UUID) async throws {
        let result = try await testHost.host.perform(RPCMethod.uploadsCancel.rawValue,
                                                     params: WireCoding.encodeJSON(UploadsCancelParams(uploadID: id)),
                                                     context: testHost.deviceContext)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: result) as? [String: Int], [:])
    }

    /// A complete upload of `bytes` for HEPH, in chunks of 4 MiB.
    private func upload(_ bytes: Data, fileName: String) async throws -> UUID {
        let id = try await begin(fileName: fileName, size: bytes.count)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + Self.mebibytes4, bytes.count)
            try await chunk(id, offset: offset, data: bytes.subdata(in: offset..<end))
            offset = end
        }
        return id
    }

    @discardableResult
    private func addComment(_ ref: UploadRef, taskID: String = "HEPH-1") async throws -> TaskItem {
        try await testHost.perform(.tasksAddComment,
                                   TasksAddCommentParams(projectID: "HEPH", taskID: taskID, body: "Attachment",
                                                         attachments: [ref]),
                                   as: TaskItem.self)
    }

    private func readAttachment(offset: Int, length: Int?) async throws -> AttachmentsReadResult {
        try await testHost.perform(.attachmentsRead,
                                   AttachmentsReadParams(projectID: "HEPH", taskID: "HEPH-1", fileName: "big.zip",
                                                         offset: offset, length: length),
                                   as: AttachmentsReadResult.self)
    }
}
#endif
