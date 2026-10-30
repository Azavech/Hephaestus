import Foundation
import HephCore

/// What an upload reads.
public enum UploadSource: Sendable, Hashable {
    /// Bytes in memory: pasted and dropped images, photos, the feedback screenshot.
    case data(Data)
    /// A local file, read chunk by chunk: chosen and dropped files.
    case file(URL)
}

/// Progress of one transfer, in bytes.
public struct TransferProgress: Sendable, Hashable {
    public var completed: Int
    public var total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    /// completed / total; 1 when total is 0.
    public var fraction: Double {
        total == 0 ? 1 : Double(completed) / Double(total)
    }
}

/// Uploads in chunks and downloads in ranges, with progress (docs/client/workspace.md, "Transfers"). The requests go
/// through the request API, so its errors and timeouts apply. `progress` is called on the main actor.
extension MainConnection {
    /// Sends the file as an upload of `projectID`; returns the reference that a request attaches. A failure after
    /// `uploads.begin`, and the cancellation of the calling task, cancel the upload on the Main.
    public func upload(fileName: String, projectID: String, source: UploadSource,
                       progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> UploadRef {
        try requireOnline()
        switch source {
        case .data(let data):
            return try await uploadChunks(fileName: fileName, projectID: projectID, size: data.count,
                                          progress: progress) { offset, count in
                let start = data.startIndex + offset
                return data.subdata(in: start..<(start + count))
            }
        case .file(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let reader = UploadFileReader()
            do {
                let size = try await reader.open(url)
                let reference = try await uploadChunks(fileName: fileName, projectID: projectID, size: size,
                                                       progress: progress) { _, count in
                    let chunk = try await reader.read(upToCount: count)
                    guard chunk.count == count else {
                        throw ProtocolError(.conflict, "\(fileName) changed while it was uploaded.")
                    }
                    return chunk
                }
                await reader.close()
                return reference
            } catch {
                await reader.close()
                throw error
            }
        }
    }

    /// A task attachment in the attachment cache, downloaded unless the cache has it with `size` bytes.
    public func downloadAttachment(projectID: String, taskID: String, fileName: String, size: Int,
                                   progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> URL {
        let destination = try attachmentCache().taskAttachment(mainDeviceID: id, projectID: projectID,
                                                               taskID: taskID, fileName: fileName)
        return try await download(to: destination, fileName: fileName, reuseSize: size, progress: progress) { offset in
            let result = try await self.readAttachment(projectID: projectID, taskID: taskID, fileName: fileName,
                                                       offset: offset, length: nil)
            return (result.data, result.size)
        }
    }

    /// A file attached to a session message, in the attachment cache, downloaded unless the cache has it with `size`
    /// bytes.
    public func downloadSessionAttachment(projectID: String, sessionID: UUID, fileName: String, size: Int,
                                          progress: @escaping @MainActor (TransferProgress) -> Void) async throws
        -> URL {
        let destination = try attachmentCache().sessionAttachment(mainDeviceID: id, projectID: projectID,
                                                                  sessionID: sessionID, fileName: fileName)
        return try await download(to: destination, fileName: fileName, reuseSize: size, progress: progress) { offset in
            let result = try await self.readSessionAttachment(projectID: projectID, sessionID: sessionID,
                                                              fileName: fileName, offset: offset, length: nil)
            return (result.data, result.size)
        }
    }

    /// A project file, downloaded each time (project files change).
    public func downloadFile(projectID: String, path: String,
                             progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> URL {
        let destination = try attachmentCache().projectFile(mainDeviceID: id, projectID: projectID, path: path)
        let fileName = ProjectPath.name(of: path)
        return try await download(to: destination, fileName: fileName, reuseSize: nil, progress: progress) { offset in
            let result = try await self.readFile(projectID: projectID, path: path, offset: offset, length: nil)
            return (result.data, result.size)
        }
    }

    // MARK: - Uploading

    /// Steps 2–4 of an upload: `uploads.begin`, the chunks one at a time, the reference.
    private func uploadChunks(fileName: String, projectID: String, size: Int,
                              progress: @escaping @MainActor (TransferProgress) -> Void,
                              chunk: (_ offset: Int, _ count: Int) async throws -> Data) async throws -> UploadRef {
        let uploadID = try await beginUpload(projectID: projectID, fileName: fileName, size: size)
        progress(TransferProgress(completed: 0, total: size))
        do {
            var offset = 0
            while offset < size {
                try Task.checkCancellation()
                let data = try await chunk(offset, min(MethodLimits.maxChunkSize, size - offset))
                try await uploadChunk(uploadID: uploadID, offset: offset, data: data)
                offset += data.count
                progress(TransferProgress(completed: offset, total: size))
            }
            return UploadRef(uploadID: uploadID, fileName: fileName)
        } catch {
            Task { [weak self] in
                do {
                    try await self?.cancelUpload(uploadID: uploadID)
                } catch {
                    // Ignored: the Main deletes an unused upload after an hour.
                }
            }
            throw error
        }
    }

    // MARK: - Downloading

    /// Fills `destination` with ranged reads (`read(offset)` returns the bytes and the size of the whole file). One
    /// download per destination at a time; `reuseSize`: the size of a cached file that is reused.
    private func download(to destination: URL, fileName: String, reuseSize: Int?,
                          progress: @escaping @MainActor (TransferProgress) -> Void,
                          read: (_ offset: Int) async throws -> (data: Data, size: Int)) async throws -> URL {
        guard let workspace else {
            throw ProtocolError(.unavailable, "\(name) is offline.")
        }
        let key = destination.standardizedFileURL.path(percentEncoded: false)
        while let running = workspace.downloadGates[key] {
            await running.wait()
            try Task.checkCancellation()
        }
        let gate = DownloadGate()
        workspace.downloadGates[key] = gate
        defer {
            if workspace.downloadGates[key] === gate {
                workspace.downloadGates[key] = nil
            }
            gate.open()
        }

        let file = DownloadFile(destination: destination)
        // 1. Reuse.
        if let reuseSize, await file.existingSize() == reuseSize {
            progress(TransferProgress(completed: reuseSize, total: reuseSize))
            return destination
        }
        do {
            // 2. The parent folders and an empty <destination>.download.
            try await file.start()
            // 3. Ranged reads, in order.
            var written = 0
            var total: Int?
            repeat {
                let result = try await read(written)
                if let total, result.size != total {
                    throw ProtocolError(.conflict, "\(fileName) changed during the download.")
                }
                let expected = total ?? result.size
                total = expected
                if result.data.isEmpty, written < expected {
                    throw ProtocolError(.conflict, "\(fileName) changed during the download.")
                }
                try await file.append(result.data)
                written += result.data.count
                progress(TransferProgress(completed: written, total: expected))
            } while written < (total ?? 0)
            // 4. The partial file replaces the destination.
            try await file.finish()
            return destination
        } catch {
            await file.discard()
            throw error
        }
    }

    /// `unavailable` "<name> is offline." when the connection is not connected (previews answer every request).
    private func requireOnline() throws {
        guard workspace?.isPreview == true || isConnected else {
            throw ProtocolError(.unavailable, "\(name) is offline.")
        }
    }

    private func attachmentCache() throws -> AttachmentCache {
        guard let workspace else {
            throw ProtocolError(.unavailable, "\(name) is offline.")
        }
        return workspace.environment.attachmentCache
    }
}

/// Opens when a download of its destination ends; the calls for the same destination wait for it.
@MainActor
final class DownloadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        for continuation in waiting {
            continuation.resume()
        }
    }
}

/// The file read by an upload: opened, read chunk by chunk and closed off the main actor.
actor UploadFileReader {
    private var handle: FileHandle?

    /// Opens the file; returns its size.
    func open(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        handle = try FileHandle(forReadingFrom: url)
        return size
    }

    func read(upToCount count: Int) throws -> Data {
        guard let handle else { return Data() }
        return try handle.read(upToCount: count) ?? Data()
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

/// The files of a download: `<destination>.download` filled chunk by chunk, then moved over the destination, off the
/// main actor.
actor DownloadFile {
    let destination: URL
    let partial: URL
    private var handle: FileHandle?

    init(destination: URL) {
        self.destination = destination
        partial = destination.deletingLastPathComponent()
            .appending(component: destination.lastPathComponent + ".download", directoryHint: .notDirectory)
    }

    /// The size of the cached file; nil when there is none.
    func existingSize() -> Int? {
        let path = destination.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    /// Creates the parent folders and an empty partial file, replacing an older one.
    func start() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = partial.path(percentEncoded: false)
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(at: partial)
        }
        guard fileManager.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        handle = try FileHandle(forWritingTo: partial)
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle?.write(contentsOf: data)
    }

    /// The partial file replaces the destination (a move when there is none).
    func finish() throws {
        try handle?.close()
        handle = nil
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
        } else {
            try fileManager.moveItem(at: partial, to: destination)
        }
    }

    /// A failure or a cancellation: the partial file is deleted.
    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: partial)
    }
}
