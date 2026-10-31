# Search

files:
- HephaestusKit/Sources/HephCore/Search/SearchMatcher.swift
- HephaestusKit/Sources/HephHost/Search/SearchService.swift
- HephaestusKit/Sources/HephClient/SearchModel.swift

---

Global search, end to end: the matcher shared by every platform (`SearchMatcher`, HephCore), the search each Main runs
on its own projects, skills and registry (`SearchService`, HephHost), and the client model that asks every connected
Main and merges the answers (`SearchModel`, HephClient). The method is `search.query`
([../protocol/methods.md](../protocol/methods.md)); `SearchScope` and `SearchResult` are in
[../protocol/types.md](../protocol/types.md#searchresult). The search screen and the navigation to a result are in
[../ui/search.md](../ui/search.md).

## 1. What is searched

Every item gets three inputs for matching (§2.2): an `id` for the exact id match, a `title`, and content `fields`.

| Scope      | Item                                 | `id`       | `title`       | `fields`                                  |
|------------|--------------------------------------|------------|---------------|-------------------------------------------|
| `projects` | a hosted project or sub project      | identifier | name          | description                               |
| `tickets`  | a ticket                             | ticket id  | name          | description                               |
| `comments` | a comment                            | none       | none (`""`)   | body                                      |
| `docs`     | a Markdown file of the docs folder   | none       | file name     | content                                   |
| `code`     | any other file of the code folder    | none       | file name     | content                                   |
| `skills`   | a skill of the library               | none       | skill name    | content of each of its files              |
| `webTabs`  | a web tab                            | none       | tab title     | URL                                       |
| `sessions` | a Claude session                     | none       | session title | text of each `user` and `assistant` event |
| `devices`  | a non-revoked device of the registry | none       | device name   | none                                      |

- The id is also searched as content: "HEPH" matches every ticket of HEPH.
- A broken ticket is searched by its id only (`title` and `fields` empty).
- A skill's description is in the front matter of its `SKILL.md`, so it is searched as content.

## 2. SearchMatcher

```swift
// HephCore/Search/SearchMatcher.swift
public struct SearchQuery: Sendable, Equatable {
    public let text: String            // the query, white space and newlines trimmed at both ends
    public let words: [String]         // `text` split on white space and newlines; duplicates removed
    public init(_ text: String)
    public var isEmpty: Bool { get }   // no words
}

public enum SearchMatcher {
    /// [.caseInsensitive, .diacriticInsensitive]
    public static let options: String.CompareOptions
    public static func contains(_ word: String, in text: String) -> Bool
    /// The item's SearchResult.rank (§2.2): 0 exact id match, 1 title match, 2 content match; nil when it does not
    /// match.
    public static func rank(_ query: SearchQuery, id: String?, title: String, fields: [String]) -> Int?
    /// One line around the first match in `text`, with its 1-based line number; nil when no word occurs.
    public static func snippet(_ query: SearchQuery, in text: String) -> (text: String, line: Int)?
    /// Ranges of every occurrence of every word in `text`, merged and sorted.
    public static func highlights(_ query: SearchQuery, in text: String) -> [Range<String.Index>]
    /// Result order: true when `a` comes before `b` (§2.5).
    public static func precedes(_ a: SearchResult, _ b: SearchResult) -> Bool
}
```

### 2.1 Normalization

- Comparisons are case- and diacritic-insensitive: `contains` is `text.range(of: word, options: options) != nil`
  ("cafe" matches "Café", "heph-12" matches "HEPH-12").
- Two words are duplicates when `a.compare(b, options: options) == .orderedSame`; the first one is kept.

### 2.2 rank

1. `0` when `id` is given and `query.text.compare(id, options: options) == .orderedSame`.
2. Else `1` when every word occurs in `title`.
3. Else `2` when every word occurs in at least one of `title`, `id` and `fields` (words are ANDed within one item;
   different words may occur in different fields).
4. Else `nil`.

### 2.3 snippet

1. The earliest occurrence in `text` of any word; none → `nil`.
2. Its line runs from after the previous `\n` to before the next one; `line` = 1 + the number of `\n` before the
   occurrence.
3. The line is trimmed of white space at both ends.
4. A line longer than 160 characters is cut to a 160-character window that starts 40 characters before the occurrence
   (not before the line start, and moved left when it would pass the line end); `…` is added at each end that was cut.

### 2.4 highlights

For each word, every non-overlapping occurrence from left to right with `options`; the ranges of all words are merged
where they overlap or touch and sorted by position. Clients highlight `title` and `snippet` with it; ranges are not
sent over the wire.

### 2.5 Order

`precedes(a, b)` compares, in order:

1. `rank`, ascending: id matches, then title matches, then content matches;
2. `date`, newest first; a result without `date` comes after those with one;
3. `title` with `localizedStandardCompare`;
4. then, as plain strings with an absent value read as `""`: `deviceID` (`uuidString`), `kind` (raw value),
   `projectID`, `itemID`, `ticketID`, `path`;
5. then `line`, an absent value read as `0`.

This is a total order on the results of every Main (`deviceID`, `kind` and `itemID` identify a result), so merged
lists are stable.

## 3. SearchResult

| Kind       | Fields set                                                                                       | `title`         | `snippet` of a content match       | `date`                           |
|------------|--------------------------------------------------------------------------------------------------|-----------------|------------------------------------|----------------------------------|
| `projects` | `projectID`; `itemID` = the identifier                                                           | name            | description                        | project.yml modification date    |
| `tickets`  | `projectID`, `ticketID`; `itemID` = the ticket id                                                | name            | description                        | `updated`                        |
| `comments` | `projectID`, `ticketID`; `itemID` = the comment id (`uuidString`)                                | the ticket name | body                               | `edited`, else `created`         |
| `docs`     | `projectID`, `path`, `line`; `itemID` = `path`, the project path                                 | file name       | content                            | file modification date           |
| `code`     | `projectID`, `path`, `line`; `itemID` = `path`, the project path                                 | file name       | content                            | file modification date           |
| `skills`   | `path`, `line`; `itemID` = the skill name                                                        | skill name      | content of the first matching file | latest modification of its files |
| `webTabs`  | `projectID`; `itemID` = the tab id (`uuidString`)                                                | tab title       | URL                                | absent                           |
| `sessions` | `projectID`, `ticketID` (ticket and feedback sessions); `itemID` = the session id (`uuidString`) | session title   | text of the first matching event   | session `updated`                |
| `devices`  | `itemID` = the device id (`uuidString`)                                                          | device name     | none                               | absent                           |

- `kind` is the item's scope and `rank` is §2.2. `deviceID` is always the answering Main, for `devices` results too
  (the matched device is `itemID`). Fields not set by the table are absent: `projectID` for `skills` and `devices`.
- `snippet` is the text of `SearchMatcher.snippet` for the first field (in `fields` order) that contains a word. It is
  `""` (never absent) for id and title matches (rank 0 and 1) and when no field contains a word.
- `line` is the snippet's line number when the snippet comes from the content of a file (`docs`, `code`, `skills`);
  absent otherwise. `path` of a skill is the path, inside the skill folder, of the file the snippet comes from;
  `SKILL.md` when the snippet comes from no file.

## 4. SearchService (Main)

```swift
// HephHost/Search/SearchService.swift
actor SearchService: HostMethodHandler {
    init(host: HostService)
    func query(_ params: SearchQueryParams) async throws -> [SearchResult]
    func clearCache()                     // HostService.stop()
}
```

`search.query` searches this Main only. The MCP tool `search` reaches it through the host
([../claude/mcp.md](../claude/mcp.md)).

### 4.1 Query flow

1. `limit`: `nil` → `MethodLimits.maxSearchResults` (200); below 1 → 1; above 200 → 200.
2. `scopes`: `nil` or empty → every scope.
3. `projectID`: when set, it must be hosted here (`notFound`); only that project and its descendants are searched, in
   the project scopes (`projects`, `tickets`, `comments`, `docs`, `code`, `webTabs`, `sessions`); `skills` and `devices`
   give no result. Without it, every hosted project is searched, and `skills` and `devices` too.
4. `SearchQuery(query)` empty → `{results: []}`.
5. Every item of every selected scope gets `SearchMatcher.rank`; a matching item gives a result with the fields of §3
   except `snippet` and `line`.
6. The results are sorted with `SearchMatcher.precedes` and the first `limit` are kept; their `snippet` and `line` are
   then computed (`line` never decides the order of one Main's results, §2.5) and they are returned.

Queries are served one at a time, in arrival order. A query must answer within the request timeout: 20 s after its
request arrived, it stops looking at new items and answers with what it found so far (logged). A query that waited in
line for 20 s answers at once with what it finds before the deadline (possibly nothing).

### 4.2 Sources

- `projects`, `webTabs`: `registry.all()` and each project's cached project.yml ([host.md](host.md) §6).
- `tickets`, `comments`: `tickets.list(projectID:)` ([host.md](host.md) §8).
- `docs`, `code`: the file walk of §4.3 through the content cache of §4.4.
- `skills`: each folder of `appSupport.skillsFolder` ([../claude/skills.md](../claude/skills.md)) whose name does not
  start with `.` and that holds a `SKILL.md`. The skill name is the folder name. Its files are walked like §4.3 (hidden
  names and symbolic links skipped) and read through the content cache with the text rule of §4.3 step 5; `fields` are
  `SKILL.md` first, then the other files by path.
- `sessions`: `sessions.sessions(projectID:)` for `id`, `title`, `ticketID` and `updated`. The texts are the `text` of
  each `user` and `assistant` event, in order, read from the project's `SessionArchive` with
  `history(_:before: nil, limit: nil)` ([../data/sessions.md](../data/sessions.md#reading-events)), so every event of
  the log is read (the default and maximum page sizes of the `sessions.history` method do not apply). They are cached
  like a file (§4.4), keyed by the session's `.jsonl` path, its modification date and size.
- `devices`: `mesh.snapshot().devices` without the revoked records.

### 4.3 File walk (docs and code)

For each searched project:

1. Code folder = root + `code` of project.yml (`.` is the root); docs folder = code folder + `docs`. A missing code
   folder gives no items.
2. The code folder is enumerated recursively with `FileManager.enumerator(at:includingPropertiesForKeys:options:)`
   (keys: is-directory, is-regular-file, is-symbolic-link, file size, content modification date):
   - an item whose name is hidden (`IgnoreRules.isHidden(name:)`, [files.md](files.md) §6) is skipped, with its
     content;
   - a folder that is the root of a registered sub project is skipped with its content (the sub project is searched as
     its own project when it is searched);
   - symbolic links are skipped, never followed;
   - only regular files are items.
3. At most 20,000 files per project are considered, in enumeration order; the rest are ignored (logged once per query).
4. A file inside the docs folder with the extension `md` or `markdown` (any case) is a `docs` item; every other file is
   a `code` item. `path` is its project path ([files.md](files.md) §2).
5. The file name is always searched (`title`). The content is searched for text files of at most 1 MiB (1,048,576
   bytes) only: a file is text when its first 8,192 bytes contain no NUL byte and its whole content decodes as UTF-8.

### 4.4 Content cache

- Key: absolute path. Value: modification date, size and the searchable texts (none for a binary, too large or
  unreadable file).
- An entry is used when the file's current modification date and size equal the stored ones; otherwise the file is
  read again and the entry replaced.
- The cached texts total at most 128 MiB of UTF-8; beyond it, the least recently used entries are evicted.
- `clearCache()` empties it.

## 5. SearchModel (client)

```swift
// HephClient/SearchModel.swift
@MainActor @Observable
public final class SearchModel {
    public init(workspace: Workspace)
    public var text: String                       // the search field; a change schedules a search
    public var scopes: Set<SearchScope>           // empty = every scope; a change schedules a search
    public var projectID: String?                 // optional restriction to one project…
    public var mainDeviceID: UUID?                // …on this Main
    public private(set) var query: SearchQuery    // the query of the shown results
    public private(set) var results: [SearchResult]
    public private(set) var isSearching: Bool
    public private(set) var failures: [UUID: String]   // Main device id → error message, for the current search
    public func searchNow()                       // runs the scheduled search without waiting (Return key)
    public func clear()                           // text = "", results = [], cancels the search
    public func highlights(in text: String) -> [Range<String.Index>]   // SearchMatcher.highlights(query, in:)
}
```

### 5.1 Scheduling and cancellation

1. A change of `text`, `scopes`, `projectID` or `mainDeviceID` cancels the pending debounce and the search in flight
   (its task is cancelled and its generation number becomes stale), then starts a 250 ms debounce.
2. When the debounce ends, or on `searchNow()`: `SearchQuery(text)`. When it is empty: `query` takes it,
   `results = []`, `failures = [:]`, `isSearching = false`, and nothing is sent.
3. Targets: every `MainConnection` of `workspace.connections` with `isConnected`
   ([../client/workspace.md](../client/workspace.md)); with `projectID`, only the connection of `mainDeviceID`. No
   target → `results = []`, `isSearching = false`.
4. `failures = [:]`, `isSearching = true`; `connection.search(query: <trimmed text>, scopes: <nil when empty>,
   projectID:, limit: 200)` on every target in parallel.
5. An answer of a stale generation is dropped. The Mains are not told: they finish the query and the answer is ignored.

### 5.2 Merge

1. The first successful answer of a generation replaces `results` and sets `query` (the previous results stay visible
   until then); each later answer is merged into them. When every target failed, `results = []`.
2. Results of kind `devices` or `skills` with the same `itemID` from several Mains are kept once: the one that comes
   first by `SearchMatcher.precedes`.
3. `results` is sorted with `SearchMatcher.precedes`. There is no limit beyond the 200 per Main.
4. A failed target sets `failures[<Main id>]` to the error's message; the other answers are still shown.
5. When every target has answered or failed, `isSearching = false`.

Every Main answers every requested scope, `devices` and `skills` included (skills are synchronized between Mains,
[../claude/skills.md](../claude/skills.md)); step 2 removes the duplicates. The search screen shows the location of a
result (device ▸ project) from `deviceID` and `projectID` with the names of the client's mirrors, and highlights
`title` and `snippet` with `highlights(in:)` ([../ui/search.md](../ui/search.md)).
