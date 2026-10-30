# Skills screen

files:
- HephaestusKit/Sources/HephUI/Skills/SkillsView.swift
- HephaestusKit/Sources/HephUI/Skills/SkillListView.swift
- HephaestusKit/Sources/HephUI/Skills/NewSkillSheet.swift
- HephaestusKit/Sources/HephUI/Skills/RenameSkillSheet.swift
- HephaestusKit/Sources/HephUI/Skills/SkillDetailView.swift
- HephaestusKit/Sources/HephUI/Skills/SkillFileList.swift
- HephaestusKit/Sources/HephUI/Skills/SkillFileView.swift
- HephaestusKit/Sources/HephUI/Skills/SkillFileDocument.swift
- HephaestusKit/Sources/HephUI/Skills/NewSkillFileSheet.swift

---

The Skills section is a workspace section of the sidebar ([shell.md](shell.md)). It lists, creates, shows and edits
the skills of the library ([../claude/skills.md](../claude/skills.md)). Every Main has a library and the Mains sync
them, so the screen works on the library of the Main selected in the window's path bar; the other Mains receive the
changes through the sync. Projects choose their skills in their Overview ([overview.md](overview.md#skills)).

Requests use the request functions of the selected Main's `MainConnection` (`workspace.connection(mainDeviceID)`,
[../client/workspace.md](../client/workspace.md#request-api)), run through `banners.perform` of the window's
`WindowBanners` (`@Environment(WindowBanners.self)`, [shell.md](shell.md#81-windowbanners)), which shows a failure as an
error banner. Sheets call the functions directly and show a failure's message in red above their buttons; they have the
sheet layout of [sessions.md](sessions.md#options-menu) (`EditSheetLayout`). Failures of the requests the screen makes
by itself (the skill list, a file list, `SKILL.md` in the compact detail, a file read again after `skills.changed`, the
save when a file view goes away) are posted with `appModel.banners.post(Banner(style: .error, message:))`, the router of
the environment's `AppModel` (`@Environment(AppModel.self)`, [shell.md](shell.md#81-windowbanners)); a view gives that
router to the `SkillFileDocument` it creates. The window's selection is the `Selection` of its `WindowContext`
([shell.md](shell.md#52-windowcontext)). While the selected Main is not connected, the screen shows "<Main name> is
offline. Skills are edited on a Main." centered. A request made while `workspace.connection(mainDeviceID)` is nil fails
with `ProtocolError(.unavailable, "<Main name> is offline.")`. <Main name>, here and below, is the name of the Main's
connection, else the name of its record in `workspace.mesh`, else "Main".

## Layout

| Width class     | Layout                                                                                 |
|-----------------|----------------------------------------------------------------------------------------|
| regular, macOS  | `HSplitView`: skill list (min 220, ideal 260, max 360 pt), skill detail                |
| regular, iPadOS | `HStack(spacing: 0)`: skill list (280 pt), `Divider`, skill detail                     |
| compact         | `NavigationStack` rooted at the skill list; its path follows `selection.item` (below)  |

While the Skills section is shown, `selection.item` is `<skill name>`, or `<skill name>/<file path>` to select a file
of the skill (skill names have no `/`). Search results of kind `skills` give the result's `itemID` (the skill name),
followed by `/<path>` when the result's `path` is set and is not `SKILL.md` ([search.md](search.md#opening-a-result)).

In compact width the stack's path follows `selection.item`: `<name>` gives [detail]; `<name>/<path>` gives [detail,
file view]. Back from the file view sets `selection.item` to `<name>`; Back from the detail sets it to nil. An item set
from elsewhere, or already set when the section appears, pushes its levels at once.

## Skill list

- Source: `listSkills()` of the selected Main, requested when the screen appears and after each
  `WorkspaceEvent.connected(mainDeviceID:)` of that Main, and replaced by the `skills` of each `skills.changed` event
  from that Main (the screen iterates `workspace.events()` while it is shown). `SkillSummary {name, description,
  modified}`. Until the first answer from that Main, the list shows a `ProgressView`.
- Above the list: the caption "Library on <Main name>", a search field (placeholder "Filter") and a `plus` button that
  opens the New Skill sheet.
- Filter: the query is split on whitespace; every word must occur, case- and diacritic-insensitive, in the name or the
  description.
- Rows: name (headline), description (secondary, up to 2 lines), in the order of the list (by name).
- Context menu: Rename…, Delete….
- Empty library: "No skills yet" and a "New Skill…" button. No match: "No matching skills". Regular width with no
  skill selected: the detail area shows "Select a skill".
- When the selected skill leaves the list (deleted or renamed elsewhere), the selection is cleared; a rename made from
  this screen moves it to the new name instead ([Rename the skill](#rename-the-skill)).

## New skill

`NewSkillSheet` creates a skill from a name and a description; the Main writes `SKILL.md` from its template.

| Field       | Control                | Rule                                                                        |
|-------------|------------------------|-----------------------------------------------------------------------------|
| Name        | text field, monospaced | `SkillName.isValid` (1–64 characters among `a`–`z`, digits, `-`); unique    |
| Description | text field, 1–4 lines  | required; at most 1,024 characters after trimming                           |

- Letters `A`–`Z` are lowercased as they are typed. Unique: no skill of the list has that name.
- Messages under the name: "Use lowercase letters, digits and hyphens (1 to 64 characters)." (once the name is not
  empty) and "A skill named “<name>” already exists."; when the name is valid: "Claude sees it as
  hephaestus:<name>." (secondary). Under the description, over the limit: "Use at most 1,024 characters."
- Buttons: Cancel (Escape) and Create (⌘↩, default action).
- Create calls `createSkill(name:description:)` with the trimmed description. Success: the sheet dismisses itself, the
  window selects the skill and `SKILL.md` opens in Edit mode; in compact width the selection is `<name>/SKILL.md`,
  which pushes the file view, since the compact detail shows `SKILL.md` only as in Preview. Failure: the message shows;
  the sheet stays open.

## Skill detail

`SkillDetailView` shows one skill.

- Header: the name (`.title2`, semibold), `hephaestus:<name>` (monospaced caption, secondary), the description
  (secondary), and an actions menu (`ellipsis.circle`): Add File ▸ (New File…, Import Files…), Rename…, Delete
  Skill….
- Regular width: `HStack(spacing: 0)` with the file list (220 pt), a `Divider`, and the file view of the selected file
  (default `SKILL.md`).
- Compact width: a `ScrollView` with the header, a "Files" section (one row per file; a row selects the file, which
  pushes its file view), then `SKILL.md` rendered as in Preview.

### File list

- Source: `skillFiles(name:)` (`[SkillFile]`), requested when the detail appears, after each `skills.changed` that
  gives this skill a new `modified`, and after each file added or deleted from this screen.
- Order: `SKILL.md` first, then the other files by path (`localizedStandardCompare`). Rows: the full relative path
  (monospaced) and the size (`ByteCountFormatter`, `.file`, secondary); a dot before the path when the open document of
  that file has unsaved changes.
- Choosing a row selects the file (`selection.item` = `<name>/<path>`).
- Context menu: Delete… (not on `SKILL.md`).

### File view

`SkillFileView` shows the selected file through its `SkillFileDocument`.

- The file is read with `readSkillFile(name:path:)`. Data that decodes as UTF-8 is text; any other data shows "Binary
  file — <size>" and cannot be edited.
- Markdown files (extension `.md`): a segmented control Preview | Edit above the content; Preview by default.
  Preview renders the document's current text (unsaved edits included) with the HephMarkdown view
  ([markdown.md](markdown.md)). For `SKILL.md` the YAML front matter (from a first line `---` to the next line `---`)
  is not rendered. Relative links and images are not resolved; http(s) links open in the system browser (`openURL`).
- `SKILL.md`: when `SkillFrontMatter.problem(in:skillName:)` of the document's text is not nil, a warning shows above
  the content: the problem, then "Sessions do not get this skill until it is fixed."
  ([../claude/skills.md](../claude/skills.md)).
- Edit mode, and every other text file: `CodeEditorView(text:language:)` of HephEditor ([editor.md](editor.md)) with
  `EditorLanguage(fileName:)` of the file's path.
- Save: ⌘S, and autosave 1.5 s after the last edit when the `autosave` setting is on (`SettingsStore.settings`,
  [../data/app-storage.md](../data/app-storage.md)). While a text file is shown, `SkillFileView` publishes
  `saveDocumentAction` ([code.md](code.md#swift-api)) with `.focusedSceneValue`; File ▸ Save (⌘S) calls it
  ([shell.md](shell.md#113-focused-values)).

`SkillFileDocument` holds the text of one file:

- Load: `readSkillFile(name:path:)`; the document holds the text and is not modified.
- Edit: the document is modified; when autosave is on, the 1.5 s delay restarts. An edit cancels only that delay: a
  save the autosave has started runs to its end.
- ⌘S or autosave: `writeSkillFile(name:path:data:)` with the UTF-8 text. Success: not modified, unless the text
  changed during the request. Failure: the error banner (⌘S: the window's `WindowBanners`; autosave: the router the
  view gave, `appModel.banners`, [shell.md](shell.md#81-windowbanners)); still modified.
- `skills.changed` gives this skill a new `modified`: the file is read again. Equal to the text, or to the text this
  device last read or wrote (this device's own save): nothing. Document not modified: the text is replaced. Document
  modified: a banner "Changed on the Main" with Reload (takes the Main's text) and Keep Mine (closes the banner; the
  next save overwrites).
- A read answering `notFound`: "This file was deleted." above the content; editing is disabled.
- The view goes away while the document is modified: it saves first. From the moment this screen starts deleting its
  file or its skill, the document is discarded: nothing saves it any more, neither its view going away nor ⌘S nor
  autosave ([Delete a file](#delete-a-file), [Delete the skill](#delete-the-skill)). When that deletion fails, it is no
  longer discarded, and it saves at once when its view went away meanwhile.

### Add a file

- New File…: `NewSkillFileSheet` with a Path field (monospaced, placeholder `references/notes.md`). Rule: a relative
  `/`-separated path, no leading `/`, no empty, `.` or `..` component, not the path of an existing file of the skill.
  Buttons: Cancel (Escape) and Create (⌘↩, default action). Create calls `writeSkillFile(name:path:data:)` with empty
  data; success: the list is refreshed and the file selected (`.md` files open in Edit mode).
- Import Files…: `.fileImporter` with `[.item]` and multiple selection. Each file is added at the skill's root under
  its own name with `writeSkillFile(name:path:data:)`. A file whose name is already a file of the skill is skipped and
  the error banner shows "<file name> already exists in the skill."; a file over `MethodLimits.maxFileSize` (10 MiB) is
  skipped and the error banner shows "<file name> is larger than 10 MiB.". The list is refreshed at the end.

### Delete a file

Confirmation "Delete <path>?" with the message "This cannot be undone." and the buttons Delete (destructive) and
Cancel. Delete calls `deleteSkillFile(name:path:)`, then refreshes the list; when the file was selected, `SKILL.md`
becomes selected. The open document of that file is discarded without saving ([File view](#file-view)).

### Rename the skill

`RenameSkillSheet`: a Name field prefilled with the current name, the rules of New Skill (unique among the other
skills, different from the current name). Buttons Cancel (Escape) and Rename (⌘↩, default action). Rename first saves
each open document of the skill that has unsaved changes, as ⌘S does; when a save fails, its message shows in the
sheet and the skill is not renamed. Then it calls `renameSkill(name:to:)`; the Main also rewrites `name` in
`SKILL.md`. Success: the window selects the new name, also after a rename from the context menu of a skill that was
not selected; when the renamed skill was selected, the same file stays selected, and the selection is not cleared in
between, also when the rename's `skills.changed` arrives before its answer. Failure: the message shows.

### Delete the skill

Confirmation "Delete the skill “<name>”?" with the message "It is deleted from the library of every Main. This cannot
be undone." and the buttons Delete (destructive) and Cancel. Delete calls `deleteSkill(name:)`; the open documents of
that skill are discarded without saving ([File view](#file-view)), and the selection is cleared when it was that
skill.

## Swift API

```swift
/// The Skills section for the library of the Main `mainDeviceID` (the Main selected in the window's path bar).
/// @MainActor; reads the AppModel, the Workspace, the SettingsStore, the window's WindowContext and its WindowBanners
/// from the environment.
public struct SkillsView: View {
    public init(mainDeviceID: UUID)
}
```

`SkillsView` ends its file with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

- [../client/workspace.md](../client/workspace.md): `Workspace` (`connection(_:)`, `events()`, `WorkspaceEvent`),
  `MainConnection` request functions, `Selection`.
- [../protocol/types.md](../protocol/types.md): `SkillSummary`, `SkillFile`.
  [../protocol/methods.md](../protocol/methods.md): `skills.*`, `MethodLimits`.
  [../protocol/events.md](../protocol/events.md): `skills.changed`.
- [../claude/skills.md](../claude/skills.md): `SkillName`, `SkillFrontMatter`, the template, sync between Mains.
- [../data/app-storage.md](../data/app-storage.md): `SettingsStore`, `autosave`.
- [markdown.md](markdown.md): HephMarkdown view. [editor.md](editor.md): code editor view and language detection.
  [code.md](code.md): `saveDocumentAction`.
- [shell.md](shell.md): `WindowContext`, `WindowBanners` (`perform`), `AppModel.banners`, workspace sections, File ▸
  Save.
