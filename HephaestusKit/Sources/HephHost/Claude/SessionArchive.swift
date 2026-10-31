#if os(macOS)
import Foundation
import HephCore

/// The session files of one project, `<project root>/.hephaestus/sessions/` (docs/data/sessions.md): the metadata
/// files, the event logs and the attachment folders. The host creates one per loaded project and gives it to
/// `SessionService`, which reads and writes session files only through it. Errors are `DataError` values.
public actor SessionArchive {
    public nonisolated let projectRoot: URL

    /// A `text` or `input` longer than this many UTF-8 bytes is cut (Writing events).
    private static let maxFieldBytes = 65_536
    /// A page of `history` with a limit fits in this many bytes, each line counted with its LF (Reading events).
    private static let maxPageBytes = 16_777_216

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    // MARK: - Metadata

    /// Every valid metadata file, `status` read as in Status, sorted by created.
    public func list() -> [SessionFile] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
        var files: [SessionFile] = []
        for name in names where Self.isMetadataFileName(name) {
            do {
                files.append(try read(fileName: name))
            } catch {
                let message = (error as? DataError)?.message ?? error.localizedDescription
                Log.host.error("Skipped the session file \(name, privacy: .public): \(message)")
            }
        }
        return files.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
    }

    public func load(_ id: UUID) throws -> SessionFile {
        guard FileManager.default.fileExists(atPath: metadataURL(id).path) else {
            throw Self.notFound(id)
        }
        return try read(fileName: Self.metadataFileName(id))
    }

    /// Writes a new <id>.yml; .invalid("<lowercase id>.yml already exists") when it exists. A broken rule fails with
    /// .invalid(<the rule's message>), and nothing is written.
    public func create(_ file: SessionFile) throws {
        let url = metadataURL(file.id)
        let fileName = url.lastPathComponent
        guard !Self.exists(url) else {
            throw DataError.invalid("\(fileName) already exists")
        }
        var file = file
        file.normalize()
        try file.validate(fileName: fileName)
        try AtomicFile.write(Data(try file.encode(preserving: nil).utf8), to: url)
    }

    /// Read-modify-write of <id>.yml; sets `updated`; returns the file as written.
    @discardableResult
    public func update(_ id: UUID, _ change: @Sendable (inout SessionFile) throws -> Void) throws -> SessionFile {
        let url = metadataURL(id)
        let fileName = url.lastPathComponent
        // 1. The current text.
        let previousText: String
        do {
            previousText = try Self.text(of: try Data(contentsOf: url), fileName: fileName)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            throw Self.notFound(id)
        } catch let error as DataError {
            throw DataError.refused("The file is invalid: \(error.message)")
        } catch {
            throw DataError.io("\(fileName): \(error.localizedDescription)")
        }
        // 2. Decoded, normalized and validated.
        var file: SessionFile
        do {
            file = try SessionFile.decode(previousText, fileName: fileName)
        } catch let error as DataError {
            throw DataError.refused("The file is invalid: \(error.message)")
        }
        // 3. The change, then the rules: a broken rule fails with .invalid(<the rule's message>).
        try change(&file)
        file.updated = YAMLCoding.now()
        file.normalize()
        try file.validate(fileName: fileName)
        // 4. Encoded with the unknown keys of the previous text, written atomically.
        try AtomicFile.write(Data(try file.encode(preserving: previousText).utf8), to: url)
        return file
    }

    // MARK: - Events

    /// Applies the size limit, appends one line, returns the event as stored.
    public func append(_ event: SessionEvent, to id: UUID) throws -> SessionEvent {
        // 1. Size limit.
        var stored = event
        stored.text = event.text.map(Self.limited)
        stored.input = event.input.map(Self.limited)
        // 2. One line.
        var line: Data
        do {
            line = try WireCoding.makeEncoder().encode(stored)
        } catch {
            Log.host.fault("Could not encode an event of session \(id.uuidString, privacy: .public)")
            throw DataError.io("\(Self.eventsFileName(id)): \(error.localizedDescription)")
        }
        line.append(0x0A)
        // 3, 4. Appended in one write, after an LF when the last line was cut short.
        let url = eventsURL(id)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data([0x0A]) {
                    line.insert(0x0A, at: line.startIndex)
                }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: line)
        } catch {
            Log.host.fault("Could not append an event to session \(id.uuidString, privacy: .public): \(error.localizedDescription)")
            throw DataError.io("\(Self.eventsFileName(id)): \(error.localizedDescription)")
        }
        // 5. The event as stored.
        return stored
    }

    /// One page of the log (Reading events); nil `before` and `limit`: every event, without the 16 MiB cut.
    public func history(_ id: UUID, before: Int?, limit: Int?) throws -> SessionsHistoryResult {
        // 1. The session.
        guard FileManager.default.fileExists(atPath: metadataURL(id).path) else {
            throw Self.notFound(id)
        }
        // 2. The non-empty lines.
        let data: Data
        do {
            data = try Data(contentsOf: eventsURL(id))
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            data = Data()
        } catch {
            throw DataError.io("\(Self.eventsFileName(id)): \(error.localizedDescription)")
        }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let total = lines.count
        // 3. The page.
        var end = total
        if let before {
            end = min(max(before, 0), total)
        }
        var firstIndex = 0
        if let limit {
            firstIndex = max(end - max(limit, 0), 0)
        }
        // 4. The 16 MiB cut.
        if limit != nil, firstIndex < end {
            var size = lines[firstIndex..<end].reduce(0) { $0 + $1.count + 1 }
            while size > Self.maxPageBytes, end - firstIndex > 1 {
                size -= lines[firstIndex].count + 1
                firstIndex += 1
            }
        }
        // 5. Decoded, a line that fails skipped.
        let decoder = WireCoding.makeDecoder()
        var events: [SessionEvent] = []
        var skipped = 0
        for line in lines[firstIndex..<end] {
            if let event = try? decoder.decode(SessionEvent.self, from: Data(line)) {
                events.append(event)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 {
            Log.host.error("Skipped \(skipped, privacy: .public) event lines of session \(id.uuidString, privacy: .public)")
        }
        // 6.
        return SessionsHistoryResult(events: events, firstIndex: firstIndex, total: total)
    }

    // MARK: - Attachments

    /// Moves the file at `fileAt` (a complete upload) into <id>/ (Attachments).
    public func saveAttachment(fileAt: URL, originalName: String, to id: UUID) throws -> TicketAttachment {
        let fileManager = FileManager.default
        let attachments = attachmentsFolder(id)
        var name = AttachmentNaming.sanitize(originalName)
        do {
            try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
            name = AttachmentNaming.unique(name, in: attachments)
            let destination = attachments.appendingPathComponent(name, isDirectory: false)
            try fileManager.moveItem(at: fileAt, to: destination)
            let size = (try fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
            return TicketAttachment(file: name, type: AttachmentNaming.mimeType(forFileName: name), size: size)
        } catch {
            throw DataError.io("\(name): \(error.localizedDescription)")
        }
    }

    /// The absolute path of a file of the session's attachment folder.
    public nonisolated func attachmentURL(_ id: UUID, file: String) -> URL {
        attachmentsFolder(id).appendingPathComponent(file, isDirectory: false)
    }

    // MARK: - Deletion

    public func delete(_ id: UUID) throws {
        let parts = [metadataURL(id), eventsURL(id), attachmentsFolder(id)]
        var found = false
        for url in parts where Self.exists(url) {
            found = true
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                throw DataError.io("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard found else { throw Self.notFound(id) }
    }

    // MARK: - Private

    private nonisolated var folder: URL {
        SessionFile.folder(projectRoot: projectRoot)
    }

    private nonisolated func metadataURL(_ id: UUID) -> URL {
        folder.appendingPathComponent(Self.metadataFileName(id), isDirectory: false)
    }

    private nonisolated func eventsURL(_ id: UUID) -> URL {
        folder.appendingPathComponent(Self.eventsFileName(id), isDirectory: false)
    }

    private nonisolated func attachmentsFolder(_ id: UUID) -> URL {
        folder.appendingPathComponent(SessionFile.fileStem(id), isDirectory: true)
    }

    private static func metadataFileName(_ id: UUID) -> String {
        SessionFile.fileStem(id) + ".yml"
    }

    private static func eventsFileName(_ id: UUID) -> String {
        SessionFile.fileStem(id) + ".jsonl"
    }

    private static func notFound(_ id: UUID) -> DataError {
        .notFound("session \(id.uuidString) not found")
    }

    /// A lowercase UUID followed by `.yml`.
    private static func isMetadataFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".yml") else { return false }
        let stem = String(name.dropLast(4))
        guard let id = UUID(uuidString: stem) else { return false }
        return SessionFile.fileStem(id) == stem
    }

    /// Reads and decodes one metadata file of the folder.
    private func read(fileName: String) throws -> SessionFile {
        let url = folder.appendingPathComponent(fileName, isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DataError.io("\(fileName): \(error.localizedDescription)")
        }
        return try SessionFile.decode(try Self.text(of: data, fileName: fileName), fileName: fileName)
    }

    /// The bytes as UTF-8 text, else `.unreadable`.
    private static func text(of data: Data, fileName: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DataError.unreadable("\(fileName): the file is not UTF-8 text")
        }
        return text
    }

    /// Something exists at `url` (a dangling symbolic link included).
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// The size limit of `text` and `input`: the longest prefix of whole Characters (grapheme clusters) whose UTF-8
    /// size is at most the limit, followed by `\n… [truncated: <N> bytes in total]`, <N> being the original size.
    private static func limited(_ text: String) -> String {
        let total = text.utf8.count
        guard total > maxFieldBytes else { return text }
        var size = 0
        var kept = 0
        for character in text {
            let characterSize = character.utf8.count
            guard size + characterSize <= maxFieldBytes else { break }
            size += characterSize
            kept += 1
        }
        return String(text.prefix(kept)) + "\n… [truncated: \(total) bytes in total]"
    }
}
#endif
