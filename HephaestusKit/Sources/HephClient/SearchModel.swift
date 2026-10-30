import Foundation
import HephCore
import Observation

/// Global search on the client: asks every connected Main and merges the answers (docs/services/search.md,
/// "SearchModel").
@MainActor @Observable
public final class SearchModel {
    /// The search field; a change schedules a search.
    public var text = "" {
        didSet {
            if text != oldValue {
                schedule()
            }
        }
    }

    /// Empty = every scope; a change schedules a search.
    public var scopes: Set<SearchScope> = [] {
        didSet {
            if scopes != oldValue {
                schedule()
            }
        }
    }

    /// Optional restriction to one project…
    public var projectID: String? {
        didSet {
            if projectID != oldValue {
                schedule()
            }
        }
    }

    /// …on this Main.
    public var mainDeviceID: UUID? {
        didSet {
            if mainDeviceID != oldValue {
                schedule()
            }
        }
    }

    /// The query of the shown results.
    public private(set) var query = SearchQuery("")
    public private(set) var results: [SearchResult] = []
    public private(set) var isSearching = false
    /// Main device id → error message, for the current search.
    public private(set) var failures: [UUID: String] = [:]

    @ObservationIgnored private let workspace: Workspace
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Incremented by each change and each search: an answer of an older generation is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isClearing = false

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    /// Runs the scheduled search without waiting (Return key).
    public func searchNow() {
        cancelPending()
        search()
    }

    /// `text = ""`, `results = []`, cancels the search.
    public func clear() {
        isClearing = true
        text = ""
        isClearing = false
        cancelPending()
        results = []
        isSearching = false
    }

    /// `SearchMatcher.highlights(query, in:)`
    public func highlights(in text: String) -> [Range<String.Index>] {
        SearchMatcher.highlights(query, in: text)
    }

    // MARK: - Scheduling

    /// Cancels the pending debounce and the search in flight, then starts a 250 ms debounce.
    private func schedule() {
        guard !isClearing else { return }
        cancelPending()
        let generation = generation
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, generation == self.generation else { return }
            self.search()
        }
    }

    private func cancelPending() {
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        searchTask?.cancel()
        searchTask = nil
    }

    private func search() {
        generation += 1
        let generation = generation
        let searchQuery = SearchQuery(text)
        guard !searchQuery.isEmpty else {
            query = searchQuery
            results = []
            failures = [:]
            isSearching = false
            return
        }
        // Every connected Main; with `projectID`, only the connection of `mainDeviceID`.
        var targets = workspace.connections.values.filter(\.isConnected).sorted { $0.id.uuidString < $1.id.uuidString }
        if projectID != nil {
            targets = targets.filter { $0.id == mainDeviceID }
        }
        guard !targets.isEmpty else {
            results = []
            isSearching = false
            return
        }
        failures = [:]
        isSearching = true
        let searchScopes = scopes.isEmpty ? nil : SearchScope.allCases.filter { scopes.contains($0) }
        let searchProjectID = projectID
        searchTask = Task { [weak self] in
            await withTaskGroup(of: (UUID, Result<[SearchResult], any Error>).self) { group in
                for connection in targets {
                    group.addTask { @MainActor in
                        do {
                            let answer = try await connection.search(query: searchQuery.text, scopes: searchScopes,
                                                                     projectID: searchProjectID, limit: 200)
                            return (connection.id, .success(answer))
                        } catch {
                            return (connection.id, .failure(error))
                        }
                    }
                }
                var pending = targets.count
                var answered = false
                for await (mainDeviceID, outcome) in group {
                    pending -= 1
                    guard let self, generation == self.generation else { continue }
                    switch outcome {
                    case .success(let answer):
                        self.merge(answer, query: searchQuery, replacing: !answered)
                        answered = true
                    case .failure(let error):
                        self.failures[mainDeviceID] = Workspace.message(of: error)
                        if pending == 0, !answered {
                            self.results = []
                        }
                    }
                    if pending == 0 {
                        self.isSearching = false
                    }
                }
            }
        }
    }

    /// The first successful answer of a generation replaces `results` and sets `query`; each later answer is merged
    /// into them. Devices and skills found by several Mains are kept once; the list is sorted.
    private func merge(_ answer: [SearchResult], query searchQuery: SearchQuery, replacing: Bool) {
        var merged = replacing ? answer : results + answer
        if replacing {
            query = searchQuery
        }
        merged.sort(by: SearchMatcher.precedes)
        var seen = Set<String>()
        merged = merged.filter { result in
            guard result.kind == .devices || result.kind == .skills else { return true }
            return seen.insert("\(result.kind.rawValue)/\(result.itemID)").inserted
        }
        results = merged
    }
}
