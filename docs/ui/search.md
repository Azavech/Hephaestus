# Search UI

files:
- HephaestusKit/Sources/HephUI/Search/SearchPalette.swift
- HephaestusKit/Sources/HephUI/Search/SearchScreen.swift
- HephaestusKit/Sources/HephUI/Search/SearchScopeBar.swift
- HephaestusKit/Sources/HephUI/Search/SearchResultsList.swift
- HephaestusKit/Sources/HephUI/Search/SearchResultRow.swift
- HephaestusKit/Sources/HephUI/Search/SearchHighlighting.swift
- HephaestusKit/Sources/HephUI/Search/SearchNavigation.swift

---

Global search covers projects, tickets, comments, docs, code, skills, web tabs, sessions and devices on every connected
Main. The queries, their scheduling (250 ms debounce), the fan-out to the Mains, the merge and the order of the
results are done by `SearchModel` ([../services/search.md](../services/search.md#5-searchmodel-client)); this doc is
the UI on top of it and the navigation to a result.

| Class   | Opened by                                                                           | Presentation                                         |
|---------|-------------------------------------------------------------------------------------|------------------------------------------------------|
| regular | ⌘K (Navigate ▸ Search…), the toolbar Search button ([shell.md](shell.md#9-toolbar)) | `SearchPalette`, a panel over the window             |
| compact | the toolbar Search button                                                           | `SearchScreen`, a sheet with the system search field |

Both call `context.openSearch()` ([shell.md](shell.md#52-windowcontext)). Each presentation creates its own
`SearchModel(workspace:)` when it appears; the query starts empty every time.

## Search palette (regular)

`SearchPalette` is shown by `MainShell` while `context.isSearchPresented` is true, over the whole window
([shell.md](shell.md#61-layout)):

- A backdrop, `Color.black.opacity(0.2)` ignoring the safe area; clicking it closes the palette.
- The panel: width `min(640, window width − 32)`, 72 pt below the top of the window content, centered horizontally;
  background `.regularMaterial` in a rounded rectangle of corner radius 12 with a 1 pt separator-colored border;
  shadow radius 24, y 8. Content, top to bottom:
  1. The field row, padding 12: `magnifyingglass` (secondary), a `TextField("Search", text: $model.text)` with
     `.textFieldStyle(.plain)` and `.font(.title3)`, focused when the palette appears; a small `ProgressView` while
     `model.isSearching`; a clear button (`xmark.circle.fill`, secondary, `.borderless`) while the text is not empty,
     which calls `model.clear()`.
  2. `Divider`, then `SearchScopeBar` with padding 12 × 8, then `Divider`.
  3. The results ([Results](#results)) in a `ScrollView` as high as the results, at most 420 pt, or a state
     ([States](#states)) 120 pt high.
- Closing (Escape, the backdrop, opening a result) sets `context.isSearchPresented = false`. ⌘K while the palette is
  shown changes nothing.

### Keyboard

| Key    | Effect                                                            |
|--------|-------------------------------------------------------------------|
| ↓      | highlights the next result (stays on the last)                    |
| ↑      | highlights the previous result (stays on the first)               |
| ↩      | opens the highlighted result; with no result, `model.searchNow()` |
| Escape | closes the palette                                                |

- The keys are handled on the field with `.onKeyPress(.downArrow)`, `.onKeyPress(.upArrow)` and
  `.onKeyPress(.escape)` returning `.handled`, and `.onSubmit` for ↩; macOS also closes on `.onExitCommand`.
- The highlight is an index in the results in display order ([Results](#results)). It returns to 0 each time
  `model.results` changes. A `ScrollViewReader` keeps the highlighted row visible.
- macOS: hovering a row highlights it. A click (macOS) or a tap (iPad) on a row opens it.

## Search screen (compact)

`SearchScreen` is the content of the `.search` sheet of `MainShell` ([shell.md](shell.md#61-layout)):

- A `NavigationStack` titled "Search" (inline) with a "Close" button (cancellationAction) that dismisses the sheet.
- `.searchable(text: $model.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")`, focused
  when the screen appears (`.searchFocused`); `.onSubmit(of: .search) { model.searchNow() }`.
- `SearchScopeBar` in `.safeAreaInset(edge: .top)` on a `.bar` background, padding 16 × 8.
- The results in a `List` with one `Section` per group, or a state. Tapping a row opens it and dismisses the sheet.
- No keyboard highlight; on an iPhone with a hardware keyboard ↩ calls `searchNow()`.

## Scope bar

`SearchScopeBar(scopes: Binding<Set<SearchScope>>)` is a horizontal `ScrollView` (no indicators) of `ChipToggle`s
([shell.md](shell.md#12-shared-components)), 6 pt apart:

| Chip    | On when              | Tapping                                                                    |
|---------|----------------------|----------------------------------------------------------------------------|
| All     | `scopes` is empty    | `scopes = []`                                                              |
| a scope | `scopes` contains it | inserts or removes it; when `scopes` then holds every scope, `scopes = []` |

The scope chips, in this order, with the titles of the result groups: Projects, Tickets, Comments, Docs, Code, Skills,
Web Tabs, Sessions, Devices. `model.scopes` is the binding: a change makes the model search again
([../services/search.md](../services/search.md#51-scheduling-and-cancellation)).

## Results

`SearchResultsList` groups `model.results` by `kind`. Groups follow `SearchScope.allCases`; inside a group the results
keep the model's order. Display order = groups in that order, then rows in the group's order. A group without results
is hidden.

| `kind`     | Group title | Symbol                                    |
|------------|-------------|-------------------------------------------|
| `projects` | Projects    | `folder`                                  |
| `tickets`  | Tickets     | `checklist`                               |
| `comments` | Comments    | `text.bubble`                             |
| `docs`     | Docs        | `book.closed`                             |
| `code`     | Code        | `chevron.left.forwardslash.chevron.right` |
| `skills`   | Skills      | `wand.and.stars`                          |
| `webTabs`  | Web Tabs    | `globe`                                   |
| `sessions` | Sessions    | `bubble.left.and.bubble.right`            |
| `devices`  | Devices     | `laptopcomputer.and.iphone`               |

Group header: the title and the number of results (secondary), caption, uppercase on iOS by the system style. In the
palette the headers are pinned (`LazyVStack(pinnedViews: [.sectionHeaders])`), full width with padding 8 × 4 on a
`.regularMaterial` background.

### Row

`SearchResultRow` is an `HStack(alignment: .firstTextBaseline, spacing: 10)`, padding 8 × 6: the symbol, then a
`VStack(alignment: .leading, spacing: 2)` of the title, the location and the snippet.

| Part     | Content                                                                                                            |
|----------|--------------------------------------------------------------------------------------------------------------------|
| symbol   | the kind's symbol, secondary, 18 pt wide                                                                           |
| title    | `title`, one line, tail truncation, with the matches highlighted                                                   |
| location | caption, secondary, one line, middle truncation (table below); `devices`: a `PresenceLabel` of that device instead |
| snippet  | `snippet`, caption, one line, tail truncation, with the matches highlighted; omitted when empty                    |

| `kind`                                       | Location                      |
|----------------------------------------------|-------------------------------|
| `projects`, `skills`                         | "<Main>"                      |
| `tickets`, `comments`, `webTabs`, `sessions` | "<Main> ▸ <project>"          |
| `docs`, `code`                               | "<Main> ▸ <project> ▸ <path>" |

- `<Main>`: the name of `deviceID`: `workspace.connection(deviceID)?.name`, else the record name in `workspace.mesh`,
  else "Unknown Main".
- `<project>`: `workspace.summary(of: projectID, on: deviceID)?.name`, else `projectID`.
- `PresenceLabel` of a device result: `workspace.presence[<the UUID of itemID>]` (online, last seen).
- The highlighted row (palette) has a background of the accent color at 20 % opacity in a rounded rectangle of
  corner radius 6.

### Highlighting

`SearchHighlighting.attributed(_ text: String, ranges: [Range<String.Index>]) -> AttributedString` returns the text
with each range bold (`.inlinePresentationIntent = .stronglyEmphasized`) on the accent color at 25 % opacity
(`.backgroundColor`). The ranges are `model.highlights(in: text)`
([../services/search.md](../services/search.md#24-highlights)), computed for the title and for the snippet.

### States

Shown instead of the results, centered, secondary:

| Condition (first that applies)                   | Content                                                                                   |
|--------------------------------------------------|-------------------------------------------------------------------------------------------|
| the trimmed `model.text` is empty                | "Search projects, tickets, comments, docs, code, skills, web tabs, sessions and devices." |
| no connection of the Workspace is connected      | "No Main is online."                                                                      |
| `model.results` is empty and `model.isSearching` | a `ProgressView`                                                                          |
| `model.results` is empty                         | "No results for “<trimmed text>”"                                                         |

Under the results (or the last state), one caption line in orange per entry of `model.failures`:
"<Main> did not answer: <message>", `<Main>` being the name of that Main as in a row's location ([Row](#row)). The
lines are sorted by that name (`localizedStandardCompare`), then by the Main's id (`uuidString`).

## Opening a result

`SearchNavigation.open(_ result: SearchResult, in context: WindowContext)` calls
`context.navigate(mainDeviceID:projectID:section:item:)` ([shell.md](shell.md#52-windowcontext)), then closes the
palette or dismisses the sheet:

| `kind`     | `mainDeviceID` | `projectID` | `section`  | `item`                                                                  |
|------------|----------------|-------------|------------|-------------------------------------------------------------------------|
| `projects` | `deviceID`     | `projectID` | `overview` | nil                                                                     |
| `tickets`  | `deviceID`     | `projectID` | `tickets`  | `ticketID`                                                              |
| `comments` | `deviceID`     | `projectID` | `tickets`  | `ticketID`                                                              |
| `docs`     | `deviceID`     | `projectID` | `docs`     | `path`, followed by `#L<line>` when `line` is set                       |
| `code`     | `deviceID`     | `projectID` | `code`     | `path`, followed by `#L<line>` when `line` is set                       |
| `skills`   | `deviceID`     | unchanged   | `skills`   | `itemID`, or `<itemID>/<path>` when `path` is set and is not `SKILL.md` |
| `webTabs`  | `deviceID`     | `projectID` | `web`      | `itemID` (the tab id)                                                   |
| `sessions` | `deviceID`     | `projectID` | `claude`   | `itemID` (the session id)                                               |
| `devices`  | unchanged      | unchanged   | `devices`  | `itemID` (the device id)                                                |

"Unchanged" passes nil to `navigate`; when the Main changes, `navigate` sets the project to the given value, so a
`skills` result from another Main clears the project. The section's screen opens the item
([shell.md](shell.md#4-sections)); in compact width `navigate` pushes it. Fields are those of `SearchResult`
([../protocol/types.md](../protocol/types.md#searchresult)): `deviceID` is the Main that answered, for `devices` too;
`itemID` identifies the item within its kind (UUIDs as `uuidString`).

## Swift API

```swift
// HephUI/Search — @MainActor; read the Workspace and the WindowContext from the environment.
public struct SearchPalette: View { public init() }          // regular, shown by MainShell
public struct SearchScreen: View { public init() }           // compact, the .search sheet of MainShell

struct SearchScopeBar: View { init(scopes: Binding<Set<SearchScope>>) }
struct SearchResultsList: View { init(model: SearchModel, highlighted: Binding<Int>?, onOpen: @escaping (SearchResult) -> Void) }
struct SearchResultRow: View { init(result: SearchResult, model: SearchModel, isHighlighted: Bool) }

enum SearchHighlighting {
    static func attributed(_ text: String, ranges: [Range<String.Index>]) -> AttributedString
}

enum SearchNavigation {
    /// The arguments of WindowContext.navigate for a result (table above).
    static func target(for result: SearchResult) -> (mainDeviceID: UUID?, projectID: String?,
                                                      section: SidebarSection, item: String?)
    static func open(_ result: SearchResult, in context: WindowContext)
}
```

`SearchScreen` builds on every platform, since `MainShell` refers to it for its `.search` sheet; on macOS, where no
window is compact, it is never presented and its `.searchable` has no placement.

`SearchPalette` and `SearchScreen` end their files with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

| Name                                                                                                                                                        | Defined in                                       |
|-------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------|
| `SearchModel` (`text`, `scopes`, `results`, `isSearching`, `failures`, `searchNow`, `clear`, `highlights(in:)`)                                             | [../services/search.md](../services/search.md)   |
| `SearchResult`, `SearchScope`                                                                                                                               | [../protocol/types.md](../protocol/types.md)     |
| `Workspace` (`connection(_:)`, `connections`, `mesh`, `presence`, `summary(of:on:)`), `SidebarSection`                                                      | [../client/workspace.md](../client/workspace.md) |
| `WindowContext` (`isSearchPresented`, `sheet`, `navigate`), `MainShell`, `ChipToggle`, `PresenceLabel`, `AppModel.preview()`, `previewWindow(_:selection:)` | [shell.md](shell.md)                             |
