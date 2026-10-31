# Project Overview

files:
- HephaestusKit/Sources/HephUI/Overview/OverviewView.swift
- HephaestusKit/Sources/HephUI/Overview/SubProjectsSection.swift
- HephaestusKit/Sources/HephUI/Overview/OverviewSkillsSection.swift
- HephaestusKit/Sources/HephUI/Overview/OverviewClaudeSection.swift
- HephaestusKit/Sources/HephUI/Overview/ProjectIdentifierField.swift
- HephaestusKit/Sources/HephUI/Overview/NewProjectSheet.swift
- HephaestusKit/Sources/HephUI/Overview/AddExistingFolderSheet.swift
- HephaestusKit/Sources/HephUI/Overview/RemoteFolderBrowser.swift
- HephaestusKit/Sources/HephUI/Overview/MoveProjectSheet.swift
- HephaestusKit/Sources/HephUI/Overview/MigrationProgressSheet.swift
- HephaestusKit/Sources/HephUI/Overview/MigrationProgressPresenter.swift

---

The Overview is the first project section (⌘1). It shows and edits the selected project, lists its sub projects, and
holds the project lifecycle: New Project, New Sub Project, Add Existing Folder, Move to…, Remove. A sub project is a
normal project: everything below applies to it, except Move to… (top-level projects only).

Requests use the request functions of the Main's `MainConnection` (`store.connection`; in the sheets
`workspace.connection(mainDeviceID)`, [../client/workspace.md](../client/workspace.md#request-api)), run through
`banners.perform` of the window's `WindowBanners` (`@Environment(WindowBanners.self)`,
[shell.md](shell.md#81-windowbanners)), which shows a failure as an error banner. Sheets call the functions directly and
show a failure's message in red above their buttons. The window's selection is the `Selection` of its `WindowContext`,
which changes it with `navigate(mainDeviceID:projectID:section:item:)` ([shell.md](shell.md#52-windowcontext)). The
screen observes the `ProjectStore` and the Main's `MainConnection`, which the Workspace keeps current from the events.
While the project's Main is not connected (`isConnected` false) or the project is migrating (`project.migrating`), every
control that sends a request is disabled, and so is every control that opens a sheet or a confirmation dialog whose
button sends one. While the Main has no `MainConnection` (`workspace.connection(_:)` nil), a request fails with
`ProtocolError(.unavailable, "<Main name> is offline.")`, <Main name> being the name of the Main's record in
`workspace.mains`, else "Main".

The name rule, here and in the sheets: not empty after trimming whitespace and line breaks, and no line break; there
is no maximum length ([../data/project-yml.md](../data/project-yml.md#validation-and-normalization)).

## Data

| Shown                                                          | Source                                                                         |
|----------------------------------------------------------------|--------------------------------------------------------------------------------|
| Name, identifier, description, folder, skills, Claude defaults | `store.project` (`Project`)                                                    |
| Main                                                           | the record of `store.mainDeviceID` in `workspace.mains`; `workspace.presence`  |
| Sub projects                                                   | `children` of `workspace.summary(of: store.projectID, on: store.mainDeviceID)` |
| Ticket counts                                                  | `store.tickets`                                                                |
| Skills library                                                 | `listSkills()` of the project's Main ([Skills](#skills))                       |
| Active sessions (Move to…)                                     | `store.sessions`                                                               |

The shell shows this view once `store.project` is set, and the loading and failed states of the store before
([shell.md](shell.md#63-detail)).

## Layout

A `Form` with `.formStyle(.grouped)` on every platform, with these sections in this order:

1. Project: Name (text field), Identifier (read-only, monospaced, selectable), Description (text field, 1–6 lines).
   The section starts with these texts when they apply, in this order: ".hephaestus/project.yml cannot be read:
   <parseError>" (red) when `project.parseError` is set; "This project is being moved to another Main." when
   `project.migrating` is true.
2. Location: Main (device name, then a `StatusDot` and "last seen <relative time>" when offline), Folder
   (`project.rootPath`, monospaced, selectable, truncated in the middle, the full path in the help tag).
3. Tickets: one cell per status in `TicketStatus.allCases` order, each a `TicketStatusBadge` ([tickets.md](tickets.md))
   and the count; then "Broken" and the count when the project has broken tickets (a `TicketItem` with a `parseError`,
   counted apart from the statuses).
4. Sub Projects: one row per direct sub project, then a "New Sub Project…" button.
5. Skills: an "All skills" toggle, then one toggle per skill of the library.
6. Claude: Permission Mode picker, Model field.
7. No header: a "Move to…" button (top-level projects only) and a "Remove Project…" button (destructive role).

While `project.parseError` is set, the Name, Description, Skills and Claude controls, "New Sub Project…" and "Move to…"
are disabled; "Remove Project…" stays enabled.

## Editing the project

| Field       | Commit                                       | Request                                                                        |
|-------------|----------------------------------------------|--------------------------------------------------------------------------------|
| Name        | Return, or the field loses focus             | `updateProject(projectID:patch:)`, `ProjectPatch(name:)`                       |
| Description | the field loses focus                        | `ProjectPatch(description:)`; `""` removes the description                     |
| Skills      | each toggle change                           | `ProjectPatch(skills:)`                                                        |
| Claude      | picker change; Model on Return or focus loss | `ProjectPatch(claude:)` with both values ([Claude defaults](#claude-defaults)) |

- The name is trimmed of whitespace and line breaks. A name that breaks the name rule (empty, or holding a line
  break) is not sent: the field returns to the stored name. Escape (`.onKeyPress(.escape)`, and `.onExitCommand` on
  macOS) returns the field to the stored name.
- The view disappearing counts as the fields losing focus: Name and Description commit.
- A commit whose value equals the stored value sends nothing.
- While a field has focus, incoming changes do not replace its text. When the request fails, the field returns to the
  stored value.

### Sub projects

- Rows: name, identifier (monospaced, secondary), folder relative to this project's `rootPath` (secondary), in the
  order of `children`. No sub projects: the text "No sub projects".
- Choosing a row selects that sub project in the window:
  `context.navigate(mainDeviceID: nil, projectID: <sub project id>, section: .overview, item: nil)`; the path bar adds
  its segment ([shell.md](shell.md#73-sub-project-segments)).
- "New Sub Project…" presents `NewProjectSheet(mainDeviceID: store.mainDeviceID, parentID: store.projectID)`.

### Skills

The library is requested with `listSkills()` when the section appears and after each
`WorkspaceEvent.connected(mainDeviceID:)` of the project's Main; it is replaced by the `skills` of each `skills.changed`
event from that Main (the section iterates `workspace.events()` while it is shown). The request is sent only while the
Main is connected (after a reconnection, its `connected` event sends it); a failure shows the error banner. Until the
first answer, the section shows a small `ProgressView`. `project.skills` empty means every skill of the library is
enabled ([../data/project-yml.md](../data/project-yml.md)).

| State or action                              | Display or request                                                    |
|----------------------------------------------|-----------------------------------------------------------------------|
| the library is empty                         | only the text "The library of <Main> has no skills."                  |
| `project.skills` empty                       | "All skills" on; every skill toggle on and disabled                   |
| "All skills" turned off                      | sends `skills` = the names of every library skill; toggles editable   |
| "All skills" turned on                       | sends `skills = []`                                                   |
| a skill toggle changed                       | sends the list with that name added or removed                        |
| "All skills" off and exactly one skill on    | that skill's toggle is disabled, with the footer below                |

- Footer of the last state: "At least one skill stays enabled. Turn on All skills to enable every skill."
- Skill rows: name, description (secondary, one line), in the order of `listSkills()` (by name).
- Names in `project.skills` that are not in the library are not shown and are kept in every list sent.

### Claude defaults

- Permission Mode: `PermissionModePicker` ([sessions.md](sessions.md#labels)) with the nil choice labeled
  "Main Default", then the five `PermissionMode` values.
- Model: `ClaudeModelField` ([sessions.md](sessions.md#labels)) with the placeholder "Main Default".
- Both values are sent together as `ClaudeDefaults(model:permissionMode:)`, which replaces the whole `claude` block; a
  nil field means the Main's default setting ([../protocol/types.md](../protocol/types.md#claudedefaults)). An empty
  model is sent as nil.

## New Project sheet

`NewProjectSheet(mainDeviceID:parentID:)` creates a project on the Main `mainDeviceID`, the Main selected in the
window's path bar: a top-level project when `parentID` is nil (opened from the path bar's project menu,
[shell.md](shell.md)), a sub project of `parentID` otherwise (opened from the Sub Projects section).

| Field       | Control                                     | Default | Rule                                  |
|-------------|---------------------------------------------|---------|---------------------------------------|
| On          | text                                        | below   | read-only                             |
| Name        | text field                                  | empty   | required; trimmed; no line breaks     |
| Identifier  | `ProjectIdentifierField`                    | empty   | [Identifier field](#identifier-field) |
| Folder name | text field, placeholder: the default folder | empty   | below                                 |
| Location    | text, monospaced                            | below   | read-only                             |
| Description | text field, 1–4 lines                       | empty   | optional                              |

- On: "<Main name>"; for a sub project "Inside <parent name> on <Main name>".
- Name: when the trimmed name holds a line break, the sheet shows "Use a single line." in red under the field.
- Folder name: relative to the projects folder (top-level) or to the parent's root (sub project); it may contain `/`
  to create nested folders; it must not start with `/` and has no empty, `.` or `..` component. Empty: the Main uses
  the default folder, the trimmed name with `/` and `:` replaced by `-`
  ([../protocol/methods.md](../protocol/methods.md#projectscreate)).
- Location: `<base>/<folder name, or the default folder>`. Base: `connection.hostInfo?.projectsFolder` for a top-level
  project (the sheet calls `refreshHostInfo()` when it appears and `hostInfo` is nil); the parent's `rootPath` for a
  sub project. The row is empty while the base is not known.
- Buttons: Cancel (Escape) and Create (default action). Create is enabled when every rule passes, the Main is
  connected and no request is in flight. A folder name that breaks its rule only disables Create; no message shows.
- Create calls `createProject(name:identifier:parentID:folderName:description:)`; `folderName` and `description` are
  passed trimmed, and only when not empty after trimming. While the request runs, the fields are disabled and Create
  shows a `ProgressView`.
- Success: the sheet dismisses itself, then the window selects the new project, top-level or sub project:
  `context.navigate(mainDeviceID: mainDeviceID, projectID: <returned id>, section: .overview, item: nil)`. Failure: the
  message shows in red; the sheet stays open.

### Identifier field

`ProjectIdentifierField(text:isValid:)` (both bindings) is the identifier field of New Project and Add Existing Folder.

- Each change of the text is replaced by `ProjectIdentifier.normalize` of it (trimmed, `a`–`z` uppercased,
  [../data/project-yml.md](../data/project-yml.md)). Other characters stay, so the rule message shows.
- Valid: `ProjectIdentifier.isValid` (2–8 letters `A`–`Z`), and unique: no project or sub project in the trees
  (`MainConnection.projects`) of the connected Mains has that identifier. The Main checks again and answers
  `conflict`.
- Messages under the field, shown when it is not empty, the first matching condition only:

| Condition                              | Message (red unless noted)                                     |
|----------------------------------------|----------------------------------------------------------------|
| a character other than `A`–`Z`         | "Use letters A to Z only."                                     |
| fewer than 2 or more than 8 characters | "Use 2 to 8 letters."                                          |
| used by a project of a connected Main  | "<ID> is already used by “<project name>” on <Main name>."     |
| valid                                  | "Tickets will be numbered <ID>-1, <ID>-2, …" (secondary color) |

## Add Existing Folder

`AddExistingFolderSheet(mainDeviceID:)` registers an existing folder of the Main as a top-level project
(`importProject(path:name:identifier:)`). It is opened from the path bar's project menu ([shell.md](shell.md)).

1. Choose the folder.
   - macOS, and the Main is this Mac (`mainDeviceID == workspace.device.id`): a "Folder" row shows the chosen path (or
     "None") and a "Choose…" button opens an `NSOpenPanel` with `canChooseDirectories = true`, `canChooseFiles =
     false`, `allowsMultipleSelection = false`, `canCreateDirectories = false`, `prompt = "Choose"`, `directoryURL` =
     the Main's `projectsFolder`. The chosen path is `url.standardizedFileURL.path`.
   - Any other case (every iPhone and iPad, a Mac viewing another Main): the sheet embeds a `RemoteFolderBrowser`; the
     chosen path is the browser's current folder.
2. "Add" calls `importProject(path:name: nil, identifier: nil)`.
   - Success: the sheet dismisses itself, then the window selects the returned project:
     `context.navigate(mainDeviceID: mainDeviceID, projectID: <returned id>, section: .overview, item: nil)`.
   - Error `badRequest` (the folder has no `.hephaestus/project.yml`, or it cannot be parsed): the sheet goes to step 3
     and shows the error's message above the fields.
   - Any other error: the message shows in red; the sheet stays on step 1.
3. Name the project. Text: "This folder is not a Hephaestus project yet. Name it to create its
   .hephaestus/project.yml." Fields: Name (default: the folder's last path component; the rule and the message of New
   Project) and Identifier (`ProjectIdentifierField`). "Add" is enabled when both are valid and no request is in
   flight; it calls `importProject(path:name:identifier:)`; success and errors as in step 2, except that a
   `badRequest` shows its message and stays on step 3. "Back" returns to step 1.

### Remote folder browser

`RemoteFolderBrowser(mainDeviceID:path:)` (`path: Binding<String?>`, the current folder) browses the folders of a Main
with `listDirectories(path:)` ([../protocol/methods.md](../protocol/methods.md#hostlistdirectories)).

- When it appears it lists `""` (the Main user's home folder) and keeps the returned `path` as the home path, then
  lists the Main's `projectsFolder`; when that fails, it stays on the home folder.
- Header: an "Up" button (`chevron.up`), disabled at the home path, and the current absolute path (monospaced,
  truncated at the head).
- List: one row per entry (`folder` symbol and name), in the order the Main returns them. Choosing a row lists that
  folder, which becomes the current folder.
- Up lists the current path without its last component.
- While a listing loads: `ProgressView`. A failed listing shows its message and a "Retry" button; the current folder
  does not change.

## Move to…

Moves a top-level project and everything inside its folder, sub projects included, to another Main
([../devices/migration.md](../devices/migration.md)). The "Move to…" button presents `MoveProjectSheet`.

### Move sheet

- Title "Move “<name>” to Another Main".
- Targets: the records of `workspace.mains` other than the project's Main whose `workspace.presence` entry is online,
  in `mains` order; one selectable row each (`PlatformIcon` and name). The chosen row shows a `checkmark` (accent
  color); the first target is chosen until the user chooses another, and again when the chosen one leaves the list.
  None: the text "No other Main is online." and Move disabled.
- Text: "The folder <rootPath> is copied to the projects folder of the chosen Main, verified, then moved to the Trash
  on <source Main>. Sub projects move with it. .build, DerivedData and node_modules folders are not copied."
- Active processes: sessions of `store.sessions` whose status is `starting`, `running`, `waitingPermission` or `idle`.
  When there are any, a warning lists them ("Claude: <session title>") and the Move button reads "Stop and Move".
- Move:
  1. When processes are active: `stopSession` for each listed session, in parallel.
     A failed stop request is logged and the move goes on.
  2. `migrateProject(projectID:to:)`. When processes were stopped in step 1 and the answer is `conflict` (a process is
     still running), the call is repeated every second, at most 15 times; the last error then shows.
  3. Success: the sheet gives the returned migration id to `OverviewView` (its state) and dismisses itself; the
     `onDismiss` of the `.sheet` that presents it then calls `presentMigrationProgress(<migration id>)`, so the
     progress sheet is presented after the move sheet is gone. Failure: the message shows in red; the sheet stays
     open.
- While the move runs (steps 1–2), the Move button shows a `ProgressView`, and Move and the sheet's controls are
  disabled. Cancel is disabled, and the sheet cannot be dismissed (`interactiveDismissDisabled`), while a
  `migrateProject` request is in flight: cancelling it only forgets it, and the Main still starts the move
  ([../protocol/envelope.md](../protocol/envelope.md#rpcpeerswift-hephnet)). During step 1 and between the repeats of
  step 2, Cancel, or the sheet closing, stops the move.

### Progress sheet

`MigrationProgressSheet` shows one migration from the latest `migration.progress` payload of its `migrationID`
(`MigrationProgressPayload`, [../protocol/events.md](../protocol/events.md#migrationprogress)), kept by the window's
presenter.

- Title "Moving “<project name>”", subtitle "<from Main> → <to Main>" (names from `workspace.mains`).
- `<project name>`: the name of the project in the tree of the payload's source Main, else of its destination Main;
  the last name found is kept, as the project leaves one tree and enters the other. Before the first payload: the name
  of the project the window showed when `OverviewView` handed the migration over. While no name is known: the
  project's identifier.
- The subtitle and the bytes line show once a payload has arrived.
- Progress: `ProgressView(value: bytesDone, total: bytesTotal)`, indeterminate while no payload has arrived or
  `bytesTotal` is 0. Under it: "<bytesDone> of <bytesTotal>" formatted with `ByteCountFormatter` (`.file`).
- State line and button, by `state` (`MigrationState`):

| `state`        | Line                                                                   | Button |
|----------------|------------------------------------------------------------------------|--------|
| no payload yet | "Starting…"                                                            | Hide   |
| `preparing`    | "Preparing…"                                                           | Hide   |
| `transferring` | "Copying files…"                                                       | Hide   |
| `committing`   | "Installing on <to Main>…"                                             | Hide   |
| `completed`    | "Moved to <to Main>." (green)                                          | Done   |
| `failed`       | "Move failed: <error>" (red), then "The project stays on <from Main>." | Close  |

There is no cancel: Hide dismisses the sheet and the move continues.

### Presentation in every window

The shell applies `.migrationProgressPresenter()` to the root view of every window ([shell.md](shell.md)). The
presenter iterates `workspace.events()` for the life of the window, keeps the latest `MigrationProgressPayload` per
`migrationID`, and owns the window's progress sheet and its set of hidden migration ids.

- It presents the sheet for migration M when `OverviewView` handed M to it in this window
  (`presentMigrationProgress`), or when a payload of M has a state other than `completed` and `failed`, the window
  shows M's project or one of its sub projects (`selection.mainDeviceID` and `selection.projectID` are set and
  `workspace.projectPath(of: selection.projectID, on: selection.mainDeviceID)?.first` is M's `projectID`), and M is
  not in the hidden set.
- One sheet at a time: the earliest qualifying migration.
- Once presented, the sheet stays until the user closes it, also after M reaches `completed` or `failed`. Hide, Done
  and Close add M to the hidden set.
- The presenter never changes the selection. On `completed`, the Workspace moves every selection that shows the
  project to M's `toDeviceID`, keeping the project, the section and the item (selection rule 2,
  [../client/workspace.md](../client/workspace.md#selection-rules)).

## Remove project

"Remove Project…" opens a confirmation dialog:

- Title: "Remove “<name>”?"
- Message: "The project is removed from Hephaestus. Its folder <rootPath> stays on <Main>, with its tickets and
  sessions, unless you move it to the Trash." When the project has sub projects, "Its sub projects are removed with it."
  is added. The Main stops the project's sessions
  ([../protocol/methods.md](../protocol/methods.md#projectsremove)).
- Buttons: "Remove" → `removeProject(projectID:moveToTrash: false)`; "Remove and Move to Trash" (destructive) →
  `removeProject(projectID:moveToTrash: true)`; "Cancel".

After a successful removal the view does nothing more: the shell handles a selection whose project disappeared
([shell.md](shell.md)).

## Swift API

All views are `@MainActor`. They read the `Workspace`, the window's `WindowContext` and its `WindowBanners` from the
environment.

```swift
/// The Overview section of the project held by `store`.
public struct OverviewView: View {
    public init(store: ProjectStore)
}

/// Creates a project on the Main `mainDeviceID`: top-level when `parentID` is nil, else a sub project of `parentID`.
/// Dismisses itself and selects the new project on success.
public struct NewProjectSheet: View {
    public init(mainDeviceID: UUID, parentID: String? = nil)
}

/// Registers an existing folder of the Main `mainDeviceID` (projects.import).
/// Dismisses itself and selects the project on success.
public struct AddExistingFolderSheet: View {
    public init(mainDeviceID: UUID)
}

extension View {
    /// Applied once to the root view of every window: migration progress sheets.
    public func migrationProgressPresenter() -> some View
}
```

Inside the module, the presenter puts an action `presentMigrationProgress(_ migrationID: UUID)` in the environment;
`OverviewView` calls it when the move sheet has been dismissed after `migrateProject` succeeded.

`OverviewView`, `NewProjectSheet` and `AddExistingFolderSheet` end their files with a `#Preview`
([shell.md](shell.md#54-previews)).

## Depends on

- [../client/workspace.md](../client/workspace.md): `Workspace` (`mains`, `presence`, `device`, `connection(_:)`,
  `summary(of:on:)`, `projectPath(of:on:)`, `events()`, `WorkspaceEvent`, selection rule 2), `MainConnection`
  (`isConnected`, `hostInfo`, `refreshHostInfo()`, `projects`, request functions), `ProjectStore` (`mainDeviceID`,
  `projectID`, `project`, `tickets`, `sessions`, `phase`, `connection`, `reload()`), `Selection`.
- [../protocol/types.md](../protocol/types.md): `Project` (`parseError`, `migrating`), `ProjectSummary`, `ProjectPatch`,
  `ClaudeDefaults`, `DeviceRecord`, `Presence`, `SkillSummary`, `SessionInfo`, `TicketItem`, `TicketStatus`,
  `MigrationState`.
- [../protocol/methods.md](../protocol/methods.md): `projects.*`, `host.listDirectories`, `skills.list`,
  `sessions.stop`. [../protocol/events.md](../protocol/events.md): `migration.progress`,
  `skills.changed`.
- [../data/project-yml.md](../data/project-yml.md): `ProjectIdentifier`.
- [tickets.md](tickets.md): `TicketStatusBadge`. [sessions.md](sessions.md): `PermissionModePicker`, `ClaudeModelField`.
- [shell.md](shell.md): `WindowContext` (`navigate`), `WindowBanners` (`perform`), path bar and its project menu,
  window root, `StatusDot`, `PlatformIcon`.
