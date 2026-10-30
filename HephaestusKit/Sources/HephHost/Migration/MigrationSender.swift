#if os(macOS)
import Foundation
import HephCore

/// The source run of one migration (docs/devices/migration.md, "Source run", "After the commit", "Failures"): a task
/// owned by MigrationService. Its requests go to the destination on this Main's outgoing peer link.
struct MigrationSender: Sendable {
    /// Requests to the destination, `migration.status` included.
    static let requestTimeout: Duration = .seconds(30)
    static let abortTimeout: Duration = .seconds(10)
    /// While `transferring`, at most one progress event per 500 ms.
    static let progressInterval: Duration = .milliseconds(500)

    let migrationID: UUID
    let projectID: String
    let targetDeviceID: UUID
    /// This Main, the `fromDeviceID` of the progress events.
    let sourceDeviceID: UUID
    let host: HostService
    let service: MigrationService

    /// Runs the move to its end: completed, failed, or left `committing` in the journal when the host stops during an
    /// outcome check.
    func run() async {
        await transfer()
        await service.sourceEnded(migrationID)
    }

    // MARK: - Source run

    /// What the run knows, for the failure path and the cleanup.
    private struct Context {
        var rootPath = ""
        var transcriptFolders: [URL] = []
        var bytesDone = 0
        var bytesTotal = 0
        var beginSucceeded = false
        /// migration.begin failed with `unavailable` (no answer in time, or the link closed): D may have begun the
        /// migration.
        var beginUnavailable = false
    }

    /// A file sent in chunks: an entry of `manifest` or, with `transcript`, of `claudeFiles`.
    private struct OutgoingFile {
        let entry: ManifestEntry
        let url: URL
        let transcript: Bool
    }

    /// How the commit ended.
    private enum CommitOutcome {
        case committed
        /// An outcome check answered `unknown`: the message of the failed commit.
        case notCommitted(String)
        /// The outcome check was cancelled by stop(): the journal keeps the entry `committing`.
        case pending
    }

    private func transfer() async {
        var context = Context()
        let outcome: CommitOutcome
        do {
            outcome = try await send(&context)
        } catch {
            await fail(ProjectRegistry.protocolError(error).message, context)
            return
        }
        switch outcome {
        case .committed:
            await afterCommit(context)
        case .notCommitted(let message):
            await fail(message, context)
        case .pending:
            Log.host.notice("Migration \(migrationID.uuidString, privacy: .public) of \(projectID, privacy: .public) waits for its outcome check at the next start")
        }
    }

    /// Steps 1 to 6: manifest, journal, begin, chunks, commit.
    private func send(_ context: inout Context) async throws -> CommitOutcome {
        let mesh: MeshService = host.mesh
        // 1.
        await progress(.preparing, done: 0, total: 0)

        // 2. The manifest and the transcripts.
        let project = try await host.registry.hosted(projectID)
        context.rootPath = project.root.path
        guard let summary = await host.registry.summaries().first(where: { $0.id == projectID }) else {
            throw ProtocolError(.notFound, "Project \(projectID) is not hosted on this Main.")
        }
        let root = URL(fileURLWithPath: ClaudePathEncoding.canonicalPath(project.root.path) ?? project.realRoot.path,
                       isDirectory: true)
        let manifest = try ManifestBuilder.entries(of: root, prefix: "")
        let configDirectory = ClaudePathEncoding.configDirectory(
            environment: await LoginEnvironment.shared.environment(),
            home: FileManager.default.homeDirectoryForCurrentUser)
        let transcripts = try ManifestBuilder.claudeFiles(projectRoots: Self.roots(of: summary),
                                                          configDirectory: configDirectory)
        context.transcriptFolders = transcripts.folders
        context.bytesTotal = (manifest + transcripts.entries).filter(Self.isFile).reduce(0) { $0 + $1.size }

        // 3. The journal entry, then migration.begin.
        try await service.addSourceEntry(migrationID: migrationID, projectID: projectID, rootPath: context.rootPath,
                                         targetDeviceID: targetDeviceID)
        let begin = MigrationBeginParams(migrationID: migrationID, project: Self.canonical(summary),
                                         folderName: project.root.lastPathComponent, manifest: manifest,
                                         claudeFiles: transcripts.entries)
        do {
            _ = try await mesh.requestPeer(targetDeviceID, method: RPCMethod.migrationBegin.rawValue, params: begin,
                                           as: MigrationBeginResult.self, timeout: Self.requestTimeout)
        } catch let error as ProtocolError where error.code == .tooLarge {
            // The request does not fit in one frame; nothing was sent.
            throw ProtocolError(.tooLarge, "This project has too many files to move (\(manifest.count + transcripts.entries.count)).")
        } catch let error as ProtocolError where error.code == .unavailable {
            context.beginUnavailable = true
            throw error
        }
        context.beginSucceeded = true

        // 4.
        await progress(.transferring, done: 0, total: context.bytesTotal)

        // 5. Every file of size > 0, in order, the project's then the transcripts, one chunk at a time.
        let projectsFolder = configDirectory.appendingPathComponent("projects", isDirectory: true)
        var files: [OutgoingFile] = []
        for entry in manifest where Self.isFile(entry) && entry.size > 0 {
            files.append(OutgoingFile(entry: entry, url: root.appendingPathComponent(entry.path, isDirectory: false),
                                      transcript: false))
        }
        for entry in transcripts.entries where Self.isFile(entry) && entry.size > 0 {
            files.append(OutgoingFile(entry: entry,
                                      url: projectsFolder.appendingPathComponent(entry.path, isDirectory: false),
                                      transcript: true))
        }
        var lastProgress = ContinuousClock.now
        for file in files {
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: file.url)
            } catch {
                throw ProtocolError(.internal, "Cannot read \(file.entry.path): \(error.localizedDescription)")
            }
            defer { try? handle.close() }
            var offset = 0
            while offset < file.entry.size {
                let length = min(MethodLimits.migrationChunkSize, file.entry.size - offset)
                let data = try Self.read(handle, count: length, path: file.entry.path)
                let chunk = MigrationChunkParams(migrationID: migrationID, path: file.entry.path, offset: offset,
                                                 data: data, transcript: file.transcript)
                _ = try await mesh.requestPeer(targetDeviceID, method: RPCMethod.migrationChunk.rawValue,
                                               params: chunk, as: EmptyPayload.self, timeout: Self.requestTimeout)
                offset += length
                context.bytesDone += length
                if ContinuousClock.now - lastProgress >= Self.progressInterval {
                    await progress(.transferring, done: context.bytesDone, total: context.bytesTotal)
                    lastProgress = ContinuousClock.now
                }
            }
        }
        if !files.isEmpty {
            await progress(.transferring, done: context.bytesDone, total: context.bytesTotal)
        }

        // 6. Committing.
        await progress(.committing, done: context.bytesTotal, total: context.bytesTotal)
        try await service.setEntryState(migrationID, .committing, required: true)
        do {
            _ = try await mesh.requestPeer(targetDeviceID, method: RPCMethod.migrationCommit.rawValue,
                                           params: MigrationCommitParams(migrationID: migrationID),
                                           as: EmptyPayload.self, timeout: Self.requestTimeout)
        } catch let error as ProtocolError where error.code == .unavailable {
            // Lost commit answer: the project stays locked and the entry `committing` until an outcome check answers.
            Log.host.notice("Migration \(migrationID.uuidString, privacy: .public): the commit answer was lost; checking its outcome")
            switch await service.outcomeCheck(migrationID: migrationID, targetDeviceID: targetDeviceID) {
            case .committed?:
                return .committed
            case .unknown?:
                return .notCommitted(error.message)
            case nil:
                return .pending
            }
        }
        return .committed
    }

    // MARK: - After the commit

    /// The entry becomes `committed`; the project leaves the registry; its sessions and runs are forgotten; its folder
    /// and its transcript folders go to the Trash; the entry is removed once the folder is gone; progress `completed`.
    private func afterCommit(_ context: Context) async {
        try? await service.setEntryState(migrationID, .committed, required: false)
        let registry: ProjectRegistry = host.registry
        let tree = [projectID] + (await registry.descendants(of: projectID))
        // 1.
        await registry.unregister(projectID, forget: true)
        // 2.
        for id in tree {
            await host.sessions.stopAll(projectID: id)
            await host.runs.stopAll(projectID: id)
        }
        // 3.
        var projectFolderGone = true
        if let realRoot = ClaudePathEncoding.canonicalPath(context.rootPath) {
            do {
                try host.appSupport.trashItem(URL(fileURLWithPath: realRoot, isDirectory: true))
            } catch {
                projectFolderGone = false
                Log.host.error("Migration \(migrationID.uuidString, privacy: .public): could not move the folder of \(projectID, privacy: .public) to the Trash: \(error.localizedDescription)")
            }
        }
        for folder in context.transcriptFolders {
            do {
                try host.appSupport.trashItem(folder)
            } catch {
                Log.host.error("Migration \(migrationID.uuidString, privacy: .public): could not move a transcript folder to the Trash: \(error.localizedDescription)")
            }
        }
        // 4.
        if projectFolderGone {
            await service.removeEntry(migrationID)
        }
        // 5.
        await progress(.completed, done: context.bytesTotal, total: context.bytesTotal)
        Log.host.notice("Migration \(migrationID.uuidString, privacy: .public): \(projectID, privacy: .public) moved to \(targetDeviceID.uuidString, privacy: .public)")
    }

    // MARK: - Failures

    /// The destination is told to abort when migration.begin had succeeded, or failed with `unavailable` (D may have
    /// begun the migration); the project is unlocked, the entry removed, and progress `failed` carries the message.
    private func fail(_ message: String, _ context: Context) async {
        if context.beginSucceeded || context.beginUnavailable {
            _ = try? await host.mesh.requestPeer(targetDeviceID, method: RPCMethod.migrationAbort.rawValue,
                                                 params: MigrationAbortParams(migrationID: migrationID),
                                                 as: EmptyPayload.self, timeout: Self.abortTimeout)
        }
        await host.registry.setMigrating(projectID, false)
        await service.removeEntry(migrationID)
        await progress(.failed, done: context.bytesDone, total: context.bytesTotal, error: message)
        Log.host.notice("Migration \(migrationID.uuidString, privacy: .public) of \(projectID, privacy: .public) failed: \(message)")
    }

    // MARK: - Helpers

    private func progress(_ state: MigrationState, done: Int, total: Int, error: String? = nil) async {
        let payload = MigrationProgressPayload(migrationID: migrationID, projectID: projectID,
                                               fromDeviceID: sourceDeviceID, toDeviceID: targetDeviceID,
                                               state: state, bytesDone: done, bytesTotal: total, error: error)
        await host.events.broadcast(.migrationProgress(payload))
    }

    /// Exactly `count` bytes from the current position; fewer before the end of the file means it changed.
    private static func read(_ handle: FileHandle, count: Int, path: String) throws -> Data {
        var data = Data()
        while data.count < count {
            let block: Data?
            do {
                block = try handle.read(upToCount: count - data.count)
            } catch {
                throw ProtocolError(.internal, "Cannot read \(path): \(error.localizedDescription)")
            }
            guard let block, !block.isEmpty else { break }
            data.append(block)
        }
        guard data.count == count else {
            throw ProtocolError(.internal, "\(path) changed during the move.")
        }
        return data
    }

    private static func isFile(_ entry: ManifestEntry) -> Bool {
        !entry.isDirectory && entry.symlinkTarget == nil
    }

    /// The roots of the tree: the project's, then its sub projects' depth-first in `subprojects` order.
    private static func roots(of summary: ProjectSummary) -> [String] {
        [summary.rootPath] + summary.children.flatMap(roots(of:))
    }

    /// The summary with every `rootPath` replaced by its canonical path.
    private static func canonical(_ summary: ProjectSummary) -> ProjectSummary {
        var copy = summary
        copy.rootPath = ClaudePathEncoding.canonicalPath(summary.rootPath) ?? summary.rootPath
        copy.children = summary.children.map(canonical)
        return copy
    }
}
#endif
