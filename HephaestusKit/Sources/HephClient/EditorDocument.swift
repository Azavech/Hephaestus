import Foundation
import HephCore
import ImageIO
import Observation

/// What a document shows.
public enum DocumentContent: Equatable, Sendable {
    case loading
    case text
    case image(Data)
    case binary(size: Int)
    case tooLarge
    case failed(String)
}

/// The banner of a document.
public enum DocumentBanner: Equatable, Sendable {
    /// A save was refused: the file changed on the Main.
    case conflict
    /// The file changed on the Main while this document is modified.
    case changedOnMain(revision: String)
    /// The file was deleted on the Main while this document is modified.
    case deletedOnMain
}

/// One open file of a project: its content, edits, autosave and the changes made on the Main (docs/ui/code.md,
/// "EditorDocument").
@MainActor @Observable
public final class EditorDocument: Identifiable {
    public nonisolated let id = UUID()
    public let files: ProjectFiles
    public private(set) var path: String
    public private(set) var content: DocumentContent = .loading
    /// "" unless content is .text.
    public private(set) var text = ""
    /// Kept for the editor; starts at {0, 0}.
    public var selection = NSRange(location: 0, length: 0)
    public private(set) var revision: String?
    public private(set) var isDirty = false
    public private(set) var isSaving = false
    public private(set) var banner: DocumentBanner?
    /// Default true.
    public var autosaveEnabled = true
    @ObservationIgnored public var onRemoved: (@MainActor (EditorDocument) -> Void)?
    @ObservationIgnored public var onError: (@MainActor (String) -> Void)?

    /// Incremented by each edit: a save keeps the document dirty when an edit happened while it ran.
    @ObservationIgnored private var editCount = 0
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    /// A line asked while loading, applied when the load ends with text.
    @ObservationIgnored private var pendingLine: Int?
    /// A save asked while a save runs.
    @ObservationIgnored private var saveRequested = false
    /// A check asked while a save runs; true when one was asked by a reconnection.
    @ObservationIgnored private var checkRequested: Bool?
    @ObservationIgnored private var loadGeneration = 0

    public init(files: ProjectFiles, path: String) {
        self.files = files
        self.path = path
        let changes = files.changes()
        changesTask = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                await self.apply(change)
            }
        }
    }

    /// `ProjectPath.name(of: path)`
    public var fileName: String {
        ProjectPath.name(of: path)
    }

    // MARK: - Loading

    /// Reads the file and classifies it as text, image or binary.
    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        autosaveTask?.cancel()
        autosaveTask = nil
        content = .loading
        text = ""
        do {
            let result = try await files.read(path)
            guard generation == loadGeneration else { return }
            await show(result, generation: generation, servesCheck: false)
        } catch {
            guard generation == loadGeneration else { return }
            if (error as? ProtocolError)?.code == .tooLarge {
                content = .tooLarge
            } else {
                content = .failed(Workspace.message(of: error))
            }
            // The local text is gone with the load.
            isDirty = false
            banner = nil
            pendingLine = nil
        }
    }

    /// `load()`; discards the local text.
    public func reload() async {
        await load()
    }

    // MARK: - Editing

    /// The setter of the editor binding: sets `text`, marks the document dirty and, with autosave, saves 1.5 s
    /// after the last edit.
    public func edit(_ newText: String) {
        text = newText
        isDirty = true
        editCount += 1
        autosaveTask?.cancel()
        autosaveTask = nil
        guard autosaveEnabled else { return }
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1_500))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            // The wait is over: the save starts and is no longer the timer, which the next edit cancels; cancelling it
            // now would cancel its request.
            self.autosaveTask = nil
            await self.save()
        }
    }

    /// Selects line `line` (1-based) of the text: the range from the start of the line to before its `\n` (and a `\r`
    /// just ahead of it), in UTF-16 offsets; a line past the last line selects the last line. Kept while loading.
    public func selectLine(_ line: Int) {
        switch content {
        case .text:
            selection = Self.range(ofLine: line, in: text)
        case .loading:
            pendingLine = line
        default:
            break
        }
    }

    // MARK: - Saving

    /// Writes the text with the revision it started from (⌘S, Save, autosave, Keep Mine).
    public func save() async {
        guard content == .text, isDirty, banner != .conflict, files.isConnected else { return }
        guard !isSaving else {
            saveRequested = true
            return
        }
        isSaving = true
        let edits = editCount
        do {
            let newRevision = try await files.write(path, data: Data(text.utf8), baseRevision: revision)
            revision = newRevision
            if editCount == edits {
                isDirty = false
            }
        } catch {
            if (error as? ProtocolError)?.code == .conflict {
                banner = .conflict
            } else {
                onError?("Could not save \(fileName): \(Workspace.message(of: error))")
            }
        }
        isSaving = false
        await afterSave()
    }

    /// Conflict: writes the local text without `baseRevision`.
    public func overwrite() async {
        await writeUnconditionally(notFoundMessage: nil)
    }

    /// Changed on the Main: the local text will replace the Main's version.
    public func keepMine() async {
        guard case .changedOnMain(let newRevision) = banner else { return }
        revision = newRevision
        banner = nil
        if autosaveEnabled {
            await save()
        }
    }

    /// Deleted on the Main: writes the file again (it creates it).
    public func recreate() async {
        await writeUnconditionally(notFoundMessage: "Could not save \(fileName): its folder no longer exists.")
    }

    /// The path after a rename made from this device.
    public func moved(to newPath: String) {
        path = newPath
    }

    /// Cancels the autosave timer and the change task. A document is not used after `close()`.
    public func close() {
        autosaveTask?.cancel()
        autosaveTask = nil
        changesTask?.cancel()
        changesTask = nil
    }

    // MARK: - Private

    /// The data of a read replaces the content: classified, with its revision; the document is clean. For a check
    /// (`servesCheck`), the dirty state is read once the data is classified: an edit made meanwhile (the editor stays
    /// live) gives `banner = .changedOnMain(revision:)`, and the text is kept.
    private func show(_ result: FilesReadResult, generation: Int, servesCheck: Bool) async {
        let fileName = fileName
        let data = result.data
        let size = result.size
        let edits = editCount
        let classified = await Task.detached(priority: .userInitiated) {
            Self.classify(data, size: size, fileName: fileName)
        }.value
        guard generation == loadGeneration else { return }
        if servesCheck, editCount != edits {
            banner = .changedOnMain(revision: result.revision)
            return
        }
        switch classified {
        case .text(let decoded):
            text = decoded
            content = .text
        case .image:
            text = ""
            content = .image(data)
        case .binary(let size):
            text = ""
            content = .binary(size: size)
        }
        revision = result.revision
        isDirty = false
        banner = nil
        selection = Self.clamp(selection, toUTF16Count: text.utf16.count)
        if let line = pendingLine {
            pendingLine = nil
            if content == .text {
                selection = Self.range(ofLine: line, in: text)
            }
        }
    }

    private func writeUnconditionally(notFoundMessage: String?) async {
        let edits = editCount
        do {
            let newRevision = try await files.write(path, data: Data(text.utf8), baseRevision: nil)
            revision = newRevision
            if editCount == edits {
                isDirty = false
            }
            banner = nil
        } catch {
            if let notFoundMessage, (error as? ProtocolError)?.code == .notFound {
                onError?(notFoundMessage)
            } else {
                onError?("Could not save \(fileName): \(Workspace.message(of: error))")
            }
        }
    }

    /// Runs what was asked while the save ran: a check, then a save.
    private func afterSave() async {
        if let reconnected = checkRequested {
            checkRequested = nil
            await check(afterReconnection: reconnected)
        }
        if saveRequested {
            saveRequested = false
            await save()
        }
    }

    private func apply(_ change: ProjectFileChange) async {
        switch change {
        case .paths(let paths):
            guard paths.contains(where: { ProjectPath.isSameOrInside(path, ProjectPath.normalize($0)) }) else {
                return
            }
            await check(afterReconnection: false)
        case .reconnected:
            await check(afterReconnection: true)
        }
    }

    /// Reads the file again and compares revisions (docs/ui/code.md, "Changes on the Main").
    private func check(afterReconnection: Bool) async {
        guard content != .loading else { return }
        guard !isSaving else {
            checkRequested = (checkRequested ?? false) || afterReconnection
            return
        }
        let generation = loadGeneration
        do {
            let result = try await files.read(path)
            guard generation == loadGeneration, content != .loading else { return }
            if result.revision == revision {
                if isDirty, afterReconnection, autosaveEnabled {
                    await save()
                }
            } else if isDirty {
                banner = .changedOnMain(revision: result.revision)
            } else {
                await show(result, generation: generation, servesCheck: true)
            }
        } catch {
            guard generation == loadGeneration, (error as? ProtocolError)?.code == .notFound else { return }
            if isDirty {
                banner = .deletedOnMain
            } else {
                onRemoved?(self)
            }
        }
    }

    // MARK: - Classification

    private enum Classified: Sendable {
        case text(String)
        case image
        case binary(Int)
    }

    private nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico",
    ]

    /// Image when the extension is an image one and ImageIO reads it; binary when a NUL byte is in the first 8,000
    /// bytes or the data is not valid UTF-8; else text, decoded unchanged.
    private nonisolated static func classify(_ data: Data, size: Int, fileName: String) -> Classified {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        if imageExtensions.contains(fileExtension),
           let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 {
            return .image
        }
        if data.prefix(8_000).contains(0) {
            return .binary(size)
        }
        guard let decoded = String(validating: data, as: UTF8.self) else {
            return .binary(size)
        }
        return .text(decoded)
    }

    /// The range of line `line` (1-based) in UTF-16 offsets; only `\n` ends a line.
    static func range(ofLine line: Int, in text: String) -> NSRange {
        let newline = UInt16(UInt8(ascii: "\n"))
        let carriageReturn = UInt16(UInt8(ascii: "\r"))
        var start = 0
        var currentLine = 1
        var offset = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if unit == newline {
                if currentLine >= line {
                    let end = previous == carriageReturn ? offset - 1 : offset
                    return NSRange(location: start, length: end - start)
                }
                currentLine += 1
                start = offset + 1
            }
            previous = unit
            offset += 1
        }
        // The last line, or a line past it.
        return NSRange(location: start, length: offset - start)
    }

    private static func clamp(_ range: NSRange, toUTF16Count count: Int) -> NSRange {
        let location = min(max(range.location, 0), count)
        let length = min(max(range.length, 0), count - location)
        return NSRange(location: location, length: length)
    }
}
