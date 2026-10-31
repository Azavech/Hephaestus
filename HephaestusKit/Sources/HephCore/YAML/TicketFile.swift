import Foundation
import UniformTypeIdentifiers
import Yams

/// A ticket file, `<project root>/.hephaestus/tickets/<TICKET-ID>.yml` (docs/data/ticket-yml.md). The files attached to
/// its comments are in `<project root>/.hephaestus/attachments/<TICKET-ID>/`.
public struct TicketFile: Codable, Sendable, Equatable {
    /// A comment, item of `comments`; maps to `TicketComment` field by field.
    public struct Comment: Codable, Sendable, Equatable {
        public var id: UUID
        public var author: String
        public var created: Date
        public var edited: Date?
        public var body: String
        /// nil when the comment has no attachment.
        public var attachments: [TicketAttachment]?

        public init(id: UUID, author: String, created: Date, edited: Date?, body: String,
                    attachments: [TicketAttachment]?) {
            self.id = id
            self.author = author
            self.created = created
            self.edited = edited
            self.body = body
            self.attachments = attachments
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            author = try container.decode(String.self, forKey: .author)
            created = try container.decode(Date.self, forKey: .created)
            edited = try container.decodeIfPresent(Date.self, forKey: .edited)
            body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            attachments = try container.decodeIfPresent([TicketAttachment].self, forKey: .attachments)
        }
    }

    public var id: String
    public var name: String
    public var description: String?
    public var status: TicketStatus
    public var created: Date
    public var updated: Date
    public var comments: [Comment]

    public static let shape: YAMLShape = .mapping([
        "id": .value, "name": .value, "description": .value, "status": .value, "created": .value, "updated": .value,
        "comments": .list(identity: "id", item: .mapping([
            "id": .value, "author": .value, "created": .value, "edited": .value, "body": .value,
            "attachments": .list(identity: "file", item: .mapping(["file": .value, "type": .value, "size": .value])),
        ])),
    ])

    /// A new ticket: created = updated = YAMLCoding.now(), no comments.
    public init(id: TicketID, name: String, description: String?, status: TicketStatus) {
        let now = YAMLCoding.now()
        self.id = id.description
        self.name = name
        self.description = description
        self.status = status
        created = now
        updated = now
        comments = []
    }

    /// A key absent from the file takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        status = try container.decodeIfPresent(TicketStatus.self, forKey: .status) ?? .todo
        created = try container.decode(Date.self, forKey: .created)
        updated = try container.decode(Date.self, forKey: .updated)
        comments = try container.decodeIfPresent([Comment].self, forKey: .comments) ?? []
    }

    /// <projectRoot>/.hephaestus/tickets
    public static func folder(projectRoot: URL) -> URL {
        projectRoot
            .appendingPathComponent(".hephaestus", isDirectory: true)
            .appendingPathComponent("tickets", isDirectory: true)
    }

    /// <projectRoot>/.hephaestus/tickets/<id>.yml
    public static func url(projectRoot: URL, id: TicketID) -> URL {
        folder(projectRoot: projectRoot).appendingPathComponent(id.fileName, isDirectory: false)
    }

    /// <projectRoot>/.hephaestus/attachments/<id>
    public static func attachmentsFolder(projectRoot: URL, id: TicketID) -> URL {
        projectRoot
            .appendingPathComponent(".hephaestus", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(id.description, isDirectory: true)
    }

    /// Decodes, normalizes and validates; `fileID` is the id given by the file name.
    public static func decode(_ text: String, fileID: TicketID) throws -> TicketFile {
        var file = try YAMLCoding.decode(TicketFile.self, from: text, fileName: fileID.fileName)
        file.normalize()
        do {
            try file.validate(fileID: fileID)
        } catch let error as DataError {
            throw DataError.invalid("\(fileID.fileName): \(error.message)")
        }
        return file
    }

    public func encode(preserving previousText: String?) throws -> String {
        do {
            return try YAMLCoding.encode(self, shape: Self.shape, preserving: previousText)
        } catch let error as DataError {
            throw DataError.io("\(id).yml: \(error.message)")
        }
    }

    /// Normalizes in place (docs/data/ticket-yml.md, "Validation and normalization").
    public mutating func normalize() {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if description?.isEmpty == true {
            description = nil
        }
        for index in comments.indices {
            comments[index].author = comments[index].author.trimmingCharacters(in: .whitespacesAndNewlines)
            if comments[index].attachments?.isEmpty == true {
                comments[index].attachments = nil
            }
        }
    }

    /// Throws `DataError.invalid` with the message of the first broken rule.
    public func validate(fileID: TicketID) throws {
        guard id == fileID.description else {
            throw DataError.invalid("id \(id) does not match the file name \(fileID.fileName)")
        }
        guard ProjectFile.isOneLineName(name) else {
            throw DataError.invalid("the name must not be empty and must be on one line")
        }
        var commentIDs = Set<UUID>()
        for (index, comment) in comments.enumerated() where !commentIDs.insert(comment.id).inserted {
            throw DataError.invalid("comments[\(index)].id must be unique")
        }
        for (index, comment) in comments.enumerated()
        where comment.author.isEmpty || comment.author.contains(where: { $0.isNewline }) {
            throw DataError.invalid("comments[\(index)].author must not be empty")
        }
        for (index, comment) in comments.enumerated()
        where comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (comment.attachments ?? []).isEmpty {
            throw DataError.invalid("comments[\(index)] needs text or an attachment")
        }
        for (index, comment) in comments.enumerated() {
            for (item, attachment) in (comment.attachments ?? []).enumerated()
            where !Self.isSingleComponent(attachment.file) {
                throw DataError.invalid("comments[\(index)].attachments[\(item)].file is not a valid file name")
            }
        }
        for (index, comment) in comments.enumerated() {
            for (item, attachment) in (comment.attachments ?? []).enumerated() where attachment.type.isEmpty {
                throw DataError.invalid("comments[\(index)].attachments[\(item)].type must not be empty")
            }
        }
        for (index, comment) in comments.enumerated() {
            for (item, attachment) in (comment.attachments ?? []).enumerated() where attachment.size < 0 {
                throw DataError.invalid("comments[\(index)].attachments[\(item)].size must not be negative")
            }
        }
    }

    /// The ticket files of `.hephaestus/tickets/` (one level), sorted by ticket number. A missing folder gives no
    /// ticket.
    public static func loadAll(projectRoot: URL, projectID: String) -> [TicketLoadResult] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder(projectRoot: projectRoot),
                                                                includingPropertiesForKeys: [.isRegularFileKey])
        } catch {
            return []
        }
        var results: [(id: TicketID, result: TicketLoadResult)] = []
        for url in urls {
            guard let id = TicketID(fileName: url.lastPathComponent), id.projectID == projectID, isRegularFile(url)
            else { continue }
            results.append((id, load(url: url, id: id)))
        }
        return results.sorted { $0.id < $1.id }.map(\.result)
    }

    /// nil when the file does not exist.
    public static func loadOne(projectRoot: URL, id: TicketID) -> TicketLoadResult? {
        let fileURL = url(projectRoot: projectRoot, id: id)
        guard isRegularFile(fileURL) else { return nil }
        return load(url: fileURL, id: id)
    }

    /// The largest number of the series among the ticket file names (Id allocation step 1): the largest `n` among the
    /// entries of `.hephaestus/tickets/` named `<projectID>-<n>.yml` (`feedback` false) or `<projectID>-F<n>.yml`
    /// (`feedback` true), valid and broken files alike; 0 when there is none.
    public static func highestNumber(projectRoot: URL, projectID: String, feedback: Bool) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder(projectRoot: projectRoot).path)
        else { return 0 }
        return names
            .compactMap { TicketID(fileName: $0) }
            .filter { $0.projectID == projectID && $0.feedback == feedback }
            .map(\.number)
            .max() ?? 0
    }

    /// Reserves the number of a new ticket, or of a feedback ticket when `feedback` is true, with one
    /// `ProjectFile.update` of the project's `project.yml` (`ticketCounter`, `feedbackCounter`). When the number would
    /// be above `Int.max`, it throws `.invalid("no ticket number is left in <projectID>")`, or
    /// `.invalid("no feedback number is left in <projectID>")`, and writes nothing.
    public static func allocateID(projectRoot: URL, feedback: Bool = false) throws -> TicketID {
        var allocated: TicketID?
        try ProjectFile.update(projectRoot: projectRoot) { file in
            let noNumberLeft = DataError.invalid(
                feedback ? "no feedback number is left in \(file.id)" : "no ticket number is left in \(file.id)")
            let counter = feedback ? file.feedbackCounter : file.ticketCounter
            let highest = highestNumber(projectRoot: projectRoot, projectID: file.id, feedback: feedback)
            var (number, overflow) = max(counter, highest).addingReportingOverflow(1)
            guard !overflow else { throw noNumberLeft }
            while exists(url(projectRoot: projectRoot, id: TicketID(projectID: file.id, number: number,
                                                                   feedback: feedback))) {
                (number, overflow) = number.addingReportingOverflow(1)
                guard !overflow else { throw noNumberLeft }
            }
            if feedback {
                file.feedbackCounter = number
            } else {
                file.ticketCounter = number
            }
            allocated = TicketID(projectID: file.id, number: number, feedback: feedback)
        }
        guard let allocated else {
            throw DataError.io("project.yml: no ticket number was allocated")
        }
        return allocated
    }

    /// Data from before tickets: moves the old folder and rewrites the files that hold old names; logs its failures.
    /// Each step runs whatever the result of the others.
    public static func migrateFromTasks(projectRoot: URL) {
        migrateTasksFolder(projectRoot: projectRoot)
        migrateProjectFile(projectRoot: projectRoot)
        migrateSessionFiles(projectRoot: projectRoot)
        migrateBundleFiles(projectRoot: projectRoot)
    }

    /// Fails with .invalid("<id> is not a ticket id") when `file.id` is not a ticket id, and with
    /// .invalid("<id>.yml already exists") when the file exists.
    public static func create(_ file: TicketFile, projectRoot: URL) throws {
        guard let id = TicketID(fileName: "\(file.id).yml") else {
            throw DataError.invalid("\(file.id) is not a ticket id")
        }
        let fileURL = url(projectRoot: projectRoot, id: id)
        guard !exists(fileURL) else {
            throw DataError.invalid("\(id.fileName) already exists")
        }
        var file = file
        file.normalize()
        try file.validate(fileID: id)
        let text = try file.encode(preserving: nil)
        try AtomicFile.write(Data(text.utf8), to: fileURL)
    }

    /// Read-modify-write; returns the file as written. Writes nothing when `change` leaves the file equal. Sets
    /// `updated`; the change only edits the other fields.
    @discardableResult
    public static func update(projectRoot: URL, id: TicketID, _ change: (inout TicketFile) throws -> Void) throws -> TicketFile {
        let fileURL = url(projectRoot: projectRoot, id: id)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            throw DataError.notFound("ticket \(id) not found")
        } catch {
            throw DataError.io("\(id.fileName): \(error.localizedDescription)")
        }
        let previousText: String
        let original: TicketFile
        do {
            previousText = try ProjectFile.text(of: data, fileName: id.fileName)
            original = try decode(previousText, fileID: id)
        } catch let error as DataError {
            throw DataError.refused("The file is invalid: \(error.message)")
        }
        var file = original
        try change(&file)
        file.normalize()
        if file == original {
            return original
        }
        file.updated = YAMLCoding.now()
        try file.validate(fileID: id)
        let text = try file.encode(preserving: previousText)
        try AtomicFile.write(Data(text.utf8), to: fileURL)
        return file
    }

    /// Deletes the ticket file, then the attachments folder; works on broken files.
    public static func delete(projectRoot: URL, id: TicketID) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: url(projectRoot: projectRoot, id: id))
        } catch CocoaError.fileNoSuchFile {
            throw DataError.notFound("ticket \(id) not found")
        } catch {
            throw DataError.io("\(id.fileName): \(error.localizedDescription)")
        }
        do {
            try fileManager.removeItem(at: attachmentsFolder(projectRoot: projectRoot, id: id))
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            throw DataError.io("\(id): \(error.localizedDescription)")
        }
    }

    /// Moves the file at `fileAt` (a complete upload) into the ticket's attachments folder (Storing a file).
    public static func storeAttachment(fileAt: URL, originalName: String, projectRoot: URL, id: TicketID) throws
        -> TicketAttachment {
        let fileManager = FileManager.default
        let folder = attachmentsFolder(projectRoot: projectRoot, id: id)
        var name = AttachmentNaming.sanitize(originalName)
        do {
            let size = (try fileManager.attributesOfItem(atPath: fileAt.path)[.size] as? NSNumber)?.intValue ?? 0
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            name = AttachmentNaming.unique(name, in: folder)
            try fileManager.moveItem(at: fileAt, to: folder.appendingPathComponent(name, isDirectory: false))
            return TicketAttachment(file: name, type: AttachmentNaming.mimeType(forFileName: name), size: size)
        } catch {
            throw DataError.io("\(name): \(error.localizedDescription)")
        }
    }

    /// Deletes one stored file; a missing file is ignored.
    public static func deleteAttachment(file: String, projectRoot: URL, id: TicketID) throws {
        guard isSingleComponent(file) else {
            throw DataError.invalid("invalid attachment name")
        }
        do {
            try FileManager.default.removeItem(at: attachmentsFolder(projectRoot: projectRoot, id: id)
                .appendingPathComponent(file, isDirectory: false))
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            throw DataError.io("\(file): \(error.localizedDescription)")
        }
    }

    /// `<folder>/<file>` for `attachments.read`: `file` must be a single path component and the file must exist.
    public static func attachmentURL(projectRoot: URL, id: TicketID, file: String) throws -> URL {
        guard isSingleComponent(file) else {
            throw DataError.invalid("invalid attachment name")
        }
        let fileURL = attachmentsFolder(projectRoot: projectRoot, id: id).appendingPathComponent(file, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw DataError.notFound("attachment \(file) not found")
        }
        return fileURL
    }

    // MARK: - Private

    /// Reads and decodes one ticket file; any failure gives a broken result (logged).
    private static func load(url: URL, id: TicketID) -> TicketLoadResult {
        do {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw DataError.io("\(id.fileName): \(error.localizedDescription)")
            }
            return .valid(try decode(ProjectFile.text(of: data, fileName: id.fileName), fileID: id))
        } catch {
            let message = (error as? DataError)?.message ?? "\(id.fileName): \(error.localizedDescription)"
            Log.core.error("Broken ticket file \(id.fileName, privacy: .public): \(message)")
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return .broken(id: id, message: message, modified: modified ?? Date())
        }
    }

    /// Migration step 1: `.hephaestus/tasks/` renamed `tickets`, or its entries moved into `tickets`.
    private static func migrateTasksFolder(projectRoot: URL) {
        let fileManager = FileManager.default
        let tasks = projectRoot
            .appendingPathComponent(".hephaestus", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
        let tickets = folder(projectRoot: projectRoot)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: tasks.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        if !exists(tickets) {
            do {
                try fileManager.moveItem(at: tasks, to: tickets)
                Log.core.info("Renamed \(tasks.path) to tickets")
            } catch {
                Log.core.error("Could not rename \(tasks.path) to tickets: \(error.localizedDescription)")
            }
            return
        }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: tasks.path)
        } catch {
            Log.core.error("Could not list \(tasks.path): \(error.localizedDescription)")
            return
        }
        for name in names {
            let source = tasks.appendingPathComponent(name, isDirectory: false)
            let destination = tickets.appendingPathComponent(name, isDirectory: false)
            if exists(destination) {
                Log.core.error("Left \(source.path) in tasks: tickets already has \(name)")
                continue
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
                Log.core.info("Moved \(source.path) to tickets")
            } catch {
                Log.core.error("Could not move \(source.path) to tickets: \(error.localizedDescription)")
            }
        }
        do {
            if try fileManager.contentsOfDirectory(atPath: tasks.path).isEmpty {
                try fileManager.removeItem(at: tasks)
                Log.core.info("Removed the empty folder \(tasks.path)")
            }
        } catch {
            Log.core.error("Could not remove \(tasks.path): \(error.localizedDescription)")
        }
    }

    /// Migration step 2: a project.yml holding `taskCounter` is updated without change.
    private static func migrateProjectFile(projectRoot: URL) {
        let fileURL = ProjectFile.url(projectRoot: projectRoot)
        guard let mapping = topLevelMapping(of: fileURL), mapping["taskCounter"] != nil else { return }
        do {
            try ProjectFile.update(projectRoot: projectRoot) { _ in }
            Log.core.info("Migrated \(fileURL.path)")
        } catch {
            Log.core.error("Could not migrate \(fileURL.path): \(errorMessage(error))")
        }
    }

    /// Migration step 3: the session files holding `taskID` or the kind `task` are decoded and written again.
    private static func migrateSessionFiles(projectRoot: URL) {
        let sessions = SessionFile.folder(projectRoot: projectRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessions.path) else { return }
        for name in names.sorted() where name.hasSuffix(".yml") {
            let fileURL = sessions.appendingPathComponent(name, isDirectory: false)
            guard isRegularFile(fileURL), let mapping = topLevelMapping(of: fileURL),
                  mapping["taskID"] != nil || mapping["kind"]?.string == "task"
            else { continue }
            rewrite(fileURL) { text in
                try SessionFile.decode(text, fileName: name).encode(preserving: text)
            }
        }
    }

    /// Migration step 4: the bundle files holding `tasks` are decoded and written again.
    private static func migrateBundleFiles(projectRoot: URL) {
        let bundles = BundleFile.folder(projectRoot: projectRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: bundles.path) else { return }
        for name in names.sorted() {
            guard let id = BundleID(fileName: name) else { continue }
            let fileURL = bundles.appendingPathComponent(name, isDirectory: false)
            guard isRegularFile(fileURL), let mapping = topLevelMapping(of: fileURL), mapping["tasks"] != nil
            else { continue }
            rewrite(fileURL) { text in
                try BundleFile.decode(text, fileID: id).encode(preserving: text)
            }
        }
    }

    /// The top-level mapping of a YAML file; nil when the file cannot be read or is not a mapping.
    private static func topLevelMapping(of url: URL) -> Node.Mapping? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
              let node = try? Yams.compose(yaml: text)
        else { return nil }
        return node.mapping
    }

    /// Reads the file, gives its text to `encode` and writes the result atomically; a failure is logged and leaves
    /// the file as it is.
    private static func rewrite(_ url: URL, _ encode: (String) throws -> String) {
        do {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw DataError.io("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            let text = try ProjectFile.text(of: data, fileName: url.lastPathComponent)
            try AtomicFile.write(Data(try encode(text).utf8), to: url)
            Log.core.info("Migrated \(url.path)")
        } catch {
            Log.core.error("Could not migrate \(url.path): \(errorMessage(error))")
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        (error as? DataError)?.message ?? error.localizedDescription
    }

    /// Not empty, no `/`, not `.` or `..`.
    private static func isSingleComponent(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// Something exists at `url` (`lstat`: a dangling symbolic link exists).
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}

/// The result of loading one ticket file.
public enum TicketLoadResult: Sendable {
    case valid(TicketFile)
    /// `message` is the DataError message; `modified` the file's modification date.
    case broken(id: TicketID, message: String, modified: Date)
}

/// The names and MIME types of the files attached to comments and to session messages (docs/data/ticket-yml.md,
/// "Naming").
public enum AttachmentNaming {
    /// The name a stored file gets from its original name.
    public static func sanitize(_ originalName: String) -> String {
        // 1. Keep the part after the last "/". 2. Control characters, "\" and ":" become "-".
        let scalars = originalName.unicodeScalars
        let start = scalars.lastIndex(of: "/").map { scalars.index(after: $0) } ?? scalars.startIndex
        var replaced = String.UnicodeScalarView()
        for scalar in scalars[start...] {
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "\\" || scalar == ":" {
                replaced.append("-")
            } else {
                replaced.append(scalar)
            }
        }
        // 3. Leading and trailing whitespace, then leading "." characters.
        var name = String(replaced).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        // 4. Unicode NFC. 5. An empty result becomes "file".
        name = name.precomposedStringWithCanonicalMapping
        if name.isEmpty {
            name = "file"
        }
        // 6. At most 200 UTF-8 bytes, the extension kept.
        if name.utf8.count > maxNameBytes {
            name = shortened(name)
        }
        return name
    }

    /// The name when the folder has no entry with that name, else the first free name with " 2", " 3", … inserted
    /// before the extension.
    public static func unique(_ name: String, in folder: URL) -> String {
        func isTaken(_ candidate: String) -> Bool {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate, isDirectory: false).path)
        }
        guard isTaken(name) else { return name }
        var counter = 2
        while true {
            let candidate: String
            if let parts = split(name) {
                candidate = "\(parts.base) \(counter).\(parts.ext)"
            } else {
                candidate = "\(name) \(counter)"
            }
            if !isTaken(candidate) {
                return candidate
            }
            counter += 1
        }
    }

    /// The preferred MIME type of the lowercased extension, else `application/octet-stream`.
    public static func mimeType(forFileName name: String) -> String {
        guard let parts = split(name),
              let type = UTType(filenameExtension: parts.ext.lowercased())?.preferredMIMEType
        else { return "application/octet-stream" }
        return type
    }

    private static let maxNameBytes = 200

    /// The base name and the extension: the part after the last "." when that "." is not the first character.
    private static func split(_ name: String) -> (base: String, ext: String)? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// Whole characters removed from the end of the base name until the name fits; a name without extension, or
    /// whose base name would become empty, is shortened from its end.
    private static func shortened(_ name: String) -> String {
        if let parts = split(name) {
            var base = parts.base
            while !base.isEmpty, (base + "." + parts.ext).utf8.count > maxNameBytes {
                base.removeLast()
            }
            if !base.isEmpty {
                return base + "." + parts.ext
            }
        }
        var shortened = name
        while shortened.utf8.count > maxNameBytes {
            shortened.removeLast()
        }
        return shortened
    }
}
