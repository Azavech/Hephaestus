#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import HephCore

/// The destination state of one migration (docs/devices/migration.md, "migration.begin", "migration.chunk",
/// "migration.commit", "Destination"): its lists, its files with the bytes received and an incremental SHA-256 hasher
/// each, the destination folder and the staging folder of the transcripts, and its begin, chunk, commit and abort
/// steps. MigrationService owns it and uses it on its actor only.
final class MigrationReceiver {
    let migrationID: UUID
    /// The device that sent migration.begin, and the connection that carried it (nil in process).
    let sourceDeviceID: UUID
    let connectionID: UUID?
    let project: ProjectSummary
    let manifest: [ManifestEntry]
    let claudeFiles: [ManifestEntry]
    /// `<projectsFolder>/<folderName>` (or `<folderName> 2`, …): the new project root.
    let destination: URL
    /// Where the transcript files are received, named by the index of their entry in `claudeFiles`.
    let staging: URL
    /// This Main's Claude CLI configuration folder.
    let configDirectory: URL
    /// The folder name of each project of `project`, mapped to its root relative to the top-level root.
    let transcriptRoots: [String: String]

    private struct FileKey: Hashable {
        let transcript: Bool
        let path: String
    }

    private struct FileState {
        let entry: ManifestEntry
        let index: Int              // in its list
        var received = 0
        var hasher = SHA256()
        var digest: String?         // set when `received` reaches the entry's size
    }

    private var files: [FileKey: FileState] = [:]
    /// At most one file is open.
    private var openFile: (key: FileKey, handle: FileHandle)?
    /// The transcript paths installed by the commit, removed by a roll-back.
    private(set) var installed: [URL] = []

    init(params: MigrationBeginParams, sourceDeviceID: UUID, connectionID: UUID?, transcriptRoots: [String: String],
         destination: URL, staging: URL, configDirectory: URL) {
        migrationID = params.migrationID
        self.sourceDeviceID = sourceDeviceID
        self.connectionID = connectionID
        project = params.project
        manifest = params.manifest
        claudeFiles = params.claudeFiles
        self.destination = destination
        self.staging = staging
        self.configDirectory = configDirectory
        self.transcriptRoots = transcriptRoots
        for (index, entry) in manifest.enumerated() where Self.isFile(entry) {
            files[FileKey(transcript: false, path: entry.path)] = FileState(entry: entry, index: index)
        }
        for (index, entry) in claudeFiles.enumerated() where Self.isFile(entry) {
            files[FileKey(transcript: true, path: entry.path)] = FileState(entry: entry, index: index)
        }
    }

    deinit {
        try? openFile?.handle.close()
    }

    // MARK: - migration.begin

    /// Step 1, `folderName`: not empty, not `.` or `..`, no `/` and no NUL.
    static func checkFolderName(_ folderName: String) throws {
        guard !folderName.isEmpty, folderName != ".", folderName != "..", !folderName.contains("/"),
              !folderName.contains("\u{0}")
        else {
            throw ProtocolError(.badRequest, "Invalid folder name.")
        }
    }

    /// The identifiers of `project` and of its children at any depth, top-level first.
    static func identifiers(of project: ProjectSummary) -> [String] {
        [project.id] + project.children.flatMap(identifiers(of:))
    }

    /// Step 1, the checks of both lists, in order: paths, duplicates, parents, fields, transcript folders. Returns the
    /// folder name of each project of `params.project` mapped to its root relative to the top-level root.
    static func checkLists(_ params: MigrationBeginParams) throws -> [String: String] {
        let lists = [(entries: params.manifest, isManifest: true), (entries: params.claudeFiles, isManifest: false)]
        // Every path: not empty, no leading `/`, no empty, `.` or `..` component.
        for list in lists {
            for entry in list.entries {
                try checkPath(entry.path)
            }
        }
        // No path appears twice in a list.
        for list in lists {
            var seen: Set<String> = []
            for entry in list.entries {
                guard seen.insert(entry.path).inserted else {
                    throw invalidEntry(entry.path, "it appears twice")
                }
            }
        }
        // The parent path of every entry is a folder entry of the same list, or the root for `manifest`; the entries
        // at the top of `claudeFiles` are the transcript folders.
        for list in lists {
            let folders = Set(list.entries.filter(\.isDirectory).map(\.path))
            for entry in list.entries {
                if let slash = entry.path.lastIndex(of: "/") {
                    guard folders.contains(String(entry.path[..<slash])) else {
                        throw invalidEntry(entry.path, "its parent is not a folder of the list")
                    }
                } else if !list.isManifest, !entry.isDirectory || entry.symlinkTarget != nil {
                    throw invalidEntry(entry.path, "a transcript folder must be a folder")
                }
            }
        }
        // The fields of each kind of entry.
        for list in lists {
            for entry in list.entries {
                try checkFields(entry)
            }
        }
        // The first component of every `claudeFiles` path is the folder name of a project of `project`.
        let roots = transcriptRoots(of: params.project)
        for entry in params.claudeFiles {
            let name = firstComponent(entry.path)
            guard roots[name] != nil else {
                throw ProtocolError(.badRequest, "Unknown transcript folder \(name).")
            }
        }
        return roots
    }

    /// The folder name of each project of the tree, `ClaudePathEncoding.folderName(for:)` of its received `rootPath`,
    /// mapped to its root relative to `project.rootPath` (`""` for the top-level project). The first project of a
    /// name wins, top-level first, then the sub projects depth-first, as the source includes the folders.
    static func transcriptRoots(of project: ProjectSummary) -> [String: String] {
        var roots: [String: String] = [:]
        var pending = [project]
        while let summary = pending.popLast() {
            let name = ClaudePathEncoding.folderName(for: summary.rootPath)
            if roots[name] == nil, let relative = relativeRoot(summary.rootPath, in: project.rootPath) {
                roots[name] = relative
            }
            pending.append(contentsOf: summary.children.reversed())
        }
        return roots
    }

    /// Step 2: `<projectsFolder>/<folderName>`, or the first of `<folderName> 2`, `<folderName> 3`, … for which no
    /// item exists (lstat); `projectsFolder` is created when missing.
    static func makeDestination(projectsFolder: URL, folderName: String) throws -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: projectsFolder, withIntermediateDirectories: true)
        } catch {
            throw cannotCreate(projectsFolder.path, error.localizedDescription)
        }
        var number = 1
        while true {
            let name = number == 1 ? folderName : "\(folderName) \(number)"
            let candidate = projectsFolder.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            if lstat(candidate.path, &info) == 0 {
                number += 1
                continue
            }
            let code = errno
            guard code == ENOENT else {
                throw cannotCreate(candidate.path, String(cString: strerror(code)))
            }
            do {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
            } catch {
                throw cannotCreate(candidate.path, error.localizedDescription)
            }
            return candidate
        }
    }

    /// Step 3: a staging folder for the transcripts, an item replacement folder appropriate for
    /// `<configDirectory>/projects`, which is created first when missing.
    static func makeStaging(configDirectory: URL) throws -> URL {
        let projects = configDirectory.appendingPathComponent("projects", isDirectory: true)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: projects, withIntermediateDirectories: true)
            return try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: projects,
                                       create: true)
        } catch {
            throw cannotCreate(projects.path, error.localizedDescription)
        }
    }

    // MARK: - migration.chunk

    /// Checks a chunk and writes it at the end of its file, feeding the file's hasher. The first chunk of a file creates
    /// it (mode 0o644) after its missing parent folders (mode 0o755); the file is closed once it has its size.
    func receive(_ chunk: MigrationChunkParams) throws {
        let key = FileKey(transcript: chunk.transcript, path: chunk.path)
        guard var state = files[key] else {
            throw ProtocolError(.notFound, "\(chunk.path) is not in the manifest.")
        }
        guard chunk.offset == state.received else {
            throw ProtocolError(.badRequest, "Unexpected offset \(chunk.offset) for \(chunk.path).")
        }
        let end = chunk.offset + chunk.data.count
        guard !chunk.data.isEmpty, end <= state.entry.size,
              chunk.data.count == MethodLimits.migrationChunkSize || end == state.entry.size
        else {
            throw ProtocolError(.badRequest, "Invalid chunk for \(chunk.path).")
        }
        let handle = try handle(for: key, state: state)
        do {
            try handle.write(contentsOf: chunk.data)
        } catch {
            closeOpenFile()
            throw Self.cannotWrite(chunk.path, error.localizedDescription)
        }
        state.hasher.update(data: chunk.data)
        state.received = end
        if end == state.entry.size {
            state.digest = ManifestBuilder.hex(state.hasher.finalize())
            closeOpenFile()
        }
        files[key] = state
    }

    // MARK: - migration.commit

    /// Step 2: every file of both lists received with its size and its SHA-256; a file of size 0 must have the SHA-256
    /// of empty data.
    func verify() throws {
        closeOpenFile()
        for (entries, transcript) in [(manifest, false), (claudeFiles, true)] {
            for entry in entries where Self.isFile(entry) {
                if entry.size == 0 {
                    guard entry.sha256 == Self.emptyDigest else {
                        throw ProtocolError(.badRequest, "Checksum mismatch for \(entry.path).")
                    }
                    continue
                }
                guard let state = files[FileKey(transcript: transcript, path: entry.path)],
                      state.received == entry.size, let digest = state.digest
                else {
                    throw ProtocolError(.badRequest, "Missing data for \(entry.path).")
                }
                guard digest == entry.sha256 else {
                    throw ProtocolError(.badRequest, "Checksum mismatch for \(entry.path).")
                }
            }
        }
    }

    /// Steps 3 to 5: the folders, empty files and symbolic links of the project folder, modes and dates, then the
    /// transcripts installed under this Main's own encoded folders. Every installed transcript path is recorded.
    func install() throws {
        closeOpenFile()
        let fileManager = FileManager.default

        // 3. Project folder, in manifest order. The paths are resolved inside the destination folder, a symbolic link
        // created earlier never followed out of it.
        let realDestination = ClaudePathEncoding.canonicalPath(destination.path) ?? destination.path
        let resolver = PathResolver(root: URL(fileURLWithPath: realDestination, isDirectory: true))
        var urls: [URL] = []
        urls.reserveCapacity(manifest.count)
        for entry in manifest {
            let url = try resolver.resolve(entry.path, followLast: false)
            urls.append(url)
            try Self.writing(entry.path) {
                if let target = entry.symlinkTarget {
                    try Self.createParent(of: url)
                    try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
                } else if entry.isDirectory {
                    if !Self.exists(url) {
                        try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o755])
                    }
                } else if entry.size == 0 {
                    try Self.createParent(of: url)
                    try Self.createEmptyFile(url, path: entry.path)
                }
            }
        }

        // 4. Modes and dates: each file, then each folder in reverse order.
        try Self.applyModesAndDates(manifest, urls: urls)

        // 5. Transcripts.
        let projectsFolder = configDirectory.appendingPathComponent("projects", isDirectory: true)
        var folders: [String: URL] = [:]
        var transcriptURLs: [URL] = []
        transcriptURLs.reserveCapacity(claudeFiles.count)
        for (index, entry) in claudeFiles.enumerated() {
            let name = Self.firstComponent(entry.path)
            let folder: URL
            if let known = folders[name] {
                folder = known
            } else {
                let relative = transcriptRoots[name] ?? ""
                let root = relative.isEmpty ? destination : destination.appendingPathComponent(relative, isDirectory: true)
                let encoded = ClaudePathEncoding.folderName(for: ClaudePathEncoding.canonicalPath(root.path) ?? root.path)
                folder = projectsFolder.appendingPathComponent(encoded, isDirectory: true)
                folders[name] = folder
            }
            let url: URL
            if entry.path == name {
                url = folder
            } else {
                guard let realFolder = ClaudePathEncoding.canonicalPath(folder.path) else {
                    // realpath(3) of the transcript folder failed: a file system failure.
                    let code = errno
                    throw Self.cannotWrite(entry.path, String(cString: strerror(code == 0 ? ENOENT : code)))
                }
                url = try PathResolver(root: URL(fileURLWithPath: realFolder, isDirectory: true))
                    .resolve(String(entry.path.dropFirst(name.count + 1)), followLast: false)
            }
            transcriptURLs.append(url)
            try Self.writing(entry.path) {
                if entry.isDirectory {
                    if !Self.exists(url) {
                        try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o755])
                        installed.append(url)
                    }
                    return
                }
                if Self.exists(url) {
                    try fileManager.removeItem(at: url)
                }
                try Self.createParent(of: url)
                if let target = entry.symlinkTarget {
                    try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: target)
                } else if entry.size == 0 {
                    try Self.createEmptyFile(url, path: entry.path)
                } else {
                    try fileManager.moveItem(at: staging.appendingPathComponent(String(index), isDirectory: false),
                                             to: url)
                }
                installed.append(url)
            }
        }
        try Self.applyModesAndDates(claudeFiles, urls: transcriptURLs)
    }

    /// A failure in steps 2 to 6: the recorded transcript paths, the destination folder and the staging folder are
    /// removed.
    func rollBack() {
        closeOpenFile()
        for url in installed.reversed() {
            Self.remove(url)
        }
        installed.removeAll()
        Self.remove(destination)
        Self.remove(staging)
    }

    /// Step 8: the staging folder is removed.
    func finish() {
        closeOpenFile()
        Self.remove(staging)
    }

    // MARK: - migration.abort

    /// The open file is closed; the destination folder and the staging folder are removed.
    func abort() {
        closeOpenFile()
        Self.remove(destination)
        Self.remove(staging)
    }

    // MARK: - Files

    /// The open handle of the file of `key`, opening it when needed (the open file of another key is closed first).
    private func handle(for key: FileKey, state: FileState) throws -> FileHandle {
        if let openFile, openFile.key == key {
            return openFile.handle
        }
        closeOpenFile()
        let url = key.transcript
            ? staging.appendingPathComponent(String(state.index), isDirectory: false)
            : destination.appendingPathComponent(key.path, isDirectory: false)
        let flags: Int32
        if state.received == 0 {
            do {
                try Self.createParent(of: url)
            } catch {
                throw Self.cannotWrite(key.path, error.localizedDescription)
            }
            flags = O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
        } else {
            // A file closed before it was complete continues at its end.
            flags = O_WRONLY | O_APPEND | O_CLOEXEC
        }
        let descriptor = try Self.open(url, flags: flags, path: key.path)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        if state.received > 0 {
            _ = try? handle.seekToEnd()
        }
        openFile = (key, handle)
        return handle
    }

    private func closeOpenFile() {
        guard let openFile else { return }
        try? openFile.handle.close()
        self.openFile = nil
    }

    // MARK: - Helpers

    /// SHA-256 of empty data, lowercase hex.
    private static let emptyDigest = ManifestBuilder.hex(SHA256.hash(data: Data()))

    private static func isFile(_ entry: ManifestEntry) -> Bool {
        !entry.isDirectory && entry.symlinkTarget == nil
    }

    private static func firstComponent(_ path: String) -> String {
        String(path.prefix { $0 != "/" })
    }

    private static func checkPath(_ path: String) throws {
        guard !path.isEmpty else { throw invalidEntry(path, "the path is empty") }
        guard !path.hasPrefix("/") else { throw invalidEntry(path, "the path starts with /") }
        guard !path.contains("\u{0}") else { throw invalidEntry(path, "the path contains a NUL character") }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw invalidEntry(path, "the path has an empty, . or .. component")
        }
    }

    /// File: `sha256` of 64 lowercase hex digits, `size` ≥ 0, no `symlinkTarget`; folder: `size` 0, no `sha256`, no
    /// `symlinkTarget`; link: not a folder, `size` 0, no `sha256`, `symlinkTarget` not empty; `mode` in 0…0o7777.
    private static func checkFields(_ entry: ManifestEntry) throws {
        if let target = entry.symlinkTarget {
            guard !entry.isDirectory, entry.size == 0, entry.sha256 == nil, !target.isEmpty,
                  !target.contains("\u{0}")
            else {
                throw invalidEntry(entry.path, "a symbolic link is not a folder and has size 0, no sha256 and a target")
            }
        } else if entry.isDirectory {
            guard entry.size == 0, entry.sha256 == nil else {
                throw invalidEntry(entry.path, "a folder has size 0 and no sha256")
            }
        } else {
            guard let sha256 = entry.sha256, isDigest(sha256) else {
                throw invalidEntry(entry.path, "sha256 is not 64 lowercase hex digits")
            }
            guard entry.size >= 0 else {
                throw invalidEntry(entry.path, "the size is negative")
            }
        }
        guard (0...0o7777).contains(entry.mode) else {
            throw invalidEntry(entry.path, "the mode is not in 0…0o7777")
        }
    }

    private static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// `path` relative to `top` ("" for `top` itself); nil when it is not inside `top` or has an empty, `.` or `..`
    /// component.
    private static func relativeRoot(_ path: String, in top: String) -> String? {
        if path == top {
            return ""
        }
        guard path.hasPrefix(top + "/") else { return nil }
        let relative = String(path.dropFirst(top.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return relative
    }

    /// Each file gets its mode and modification date, then each folder, in reverse order (deepest first, after their
    /// content was written). Symbolic links are left as created.
    private static func applyModesAndDates(_ entries: [ManifestEntry], urls: [URL]) throws {
        let fileManager = FileManager.default
        for (index, entry) in entries.enumerated() where isFile(entry) {
            try writing(entry.path) {
                try fileManager.setAttributes([.posixPermissions: entry.mode, .modificationDate: entry.modified],
                                              ofItemAtPath: urls[index].path)
            }
        }
        for (index, entry) in entries.enumerated().reversed() where entry.isDirectory && entry.symlinkTarget == nil {
            try writing(entry.path) {
                try fileManager.setAttributes([.posixPermissions: entry.mode, .modificationDate: entry.modified],
                                              ofItemAtPath: urls[index].path)
            }
        }
    }

    /// Runs a file system operation on the item of `path`; its failure is internal "Cannot write <path>: <error>".
    private static func writing(_ path: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error as ProtocolError {
            throw error
        } catch {
            throw cannotWrite(path, error.localizedDescription)
        }
    }

    /// lstat: a dangling symbolic link exists.
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Creates the missing parent folders of `url`, mode 0o755.
    private static func createParent(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        guard !exists(parent) else { return }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
    }

    /// Creates an empty file, mode 0o644 (replacing nothing: the place is free); a failure is internal "Cannot write
    /// <path>: <error>", `path` being the entry's path.
    private static func createEmptyFile(_ url: URL, path: String) throws {
        let descriptor = try open(url, flags: O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, path: path)
        close(descriptor)
    }

    /// open(2) with mode 0o644; a failure is internal "Cannot write <path>: <error>".
    private static func open(_ url: URL, flags: Int32, path: String) throws -> Int32 {
        var failure: Int32 = 0
        let descriptor = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            let result = Darwin.open(representation, flags, 0o644)
            failure = result >= 0 ? 0 : errno
            return result
        }
        guard descriptor >= 0 else {
            throw cannotWrite(path, failure == 0 ? "invalid path" : String(cString: strerror(failure)))
        }
        return descriptor
    }

    /// Removes an item; a missing item is no failure; other failures are logged.
    private static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Log.host.error("Migration: could not remove \(url.path): \(error.localizedDescription)")
        }
    }

    private static func invalidEntry(_ path: String, _ reason: String) -> ProtocolError {
        ProtocolError(.badRequest, "Invalid manifest entry \(path): \(reason).")
    }

    private static func cannotCreate(_ path: String, _ reason: String) -> ProtocolError {
        ProtocolError(.internal, "Cannot create \(path): \(reason)")
    }

    private static func cannotWrite(_ path: String, _ reason: String) -> ProtocolError {
        ProtocolError(.internal, "Cannot write \(path): \(reason)")
    }
}
#endif
