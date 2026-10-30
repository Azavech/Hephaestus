# Code screen

files:
- HephaestusKit/Sources/HephClient/ProjectFiles.swift
- HephaestusKit/Sources/HephClient/FileTreeModel.swift
- HephaestusKit/Sources/HephClient/EditorDocument.swift
- HephaestusKit/Sources/HephUI/Code/CodeView.swift
- HephaestusKit/Sources/HephUI/Code/CodeSectionModel.swift
- HephaestusKit/Sources/HephUI/Code/FileTreeView.swift
- HephaestusKit/Sources/HephUI/Code/FileTreeActions.swift
- HephaestusKit/Sources/HephUI/Code/FileNameSheet.swift
- HephaestusKit/Sources/HephUI/Code/FileIcon.swift
- HephaestusKit/Sources/HephUI/Code/EditorTabStrip.swift
- HephaestusKit/Sources/HephUI/Code/EditorPane.swift
- HephaestusKit/Sources/HephUI/Code/DocumentBannerView.swift
- HephaestusKit/Sources/HephUI/Code/EditorCommands.swift

---

The Code section (⌘3) shows the project's code folder as a file tree and edits its files in tabs. The client
models of this doc (`ProjectFiles`, `FileTreeModel`, `EditorDocument`) are also used by the Docs section
([docs.md](docs.md)). The editor view itself is [editor.md](editor.md).

- Requests use the request functions of the project's `MainConnection`
  ([../client/workspace.md](../client/workspace.md#request-api)) through `ProjectFiles`.
- A failed user action shows in the window's error banner: the `WindowBanners` of the environment, usually through
  `banners.perform` ([shell.md](shell.md#81-windowbanners)); sheets show the error message in red above their buttons
  instead. Failures of work nobody clicked (autosave, a listing after a change) are posted with
  `AppModel.shared.banners.post(Banner(style: .error, message:))`, which shows them in the active window
  ([shell.md](shell.md#82-appbannerrouter)).
- The shell keeps the section shown while the project's Main reconnects, with its offline bar
  ([shell.md](shell.md#63-detail)). While the Main is not connected (`isConnected` false), every control that sends a
  request is disabled: Save, the New File…, New Folder…, Rename… and Delete… items, Refresh, every Retry, and the
  buttons of a document's banner except Close. Choosing a file stays possible: its load fails with the request's error
  (`failed`). Documents are checked and saved again when the Main is back. The section model keeps its state while the
  view is gone (open tabs, unsaved text).

## Swift API

```swift
/// The Code section of the project held by `store`. @MainActor; reads the Workspace, the SettingsStore, the window's
/// Selection and WindowBanners from the environment.
public struct CodeView: View {
    public init(store: ProjectStore)
}

// EditorCommands.swift
extension FocusedValues {
    /// Saves the shown document. Published by the Code and Docs sections and the skill file view while they show a
    /// document that can be saved; File ▸ Save (⌘S) calls it (shell.md).
    public var saveDocumentAction: (() -> Void)? {
        get { self[SaveDocumentActionKey.self] }
        set { self[SaveDocumentActionKey.self] = newValue }
    }
}

private struct SaveDocumentActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
```

The key is written by hand: `@Entry` on a closure value gives the compiler warning "Storing a closure in '@Entry var
saveDocumentAction' may invalidate dependents on every update because closures may not be comparable."

The section publishes, with `.focusedSceneValue` ([shell.md](shell.md#113-focused-values)):

| Focused value        | Published while                          | Action                                                  |
|----------------------|------------------------------------------|---------------------------------------------------------|
| `saveDocumentAction` | the active document's content is `.text` | `save()` of the active document                         |
| `closeTabAction`     | a tab is active                          | closes the active tab ([Closing a tab](#closing-a-tab)) |

The client models are in [Client models](#client-models).

## Data

| Shown                       | Source                                                                                       |
|-----------------------------|----------------------------------------------------------------------------------------------|
| Code folder                 | `store.project.code` (`Project`, [../protocol/types.md](../protocol/types.md))               |
| Folder listings             | `files.list`                                                                                 |
| File contents and revisions | `files.read` (whole reads, up to 10 MiB)                                                     |
| Files larger than 10 MiB    | ranged `files.read` through `ProjectFiles.download` ([media.md](media.md#largefileview))     |
| Changes made anywhere       | `files.changed` ([../protocol/events.md](../protocol/events.md#fileschanged))                |
| Autosave, hidden files      | settings `autosave` and `showHiddenFiles` ([../data/app-storage.md](../data/app-storage.md)) |

- The code folder path is `ProjectPath.normalize(project.code)`: `.` is the project root, `""`.
- The shell shows the view once `store.project` is set, and the store's loading and failed states before
  ([shell.md](shell.md#63-detail)).

## Section model

`CodeSectionModel` (internal, `@MainActor @Observable`) holds the state of the Code section of one project.

- `CodeSectionModel.shared(store:workspace:)` returns the model of `store.projectID`, creating it on first use. Models
  live for the life of the process, so the open tabs survive switching sections, projects and the offline state.
  Every window showing the Code section of that project shares the model: same tree, same tabs, same active file.
- The model is keyed by project identifier only. Each call sets `files.mainDeviceID = store.mainDeviceID`: after the
  project moves to another Main ([../devices/migration.md](../devices/migration.md)) the tabs and their unsaved text
  carry on, and revisions stay valid (the files are copied byte for byte).

| Member                                    | Meaning                                                                                                  |
|-------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `files: ProjectFiles`                     | The project's file access                                                                                |
| `tree: FileTreeModel`                     | Filter `.all`, rooted at the code folder                                                                 |
| `documents: [EditorDocument]`             | The open tabs, in tab order                                                                              |
| `activePath: String?`                     | Path of the active tab                                                                                   |
| `isTreeVisible: Bool`                     | Regular width: the tree pane is shown (default `true`)                                                   |
| `open(_ path: String)`                    | Activates or opens the tab of `path` ([Opening](#opening))                                               |
| `close(_ document: EditorDocument)`       | Closes one tab with the rules of [Closing a tab](#closing-a-tab)                                         |
| `closeOthers(_ document: EditorDocument)` | Closes every other tab, each with the same rules                                                         |
| `follow(_ settingsStore: SettingsStore)`  | Applies the settings and follows their changes (below)                                                   |
| `questions: SaveChangesQuestions`         | The "Do you want to save the changes?" questions waiting for an answer ([Closing a tab](#closing-a-tab)) |

- When `project.code` changes, `tree.setRoot(_:)` with the new path; open tabs stay.
- `tree.showHidden` and every document's `autosaveEnabled` follow the settings `showHiddenFiles` and `autosave` of the
  `SettingsStore`: the view calls `follow(_:)` with the environment's `SettingsStore` when it appears, which applies
  the current settings, then each value of `settingsStore.changes()`. A document opened later takes the current
  `autosave`.
- The `onError` of the tree and of every document posts its message:
  `{ AppModel.shared.banners.post(Banner(style: .error, message: $0)) }`.

## Layout

The width class is the `horizontalSizeClass`: always regular on macOS; compact on iPhone and in narrow iPad
multitasking.

| Width class     | Layout                                                                                        |
|-----------------|-----------------------------------------------------------------------------------------------|
| regular, macOS  | `HSplitView`: tree pane (min 180, ideal 240, max 400 pt), editor area                         |
| regular, iPadOS | `HStack(spacing: 0)`: tree pane (260 pt), `Divider`, editor area                              |
| compact         | `NavigationStack` rooted at the tree pane; choosing a file pushes the editor of that document |

Regular width toolbar (trailing): Show Files / Hide Files (`sidebar.left`, toggles `isTreeVisible`; the tree pane is
removed when hidden), Find (`magnifyingglass`, iPadOS only, calls `CodeEditorProxy.showFind()`), Save
(`square.and.arrow.down`).

Compact width:

- The stack's path is view state of the window (`[String]`, document paths). Back pops it; the document stays open.
- Tree screen: title = the project name; the tree header row is not shown: its "+" and "…" menus are in the toolbar,
  with Open Files (`doc.on.doc`, shown when a tab is open): a menu listing the open documents (checkmark on the active
  one, "●" before dirty ones); choosing one activates it and pushes its editor. The list has no selected row: choosing
  a file, the active one included, pushes its editor.
- Editor screen: title = the file name, with "●" appended when dirty; toolbar: Find (`magnifyingglass`), Save
  (`square.and.arrow.down`) and Open Files, which lists the open documents (choosing one shows it in place) and then
  "Close File".

Save (toolbar button) is enabled when the active document has `content == .text`, is dirty, has no `conflict` banner,
and the Main is connected; it calls `save()`.

Each editor gets its own `CodeEditorProxy` (`@State` of the view showing it), so a Find button acts on the editor of its
own window.

## Tree pane

### Header

One row, 28 pt high on macOS, 36 pt on iOS: the name of the code folder (`ProjectPath.name(of:)`; the project name when
the code folder is the project root), then, trailing:

- "+" menu (`plus`): New File…, New Folder…, acting on the root;
- "…" menu (`ellipsis.circle`): Show Hidden Files, a toggle with a checkmark that runs `settingsStore.update {
  $0.showHiddenFiles.toggle() }` (an error goes to the error banner), and Refresh (`tree.refresh()`).

### FileTreeView

- A `List` of recursive `DisclosureGroup`s whose `isExpanded` binding reads `tree.expanded` and calls
  `tree.setExpanded(_:_:)`; files are plain rows.
- Row: `FileIcon` symbol, then the name (one line, middle truncation). A row whose name is in
  `FileTreeModel.hiddenNames` (visible only with Show Hidden Files) uses the secondary color.
- An expanded folder whose entries are not loaded yet shows one row with a small `ProgressView`.
- The row of `activePath` is the list selection (regular width). Choosing a file calls `open(path)` (compact: and
  pushes its editor). Choosing a folder toggles it: on macOS from the list selection; on iOS and iPadOS the disclosure
  row toggles itself when tapped, and a folder selection is ignored.
- iOS: `.refreshable { await tree.refresh() }`.

| `tree.rootState`  | Shown instead of the list                                                                    |
|-------------------|----------------------------------------------------------------------------------------------|
| `loading`         | centered `ProgressView`                                                                      |
| `missing`         | "The code folder “<code>” was not found on <Main name>." and a Retry button (`loadRoot()`)   |
| `failed(message)` | the message and a Retry button (`loadRoot()`)                                                |
| `loaded`          | the list; an empty root shows "Empty folder" (secondary)                                     |

### FileIcon

`FileIcon.symbolName(forFileName:isDirectory:) -> String`, extensions compared ignoring case:

| Item                                                                             | SF Symbol                                 |
|----------------------------------------------------------------------------------|-------------------------------------------|
| folder                                                                           | `folder` (accent color)                   |
| `swift`                                                                          | `swift`                                   |
| `go`                                                                             | `chevron.left.forwardslash.chevron.right` |
| `md`, `markdown`                                                                 | `doc.richtext`                            |
| `yml`, `yaml`, `json`                                                            | `curlybraces`                             |
| `png`, `jpg`, `jpeg`, `gif`, `heic`, `heif`, `webp`, `tif`, `tiff`, `bmp`, `ico` | `photo`                                   |
| anything else                                                                    | `doc`                                     |

### Context menus

`FileTreeActions` holds the menus and flows below; the Docs tree uses them with the differences listed in
[docs.md](docs.md#tree-operations).

| Target                      | Items                                                           |
|-----------------------------|-----------------------------------------------------------------|
| folder row                  | New File…, New Folder… (inside the folder), Rename…, Delete…    |
| file row                    | New File…, New Folder… (in the file's folder), Rename…, Delete… |
| header "+" menu, empty area | New File…, New Folder… (in the root)                            |

### FileNameSheet

`FileNameSheet(title:actionTitle:initialName:existingNames:onCommit:)`, where `onCommit: (String) async throws -> Void`.
`existingNames` are the names the tree shows in the folder (`children(of:)`), without the item being renamed. A name
that clashes only with an entry the tree does not show (a hidden name, or a file that is not Markdown in the Docs tree)
is refused by the Main with `conflict`, whose message shows in red in the sheet.

- Content: the title (headline), one text field (focused), the validation line, the error line, then Cancel (Escape)
  and the action button (default action), disabled while the name is invalid or the commit runs. Compact width:
  `.presentationDetents([.medium])`.
- The action calls `onCommit(<trimmed name>)` and shows a `ProgressView` while it runs. Success dismisses the sheet. An
  error shows its message in red above the buttons; the sheet stays open. Cancel stays enabled while the commit runs:
  it dismisses the sheet, the request goes on, and an error it ends with is not shown.

| Trimmed name                                                                      | Validation line                           |
|-----------------------------------------------------------------------------------|-------------------------------------------|
| empty                                                                             | none (the button is disabled)             |
| contains `/`                                                                      | "A name can't contain “/”."               |
| `.` or `..`                                                                       | "This name is reserved."                  |
| equal, ignoring case, to one of `existingNames`                                   | "“<name>” already exists in this folder." |

### Flows

| Item        | Sheet title, action                            | On commit                                                                                                                                                                                                              |
|-------------|------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| New File…   | "New File", "Create"                           | `tree.createFile(named:in:)`; once the sheet is dismissed, `open(<new path>)` and, in compact width, its editor is pushed; nothing is opened when the sheet was cancelled before the creation ended                    |
| New Folder… | "New Folder", "Create"                         | `tree.createFolder(named:in:)`                                                                                                                                                                                         |
| Rename…     | "Rename", "Rename"; the current name filled in | nothing when the name is unchanged; else `tree.rename(_:to:)`, then each open document at or inside the old path gets `moved(to:)` with its path rebased onto the new path, and `activePath` is rebased the same way   |

Delete… shows a confirmation dialog titled "Move “<name>” to the Trash on <Main name>?", with the message "Unsaved
changes in open files will be lost." when an open document at or inside the path is dirty, and the buttons Move to
Trash (destructive) and Cancel. Move to Trash runs `tree.delete(_:)` through `banners.perform`; on success the open
documents at or inside the path are closed without saving.

## Editor area

From top to bottom: the tab strip (regular width only), the banner of the active document (when it has one), then the
content of the active document.

### Banner

`DocumentBannerView(document:)`, also used by the Docs section: one row with `exclamationmark.triangle.fill`, the
message and the buttons, on yellow at 20 % opacity.

| `banner`        | Message                                                      | Buttons                                                                                             |
|-----------------|--------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| `conflict`      | "This file changed on the Main. Your changes are not saved." | Reload (`reload()`, discards mine), Overwrite (`overwrite()`)                                       |
| `changedOnMain` | "Changed on the Main"                                        | Reload (`reload()`), Keep Mine (`keepMine()`)                                                       |
| `deletedOnMain` | "Deleted on the Main"                                        | Save (`recreate()`), Close (calls the document's `onRemoved`: the section closes it without saving) |

### Content

| `content`         | Shown                                                                                                                                                                                                                                    |
|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `loading`         | centered `ProgressView`                                                                                                                                                                                                                  |
| `text`            | `CodeEditorView(text: Binding(get: { doc.text }, set: { doc.edit($0) }), language: EditorLanguage(fileName: doc.fileName), selection: $doc.selection, proxy:)` with `.id(doc.id)`                                                        |
| `image(data)`     | `ImageViewer(data: data, fileName: doc.fileName)` ([media.md](media.md))                                                                                                                                                                 |
| `binary(size)`    | centered "Binary file" and, under it, the size (`ByteCountFormatter`, `.file`, secondary)                                                                                                                                                |
| `tooLarge`        | `LargeFileView(fileName: doc.fileName, download: { try await doc.files.download(doc.path, progress: $0) })` ([media.md](media.md#largefileview)): an image is downloaded and shown in the image viewer, another file opens in Quick Look |
| `failed(message)` | centered "Couldn't open “<name>”", the message (secondary) and a Retry button (`load()`)                                                                                                                                                 |

No open tab: "No file open" (secondary, centered); with the tree hidden, also a "Show Files" button.

## Tabs

### EditorTabStrip

- One tab per open document in `documents` order, in a horizontal `ScrollView`; the active tab is scrolled into view
  when it changes. Height 28 pt on macOS, 36 pt on iPadOS; width from 100 to 220 pt.
- Tab: `FileIcon` symbol, the file name (one line, middle truncation) and, when another open document has the same
  name, " — <parent folder name>" in the secondary color (the project name for a top-level file); "●" when dirty; a
  close button (`xmark`), shown on macOS while the pointer is over the tab and always on iPadOS. The active tab has the
  selected background.
- Choosing a tab activates it. Context menu: Close, Close Other Tabs.

### Opening

`open(path)`:

1. An open document with that path becomes active.
2. Otherwise a new `EditorDocument(files:path:)` is inserted after the active tab (at the end when none), made active,
   and loaded (`load()`).

The active document's `selection` brings the cursor back when its tab is shown again (the editor is recreated with
`.id(doc.id)`).

### Closing a tab

- Not dirty: the tab is removed.
- Dirty, autosave on: `save()`, then the close waits until no save of the document runs (a save asked while another
  runs, which `save()` only remembers, has run too); the tab is removed when the document is clean; when it stays dirty
  (an error or a conflict), the tab stays.
- Dirty, autosave off: a confirmation "Do you want to save the changes to “<name>”?" with Save (as above), Don't Save
  (destructive: removed without saving) and Cancel. The questions are held by the section model (`questions`), oldest
  first: every window showing the section shows the oldest one in its dialog, and any of them answers it. Dismissing
  the dialog without a button answers Cancel.
- Removing a tab calls the document's `close()`. When the active tab is removed, the tab on its right becomes active,
  else the one on its left, else none.
- A document deleted on the Main while not dirty asks for its own removal (`onRemoved`): its tab is removed without a
  question.

## Navigation and selection

While the Code section is shown, the window's `Selection.item` is the project-relative path of the active file
([../client/workspace.md](../client/workspace.md#selection)). An item set from elsewhere may end with `#L<line>` to show
a line: search results of kind `code` set it ([search.md](search.md#opening-a-result)).

When the view appears, and whenever `selection.item` changes while it is shown:

1. The item is split with `ProjectPath.splitLineSuffix(_:)` into `path` and `line` (nil without the suffix).
2. When `path` differs from `activePath`: `open(path)`, then `tree.reveal(path)`.
3. With a `line`: the document of `path` gets `selectLine(line)` ([Line selection](#line-selection)), then
   `selection.item = path`.
4. Compact width: when step 2 opened `path` or there is a `line`, the editor of `path` is pushed, unless it is already
   the top of the stack.

- When the view appears with no item, `selection.item` becomes `activePath` (nil when no tab is open).
- When `activePath` changes, `selection.item` is set to it.
- Links from the Docs section ([docs.md](docs.md#links)) arrive through the item too.

## Client models

### ProjectFiles

`HephClient/ProjectFiles.swift` holds `ProjectFiles`, `ProjectFileChange` and `ProjectPath`.

```swift
@MainActor public final class ProjectFiles {
    public let workspace: Workspace
    public let projectID: String
    public var mainDeviceID: UUID                    // the Main hosting the project
    public init(workspace: Workspace, mainDeviceID: UUID, projectID: String)

    public var connection: MainConnection? { get }   // workspace.connection(mainDeviceID)
    public var isConnected: Bool { get }             // connection?.isConnected == true
    public var mainName: String { get }              // connection?.name, else "the Main"

    public func list(_ path: String) async throws -> [FileEntry]
    public func read(_ path: String) async throws -> FilesReadResult
    /// A file of any size, read in ranges into the attachment cache; returns its local URL.
    public func download(_ path: String, progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> URL
    public func write(_ path: String, data: Data, baseRevision: String?) async throws -> String
    public func create(_ path: String, isDirectory: Bool) async throws -> FileEntry
    public func rename(from: String, to: String) async throws
    public func delete(_ path: String) async throws

    /// files.changed events of this project from its Main, and the Main's reconnections.
    public func changes() -> AsyncStream<ProjectFileChange>
}

public enum ProjectFileChange: Sendable, Equatable {
    case paths([String])   // a files.changed event: project-relative paths
    case reconnected       // the Main completed a handshake; what is shown is fetched again
}
```

| Function   | Request function of `MainConnection`                                                                  | Method              |
|------------|-------------------------------------------------------------------------------------------------------|---------------------|
| `list`     | `listFiles(projectID:path:)`                                                                          | `files.list`        |
| `read`     | `readFile(projectID:path:)`                                                                           | `files.read`        |
| `download` | `downloadFile(projectID:path:progress:)` ([../client/workspace.md](../client/workspace.md#transfers)) | ranged `files.read` |
| `write`    | `writeFile(projectID:path:data:baseRevision:)`                                                        | `files.write`       |
| `create`   | `createFile(projectID:path:isDirectory:)`                                                             | `files.create`      |
| `rename`   | `renameFile(projectID:from:to:)`                                                                      | `files.rename`      |
| `delete`   | `deleteFile(projectID:path:)`                                                                         | `files.delete`      |

- Each call goes to `connection`. Without a connection it throws `ProtocolError(.unavailable, "The Main of <projectID>
  is not available.")`. Other errors come from the request function unchanged; callers test `ProtocolError.code`
  (`conflict`, `notFound`, `tooLarge`, `locked`, `unavailable`; [../protocol/envelope.md](../protocol/envelope.md)).
- `changes()` iterates `workspace.events()` in a task owned by the stream (cancelled when the stream terminates). It
  yields `.paths(payload.paths)` for each `.event(mainDeviceID: M, .filesChanged(payload))` with `M == mainDeviceID`
  and `payload.projectID == projectID`, and `.reconnected` for each `.connected(mainDeviceID: M)` with
  `M == mainDeviceID`. `mainDeviceID` is read when each event arrives.

`ProjectPath` (enum of static functions on project-relative paths,
[../protocol/types.md](../protocol/types.md#conventions)):

| Function                                                        | Result                                                                                                                                                    |
|-----------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `normalize(_ path: String) -> String`                           | split at `/`, empty and `.` components removed, joined with `/`: `.`, `./` and `""` give `""`                                                             |
| `join(_ folder: String, _ name: String) -> String`              | both normalized; `name` when `folder` is `""`, `folder` when `name` is `""`, else `folder + "/" + name`                                                   |
| `parent(of path: String) -> String`                             | the path without its last component; `""` for a top-level item                                                                                            |
| `name(of path: String) -> String`                               | the last component                                                                                                                                        |
| `isSameOrInside(_ path: String, _ folder: String) -> Bool`      | `path == folder`, or `folder == ""`, or `path` starts with `folder + "/"`                                                                                 |
| `rebase(_ path: String, from: String, to: String) -> String`    | for a `path` same as or inside `from`: `to` followed by the rest of `path`; else `path`                                                                   |
| `splitLineSuffix(_ item: String) -> (path: String, line: Int?)` | for an `item` ending with `#L` followed by decimal digits only, whose value is an `Int` ≥ 1: the part before that `#L` and the value; else `item` and nil |

### FileTreeModel

```swift
public enum FileTreeFilter: Sendable { case all, markdown }

public enum FileTreeRootState: Equatable, Sendable { case loading, loaded, missing, failed(String) }

@MainActor @Observable
public final class FileTreeModel {
    public static let hiddenNames: Set<String>       // .git .hephaestus .build DerivedData node_modules .DS_Store
    public init(files: ProjectFiles, rootPath: String, filter: FileTreeFilter)
    public let files: ProjectFiles
    public let filter: FileTreeFilter
    public private(set) var rootPath: String
    public private(set) var rootState: FileTreeRootState
    public private(set) var expanded: Set<String>
    public var showHidden: Bool                      // default false
    public var onError: (@MainActor (String) -> Void)?

    public func children(of folderPath: String) -> [FileEntry]?
    public func isLoading(_ folderPath: String) -> Bool
    public func setExpanded(_ folderPath: String, _ isExpanded: Bool)
    public func loadRoot() async
    public func setRoot(_ rootPath: String) async
    public func refresh() async
    public func reveal(_ path: String) async
    public func createFile(named name: String, in folderPath: String) async throws -> FileEntry
    public func createFolder(named name: String, in folderPath: String) async throws -> FileEntry
    public func rename(_ path: String, to newName: String) async throws -> String
    public func delete(_ path: String) async throws
    public func stop()
}
```

- `hiddenNames` are exact names. `files.list` returns every entry, folders first then files, each group sorted with
  `localizedStandardCompare` ([../protocol/methods.md](../protocol/methods.md#fileslist)); the model keeps that order
  and filters.
- The model keeps the raw entries of each loaded folder. `children(of:)` returns nil for a folder not loaded, else its
  entries filtered:
  - `.all`: entries whose name is in `hiddenNames` are left out unless `showHidden`;
  - `.markdown`: names in `hiddenNames` are always left out; files are kept only with the extension `md` or `markdown`
    (ignoring case); folders are all kept.
- Lazy loading: `loadRoot()` lists the root. `setExpanded(path, true)` adds the folder to `expanded` and lists it when
  it is not loaded. `setExpanded(path, false)` removes it from `expanded`; its entries stay loaded. `isLoading` is true
  while a listing of that folder runs.
- `rootState`: `loading` until the first answer for the root; then `loaded`, `missing` (the root listing failed with
  `notFound`) or `failed(message)` (any other error). A failed listing of another folder, whatever started it
  (expanding, `reveal`, a mutation, `refresh()`, a change): with `notFound` the folder is dropped with its descendants
  (from the loaded folders and from `expanded`) and nothing is reported; any other error removes it from `expanded` and
  calls `onError("Could not list <path>: <message>")`.
- `setRoot(_:)`: forgets every loaded folder and `expanded`, then `loadRoot()`.
- `refresh()`: lists the root and every loaded folder again.
- Changes: the model consumes `files.changes()` in a task it owns (ended by `stop()`).
  - `.paths(paths)`: the folders to list again are, for each path inside `rootPath`, its parent and the path itself;
    each of those that is loaded is listed again once.
  - `.reconnected`: `refresh()`.
- `reveal(path)`: expands, and loads when needed, every ancestor folder of `path` below `rootPath`, top down.
- Mutations (`folderPath` is a folder path, `name` a single component); errors are thrown to the caller:
  - `createFile`, `createFolder`: `files.create` of `ProjectPath.join(folderPath, name)`; then `folderPath` is listed
    again and, when it is not the root, expanded.
  - `rename`: `files.rename` to `ProjectPath.join(<parent>, newName)`; the loaded folders at or inside the old path are
    forgotten and the parent is listed again; the expanded folders at or inside the old path are rebased onto the new
    path and listed again, so they show their entries; returns the new path.
  - `delete`: `files.delete` (the Main moves the item to its Trash); the item and its descendants are dropped; the
    parent is listed again.

### EditorDocument

```swift
public enum DocumentContent: Equatable, Sendable {
    case loading
    case text
    case image(Data)
    case binary(size: Int)
    case tooLarge
    case failed(String)
}

public enum DocumentBanner: Equatable, Sendable {
    case conflict                        // a save was refused: the file changed on the Main
    case changedOnMain(revision: String) // the file changed on the Main while this document is modified
    case deletedOnMain                   // the file was deleted on the Main while this document is modified
}

@MainActor @Observable
public final class EditorDocument: Identifiable {
    public nonisolated let id: UUID
    public let files: ProjectFiles
    public private(set) var path: String
    public var fileName: String { get }              // ProjectPath.name(of: path)
    public private(set) var content: DocumentContent
    public private(set) var text: String             // "" unless content is .text
    public var selection: NSRange                    // kept for the editor; starts at {0, 0}
    public private(set) var revision: String?
    public private(set) var isDirty: Bool
    public private(set) var isSaving: Bool
    public private(set) var banner: DocumentBanner?
    public var autosaveEnabled: Bool                 // default true
    public var onRemoved: (@MainActor (EditorDocument) -> Void)?
    public var onError: (@MainActor (String) -> Void)?

    public init(files: ProjectFiles, path: String)
    public func load() async
    public func edit(_ newText: String)
    public func selectLine(_ line: Int)
    public func save() async
    public func reload() async
    public func overwrite() async
    public func keepMine() async
    public func recreate() async
    public func moved(to newPath: String)
    public func close()
}
```

#### Loading

`load()` (also run by `reload()`):

1. `content = .loading`; `files.read(path)`.
2. Error `tooLarge`: `content = .tooLarge`. Any other error: `content = .failed(message)`. Either way the local text is
   gone: `isDirty = false`, `banner = nil`.
3. Success, the data is classified:
   - image: the extension (ignoring case) is one of `png`, `jpg`, `jpeg`, `gif`, `heic`, `heif`, `webp`, `tif`,
     `tiff`, `bmp`, `ico`, and ImageIO can read it (`CGImageSourceCreateWithData` returns a source whose
     `CGImageSourceGetCount` is above 0): `.image(data)`;
   - binary: a `0x00` byte in the first 8,000 bytes, or the data is not valid UTF-8: `.binary(size: size)`;
   - otherwise text: `text` = the data decoded as UTF-8, unchanged (line endings and a byte order mark are kept);
     `.text`.
4. `revision` = the returned revision; `isDirty = false`; `banner = nil`; `selection` is clamped to the new text; then
   a line kept by `selectLine(_:)` ([Line selection](#line-selection)) is applied when the content is `.text`.

#### Line selection

`selectLine(_ line: Int)` (`line` ≥ 1) selects a line of the text, for search results
([Navigation and selection](#navigation-and-selection), [docs.md](docs.md#navigation-and-selection)).

- When `content == .text`: `selection` becomes the range of that line, in UTF-16 offsets. Only `\n` ends a line, as in
  search ([../services/search.md](../services/search.md)) and in the editor's line numbers
  ([editor.md](editor.md#line-index)): line `n` starts after the (`n` − 1)-th `\n` (at 0 for line 1) and ends before
  the next `\n` (before a `\r` just ahead of it), or at the end of the text. A `line` past the last line selects the
  last line.
- While `content == .loading`: the line is kept (a later call replaces it), applied when the load ends with `.text`
  ([Loading](#loading), step 4) and dropped when it ends otherwise.
- Any other content: nothing.

The editor selects the new `selection` and scrolls it into view ([editor.md](editor.md#swift-api)).

#### Editing and autosave

- `edit(_:)` is the setter of the editor binding: it sets `text`, `isDirty = true`, increments the edit counter, and,
  when `autosaveEnabled`, restarts the autosave timer: `save()` 1.5 s after the last edit (a `Task` sleeping 1.5 s,
  cancelled by the next edit). An edit cancels only that wait: a save the timer has started is never cancelled, it
  runs to its end, and an edit made meanwhile is saved by the timer it restarted ([Saving](#saving), step 3).
- `autosaveEnabled` is set by the screens from the setting `autosave`.

#### Saving

`save()` (⌘S, the Save button, autosave, Keep Mine):

1. Does nothing unless `content == .text`, `isDirty`, `banner != .conflict` and `files.isConnected`. While a save
   runs, a new call is remembered and runs once when it ends.
2. `isSaving = true`; `files.write(path, data: <UTF-8 of text>, baseRevision: revision)`.
3. Success: `revision` = the returned revision; `isDirty = false` when no edit happened since step 2 (edit counter),
   otherwise it stays dirty and its autosave timer saves again.
4. Error `conflict`: `banner = .conflict`; autosave does not run while the banner is shown.
5. Any other error: `onError("Could not save <name>: <message>")`; the document stays dirty; the next edit, ⌘S or
   reconnection tries again.

Conflict actions: Reload → `reload()` (discards the local text). Overwrite → `overwrite()`: `files.write` without
`baseRevision`; success sets the new revision and `banner = nil`, and `isDirty = false` when no edit happened during
the write (as in step 3; otherwise it stays dirty); an error goes to `onError`.

#### Changes on the Main

The document consumes `files.changes()` in a task it owns (ended by `close()`). It checks the file again on
`.paths(paths)` when a path equals `path` or is a folder containing it, and on `.reconnected`.

- While `content == .loading`, nothing. While a save runs, the check runs once the save has ended.
- The check is `files.read(path)`:

| Result                      | Document not dirty                                           | Document dirty                                        |
|-----------------------------|--------------------------------------------------------------|-------------------------------------------------------|
| same revision as `revision` | nothing (this includes this device's own saves)              | nothing; on `.reconnected` with autosave on, `save()` |
| another revision            | the new data replaces the content (classified as in Loading) | `banner = .changedOnMain(revision: <new revision>)`   |
| `notFound`                  | `onRemoved(self)`: the screen closes the document            | `banner = .deletedOnMain`                             |
| any other error             | nothing (the next reconnection checks again)                 | nothing                                               |

- The dirty state is read once the new data is classified: an edit made meanwhile (the editor stays live) gives
  `banner = .changedOnMain(revision: <new revision>)`, and the text is kept.
- The editor keeps its selection, clamped, when the text is replaced ([editor.md](editor.md#text-synchronization)).
- Changed on the Main actions: Reload → `reload()`. Keep Mine → `keepMine()`: `revision` = the banner's revision (the
  local text will replace the Main's version), `banner = nil`, then `save()` when `autosaveEnabled`.
- Deleted on the Main actions: Save → `recreate()`: `files.write` without `baseRevision` (it creates the file);
  success sets the revision and `banner = nil`, and `isDirty = false` when no edit happened during the write, as for
  Overwrite; a `notFound` error (the folder is gone too) gives
  `onError("Could not save <name>: its folder no longer exists.")`. Close → the screen closes the document without
  saving.

#### Renames and closing

- `moved(to:)` sets `path` after a rename made from this device (a rename made elsewhere arrives as a deletion of the
  old path). The language of the editor follows the new extension.
- `close()` cancels the autosave timer and the change task. A document is not used after `close()`.

`CodeView` ends its file with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

- [../client/workspace.md](../client/workspace.md): `Workspace` (`connection(_:)`, `events()`), `MainConnection`
  request functions and `downloadFile` with `TransferProgress` ([Transfers](../client/workspace.md#transfers)),
  `ProjectStore` (`project`, `mainDeviceID`, `projectID`), `Selection` (`item`).
- [../protocol/types.md](../protocol/types.md): `Project` (`code`), `FileEntry`.
  [../protocol/methods.md](../protocol/methods.md): `files.*`, `FilesReadResult`.
  [../protocol/events.md](../protocol/events.md): `files.changed`, `ServerEvent.filesChanged`.
  [../protocol/envelope.md](../protocol/envelope.md): `ProtocolError`.
- [../services/search.md](../services/search.md): line numbers of search results.
- [../data/app-storage.md](../data/app-storage.md): `SettingsStore`, settings `autosave` and `showHiddenFiles`.
- [editor.md](editor.md): `CodeEditorView`, `CodeEditorProxy`, `EditorLanguage`. [media.md](media.md): `ImageViewer`,
  `LargeFileView`.
- [shell.md](shell.md): `WindowBanners`, `AppModel.banners`, the focused value `closeTabAction`, File ▸ Save bound to
  `saveDocumentAction`.
