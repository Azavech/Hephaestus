#if os(macOS)
import Foundation
import HephCore

/// The tasks of the hosted projects (docs/services/host.md §8): `tasks.*`, `attachments.read` and the task cache.
actor TaskService: HostMethodHandler {
    private let host: HostService
    /// The TaskItem of every task file of every registered project, valid or broken.
    private var cache: [String: [TaskID: TaskItem]] = [:]

    init(host: HostService) {
        self.host = host
    }

    // MARK: - Cache

    /// TaskFile.loadAll for a registered project.
    func load(projectID: String) async {
        guard let project = try? await host.registry.hosted(projectID) else { return }
        var items: [TaskID: TaskItem] = [:]
        for result in TaskFile.loadAll(projectRoot: project.root, projectID: projectID) {
            if let (id, item) = Self.item(result) {
                items[id] = item
            }
        }
        cache[projectID] = items
    }

    func unload(projectID: String) {
        cache[projectID] = nil
    }

    /// By task number.
    func list(projectID: String) throws -> [TaskItem] {
        guard let items = cache[projectID] else {
            throw ProtocolError(.notFound, "Project \(projectID) is not hosted on this Main.")
        }
        return items.sorted { $0.key.number < $1.key.number }.map(\.value)
    }

    func task(projectID: String, taskID: String) throws -> TaskItem {
        let id = try existingID(taskID, projectID: projectID)
        guard let item = cache[projectID]?[id] else { throw Self.noTask(taskID) }
        return item
    }

    /// Largest cached task number, 0 when none.
    func highestNumber(projectID: String) -> Int {
        cache[projectID]?.keys.map(\.number).max() ?? 0
    }

    // MARK: - Methods

    func create(projectID: String, name: String, description: String?, status: TaskStatus?) async throws -> TaskItem {
        let validName = try Self.validatedName(name)
        let host = self.host
        return try await host.registry.write(projectID) { project in
            do {
                let id = try TaskFile.allocateID(projectRoot: project.root)
                do {
                    let projectFile = try ProjectFile.load(projectRoot: project.root)
                    let modified = ProjectRegistry.modificationDate(of: ProjectFile.url(projectRoot: project.root))
                    await host.registry.reloaded(projectID, file: projectFile, modified: modified)
                } catch {
                    Log.host.error("Could not read the project.yml of \(projectID, privacy: .public) after allocating \(id.description, privacy: .public)")
                }
                let file = TaskFile(id: id, name: validName, description: description, status: status ?? .todo)
                try TaskFile.create(file, projectRoot: project.root)
                let item = Self.item(file)
                await self.store(projectID: projectID, id: id, item: item)
                return item
            } catch {
                throw ProjectRegistry.protocolError(error)
            }
        }
    }

    func update(projectID: String, taskID: String, patch: TaskPatch) async throws -> TaskItem {
        let name = try patch.name.map(Self.validatedName)
        let host = self.host
        return try await host.registry.write(projectID) { project in
            let id = try await self.existingID(taskID, projectID: projectID)
            do {
                let file = try TaskFile.update(projectRoot: project.root, id: id) { file in
                    if let name { file.name = name }
                    if let description = patch.description { file.description = description }
                    if let status = patch.status { file.status = status }
                }
                let item = Self.item(file)
                await self.store(projectID: projectID, id: id, item: item)
                return item
            } catch {
                throw Self.taskError(error, id: id)
            }
        }
    }

    func delete(projectID: String, taskID: String) async throws {
        let host = self.host
        try await host.registry.write(projectID) { project in
            let id = try await self.existingID(taskID, projectID: projectID)
            do {
                try TaskFile.delete(projectRoot: project.root, id: id)
            } catch {
                throw Self.taskError(error, id: id)
            }
            await self.remove(projectID: projectID, id: id)
        }
    }

    func addComment(projectID: String, taskID: String, body: String, attachments: [UploadRef],
                    author: String) async throws -> TaskItem {
        let host = self.host
        return try await host.registry.write(projectID) { project in
            // 1. Checks.
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty {
                throw ProtocolError(.badRequest, "The comment is empty.")
            }
            let id = try await self.existingID(taskID, projectID: projectID)
            if let parseError = await self.cachedItem(projectID: projectID, id: id)?.parseError {
                throw ProtocolError(.conflict, "The file is invalid: \(parseError)")
            }
            // 2. The uploads, reserved for this request.
            let claimed = try await host.uploads.claim(attachments, projectID: projectID)
            // 3. The files, moved into the task's attachments folder.
            var stored: [(attachment: TaskAttachment, upload: ClaimedUpload)] = []
            do {
                for upload in claimed {
                    let attachment = try TaskFile.storeAttachment(fileAt: upload.url, originalName: upload.fileName,
                                                                  projectRoot: project.root, id: id)
                    stored.append((attachment, upload))
                }
                // 4. The comment.
                let comment = TaskFile.Comment(id: UUID(), author: author, created: YAMLCoding.now(), edited: nil,
                                               body: body,
                                               attachments: stored.isEmpty ? nil : stored.map(\.attachment))
                let file = try TaskFile.update(projectRoot: project.root, id: id) { file in
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
                throw Self.taskError(error, id: id)
            }
        }
    }

    func updateComment(projectID: String, taskID: String, commentID: UUID, body: String) async throws -> TaskItem {
        let host = self.host
        return try await host.registry.write(projectID) { project in
            let id = try await self.existingID(taskID, projectID: projectID)
            do {
                let file = try TaskFile.update(projectRoot: project.root, id: id) { file in
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
                throw Self.taskError(error, id: id)
            }
        }
    }

    func deleteComment(projectID: String, taskID: String, commentID: UUID) async throws -> TaskItem {
        let host = self.host
        return try await host.registry.write(projectID) { project in
            let id = try await self.existingID(taskID, projectID: projectID)
            var unnamedFiles: [String] = []
            let file: TaskFile
            do {
                file = try TaskFile.update(projectRoot: project.root, id: id) { file in
                    guard let index = file.comments.firstIndex(where: { $0.id == commentID }) else {
                        throw DataError.notFound("comment \(commentID.uuidString) not found")
                    }
                    let comment = file.comments.remove(at: index)
                    let named = Set(file.comments.flatMap { ($0.attachments ?? []).map(\.file) })
                    unnamedFiles = (comment.attachments ?? []).map(\.file).filter { !named.contains($0) }
                }
            } catch {
                throw Self.taskError(error, id: id)
            }
            for name in unnamedFiles {
                do {
                    try TaskFile.deleteAttachment(file: name, projectRoot: project.root, id: id)
                } catch {
                    Log.host.error("Could not delete an attachment of \(id.description, privacy: .public): \(ProjectRegistry.protocolError(error).message)")
                }
            }
            let item = Self.item(file)
            await self.store(projectID: projectID, id: id, item: item)
            return item
        }
    }

    func readAttachment(projectID: String, taskID: String, fileName: String, offset: Int?,
                        length: Int?) async throws -> AttachmentsReadResult {
        let project = try await host.registry.hosted(projectID)
        let id = try existingID(taskID, projectID: projectID)
        do {
            let url = try TaskFile.attachmentURL(projectRoot: project.root, id: id, file: fileName)
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

    /// TaskFile.loadOne: a file gone is removed (task.removed); a new or different file is stored (task.changed).
    func reload(projectID: String, taskID: TaskID) async {
        guard cache[projectID] != nil, let project = try? await host.registry.hosted(projectID) else { return }
        if let result = TaskFile.loadOne(projectRoot: project.root, id: taskID) {
            if let (id, item) = Self.item(result) {
                await store(projectID: projectID, id: id, item: item)
            }
        } else {
            await remove(projectID: projectID, id: taskID)
        }
    }

    /// TaskFile.loadAll, applied like `reload` to every task of the result and every cached task.
    func rescan(projectID: String) async {
        guard cache[projectID] != nil, let project = try? await host.registry.hosted(projectID) else { return }
        var found = Set<TaskID>()
        for result in TaskFile.loadAll(projectRoot: project.root, projectID: projectID) {
            guard let (id, item) = Self.item(result) else { continue }
            found.insert(id)
            await store(projectID: projectID, id: id, item: item)
        }
        let gone = (cache[projectID] ?? [:]).keys.filter { !found.contains($0) }.sorted()
        for id in gone {
            await remove(projectID: projectID, id: id)
        }
    }

    // MARK: - HostMethodHandler

    func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .tasksCreate:
                let request = try Self.decode(TasksCreateParams.self, params, method)
                return try WireCoding.encodeJSON(try await create(projectID: request.projectID, name: request.name,
                                                                  description: request.description,
                                                                  status: request.status))
            case .tasksUpdate:
                let request = try Self.decode(TasksUpdateParams.self, params, method)
                return try WireCoding.encodeJSON(try await update(projectID: request.projectID,
                                                                  taskID: request.taskID, patch: request.patch))
            case .tasksDelete:
                let request = try Self.decode(TasksDeleteParams.self, params, method)
                try await delete(projectID: request.projectID, taskID: request.taskID)
                return try WireCoding.encodeJSON(EmptyPayload())
            case .tasksAddComment:
                let request = try Self.decode(TasksAddCommentParams.self, params, method)
                let author = await commentAuthor(request.author, context: context)
                return try WireCoding.encodeJSON(try await addComment(projectID: request.projectID,
                                                                      taskID: request.taskID, body: request.body,
                                                                      attachments: request.attachments,
                                                                      author: author))
            case .tasksUpdateComment:
                let request = try Self.decode(TasksUpdateCommentParams.self, params, method)
                return try WireCoding.encodeJSON(try await updateComment(projectID: request.projectID,
                                                                         taskID: request.taskID,
                                                                         commentID: request.commentID,
                                                                         body: request.body))
            case .tasksDeleteComment:
                let request = try Self.decode(TasksDeleteCommentParams.self, params, method)
                return try WireCoding.encodeJSON(try await deleteComment(projectID: request.projectID,
                                                                         taskID: request.taskID,
                                                                         commentID: request.commentID))
            case .attachmentsRead:
                let request = try Self.decode(AttachmentsReadParams.self, params, method)
                return try WireCoding.encodeJSON(try await readAttachment(projectID: request.projectID,
                                                                          taskID: request.taskID,
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

    /// The task id of a request: parsed with the project's identifier and present in the cache, else notFound.
    private func existingID(_ taskID: String, projectID: String) throws -> TaskID {
        guard let id = TaskID(taskID), id.projectID == projectID, cache[projectID]?[id] != nil else {
            throw Self.noTask(taskID)
        }
        return id
    }

    private func cachedItem(projectID: String, id: TaskID) -> TaskItem? {
        cache[projectID]?[id]
    }

    /// Stores the item; emits task.changed when it differs from the cached one or was not cached.
    private func store(projectID: String, id: TaskID, item: TaskItem) async {
        guard cache[projectID] != nil else { return }
        let previous = cache[projectID]?[id]
        cache[projectID]?[id] = item
        if previous != item {
            await host.emit(.taskChanged(TaskChangedPayload(projectID: projectID, task: item)))
        }
    }

    /// Removes a cached task and emits task.removed.
    private func remove(projectID: String, id: TaskID) async {
        guard cache[projectID]?[id] != nil else { return }
        cache[projectID]?[id] = nil
        await host.emit(.taskRemoved(TaskRemovedPayload(projectID: projectID, taskID: id.description)))
    }

    private static func noTask(_ taskID: String) -> ProtocolError {
        let text = TaskID(taskID)?.description ?? taskID
        return ProtocolError(.notFound, "Task \(text) does not exist.")
    }

    /// The error of a task change: a task file that no longer exists is "Task <id> does not exist."; other errors are
    /// mapped as in §6.9.
    private static func taskError(_ error: any Error, id: TaskID) -> ProtocolError {
        if case DataError.notFound(let message) = error, message == "task \(id) not found" {
            return noTask(id.description)
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
    /// the task id, the upload id and the error's domain and code, never a file name).
    private static func moveBack(_ attachment: TaskAttachment, to upload: ClaimedUpload, projectRoot: URL, id: TaskID) {
        let stored = TaskFile.attachmentsFolder(projectRoot: projectRoot, id: id)
            .appendingPathComponent(attachment.file, isDirectory: false)
        do {
            try FileManager.default.moveItem(at: stored, to: upload.url)
        } catch {
            let failure = error as NSError
            Log.host.error("Could not move an attachment of \(id.description, privacy: .public) back to upload \(upload.uploadID.uuidString, privacy: .public): \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
            try? FileManager.default.removeItem(at: stored)
        }
    }

    /// The cache key and TaskItem of a loaded file (data/task-yml.md, "Mapping to TaskItem" and "Broken files").
    private static func item(_ result: TaskLoadResult) -> (TaskID, TaskItem)? {
        switch result {
        case .valid(let file):
            guard let id = TaskID(file.id) else { return nil }
            return (id, item(file))
        case .broken(let id, let message, let modified):
            return (id, TaskItem(id: id.description, name: "", description: "", status: .todo, created: modified,
                                 updated: modified, comments: [], parseError: message))
        }
    }

    private static func item(_ file: TaskFile) -> TaskItem {
        TaskItem(id: file.id,
                 name: file.name,
                 description: file.description ?? "",
                 status: file.status,
                 created: file.created,
                 updated: file.updated,
                 comments: file.comments.map {
                     TaskComment(id: $0.id, author: $0.author, created: $0.created, edited: $0.edited, body: $0.body,
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
