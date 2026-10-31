#if os(macOS)
import Darwin
import Foundation
import HephCore

/// The search a Main runs on its own projects, skills and registry (docs/services/search.md §4): `search.query`, one
/// query at a time, in arrival order.
actor SearchService: HostMethodHandler {
    /// A query answers with what it found when this much time has passed since its request arrived (§4.1).
    static let deadline: Duration = .seconds(20)
    /// At most this many files per project are considered (§4.3).
    static let maxFilesPerProject = 20_000
    /// The content of larger files is not searched (§4.3).
    static let maxTextFileSize = 1_048_576
    /// A file is text when these first bytes hold no NUL byte and the whole content is UTF-8 (§4.3).
    static let textProbeLength = 8_192

    private let host: HostService
    private var cache = ContentCache()
    /// A query is running; the next ones wait in `waiting`, in arrival order.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(host: HostService) {
        self.host = host
    }

    /// search.query on this Main (§4.1).
    func query(_ params: SearchQueryParams) async throws -> [SearchResult] {
        let deadline = ContinuousClock.now + Self.deadline
        await waitForTurn()
        defer { endTurn() }
        return try await run(params, deadline: deadline)
    }

    /// HostService.stop().
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - HostMethodHandler

    func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .searchQuery:
                let request = try Self.decode(SearchQueryParams.self, params, method)
                return try WireCoding.encodeJSON(SearchQueryResult(results: try await query(request)))
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - Query flow (§4.1)

    private func run(_ params: SearchQueryParams, deadline: ContinuousClock.Instant) async throws -> [SearchResult] {
        // 1. Limit.
        let limit = min(max(params.limit ?? MethodLimits.maxSearchResults, 1), MethodLimits.maxSearchResults)

        // 2. Scopes.
        let scopes: Set<SearchScope>
        if let requested = params.scopes, !requested.isEmpty {
            scopes = Set(requested)
        } else {
            scopes = Set(SearchScope.allCases)
        }

        // 3. Projects.
        let registry: ProjectRegistry = host.registry
        let projects: [HostedProject]
        if let projectID = params.projectID {
            var selected = [try await registry.hosted(projectID)]
            for id in await registry.descendants(of: projectID) {
                if let project = try? await registry.hosted(id) {
                    selected.append(project)
                }
            }
            projects = selected
        } else {
            projects = await registry.all()
        }

        // 4. A query without words.
        let query = SearchQuery(params.query)
        guard !query.isEmpty else { return [] }

        // 5. Every item of every selected scope.
        var state = QueryState(query: query, deadline: deadline, deviceID: await host.mesh.localDevice().id)
        if scopes.contains(.projects) {
            searchProjects(projects, state: &state)
        }
        if scopes.contains(.tickets) || scopes.contains(.comments) {
            await searchTickets(projects, tickets: scopes.contains(.tickets), comments: scopes.contains(.comments),
                              state: &state)
        }
        if scopes.contains(.docs) || scopes.contains(.code) {
            await searchFiles(projects, docs: scopes.contains(.docs), code: scopes.contains(.code), state: &state)
        }
        if scopes.contains(.webTabs) {
            searchWebTabs(projects, state: &state)
        }
        if scopes.contains(.sessions) {
            await searchSessions(projects, state: &state)
        }
        if params.projectID == nil {
            if scopes.contains(.skills) {
                searchSkills(state: &state)
            }
            if scopes.contains(.devices) {
                await searchDevices(state: &state)
            }
        }
        if state.expired {
            Log.host.error("search.query reached its deadline; answering with \(state.candidates.count, privacy: .public) matches")
        }
        if state.fileLimitReached {
            Log.host.notice("search.query considered at most \(Self.maxFilesPerProject, privacy: .public) files per folder; the other files were ignored")
        }

        // 6. Order, limit, then snippets and lines.
        let kept = state.candidates
            .sorted { SearchMatcher.precedes($0.result, $1.result) }
            .prefix(limit)
        return kept.map { Self.finished($0, query: query) }
    }

    /// The snippet of a kept result: the text of `SearchMatcher.snippet` for the first field that contains a word, for a
    /// content match; `""` otherwise. Its line for the content of a file; for a skill, the path of that file (`SKILL.md`
    /// when the snippet comes from no file).
    private static func finished(_ candidate: Candidate, query: SearchQuery) -> SearchResult {
        var result = candidate.result
        if candidate.result.kind == .skills {
            result.path = "SKILL.md"
        }
        guard candidate.result.rank == 2 else { return result }
        for (index, field) in candidate.fields.enumerated() {
            guard let snippet = SearchMatcher.snippet(query, in: field) else { continue }
            result.snippet = snippet.text
            switch candidate.result.kind {
            case .docs, .code:
                result.line = snippet.line
            case .skills:
                result.line = snippet.line
                if index < candidate.fieldPaths.count {
                    result.path = candidate.fieldPaths[index]
                }
            default:
                break
            }
            break
        }
        return result
    }

    // MARK: - Scopes (§1, §3, §4.2)

    private func searchProjects(_ projects: [HostedProject], state: inout QueryState) {
        for project in projects {
            guard state.goesOn() else { return }
            let file = project.file
            let fields = file.description.map { [$0] } ?? []
            state.add(id: project.id, title: file.name, fields: fields,
                      result: SearchResult(kind: .projects, deviceID: state.deviceID, projectID: project.id,
                                           itemID: project.id, title: file.name, snippet: "", rank: 0,
                                           date: project.modified))
        }
    }

    private func searchTickets(_ projects: [HostedProject], tickets searchTickets: Bool, comments searchComments: Bool,
                             state: inout QueryState) async {
        for project in projects {
            guard state.goesOn() else { return }
            guard let tickets = try? await host.tickets.list(projectID: project.id) else { continue }
            for ticket in tickets {
                guard state.goesOn() else { return }
                if searchTickets {
                    // A broken ticket is searched by its id only.
                    let broken = ticket.parseError != nil
                    state.add(id: ticket.id, title: broken ? "" : ticket.name, fields: broken ? [] : [ticket.description],
                              result: SearchResult(kind: .tickets, deviceID: state.deviceID, projectID: project.id,
                                                   itemID: ticket.id, ticketID: ticket.id, title: ticket.name, snippet: "",
                                                   rank: 0, date: ticket.updated))
                }
                if searchComments {
                    for comment in ticket.comments {
                        state.add(id: nil, title: "", fields: [comment.body],
                                  result: SearchResult(kind: .comments, deviceID: state.deviceID,
                                                       projectID: project.id, itemID: comment.id.uuidString,
                                                       ticketID: ticket.id, title: ticket.name, snippet: "", rank: 0,
                                                       date: comment.edited ?? comment.created))
                    }
                }
            }
        }
    }

    private func searchWebTabs(_ projects: [HostedProject], state: inout QueryState) {
        for project in projects {
            for tab in project.file.webTabValues {
                guard state.goesOn() else { return }
                state.add(id: nil, title: tab.title, fields: [tab.url],
                          result: SearchResult(kind: .webTabs, deviceID: state.deviceID, projectID: project.id,
                                               itemID: tab.id.uuidString, title: tab.title, snippet: "", rank: 0))
            }
        }
    }

    private func searchSessions(_ projects: [HostedProject], state: inout QueryState) async {
        for project in projects {
            guard state.goesOn() else { return }
            guard let sessions = try? await host.sessions.sessions(projectID: project.id), !sessions.isEmpty else {
                continue
            }
            let archive = try? await host.sessionArchive(project.id)
            for session in sessions {
                guard state.goesOn() else { return }
                let texts = await sessionTexts(projectRoot: project.root, sessionID: session.id, archive: archive)
                state.add(id: nil, title: session.title, fields: texts,
                          result: SearchResult(kind: .sessions, deviceID: state.deviceID, projectID: project.id,
                                               itemID: session.id.uuidString, ticketID: session.ticketID,
                                               title: session.title, snippet: "", rank: 0, date: session.updated))
            }
        }
    }

    private func searchDevices(state: inout QueryState) async {
        for record in await host.mesh.snapshot().devices where !record.revoked {
            guard state.goesOn() else { return }
            state.add(id: nil, title: record.name, fields: [],
                      result: SearchResult(kind: .devices, deviceID: state.deviceID, itemID: record.id.uuidString,
                                           title: record.name, snippet: "", rank: 0))
        }
    }

    // MARK: - Docs and code (§4.3)

    private func searchFiles(_ projects: [HostedProject], docs searchDocs: Bool, code searchCode: Bool,
                             state: inout QueryState) async {
        let registry: ProjectRegistry = host.registry
        for project in projects {
            guard state.goesOn() else { return }
            let file = project.file

            // 1. Code folder and docs folder.
            let code = ProjectFile.normalizedRelativePath(file.code) ?? "."
            let docs = ProjectFile.normalizedRelativePath(file.docs) ?? "."
            let codeFolder = code == "." ? project.realRoot : project.realRoot.appendingPathComponent(code, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: codeFolder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }

            // 2. The roots of the registered sub projects inside the code folder are skipped.
            var subprojectFolders: Set<String> = []
            for child in await registry.children(of: project.id) {
                if let relative = ProjectRegistry.relativePath(of: child.realRoot.path, inside: codeFolder.path),
                   !relative.isEmpty {
                    subprojectFolders.insert(relative)
                }
            }

            // 3. At most 20,000 files.
            let walked = walk(codeFolder, skipping: subprojectFolders, state: &state)

            // 4, 5. Items.
            for item in walked {
                guard state.goesOn() else { return }
                let isMarkdown = ["md", "markdown"].contains((item.name as NSString).pathExtension.lowercased())
                let insideDocs = docs == "." || item.relativePath.hasPrefix(docs + "/")
                let kind: SearchScope = isMarkdown && insideDocs ? .docs : .code
                guard kind == .docs ? searchDocs : searchCode else { continue }
                let path = code == "." ? item.relativePath : code + "/" + item.relativePath
                let texts = fileTexts(item)
                state.add(id: nil, title: item.name, fields: texts,
                          result: SearchResult(kind: kind, deviceID: state.deviceID, projectID: project.id,
                                               itemID: path, path: path, title: item.name, snippet: "", rank: 0,
                                               date: item.modified))
            }
        }
    }

    // MARK: - Skills (§4.2)

    private func searchSkills(state: inout QueryState) {
        let fileManager = FileManager.default
        let library = host.appSupport.skillsFolder
        guard let names = try? fileManager.contentsOfDirectory(atPath: library.path) else { return }
        for name in names.sorted() where !name.hasPrefix(".") {
            guard state.goesOn() else { return }
            let folder = library.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  fileManager.fileExists(atPath: folder.appendingPathComponent("SKILL.md", isDirectory: false).path)
            else { continue }
            let files = walk(folder, skipping: [], state: &state)
            // SKILL.md first, then the other files by path.
            let ordered = files.filter { $0.relativePath == "SKILL.md" }
                + files.filter { $0.relativePath != "SKILL.md" }.sorted { $0.relativePath < $1.relativePath }
            var fields: [String] = []
            var fieldPaths: [String] = []
            for file in ordered {
                for text in fileTexts(file) {
                    fields.append(text)
                    fieldPaths.append(file.relativePath)
                }
            }
            state.add(id: nil, title: name, fields: fields, fieldPaths: fieldPaths,
                      result: SearchResult(kind: .skills, deviceID: state.deviceID, itemID: name, title: name,
                                           snippet: "", rank: 0, date: files.map(\.modified).max()))
        }
    }

    // MARK: - File walk and content (§4.3, §4.4)

    private struct WalkedFile {
        let url: URL
        let relativePath: String      // relative to the walked folder, `/`-separated
        let name: String
        let size: Int
        let modified: Date
    }

    /// The regular files under `folder`, in enumeration order: hidden names are skipped with their content, folders
    /// whose relative path is in `skipped` too, symbolic links are skipped and never followed; at most 20,000 files.
    private func walk(_ folder: URL, skipping skipped: Set<String>, state: inout QueryState) -> [WalkedFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                              options: [])
        else { return [] }
        let keySet = Set(keys)
        var files: [WalkedFile] = []
        while let next = enumerator.nextObject() {
            guard state.goesOn() else { break }
            guard let url = next as? URL else { continue }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: keySet)
            // skipDescendants() applies to the last folder returned, so it is called for folders only; the enumerator
            // never enters a symbolic link.
            let isFolder = values?.isDirectory == true && values?.isSymbolicLink != true
            if IgnoreRules.isHidden(name: name) {
                if isFolder {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let values, values.isSymbolicLink != true else { continue }
            // The path relative to `folder` is made of the last `level` components of the item's URL.
            let relativePath = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            if isFolder {
                if skipped.contains(relativePath) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard files.count < Self.maxFilesPerProject else {
                state.fileLimitReached = true
                break
            }
            files.append(WalkedFile(url: url, relativePath: relativePath, name: name, size: values.fileSize ?? 0,
                                    modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)))
        }
        return files
    }

    /// The searchable text of a file, through the content cache: its content when it is a text file of at most 1 MiB.
    private func fileTexts(_ file: WalkedFile) -> [String] {
        let key = file.url.path
        if let texts = cache.texts(for: key, modified: file.modified, size: file.size) {
            return texts
        }
        let texts = Self.readText(file.url, size: file.size).map { [$0] } ?? []
        cache.store(key, modified: file.modified, size: file.size, texts: texts)
        return texts
    }

    /// The content of a text file of at most 1 MiB: its first 8,192 bytes hold no NUL byte and the whole content decodes
    /// as UTF-8; nil for any other file.
    private static func readText(_ url: URL, size: Int) -> String? {
        guard size <= maxTextFileSize, let data = try? Data(contentsOf: url), data.count <= maxTextFileSize,
              !data.prefix(textProbeLength).contains(0)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The text of each `user` and `assistant` event of a session, in order, through the content cache keyed by the
    /// session's `.jsonl` path, its modification date and size.
    private func sessionTexts(projectRoot: URL, sessionID: UUID, archive: SessionArchive?) async -> [String] {
        let log = SessionFile.folder(projectRoot: projectRoot)
            .appendingPathComponent(SessionFile.fileStem(sessionID) + ".jsonl", isDirectory: false)
        var info = stat()
        guard stat(log.path, &info) == 0 else { return [] }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let size = Int(info.st_size)
        if let texts = cache.texts(for: log.path, modified: modified, size: size) {
            return texts
        }
        guard let archive, let history = try? await archive.history(sessionID, before: nil, limit: nil) else {
            return []
        }
        let texts = history.events.compactMap { event -> String? in
            event.type == .user || event.type == .assistant ? event.text : nil
        }
        cache.store(log.path, modified: modified, size: size, texts: texts)
        return texts
    }

    // MARK: - Queue

    private func waitForTurn() async {
        if busy {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
        } else {
            busy = true
        }
    }

    /// Hands the turn to the next query in line, or frees it.
    private func endTurn() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}

/// A matching item: its result without snippet and line, and its content fields for the snippet.
private struct Candidate {
    var result: SearchResult
    var fields: [String]
    /// Skills: the path, inside the skill folder, of the file of each field.
    var fieldPaths: [String]
}

/// The state of one query: the matches found so far and its deadline.
private struct QueryState {
    let query: SearchQuery
    let deadline: ContinuousClock.Instant
    /// This Main: the `deviceID` of every result.
    let deviceID: UUID
    var candidates: [Candidate] = []
    /// The deadline passed: no new item is looked at.
    var expired = false
    /// A folder had more than 20,000 files.
    var fileLimitReached = false

    /// True while the query may look at new items.
    mutating func goesOn() -> Bool {
        if !expired, ContinuousClock.now >= deadline {
            expired = true
        }
        return !expired
    }

    /// Ranks an item (SearchMatcher.rank) and keeps it when it matches, with that rank.
    mutating func add(id: String?, title: String, fields: [String], fieldPaths: [String] = [],
                      result: SearchResult) {
        guard let rank = SearchMatcher.rank(query, id: id, title: title, fields: fields) else { return }
        var result = result
        result.rank = rank
        candidates.append(Candidate(result: result, fields: fields, fieldPaths: fieldPaths))
    }
}

/// The content cache (§4.4): by absolute path, the modification date, size and searchable texts of a file, used while
/// they do not change; at most 128 MiB of UTF-8 text, the least recently used entries evicted beyond it.
private struct ContentCache {
    static let maxBytes = 134_217_728

    private struct Entry {
        var modified: Date
        var size: Int
        var texts: [String]
        var bytes: Int
        /// Neighbours in the recency list: `older` toward the least recently used entry.
        var older: String?
        var newer: String?
    }

    private var entries: [String: Entry] = [:]
    private var newest: String?
    private var oldest: String?
    private var totalBytes = 0

    /// The stored texts when the entry has this modification date and size; the entry becomes the most recently used.
    mutating func texts(for key: String, modified: Date, size: Int) -> [String]? {
        guard let entry = entries[key], entry.modified == modified, entry.size == size else { return nil }
        unlink(key)
        insertNewest(key, entry)
        return entry.texts
    }

    /// Stores or replaces an entry, then evicts the least recently used entries beyond 128 MiB.
    mutating func store(_ key: String, modified: Date, size: Int, texts: [String]) {
        if entries[key] != nil {
            unlink(key)
        }
        let bytes = texts.reduce(0) { $0 + $1.utf8.count }
        insertNewest(key, Entry(modified: modified, size: size, texts: texts, bytes: bytes))
        while totalBytes > Self.maxBytes, let victim = oldest {
            unlink(victim)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        newest = nil
        oldest = nil
        totalBytes = 0
    }

    private mutating func insertNewest(_ key: String, _ entry: Entry) {
        var entry = entry
        entry.older = newest
        entry.newer = nil
        if let newest {
            entries[newest]?.newer = key
        } else {
            oldest = key
        }
        newest = key
        entries[key] = entry
        totalBytes += entry.bytes
    }

    /// Removes the entry from the cache and from the recency list.
    private mutating func unlink(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        if let older = entry.older {
            entries[older]?.newer = entry.newer
        } else {
            oldest = entry.newer
        }
        if let newer = entry.newer {
            entries[newer]?.older = entry.older
        } else {
            newest = entry.older
        }
        totalBytes -= entry.bytes
    }
}
#endif
