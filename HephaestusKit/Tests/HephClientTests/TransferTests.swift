import Foundation
import XCTest
@testable import HephClient
@testable import HephCore
@testable import HephNet

@MainActor
final class TransferTests: XCTestCase {
    private let mebibytes4 = 4_194_304
    private let size9MiB = 9_437_184

    /// Bytes that differ from one offset to the next.
    private func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 13) })
    }

    private final class ProgressLog {
        var reports: [TransferProgress] = []
    }

    func testUploadChunks() async throws {
        let uploadID = UUID()
        let (workspace, fakeMain, _) = try await connectedWorkspace { fakeMain in
            fakeMain.answer("uploads.begin", with: UploadsBeginResult(uploadID: uploadID))
            fakeMain.answer("uploads.chunk", with: EmptyPayload())
        }
        let connection = try XCTUnwrap(workspace.connection(fakeMain.device.id))
        let source = pattern(size9MiB)
        let progress = ProgressLog()
        let reference = try await connection.upload(fileName: "a.bin", projectID: "HEPH", source: .data(source)) {
            progress.reports.append($0)
        }

        XCTAssertEqual(reference, UploadRef(uploadID: uploadID, fileName: "a.bin"))
        let begin = try XCTUnwrap(fakeMain.requests("uploads.begin").first)
        XCTAssertEqual(begin.json, ["projectID": "HEPH", "fileName": "a.bin", "size": size9MiB])
        let chunks = try fakeMain.requests("uploads.chunk").map { try $0.decode(UploadsChunkParams.self) }
        XCTAssertEqual(chunks.map(\.offset), [0, mebibytes4, 2 * mebibytes4])
        XCTAssertEqual(chunks.map(\.data.count), [mebibytes4, mebibytes4, 1_048_576])
        XCTAssertEqual(chunks.map(\.uploadID), [uploadID, uploadID, uploadID])
        XCTAssertEqual(chunks.reduce(Data()) { $0 + $1.data }, source)
        XCTAssertEqual(progress.reports.last, TransferProgress(completed: size9MiB, total: size9MiB))
    }

    func testUploadFromFile() async throws {
        let uploadID = UUID()
        let (workspace, fakeMain, environment) = try await connectedWorkspace { fakeMain in
            fakeMain.answer("uploads.begin", with: UploadsBeginResult(uploadID: uploadID))
            fakeMain.answer("uploads.chunk", with: EmptyPayload())
        }
        let connection = try XCTUnwrap(workspace.connection(fakeMain.device.id))
        let bytes = pattern(5 * 1_048_576)
        try FileManager.default.createDirectory(at: environment.folder, withIntermediateDirectories: true)
        let file = environment.folder.appending(path: "upload.bin", directoryHint: .notDirectory)
        try bytes.write(to: file)

        let reference = try await connection.upload(fileName: "upload.bin", projectID: "HEPH", source: .file(file)) {
            _ in
        }
        XCTAssertEqual(reference, UploadRef(uploadID: uploadID, fileName: "upload.bin"))
        let begin = try XCTUnwrap(fakeMain.requests("uploads.begin").first)
        XCTAssertEqual(begin.json["size"] as? Int, bytes.count)
        let chunks = try fakeMain.requests("uploads.chunk").map { try $0.decode(UploadsChunkParams.self) }
        XCTAssertEqual(chunks.map(\.offset), [0, mebibytes4])
        XCTAssertEqual(chunks.reduce(Data()) { $0 + $1.data }, bytes)
    }

    func testUploadFailureCancels() async throws {
        let uploadID = UUID()
        let (workspace, fakeMain, _) = try await connectedWorkspace { fakeMain in
            fakeMain.answer("uploads.begin", with: UploadsBeginResult(uploadID: uploadID))
            fakeMain.answer("uploads.chunk", with: EmptyPayload())
            fakeMain.fail("uploads.chunk", with: ProtocolError(.internal, "The disk is full."))
        }
        let connection = try XCTUnwrap(workspace.connection(fakeMain.device.id))
        do {
            _ = try await connection.upload(fileName: "a.bin", projectID: "HEPH", source: .data(pattern(size9MiB))) {
                _ in
            }
            XCTFail("upload succeeded")
        } catch let error as ProtocolError {
            XCTAssertEqual(error, ProtocolError(.internal, "The disk is full."))
        }
        try await waitUntil { fakeMain.requests("uploads.cancel").count == 1 }
        XCTAssertEqual(fakeMain.requests("uploads.cancel").first?.json, ["uploadID": uploadID.uuidString])
        XCTAssertEqual(fakeMain.requests("uploads.chunk").count, 2)
    }

    /// The three `attachments.read` answers of a 9 MiB file, then the expected file.
    private func answerReads(_ fakeMain: FakeMain, _ content: Data) {
        for offset in stride(from: 0, to: content.count, by: mebibytes4) {
            let slice = content.subdata(in: offset..<min(offset + mebibytes4, content.count))
            fakeMain.answer("attachments.read",
                            with: AttachmentsReadResult(data: slice, size: content.count,
                                                        mimeType: "application/octet-stream"))
        }
    }

    func testDownloadAssembles() async throws {
        let content = pattern(size9MiB)
        let (workspace, fakeMain, environment) = try await connectedWorkspace { fakeMain in
            self.answerReads(fakeMain, content)
        }
        let connection = try XCTUnwrap(workspace.connection(fakeMain.device.id))
        let url = try await connection.downloadAttachment(projectID: "HEPH", taskID: "HEPH-1", fileName: "big.bin",
                                                          size: size9MiB) { _ in }

        let reads = fakeMain.requests("attachments.read")
        XCTAssertEqual(reads.map { $0.json["offset"] as? Int }, [0, mebibytes4, 2 * mebibytes4])
        let expected = environment.cacheRoot
            .appending(path: "\(fakeMain.device.id.uuidString)/HEPH/tasks/HEPH-1/big.bin",
                       directoryHint: .notDirectory)
        XCTAssertEqual(url.standardizedFileURL.path(percentEncoded: false),
                       expected.standardizedFileURL.path(percentEncoded: false))
        XCTAssertEqual(try Data(contentsOf: url), content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false) + ".download"))
    }

    func testDownloadReuse() async throws {
        let content = pattern(size9MiB)
        let (workspace, fakeMain, _) = try await connectedWorkspace { fakeMain in
            self.answerReads(fakeMain, content)
        }
        let connection = try XCTUnwrap(workspace.connection(fakeMain.device.id))
        let first = try await connection.downloadAttachment(projectID: "HEPH", taskID: "HEPH-1", fileName: "big.bin",
                                                            size: size9MiB) { _ in }
        XCTAssertEqual(fakeMain.requests("attachments.read").count, 3)

        let progress = ProgressLog()
        let second = try await connection.downloadAttachment(projectID: "HEPH", taskID: "HEPH-1", fileName: "big.bin",
                                                             size: size9MiB) { progress.reports.append($0) }
        XCTAssertEqual(second, first)
        XCTAssertEqual(fakeMain.requests("attachments.read").count, 3)
        XCTAssertEqual(progress.reports, [TransferProgress(completed: size9MiB, total: size9MiB)])

        answerReads(fakeMain, content)
        let third = try await connection.downloadAttachment(projectID: "HEPH", taskID: "HEPH-1", fileName: "big.bin",
                                                            size: 1_000) { _ in }
        XCTAssertEqual(third, first)
        XCTAssertEqual(fakeMain.requests("attachments.read").count, 6)
        XCTAssertEqual(try Data(contentsOf: third), content)
    }

    func testDownloadChanged() async throws {
        let content = pattern(size9MiB)
        let (workspace, fakeMain, environment) = try await connectedWorkspace { fakeMain in
            fakeMain.answer("attachments.read",
                            with: AttachmentsReadResult(data: content.subdata(in: 0..<self.mebibytes4),
                                                        size: content.count, mimeType: "application/octet-stream"))
            let second = content.subdata(in: self.mebibytes4..<(2 * self.mebibytes4))
            fakeMain.answer("attachments.read",
                            with: AttachmentsReadResult(data: second, size: content.count + 1,
                                                        mimeType: "application/octet-stream"))
        }
        let connection = try XCTUnwrap(workspace.connection(fakeMain.device.id))
        do {
            _ = try await connection.downloadAttachment(projectID: "HEPH", taskID: "HEPH-1", fileName: "big.bin",
                                                        size: size9MiB) { _ in }
            XCTFail("The download succeeded")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .conflict)
            XCTAssertEqual(error.message, "big.bin changed during the download.")
        }
        let destination = environment.cacheRoot
            .appending(path: "\(fakeMain.device.id.uuidString)/HEPH/tasks/HEPH-1/big.bin",
                       directoryHint: .notDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false) + ".download"))
    }
}
