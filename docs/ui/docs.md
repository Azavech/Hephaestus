# Docs screen

files:
- HephaestusKit/Sources/HephUI/Docs/DocsView.swift
- HephaestusKit/Sources/HephUI/Docs/DocsSectionModel.swift
- HephaestusKit/Sources/HephUI/Docs/DocReaderView.swift
- HephaestusKit/Sources/HephUI/Docs/DocEditorView.swift
- HephaestusKit/Sources/HephUI/Docs/DocLinkRouter.swift

---

The Docs section (⌘4) shows the Markdown files of the project's docs folder as a tree, renders one document, and edits
it with a live preview. It reuses the client models and tree components of [code.md](code.md), the editor of
[editor.md](editor.md) and the renderer of [markdown.md](markdown.md).

Requests, error banners and the offline state follow [code.md](code.md): failed user actions show in the window's
`WindowBanners`, sheets show their errors in red above their buttons, and failures of work nobody clicked are posted to
`AppModel.shared.banners` ([shell.md](shell.md#8-banners)). While the Main is not connected, Create Docs Folder is
disabled too; Back, Forward and links stay enabled, and a document they show fails to load with the request's error.

## Swift API

```swift
/// The Docs section of the project held by `store`. @MainActor; reads the Workspace, the SettingsStore, the window's
/// Selection, WindowContext and WindowBanners from the environment.
public struct DocsView: View {
    public init(store: ProjectStore)
}
```

The section publishes, with `.focusedSceneValue` ([shell.md](shell.md#113-focused-values)):

| Focused value                                       | Published while                         | Action                                                                                            |
|-----------------------------------------------------|-----------------------------------------|---------------------------------------------------------------------------------------------------|
| `saveDocumentAction` ([code.md](code.md#swift-api)) | the shown document's content is `.text` | `save()` of the shown document                                                                    |
| `closeTabAction`                                    | a document is shown                     | leaves it ([Leaving a document](#leaving-a-document)), then `document = nil`, `isEditing = false` |

## Docs folder

- Docs root: `ProjectPath.join(ProjectPath.normalize(project.code), ProjectPath.normalize(project.docs))` with the
  `Project` of `store.project` ([../protocol/types.md](../protocol/types.md)); `docs` for a project with the default
  `code: .` and `docs: docs`.
- The tree is a `FileTreeModel` with filter `.markdown` rooted at the docs root ([code.md](code.md#filetreemodel)):
  folders and `.md`/`.markdown` files; the hidden names are always hidden.
- When `code` or `docs` changes, `tree.setRoot(_:)` with the new docs root.
- The shell shows the view once `store.project` is set, and the store's loading and failed states before
  ([shell.md](shell.md#63-detail)).

### Missing docs folder

When the tree's `rootState` is `missing`, the section shows `EmptyStateView(symbol: "folder.badge.questionmark",
title: "This project has no docs folder.", message: "<docs root>")` ([shell.md](shell.md#13-swift-api)) with a "Create
Docs Folder" button. The button runs, through `banners.perform`, `files.create(<docs root>, isDirectory: true)` then
`tree.loadRoot()`. `files.create` answers `notFound` when a parent folder of the docs root does not exist either.

## Section model

`DocsSectionModel` (internal, `@MainActor @Observable`), one per project identifier for the life of the process
(`DocsSectionModel.shared(store:workspace:)`), shared by every window showing the Docs section of that project. Each
call sets `files.mainDeviceID = store.mainDeviceID`, as in [code.md](code.md#section-model).

| Member                                   | Meaning                                                    |
|------------------------------------------|------------------------------------------------------------|
| `files: ProjectFiles`                    | The project's file access                                  |
| `tree: FileTreeModel`                    | Filter `.markdown`, rooted at the docs root                |
| `document: EditorDocument?`              | The shown document                                         |
| `isEditing: Bool`                        | Edit mode                                                  |
| `backStack: [String]`                    | Paths for Back, most recent last                           |
| `forwardStack: [String]`                 | Paths for Forward, most recent last                        |
| `pendingAnchor: String?`                 | Heading slug to scroll to once the document is rendered    |
| `previewText: String`                    | Source of the live preview                                 |
| `isTreeVisible: Bool`                    | Regular width: the tree pane is shown (default `true`)     |
| `questions: SaveChangesQuestions`        | The questions of [Leaving a document](#leaving-a-document) |
| `follow(_ settingsStore: SettingsStore)` | Applies the setting `autosave` and follows its changes     |

- `document` is an `EditorDocument` of its own, never shared with the Code section; both follow the same rules and see
  each other's saves through `files.changed` ([code.md](code.md#changes-on-the-main)).
- The document's `autosaveEnabled` follows the setting `autosave` through `follow(_:)`, which the view calls when it
  appears, as in [code.md](code.md#section-model); its `onError` and the tree's post their message as in code.md. Its
  `onRemoved` (deleted on the Main while not dirty, or Close of its "Deleted on the Main" banner) sets `document = nil`
  and `isEditing = false`.

## Layout

| Width class     | Layout                                                                                                  |
|-----------------|---------------------------------------------------------------------------------------------------------|
| regular, macOS  | `HSplitView`: tree pane (min 180, ideal 240, max 400 pt), document pane                                 |
| regular, iPadOS | `HStack(spacing: 0)`: tree pane (260 pt), `Divider`, document pane                                      |
| compact         | `NavigationStack` rooted at the tree pane; the document pane is pushed while `isDocumentPushed` is true |

- Tree pane: the header and list of [code.md](code.md#tree-pane); the header shows the docs folder's name and the menus
  of [Tree operations](#tree-operations).
- Document pane toolbar: Back (`chevron.left`) and Forward (`chevron.right`), enabled when their stack is not empty;
  Edit (`pencil`) while reading, Done while editing; Save (`square.and.arrow.down`, editing only, enabled as in
  [code.md](code.md#layout)); Find (`magnifyingglass`, iOS and iPadOS, editing only, `CodeEditorProxy.showFind()`).
  Regular width adds Show Files / Hide Files (`sidebar.left`) as in the Code section.
- Above the content: the document's banner (`DocumentBannerView`, [code.md](code.md#banner)), while reading and while
  editing.

Compact width:

- Tree screen: title = the project name; the tree pane keeps its header.
- `isDocumentPushed` (`Bool`, view state of the window) pushes the document pane with
  `.navigationDestination(isPresented:)`. Choosing a document in the tree, New Document… ([Tree
  operations](#tree-operations)) and an item set from elsewhere ([Navigation and selection](#navigation-and-selection))
  set it to true; the system back button sets it to false and the document stays shown, as in the Code section.
- Pushed document pane: title = the file name, with "●" appended when dirty; Back and Forward in a
  `ToolbarItemGroup(placement: .bottomBar)`; Edit or Done, Save and Find at `.topBarTrailing`; while editing, the
  Edit / Preview picker is the `.principal` item.

| Mode    | Regular width                                                                 | Compact width                                                                                    |
|---------|-------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| reading | the reader fills the pane                                                     | the reader fills the screen                                                                      |
| editing | `HStack(spacing: 0)`: editor, `Divider`, preview; each half of the pane width | a segmented `Picker` "Edit" / "Preview" in the navigation bar's principal position switches them |

No document: "Select a document" (secondary, centered). A document whose content is not `.text` shows the content
placeholders of [code.md](code.md#content) and has no Edit button.

## Showing a document

`show(path:anchor:recordHistory:)`:

1. Same path as the shown document: only the anchor is applied ([Anchors](#anchors)).
2. Otherwise the shown document is left ([Leaving a document](#leaving-a-document)); when that is cancelled, nothing
   happens.
3. With `recordHistory` and a document shown, its path is pushed on `backStack` and `forwardStack` is emptied.
4. A new `EditorDocument(files:path:)` is created and loaded; `isEditing = false`; `pendingAnchor = anchor`;
   `tree.reveal(path)`.

- Choosing a file in the tree: `show(path:anchor: nil, recordHistory: true)`; in compact width
  `isDocumentPushed = true`.
- Back: pops the last path of `backStack`, pushes the shown path on `forwardStack`, shows the popped path without
  recording. Forward: the reverse.
- When the section appears with no document and no selection item, `README.md`, else `index.md` (file names compared
  ignoring case), among the docs root's entries is shown without recording, once the docs root is listed; otherwise
  nothing is shown.

### Leaving a document

| Document state      | Leaving                                                                                                                                                                                               |
|---------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| not dirty           | goes on                                                                                                                                                                                               |
| dirty, autosave on  | `save()`, then waits until no save of the document runs ([code.md](code.md#closing-a-tab)); goes on when the document is clean; when it stays dirty (an error or a conflict) the document stays shown |
| dirty, autosave off | confirmation "Do you want to save the changes to “<name>”?": Save (as with autosave on), Don't Save (goes on), Cancel                                                                                 |

Going on calls the document's `close()`. The questions are held by the section model and shown by every window showing
the section, as in [code.md](code.md#closing-a-tab).

## Reader

`DocReaderView`: `ScrollViewReader { proxy in ScrollView { MarkdownView(…).padding(20).frame(maxWidth: 760,
alignment: .leading) } }`, the column centered horizontally.

| `MarkdownView` parameter | Value                                   |
|--------------------------|-----------------------------------------|
| source                   | `document.text`, unsaved edits included |
| `basePath`               | `ProjectPath.parent(of: document.path)` |
| `imageLoader`            | [Images](#images)                       |
| `linkHandler`            | `DocLinkRouter` ([Links](#links))       |

### Anchors

- When `pendingAnchor` is set and the document's content is `.text`, the reader calls
  `proxy.scrollTo(MarkdownAnchor(slug: pendingAnchor), anchor: .top)` on the next main-actor turn after the content
  first renders, then sets `pendingAnchor = nil`. An unknown slug scrolls nowhere.
- An anchor link inside the shown document scrolls at once, animated.

## Editor

`DocEditorView`:

- Editor: `CodeEditorView(text: Binding(get: { document.text }, set: { document.edit($0) }), language: .markdown,
  selection: $document.selection, proxy:)` ([editor.md](editor.md)).
- Preview: a reader whose source is `previewText`. `previewText` takes `document.text` when edit mode starts, then
  300 ms after the last change of `document.text` (each change restarts the delay).
- Saving follows [code.md](code.md#saving): autosave 1.5 s after the last edit when the setting `autosave` is on, ⌘S
  and the Save button, `files.write` with `baseRevision`, the conflict and "Changed on the Main" banners.
- Done leaves edit mode; when the document is dirty and autosave is on, `save()` starts.

## Links

`DocLinkRouter` is the reader's `linkHandler`; its targets come from `MarkdownLinkTarget.resolve`
([markdown.md](markdown.md#links)). `context` is the window's `WindowContext` ([shell.md](shell.md#52-windowcontext)).

| Target                                                 | Action                                                                                                                                                                                                                                                                                                                                                                                                                                             |
|--------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `.anchor(slug)`                                        | scrolls the reader to `MarkdownAnchor(slug:)`                                                                                                                                                                                                                                                                                                                                                                                                      |
| `.project(path, anchor)`, extension `md` or `markdown` | `show(path:anchor:recordHistory: true)`                                                                                                                                                                                                                                                                                                                                                                                                            |
| `.project(path, _)`, any other path                    | the Code section on that file: `context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .code, item: path)` ([code.md](code.md#navigation-and-selection))                                                                                                                                                                                                                                                          |
| `.external(url)`, scheme `http` or `https`             | through `banners.perform`: `openTab(projectID:url: url.absoluteString, title: nil, locked: nil)` of `store.connection` (while it is nil the action fails with `ProtocolError(.unavailable, "The Main of <projectID> is not available.")`, as in [web.md](web.md)); on success `context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .web, item: tab.id.uuidString)` ([web.md](web.md#navigation-and-selection)) |
| `.external(url)`, any other scheme                     | the environment's `openURL`                                                                                                                                                                                                                                                                                                                                                                                                                        |

## Images

The reader's `imageLoader`:

| Target                                     | Data                                                                     |
|--------------------------------------------|--------------------------------------------------------------------------|
| `.project(path, _)`                        | `files.read(path).data`                                                  |
| `.external(url)`, scheme `http` or `https` | `URLSession.shared.data(from: url)`; a status outside 200–299 throws     |
| anything else                              | throws: the image shows its alt text ([markdown.md](markdown.md#images)) |

## Tree operations

The tree pane uses `FileTreeView`, `FileTreeActions` and `FileNameSheet` of [code.md](code.md#tree-pane), with these
differences:

| Code section                | Docs section                                                                                                                                                                                                                                                                                                                                                                          |
|-----------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| New File…                   | New Document… (sheet "New Document", "Create"): `.md` is appended to the name unless it ends with `.md` or `.markdown` (ignoring case); `tree.createFile(named:in:)`; once the sheet is dismissed, `show(path:anchor: nil, recordHistory: true)`, `isEditing = true` and, in compact width, `isDocumentPushed = true`; nothing when the sheet was cancelled before the creation ended |
| Rename…                     | the same; when the shown document is at or inside the renamed path it gets `moved(to:)`, and the paths of `backStack` and `forwardStack` at or inside it are rebased (`ProjectPath.rebase`)                                                                                                                                                                                           |
| Delete…                     | the same; when the shown document is at or inside the deleted path it is closed without saving: `document = nil`, `isEditing = false`                                                                                                                                                                                                                                                 |
| "…" menu: Show Hidden Files | absent; the "…" menu holds Refresh only                                                                                                                                                                                                                                                                                                                                               |
| choosing a file opens a tab | choosing a document shows it                                                                                                                                                                                                                                                                                                                                                          |

## Navigation and selection

While the Docs section is shown, the window's `Selection.item` is the project-relative path of the shown document
([../client/workspace.md](../client/workspace.md#selection)). An item set from elsewhere may end with `#L<line>` to show
a line: search results of kind `docs` set it ([search.md](search.md#opening-a-result)).

When the view appears, and whenever `selection.item` changes while it is shown:

1. The item is split with `ProjectPath.splitLineSuffix(_:)` ([code.md](code.md#projectfiles)) into `path` and `line`
   (nil without the suffix).
2. When `path` differs from the shown path: `show(path: path, anchor: nil, recordHistory: true)`.
3. With a `line`, once `path` is the shown document (at once when it already is): `isEditing = true` (compact width:
   the Edit segment of the picker), `document.selectLine(line)` ([code.md](code.md#line-selection)), then
   `selection.item = path`. The line opens the editor because the reader has no positions of source lines
   ([markdown.md](markdown.md)).
4. Compact width: when step 2 showed `path` or there is a `line`, `isDocumentPushed = true`.

- Showing a document sets `selection.item` to its path; no document sets it to nil. When leaving the shown document
  is cancelled ([Leaving a document](#leaving-a-document)), `selection.item` goes back to the shown path.

`DocsView` ends its file with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

- [code.md](code.md): `ProjectFiles`, `ProjectPath`, `FileTreeModel`, `EditorDocument`, `FileTreeView`,
  `FileTreeActions`, `FileNameSheet`, `DocumentBannerView`, `saveDocumentAction`, the content placeholders.
- [markdown.md](markdown.md): `MarkdownView`, `MarkdownLinkTarget`, `MarkdownAnchor`. [editor.md](editor.md):
  `CodeEditorView`, `CodeEditorProxy`.
- [../client/workspace.md](../client/workspace.md): `ProjectStore` (`project`, `connection`, `mainDeviceID`,
  `projectID`), `MainConnection` (`openTab`), `Selection`.
- [../protocol/methods.md](../protocol/methods.md): `files.*`, `tabs.open`.
  [../data/app-storage.md](../data/app-storage.md): setting `autosave`.
- [web.md](web.md): selecting a web tab. [shell.md](shell.md): `WindowContext` (`navigate`), `WindowBanners`,
  `AppModel.banners`, `EmptyStateView`, the focused value `closeTabAction`.
