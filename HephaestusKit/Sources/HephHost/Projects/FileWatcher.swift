#if os(macOS)
import CoreServices
import Foundation
import HephCore

/// FSEvents → events (docs/services/host.md §11): one stream per top-level folder of projects.json that exists,
/// registered or not; each batch becomes project, ticket and `files.changed` events.
actor FileWatcher {
    /// One FSEvents batch of one stream.
    struct Batch: Sendable {
        let root: URL           // the watched folder, projects.json form
        let realRoot: String    // its realpath(3), the form FSEvents reports
        let events: [Event]
    }

    struct Event: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    private let host: HostService
    /// By the watched folder's path (projects.json form).
    private var streams: [String: EventStream] = [:]
    private var batches: AsyncStream<Batch>.Continuation?
    private var consumer: Task<Void, Never>?

    init(host: HostService) {
        self.host = host
    }

    /// watch(_:) for every path of projects.json whose folder exists.
    func start() async {
        for path in ProjectsFile.load(host.appSupport).file.projects {
            watch(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    /// No-op when already watched.
    func watch(_ root: URL) {
        let key = root.standardizedFileURL.path
        guard streams[key] == nil else { return }
        guard let realRoot = ClaudePathEncoding.canonicalPath(key) else {
            Log.host.error("Not watching \(key): the folder does not exist")
            return
        }
        let stream = EventStream(root: URL(fileURLWithPath: key, isDirectory: true), realRoot: realRoot,
                                 batches: batchContinuation())
        guard stream.start() else {
            Log.host.error("Could not watch \(key)")
            return
        }
        streams[key] = stream
    }

    /// No-op when not watched.
    func unwatch(_ root: URL) {
        let key = root.standardizedFileURL.path
        guard let stream = streams.removeValue(forKey: key) else { return }
        stream.stop()
    }

    func stopAll() {
        for stream in streams.values {
            stream.stop()
        }
        streams.removeAll()
        batches?.finish()
        batches = nil
        consumer?.cancel()
        consumer = nil
    }

    // MARK: - Batches (§11.2)

    private func batchContinuation() -> AsyncStream<Batch>.Continuation {
        if let batches {
            return batches
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Batch.self, bufferingPolicy: .unbounded)
        batches = continuation
        consumer = Task { [weak self] in
            for await batch in stream {
                await self?.process(batch)
            }
        }
        return continuation
    }

    private func process(_ batch: Batch) async {
        let registry: ProjectRegistry = host.registry
        // 6. RootChanged: the folder no longer exists.
        if batch.events.contains(where: { $0.flags & Self.rootChanged != 0 }), !Self.folderExists(batch.root) {
            if let project = await registry.all().first(where: { $0.parentID == nil && $0.root.path == batch.root.path }) {
                await registry.unregister(project.id, forget: false)
            }
            unwatch(batch.root)
            Log.host.notice("The folder \(batch.root.path) is gone; it is no longer watched until the next start")
            return
        }
        // 1. Dropped paths.
        let events = batch.events.filter { !Self.isDropped($0.path, realRoot: batch.realRoot) }
        guard !events.isEmpty else { return }

        var projects = await registry.all()
        var rereads: [String] = []
        var registrations: [(root: URL, parentID: String?)] = []
        var reloads: [(projectID: String, ticketID: TicketID)] = []
        var rescans: [String] = []
        var flaggedPaths: [String] = []
        var paths: [String] = []
        let rootRegistered = projects.contains { $0.parentID == nil && $0.root.path == batch.root.path }

        for event in events {
            let owners = Self.containing(event.path, in: projects)
            guard let owner = owners.first else {
                // 2. A path of an unregistered top-level folder.
                if !rootRegistered,
                   ProjectRegistry.relativePath(of: event.path, inside: batch.realRoot) == ProjectFile.relativePath,
                   (try? ProjectFile.load(projectRoot: batch.root)) != nil {
                    registrations.append((batch.root, nil))
                }
                continue
            }
            paths.append(event.path)
            // 3. Classification by the owner (§11.3).
            classify(owner.relativePath, owner: owner.project, rereads: &rereads, registrations: &registrations,
                     reloads: &reloads, rescans: &rescans)
            // 5. Dropped or coalesced events: every project inside the path or containing it is read again.
            if event.flags & Self.mustScan != 0 {
                flaggedPaths.append(event.path)
                for project in projects
                where ProjectRegistry.relativePath(of: project.realRoot.path, inside: event.path) != nil
                    || ProjectRegistry.relativePath(of: event.path, inside: project.realRoot.path) != nil {
                    rereads.append(project.id)
                    rescans.append(project.id)
                }
            }
        }

        // Project events first: project.yml read again, projects registered.
        for projectID in Self.unique(rereads) {
            await reread(projectID)
        }
        var registered = Set<String>()
        for registration in registrations where registered.insert(registration.root.path).inserted {
            do {
                _ = try await registry.register(root: registration.root, parentID: registration.parentID)
            } catch {
                Log.host.error("Could not register \(registration.root.path): \(ProjectRegistry.protocolError(error).message)")
            }
        }
        // Then ticket events.
        let tickets: TicketService = host.tickets
        for reload in reloads {
            await tickets.reload(projectID: reload.projectID, ticketID: reload.ticketID)
        }
        for projectID in Self.unique(rescans) {
            await tickets.rescan(projectID: projectID)
        }
        // 4. Then files.changed, per project containing at least one path, with the projects as they are now.
        projects = await registry.all()
        var changed: [String: Set<String>] = [:]
        for path in paths {
            for match in Self.containing(path, in: projects) {
                changed[match.project.id, default: []].insert(match.relativePath)
            }
        }
        for path in flaggedPaths {
            for project in projects where ProjectRegistry.relativePath(of: project.realRoot.path, inside: path) != nil {
                changed[project.id, default: []].insert("")
            }
        }
        for (projectID, relativePaths) in changed.sorted(by: { $0.key < $1.key }) {
            let list = relativePaths.count > 1_000 ? [""] : relativePaths.sorted()
            await host.emit(.filesChanged(FilesChangedPayload(projectID: projectID, paths: list)))
        }
    }

    /// The row of §11.3 for `rel`, the path relative to the owner's root.
    private func classify(_ rel: String, owner: HostedProject, rereads: inout [String],
                          registrations: inout [(root: URL, parentID: String?)],
                          reloads: inout [(projectID: String, ticketID: TicketID)], rescans: inout [String]) {
        if rel == ProjectFile.relativePath {
            rereads.append(owner.id)
            return
        }
        if rel == Self.ticketsFolder {
            rescans.append(owner.id)
            return
        }
        if rel.hasPrefix(Self.ticketsFolder + "/") {
            let name = String(rel.dropFirst(Self.ticketsFolder.count + 1))
            if !name.contains("/"), let ticketID = TicketID(fileName: name), ticketID.projectID == owner.id {
                reloads.append((owner.id, ticketID))
            }
            return
        }
        let suffix = "/" + ProjectFile.relativePath
        if rel.hasSuffix(suffix) {
            let entry = String(rel.dropLast(suffix.count))
            if owner.file.subprojects.contains(entry) {
                registrations.append((ProjectRegistry.subprojectRoot(of: owner.root, entry: entry), owner.id))
            }
        }
    }

    /// project.yml read again (§11.3): missing → unregistered; invalid or another id → invalid; valid → reloaded.
    private func reread(_ projectID: String) async {
        let registry: ProjectRegistry = host.registry
        guard let project = try? await registry.hosted(projectID) else { return }
        do {
            let file = try ProjectFile.load(projectRoot: project.root)
            if file.id != project.id {
                await registry.markInvalid(projectID, error: "project.yml: the project identifier cannot change")
            } else {
                let modified = ProjectRegistry.modificationDate(of: ProjectFile.url(projectRoot: project.root))
                await registry.reloaded(projectID, file: file, modified: modified)
            }
        } catch DataError.notFound {
            await registry.unregister(projectID, forget: false)
        } catch {
            await registry.markInvalid(projectID, error: ProjectRegistry.protocolError(error).message)
        }
    }

    // MARK: - Private

    private static let ticketsFolder = ".hephaestus/tickets"
    private static let rootChanged = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
    private static let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
    private static let droppedComponents: Set<String> = [".git", ".build", "DerivedData", "node_modules"]

    /// The paths that files.changed never reports (§11.2 step 1).
    private static func isDropped(_ path: String, realRoot: String) -> Bool {
        let relative = ProjectRegistry.relativePath(of: path, inside: realRoot) ?? path
        let components = relative.split(separator: "/").map(String.init)
        if components.contains(where: { droppedComponents.contains($0) }) {
            return true
        }
        guard let name = components.last else { return false }
        if name == ".DS_Store" || AtomicFile.isTemporaryName(name) {
            return true
        }
        for index in components.indices.dropLast(2)
        where components[index] == ".hephaestus" && components[index + 1] == "sessions" {
            return true
        }
        return false
    }

    /// Every project whose realRoot contains `path`, deepest first, with the relative path.
    private static func containing(_ path: String, in projects: [HostedProject])
        -> [(project: HostedProject, relativePath: String)] {
        projects
            .compactMap { project in
                ProjectRegistry.relativePath(of: path, inside: project.realRoot.path).map { (project, $0) }
            }
            .sorted { $0.project.realRoot.path.count > $1.project.realRoot.path.count }
    }

    private static func folderExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// One FSEvents stream, delivered on its own serial queue; each callback is one batch, yielded in order.
///
/// `@unchecked Sendable`: the FSEventStream is created, started, stopped and released only on `queue`
/// (`ca.azavech.hephaestus.filewatcher`), where its callbacks also run.
private final class EventStream: @unchecked Sendable {
    let root: URL
    let realRoot: String
    private let batches: AsyncStream<FileWatcher.Batch>.Continuation
    private let queue = DispatchQueue(label: "ca.azavech.hephaestus.filewatcher")
    private var stream: FSEventStreamRef?

    init(root: URL, realRoot: String, batches: AsyncStream<FileWatcher.Batch>.Continuation) {
        self.root = root
        self.realRoot = realRoot
        self.batches = batches
    }

    /// FSEventStreamCreate with the folder's realpath, since now, latency 0.3 s, file events, watch root, CF types.
    func start() -> Bool {
        queue.sync {
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context,
                                                    [realRoot] as CFArray,
                                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
            else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            return true
        }
    }

    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let owner = Unmanaged<EventStream>.fromOpaque(info).takeUnretainedValue()
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var events: [FileWatcher.Event] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard index < array.count, let path = array[index] as? String else { continue }
            events.append(FileWatcher.Event(path: path, flags: flags[index]))
        }
        owner.batches.yield(FileWatcher.Batch(root: owner.root, realRoot: owner.realRoot, events: events))
    }
}
#endif
