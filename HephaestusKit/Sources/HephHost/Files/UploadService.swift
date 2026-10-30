#if os(macOS)
import Foundation
import HephCore

/// The upload store (docs/services/files.md §7): `uploads.begin`, `uploads.chunk`, `uploads.cancel`, and the complete
/// uploads handed to the requests that attach them. Public because the public SessionHost protocol names it
/// (../claude/cli.md).
public actor UploadService: HostMethodHandler {
    /// One upload of the store (§7.1).
    private struct Upload {
        let uploadID: UUID
        let projectID: String
        let fileName: String
        let size: Int
        var received: Int
        var lastChunk: Date
        var inUse: Bool
    }

    private let host: HostService
    private var uploads: [UUID: Upload] = [:]
    private var sweeper: Task<Void, Never>?

    init(host: HostService) {
        self.host = host
    }

    /// HostService.start(): empties Uploads/ and starts the expiry sweep (§7.4).
    func start() {
        uploads.removeAll()
        emptyFolder()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.host.error("Could not create the Uploads folder: \(error.localizedDescription)")
        }
        sweeper?.cancel()
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    return
                }
                await self?.sweep(now: Date())
            }
        }
    }

    /// HostService.stop(): ends the sweep, forgets every upload and deletes its file.
    func stop() {
        sweeper?.cancel()
        sweeper = nil
        uploads.removeAll()
        emptyFolder()
    }

    /// uploads.begin, uploads.chunk, uploads.cancel (§7.2).
    public func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .uploadsBegin:
                let request = try Self.decode(UploadsBeginParams.self, params, method)
                return try WireCoding.encodeJSON(try await begin(request))
            case .uploadsChunk:
                let request = try Self.decode(UploadsChunkParams.self, params, method)
                try chunk(request)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .uploadsCancel:
                let request = try Self.decode(UploadsCancelParams.self, params, method)
                cancel(request.uploadID)
                return try WireCoding.encodeJSON(EmptyPayload())
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    /// The checks of §7.3 on the UploadRefs of one request, without reserving them. Throws ProtocolError.
    func check(_ refs: [UploadRef], projectID: String) throws {
        for ref in refs {
            let id = ref.uploadID.uuidString
            guard refs.filter({ $0.uploadID == ref.uploadID }).count == 1 else {
                throw ProtocolError(.badRequest, "Upload \(id) is named twice.")
            }
            guard let upload = uploads[ref.uploadID] else {
                throw ProtocolError(.notFound, "Upload \(id) does not exist.")
            }
            guard upload.projectID == projectID else {
                throw ProtocolError(.badRequest, "Upload \(id) belongs to another project.")
            }
            guard !upload.inUse else {
                throw ProtocolError(.conflict, "Upload \(id) is in use.")
            }
            guard upload.received == upload.size else {
                throw ProtocolError(.badRequest, "Upload \(id) is incomplete.")
            }
        }
    }

    /// The checks of §7.3; then reserves the uploads for the request. Throws ProtocolError.
    func claim(_ refs: [UploadRef], projectID: String) throws -> [ClaimedUpload] {
        try check(refs, projectID: projectID)
        return refs.compactMap { ref -> ClaimedUpload? in
            guard var upload = uploads[ref.uploadID] else { return nil }
            upload.inUse = true
            uploads[ref.uploadID] = upload
            Log.host.debug("Upload \(upload.uploadID.uuidString, privacy: .public) of \(upload.projectID, privacy: .public) is used (\(upload.size, privacy: .public) bytes)")
            return ClaimedUpload(uploadID: upload.uploadID, fileName: ref.fileName, url: url(of: upload.uploadID),
                                 size: upload.size)
        }
    }

    /// The request succeeded: the uploads, whose files were moved away, are forgotten.
    func finish(_ claimed: [ClaimedUpload]) {
        for upload in claimed {
            uploads[upload.uploadID] = nil
        }
    }

    /// The request failed: each upload whose file is back at its URL is usable again; the others are forgotten.
    func release(_ claimed: [ClaimedUpload]) {
        for upload in claimed {
            guard var record = uploads[upload.uploadID] else { continue }
            if FileManager.default.fileExists(atPath: upload.url.path) {
                record.inUse = false
                uploads[upload.uploadID] = record
            } else {
                uploads[upload.uploadID] = nil
            }
        }
    }

    /// Deletes the uploads that no request holds and whose last chunk is more than an hour before `now` (§7.4).
    func sweep(now: Date) {
        let expired = uploads.values.filter { !$0.inUse && now.timeIntervalSince($0.lastChunk) > 3_600 }
        for upload in expired {
            uploads[upload.uploadID] = nil
            deleteFile(of: upload.uploadID)
            Log.host.debug("Upload \(upload.uploadID.uuidString, privacy: .public) of \(upload.projectID, privacy: .public) expired (\(upload.size, privacy: .public) bytes)")
        }
    }

    // MARK: - Methods

    private func begin(_ request: UploadsBeginParams) async throws -> UploadsBeginResult {
        _ = try await host.registry.hosted(request.projectID)
        guard request.size >= 0 else { throw ProtocolError(.badRequest, "Invalid size.") }
        guard !request.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProtocolError(.badRequest, "The file name is empty.")
        }
        let uploadID = UUID()
        guard FileManager.default.createFile(atPath: url(of: uploadID).path, contents: nil) else {
            throw ProtocolError(.internal, "Cannot create the upload: \(String(cString: strerror(errno))).")
        }
        uploads[uploadID] = Upload(uploadID: uploadID, projectID: request.projectID, fileName: request.fileName,
                                   size: request.size, received: 0, lastChunk: Date(), inUse: false)
        Log.host.debug("Upload \(uploadID.uuidString, privacy: .public) of \(request.projectID, privacy: .public) begun (\(request.size, privacy: .public) bytes)")
        return UploadsBeginResult(uploadID: uploadID)
    }

    private func chunk(_ request: UploadsChunkParams) throws {
        let id = request.uploadID.uuidString
        guard var upload = uploads[request.uploadID] else {
            throw ProtocolError(.notFound, "Upload \(id) does not exist.")
        }
        guard !upload.inUse else { throw ProtocolError(.conflict, "Upload \(id) is in use.") }
        guard request.data.count <= MethodLimits.maxChunkSize else {
            throw ProtocolError(.tooLarge, "A chunk is larger than 4 MiB.")
        }
        guard !request.data.isEmpty else { throw ProtocolError(.badRequest, "The chunk is empty.") }
        guard request.offset == upload.received else {
            throw ProtocolError(.badRequest, "Unexpected offset \(request.offset) for upload \(id).")
        }
        guard request.offset + request.data.count <= upload.size else {
            throw ProtocolError(.badRequest, "The chunk goes past the size of upload \(id).")
        }
        do {
            let handle = try FileHandle(forWritingTo: url(of: upload.uploadID))
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: request.data)
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
        } catch {
            uploads[upload.uploadID] = nil
            deleteFile(of: upload.uploadID)
            Log.host.error("Could not write upload \(id, privacy: .public): \(error.localizedDescription)")
            // <reason>: the error's localizedDescription without its final period.
            var reason = error.localizedDescription
            if reason.hasSuffix(".") {
                reason.removeLast()
            }
            throw ProtocolError(.internal, "Cannot write the upload: \(reason).")
        }
        upload.received += request.data.count
        upload.lastChunk = Date()
        uploads[upload.uploadID] = upload
        if upload.received == upload.size {
            Log.host.debug("Upload \(id, privacy: .public) of \(upload.projectID, privacy: .public) completed (\(upload.size, privacy: .public) bytes)")
        }
    }

    private func cancel(_ uploadID: UUID) {
        guard let upload = uploads[uploadID], !upload.inUse else { return }
        uploads[uploadID] = nil
        deleteFile(of: uploadID)
        Log.host.debug("Upload \(uploadID.uuidString, privacy: .public) of \(upload.projectID, privacy: .public) cancelled (\(upload.size, privacy: .public) bytes)")
    }

    // MARK: - Files

    private var folder: URL {
        host.appSupport.uploadsFolder
    }

    /// Uploads/<uploadID>, the id in canonical uppercase form.
    private func url(of uploadID: UUID) -> URL {
        folder.appendingPathComponent(uploadID.uuidString, isDirectory: false)
    }

    private func deleteFile(of uploadID: UUID) {
        do {
            try FileManager.default.removeItem(at: url(of: uploadID))
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Log.host.error("Could not delete upload \(uploadID.uuidString, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Deletes every item of Uploads/.
    private func emptyFolder() {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            do {
                try fileManager.removeItem(at: folder.appendingPathComponent(name, isDirectory: false))
            } catch {
                Log.host.error("Could not delete an item of the Uploads folder: \(error.localizedDescription)")
            }
        }
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}

/// An upload reserved by one request.
struct ClaimedUpload: Sendable {
    let uploadID: UUID
    let fileName: String   // the UploadRef's fileName: the original name of the attachment
    let url: URL           // Uploads/<uploadID>
    let size: Int
}
#endif
