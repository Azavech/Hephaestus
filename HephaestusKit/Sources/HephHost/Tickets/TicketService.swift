#if os(macOS)
import Foundation
import HephCore

/// The tickets of the hosted projects (docs/services/host.md §8): `tickets.*`, `attachments.read` and the ticket
/// cache.
actor TicketService: HostMethodHandler {
    private let host: HostService
    /// The TicketItem of every ticket file of every registered project, valid or broken.
    private var cache: [String: [TicketID: TicketItem]] = [:]
    /// The last status of every session given to sessionChanged, per session id (§8.1).
    private var sessionStatuses: [UUID: SessionStatus] = [:]

    init(host: HostService) {
        self.host = host
    }

    // MARK: - Cache

    /// TicketFile.loadAll for a registered project.
    func load(projectID: String) async {
        guard let project = try? await host.registry.hosted(projectID) else { return }
        var items: [TicketID: TicketItem] = [:]
        for result in TicketFile.loadAll(projectRoot: project.root, projectID: projectID) {
            if let (id, item) = Self.item(result) {
                items[id] = item
            }
        }
        cache[projectID] = items
    }

    func unload(projectID: String) {
        cache[projectID] = nil
    }

    /// By ticket number.
    func list(projectID: String) throws -> [TicketItem] {
        guard let items = cache[projectID] else {
            throw ProtocolError(.notFound, "Project \(projectID) is not hosted on this Main.")
        }
        return items.sorted { $0.key < $1.key }.map(\.value)
    }

    func ticket(projectID: String, ticketID: String) throws -> TicketItem {
        let id = try existingID(ticketID, projectID: projectID)
        guard let item = cache[projectID]?[id] else { throw Self.noTicket(ticketID) }
        return item
    }

    /// Largest cached number of the series, 0 when none.
    func highestNumber(projectID: String, feedback: Bool) -> Int {
        cache[projectID]?.keys.filter { $0.feedback == feedback }.map(\.number).max() ?? 0
    }

    // MARK: - Methods

    /// feedback: true for the Forge's feedback tickets (<projectID>-F<n>); tickets.create passes false.
    func create(projectID: String, name: String, description: String?, status: TicketStatus?,
                feedback: Bool = false) async throws -> TicketItem {
        let validName = try Self.validatedName(name)
        let host = self.host
        return try await host.registry.write(projectID) { project in
            do {
                let id = try TicketFile.allocateID(projectRoot: project.root, feedback: feedback)
                do {
                    let projectFile = try ProjectFile.load(projectRoot: project.root)
                    let modified = ProjectRegistry.modificationDate(of: ProjectFile.url(projectRoot: project.root))
                    await host.registry.reloaded(projectID, file: projectFile, modified: modified)
                } catch {
                    Log.host.error("Could not read the project.yml of \(projectID, privacy: .public) after allocating \(id.description, privacy: .public)")
                }
                let file = TicketFile(id: id, name: validName, description: description, status: status ?? .todo)
                try TicketFile.create(file, projectRoot: project.root)
                let item = Self.item(file)
                await self.store(projectID: projectID, id: id, item: item)
                return item
            } catch {
                throw ProjectRegistry.protocolError(error)
            }
        }
    }

    func update(projectID: String, ticketID: String, patch: TicketPatch) async throws -> TicketItem {
        let name = try patch.name.map(Self.validatedName)
        let host = self.host
        return try await host.registry.write(projectID) { project in
            let id = try await self.existingID(ticketID, projectID: projectID)
            do {
                let file = try TicketFile.update(projectRoot: project.root, id: id) { file in
                    if let name { file.name = name }
                    if let description = patch.description { file.description = description }
                    if let status = patch.status { file.status = status }
                }
                let item = Self.item(file)
                await self.store(projectID: projectID, id: id, item: item)
                return item
            } catch {
                throw Self.ticketError(error, id: id)
            }
        }
    }

    func delete(projectID: String, ticketID: String) async throws {
        let host = self.host
        try await host.registry.write(projectID) { project in
            let id = try await self.existingID(ticketID, projectID: projectID)
            do {
                try TicketFile.delete(projectRoot: project.root, id: id)
            } catch {
                throw Self.ticketError(error, id: id)
            }
            await self.remove(projectID: projectID, id: id)
        }
    }

    func addComment(projectID: String, ticketID: String, body: String, attachments: [UploadRef],
                    author: String) async throws -> TicketItem {
        let host = self.host
        return try await host.registry.write(projectID) { project in
            // 1. Checks.
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty {
                throw ProtocolError(.badRequest, "The comment is empty.")
            }
            let id = try await self.existingID(ticketID, projectID: projectID)
            if let parseError = await self.cachedItem(projectID: projectID, id: id)?.parseError {
                throw ProtocolError(.conflict, "The file is invalid: \(parseError)")
            }
            // 2. The uploads, reserved for this request.
            let claimed = try await host.uploads.claim(attachments, projectID: projectID)
            // 3. The files, moved into the ticket's attachments folder.
            var stored: [(attachment: TicketAttachment, upload: ClaimedUpload)] = []
            do {
                for upload in claimed {
                    let attachment = try TicketFile.storeAttachment(fileAt: upload.url, originalName: upload.fileName,
                                                                  projectRoot: project.root, id: id)
                    stored.append((attachment, upload))
                }
                // 4. The comment.
                let comment = TicketFile.Comment(id: UUID(), author: author, created: YAMLCoding.now(), edited: nil,
                                               body: body,
                                               attachments: stored.isEmpty ? nil : stored.map(\.attachment))
                let file = try TicketFile.update(projectRoot: project.root, id: id) { file in
                    file.comments.append(comment)
                }
                // 5. Success.
                await host.uploads.finish(claimed)
                let item = Self.item(file)
                await self.store(projectID: projectID, id: id, item: item)
                return item
            } catch {
                for (attachment, upload) in stored {
                    Self.moveBack(attachment, to: upload, projectRoot: project.root, id: id)
                }
                await host.uploads.release(claimed)
                throw Self.ticketError(error, id: id)
            }
        }
    }

    func updateComment(projectID: String, ticketID: String, commentID: UUID, body: String) async throws -> TicketItem {
        let host = self.host
        return try await host.registry.write(projectID) { project in
            let id = try await self.existingID(ticketID, projectID: projectID)
            do {
                let file = try TicketFile.update(projectRoot: project.root, id: id) { file in
                    guard let index = file.comments.firstIndex(where: { $0.id == commentID }) else {
                        throw DataError.notFound("comment \(commentID.uuidString) not found")
                    }
                    if file.comments[index].author == Self.claude {
                        throw ProtocolError(.badRequest, "Claude's comments cannot be edited.")
                    }
                    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       (file.comments[index].attachments ?? []).isEmpty {
                        throw ProtocolError(.badRequest, "The comment is empty.")
                    }
                    file.comments[index].body = body
                    file.comments[index].edited = YAMLCoding.now()
                }
                let item = Self.item(file)
                await self.store(projectID: projectID, id: id, item: item)
                return item
            } catch {
                throw Self.ticketError(error, id: id)
            }
        }
    }

    func deleteComment(projectID: String, ticketID: String, commentID: UUID) async throws -> TicketItem {
        let host = self.host
        return try await host.registry.write(projectID) { project in
            let id = try await self.existingID(ticketID, projectID: projectID)
            var unnamedFiles: [String] = []
            let file: TicketFile
            do {
                file = try TicketFile.update(projectRoot: project.root, id: id) { file in
                    guard let index = file.comments.firstIndex(where: { $0.id == commentID }) else {
                        throw DataError.notFound("comment \(commentID.uuidString) not found")
                    }
                    let comment = file.comments.remove(at: index)
                    let named = Set(file.comments.flatMap { ($0.attachments ?? []).map(\.file) })
                    unnamedFiles = (comment.attachments ?? []).map(\.file).filter { !named.contains($0) }
                }
            } catch {
                throw Self.ticketError(error, id: id)
            }
            for name in unnamedFiles {
                do {
                    try TicketFile.deleteAttachment(file: name, projectRoot: project.root, id: id)
                } catch {
                    Log.host.error("Could not delete an attachment of \(id.description, privacy: .public): \(ProjectRegistry.protocolError(error).message)")
                }
            }
            let item = Self.item(file)
            await self.store(projectID: projectID, id: id, item: item)
            return item
        }
    }

    func readAttachment(projectID: String, ticketID: String, fileName: String, offset: Int?,
                        length: Int?) async throws -> AttachmentsReadResult {
        let project = try await host.registry.hosted(projectID)
        let id = try existingID(ticketID, projectID: projectID)
        do {
            let url = try TicketFile.attachmentURL(projectRoot: project.root, id: id, file: fileName)
            let size = try FileService.fileSize(url)
            let start = offset ?? 0
            guard start >= 0, start <= size else {
                throw ProtocolError(.badRequest, "Invalid offset \(start) for \(fileName).")
            }
            let requested = length ?? MethodLimits.maxChunkSize
            guard requested >= 1 else { throw ProtocolError(.badRequest, "Invalid length.") }
            let count = min(min(requested, MethodLimits.maxChunkSize), size - start)
            let data = try FileService.readRange(url, offset: start, count: count)
            let entry = cache[projectID]?[id]?.comments
                .flatMap(\.attachments)
                .first { $0.file == fileName }
            return AttachmentsReadResult(data: data, size: size,
                                         mimeType: entry?.type ?? AttachmentNaming.mimeType(forFileName: fileName))
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - FileWatcher (§11.3)

    /// TicketFile.loadOne: a file gone is removed (ticket.removed); a new or different file is stored (ticket.changed).
    func reload(projectID: String, ticketID: TicketID) async {
        guard cache[projectID] != nil, let project = try? await host.registry.hosted(projectID) else { return }
        if let result = TicketFile.loadOne(projectRoot: project.root, id: ticketID) {
            if let (id, item) = Self.item(result) {
                await store(projectID: projectID, id: id, item: item)
            }
        } else {
            await remove(projectID: projectID, id: ticketID)
        }
    }

    /// TicketFile.loadAll, applied like `reload` to every ticket of the result and every cached ticket.
    func rescan(projectID: String) async {
        guard cache[projectID] != nil, let project = try? await host.registry.hosted(projectID) else { return }
        var found = Set<TicketID>()
        for result in TicketFile.loadAll(projectRoot: project.root, projectID: projectID) {
            guard let (id, item) = Self.item(result) else { continue }
            found.insert(id)
            await store(projectID: projectID, id: id, item: item)
        }
        let gone = (cache[projectID] ?? [:]).keys.filter { !found.contains($0) }.sorted()
        for id in gone {
            await remove(projectID: projectID, id: id)
        }
    }

    // MARK: - Sessions (§8.1)

    /// The status of the ticket follows the turns of its `ticket` and `feedback` sessions: a turn that starts sets it
    /// to in_progress, a turn that ends sets it to review.
    func sessionChanged(projectID: String, session: SessionInfo) async {
        let previous = sessionStatuses[session.id]
        sessionStatuses[session.id] = session.status
        guard session.kind == .ticket || session.kind == .feedback, let ticketID = session.ticketID else { return }
        let working: Set<SessionStatus> = [.running, .waitingPermission]
        let target: TicketStatus
        if working.contains(session.status), previous.map({ !working.contains($0) }) ?? true {
            target = .inProgress
        } else if let previous, working.contains(previous),
                  [.idle, .stopped, .failed].contains(session.status) {
            target = .review
        } else {
            return
        }
        guard let id = TicketID(ticketID), let item = cache[projectID]?[id], item.parseError == nil,
              item.status != target else { return }
        do {
            _ = try await update(projectID: projectID, ticketID: ticketID, patch: TicketPatch(status: target))
        } catch {
            Log.host.error("Could not set the status of \(ticketID, privacy: .public) from its session: \(ProjectRegistry.protocolError(error).message)")
        }
    }

    /// Forgets the last status of the session.
    func sessionRemoved(sessionID: UUID) {
        sessionStatuses[sessionID] = nil
    }

    // MARK: - HostMethodHandler

    func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .ticketsCreate:
                let request = try Self.decode(TicketsCreateParams.self, params, method)
                return try WireCoding.encodeJSON(try await create(projectID: request.projectID, name: request.name,
                                                                  description: request.description,
                                                                  status: request.status))
            case .ticketsUpdate:
                let request = try Self.decode(TicketsUpdateParams.self, params, method)
                return try WireCoding.encodeJSON(try await update(projectID: request.projectID,
                                                                  ticketID: request.ticketID, patch: request.patch))
            case .ticketsDelete:
                let request = try Self.decode(TicketsDeleteParams.self, params, method)
                try await delete(projectID: request.projectID, ticketID: request.ticketID)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .ticketsAddComment:
                let request = try Self.decode(TicketsAddCommentParams.self, params, method)
                let author = await commentAuthor(request.author, context: context)
                return try WireCoding.encodeJSON(try await addComment(projectID: request.projectID,
                                                                      ticketID: request.ticketID, body: request.body,
                                                                      attachments: request.attachments,
                                                                      author: author))
            case .ticketsUpdateComment:
                let request = try Self.decode(TicketsUpdateCommentParams.self, params, method)
                return try WireCoding.encodeJSON(try await updateComment(projectID: request.projectID,
                                                                         ticketID: request.ticketID,
                                                                         commentID: request.commentID,
                                                                         body: request.body))
            case .ticketsDeleteComment:
                let request = try Self.decode(TicketsDeleteCommentParams.self, params, method)
                return try WireCoding.encodeJSON(try await deleteComment(projectID: request.projectID,
                                                                         ticketID: request.ticketID,
                                                                         commentID: request.commentID))
            case .attachmentsRead:
                let request = try Self.decode(AttachmentsReadParams.self, params, method)
                return try WireCoding.encodeJSON(try await readAttachment(projectID: request.projectID,
                                                                          ticketID: request.ticketID,
                                                                          fileName: request.fileName,
                                                                          offset: request.offset,
                                                                          length: request.length))
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - Private

    private static let claude = "Claude"

    /// Author of a new comment (§8): the `author` param on a peer link, else `context.author`, else the name of the
    /// caller's record in the registry, else the hello device name.
    private func commentAuthor(_ author: String?, context: RequestContext) async -> String {
        if context.device.isMain, let author {
            return author
        }
        if let author = context.author {
            return author
        }
        let snapshot = await host.mesh.snapshot()
        if let record = snapshot.devices.first(where: { $0.id == context.device.id }) {
            return record.name
        }
        return context.device.name
    }

    /// The ticket id of a request: parsed with the project's identifier and present in the cache, else notFound.
    private func existingID(_ ticketID: String, projectID: String) throws -> TicketID {
        guard let id = TicketID(ticketID), id.projectID == projectID, cache[projectID]?[id] != nil else {
            throw Self.noTicket(ticketID)
        }
        return id
    }

    private func cachedItem(projectID: String, id: TicketID) -> TicketItem? {
        cache[projectID]?[id]
    }

    /// Stores the item; emits ticket.changed when it differs from the cached one or was not cached.
    private func store(projectID: String, id: TicketID, item: TicketItem) async {
        guard cache[projectID] != nil else { return }
        let previous = cache[projectID]?[id]
        cache[projectID]?[id] = item
        if previous != item {
            await host.emit(.ticketChanged(TicketChangedPayload(projectID: projectID, ticket: item)))
        }
    }

    /// Removes a cached ticket and emits ticket.removed.
    private func remove(projectID: String, id: TicketID) async {
        guard cache[projectID]?[id] != nil else { return }
        cache[projectID]?[id] = nil
        await host.emit(.ticketRemoved(TicketRemovedPayload(projectID: projectID, ticketID: id.description)))
    }

    private static func noTicket(_ ticketID: String) -> ProtocolError {
        let text = TicketID(ticketID)?.description ?? ticketID
        return ProtocolError(.notFound, "Ticket \(text) does not exist.")
    }

    /// The error of a ticket change: a ticket file that no longer exists is "Ticket <id> does not exist."; other errors
    /// are mapped as in §6.9.
    private static func ticketError(_ error: any Error, id: TicketID) -> ProtocolError {
        if case DataError.notFound(let message) = error, message == "ticket \(id) not found" {
            return noTicket(id.description)
        }
        return ProjectRegistry.protocolError(error)
    }

    /// Trimmed, not empty and on one line (badRequest).
    private static func validatedName(_ name: String) throws -> String {
        do {
            return try ProjectFile.validatedName(name)
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    /// A stored attachment goes back to its upload; a file that cannot be moved back is deleted (logged, files.md §7.5:
    /// the ticket id, the upload id and the error's domain and code, never a file name).
    private static func moveBack(_ attachment: TicketAttachment, to upload: ClaimedUpload, projectRoot: URL, id: TicketID) {
        let stored = TicketFile.attachmentsFolder(projectRoot: projectRoot, id: id)
            .appendingPathComponent(attachment.file, isDirectory: false)
        do {
            try FileManager.default.moveItem(at: stored, to: upload.url)
        } catch {
            let failure = error as NSError
            Log.host.error("Could not move an attachment of \(id.description, privacy: .public) back to upload \(upload.uploadID.uuidString, privacy: .public): \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
            try? FileManager.default.removeItem(at: stored)
        }
    }

    /// The cache key and TicketItem of a loaded file (data/ticket-yml.md, "Mapping to TicketItem" and "Broken files").
    private static func item(_ result: TicketLoadResult) -> (TicketID, TicketItem)? {
        switch result {
        case .valid(let file):
            guard let id = TicketID(file.id) else { return nil }
            return (id, item(file))
        case .broken(let id, let message, let modified):
            return (id, TicketItem(id: id.description, name: "", description: "", status: .todo, created: modified,
                                 updated: modified, comments: [], parseError: message))
        }
    }

    private static func item(_ file: TicketFile) -> TicketItem {
        TicketItem(id: file.id,
                 name: file.name,
                 description: file.description ?? "",
                 status: file.status,
                 created: file.created,
                 updated: file.updated,
                 comments: file.comments.map {
                     TicketComment(id: $0.id, author: $0.author, created: $0.created, edited: $0.edited, body: $0.body,
                                 attachments: $0.attachments ?? [])
                 },
                 parseError: nil)
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}
#endif
