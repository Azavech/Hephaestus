import Foundation
import UniformTypeIdentifiers
import Yams

/// A task file, `<project root>/.hephaestus/tasks/<TASK-ID>.yml` (docs/data/task-yml.md). The files attached to its
/// comments are in `<project root>/.hephaestus/attachments/<TASK-ID>/`.
public struct TaskFile: Codable, Sendable, Equatable {
    /// A comment, item of `comments`; maps to `TaskComment` field by field.
    public struct Comment: Codable, Sendable, Equatable {
        public var id: UUID
        public var author: String
        public var created: Date
        public var edited: Date?
        public var body: String
        /// nil when the comment has no attachment.
        public var attachments: [TaskAttachment]?

        public init(id: UUID, author: String, created: Date, edited: Date?, body: String,
                    attachments: [TaskAttachment]?) {
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
            attachments = try container.decodeIfPresent([TaskAttachment].self, forKey: .attachments)
        }
    }

    public var id: String
    public var name: String
    public var description: String?
    public var status: TaskStatus
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

    /// A new task: created = updated = YAMLCoding.now(), no comments.
    public init(id: TaskID, name: String, description: String?, status: TaskStatus) {
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
        status = try container.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .todo
        created = try container.decode(Date.self, forKey: .created)
        updated = try container.decode(Date.self, forKey: .updated)
        comments = try container.decodeIfPresent([Comment].self, forKey: .comments) ?? []
    }

    /// <projectRoot>/.hephaestus/tasks
    public static func folder(projectRoot: URL) -> URL {
        projectRoot
            .appendingPathComponent(".hephaestus", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
    }

    /// <projectRoot>/.hephaestus/tasks/<id>.yml
    public static func url(projectRoot: URL, id: TaskID) -> URL {
        folder(projectRoot: projectRoot).appendingPathComponent(id.fileName, isDirectory: false)
    }

    /// <projectRoot>/.hephaestus/attachments/<id>
    public static func attachmentsFolder(projectRoot: URL, id: TaskID) -> URL {
        projectRoot
            .appendingPathComponent(".hephaestus", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(id.description, isDirectory: true)
    }

    /// Decodes, normalizes and validates; `fileID` is the id given by the file name.
    public static func decode(_ text: String, fileID: TaskID) throws -> TaskFile {
        var file = try YAMLCoding.decode(TaskFile.self, from: text, fileName: fileID.fileName)
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

    /// Normalizes in place (docs/data/task-yml.md, "Validation and normalization").
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
    public func validate(fileID: TaskID) throws {
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

    /// The task files of `.hephaestus/tasks/` (one level), sorted by task number. A missing folder gives no task.
    public static func loadAll(projectRoot: URL, projectID: String) -> [TaskLoadResult] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder(projectRoot: projectRoot),
                                                                includingPropertiesForKeys: [.isRegularFileKey])
        } catch {
            return []
        }
        var results: [(number: Int, result: TaskLoadResult)] = []
        for url in urls {
            guard let id = TaskID(fileName: url.lastPathComponent), id.projectID == projectID, isRegularFile(url)
            else { continue }
            results.append((id.number, load(url: url, id: id)))
        }
        return results.sorted { $0.number < $1.number }.map(\.result)
    }

    /// nil when the file does not exist.
    public static func loadOne(projectRoot: URL, id: TaskID) -> TaskLoadResult? {
        let fileURL = url(projectRoot: projectRoot, id: id)
        guard isRegularFile(fileURL) else { return nil }
        return load(url: fileURL, id: id)
    }

    /// The largest `n` among the entries of `.hephaestus/tasks/` named `<projectID>-<n>.yml`, valid and broken files
    /// alike; 0 when there is none.
    public static func highestNumber(projectRoot: URL, projectID: String) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder(projectRoot: projectRoot).path)
        else { return 0 }
        return names
            .compactMap { TaskID(fileName: $0) }
            .filter { $0.projectID == projectID }
            .map(\.number)
            .max() ?? 0
    }

    /// Reserves the number of a new task with one `ProjectFile.update` of the project's `project.yml`. When the number
    /// would be above `Int.max`, it throws `.invalid("no task number is left in <projectID>")` and writes nothing.
    public static func allocateID(projectRoot: URL) throws -> TaskID {
        var allocated: TaskID?
        try ProjectFile.update(projectRoot: projectRoot) { file in
            let noNumberLeft = DataError.invalid("no task number is left in \(file.id)")
            let highest = highestNumber(projectRoot: projectRoot, projectID: file.id)
            var (number, overflow) = max(file.taskCounter, highest).addingReportingOverflow(1)
            guard !overflow else { throw noNumberLeft }
            while exists(url(projectRoot: projectRoot, id: TaskID(projectID: file.id, number: number))) {
                (number, overflow) = number.addingReportingOverflow(1)
                guard !overflow else { throw noNumberLeft }
            }
            file.taskCounter = number
            allocated = TaskID(projectID: file.id, number: number)
        }
        guard let allocated else {
            throw DataError.io("project.yml: no task number was allocated")
        }
        return allocated
    }

    /// Fails with .invalid("<id> is not a task id") when `file.id` is not a task id, and with
    /// .invalid("<id>.yml already exists") when the file exists.
    public static func create(_ file: TaskFile, projectRoot: URL) throws {
        guard let id = TaskID(fileName: "\(file.id).yml") else {
            throw DataError.invalid("\(file.id) is not a task id")
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
    public static func update(projectRoot: URL, id: TaskID, _ change: (inout TaskFile) throws -> Void) throws -> TaskFile {
        let fileURL = url(projectRoot: projectRoot, id: id)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            throw DataError.notFound("task \(id) not found")
        } catch {
            throw DataError.io("\(id.fileName): \(error.localizedDescription)")
        }
        let previousText: String
        let original: TaskFile
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

    /// Deletes the task file, then the attachments folder; works on broken files.
    public static func delete(projectRoot: URL, id: TaskID) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: url(projectRoot: projectRoot, id: id))
        } catch CocoaError.fileNoSuchFile {
            throw DataError.notFound("task \(id) not found")
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

    /// Moves the file at `fileAt` (a complete upload) into the task's attachments folder (Storing a file).
    public static func storeAttachment(fileAt: URL, originalName: String, projectRoot: URL, id: TaskID) throws
        -> TaskAttachment {
        let fileManager = FileManager.default
        let folder = attachmentsFolder(projectRoot: projectRoot, id: id)
        var name = AttachmentNaming.sanitize(originalName)
        do {
            let size = (try fileManager.attributesOfItem(atPath: fileAt.path)[.size] as? NSNumber)?.intValue ?? 0
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            name = AttachmentNaming.unique(name, in: folder)
            try fileManager.moveItem(at: fileAt, to: folder.appendingPathComponent(name, isDirectory: false))
            return TaskAttachment(file: name, type: AttachmentNaming.mimeType(forFileName: name), size: size)
        } catch {
            throw DataError.io("\(name): \(error.localizedDescription)")
        }
    }

    /// Deletes one stored file; a missing file is ignored.
    public static func deleteAttachment(file: String, projectRoot: URL, id: TaskID) throws {
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
    public static func attachmentURL(projectRoot: URL, id: TaskID, file: String) throws -> URL {
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

    /// Reads and decodes one task file; any failure gives a broken result (logged).
    private static func load(url: URL, id: TaskID) -> TaskLoadResult {
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
            Log.core.error("Broken task file \(id.fileName, privacy: .public): \(message)")
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return .broken(id: id, message: message, modified: modified ?? Date())
        }
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

/// The result of loading one task file.
public enum TaskLoadResult: Sendable {
    case valid(TaskFile)
    /// `message` is the DataError message; `modified` the file's modification date.
    case broken(id: TaskID, message: String, modified: Date)
}

/// The names and MIME types of the files attached to comments and to session messages (docs/data/task-yml.md,
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
