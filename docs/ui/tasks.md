# Tasks screen

files:
- HephaestusKit/Sources/HephUI/Tasks/TasksView.swift
- HephaestusKit/Sources/HephUI/Tasks/TaskListView.swift
- HephaestusKit/Sources/HephUI/Tasks/TaskListState.swift
- HephaestusKit/Sources/HephUI/Tasks/TaskRow.swift
- HephaestusKit/Sources/HephUI/Tasks/NewTaskSheet.swift
- HephaestusKit/Sources/HephUI/Tasks/TaskDetailView.swift
- HephaestusKit/Sources/HephUI/Tasks/TaskHeaderView.swift
- HephaestusKit/Sources/HephUI/Tasks/TaskDescriptionView.swift
- HephaestusKit/Sources/HephUI/Tasks/CommentsView.swift
- HephaestusKit/Sources/HephUI/Tasks/CommentView.swift
- HephaestusKit/Sources/HephUI/Tasks/TaskClaudeView.swift
- HephaestusKit/Sources/HephUI/Tasks/NewTaskSessionSheet.swift
- HephaestusKit/Sources/HephUI/Tasks/TaskStatusStyle.swift
- HephaestusKit/Sources/HephUI/Tasks/BundleRow.swift
- HephaestusKit/Sources/HephUI/Tasks/BundleDetailView.swift
- HephaestusKit/Sources/HephUI/Tasks/NewBundleSheet.swift
- HephaestusKit/Sources/HephUI/Tasks/AddBundleTasksSheet.swift

---

The Tasks section (⌘2) lists the tasks and the bundles of the selected project and shows one task, with its fields,
description, comments and Claude sessions, or one bundle ([Bundles](#bundles)). Task data:
[../data/task-yml.md](../data/task-yml.md) and `TaskItem` in [../protocol/types.md](../protocol/types.md#taskitem).

Requests use the request functions of the project's `MainConnection` (`store.connection`,
[../client/workspace.md](../client/workspace.md#request-api)), run through `banners.perform` of the window's
`WindowBanners` (`@Environment(WindowBanners.self)`, [shell.md](shell.md#81-windowbanners)), which shows a failure as an
error banner. Sheets call the functions directly and show a failure's message in red above their buttons. The screen
observes the `ProjectStore` (`tasks`, `bundles`, `sessions`), which the Workspace keeps current from `task.changed`,
`task.removed`, `bundle.changed`, `bundle.removed`, `session.changed` and `session.removed`. The window's selection is
the `Selection` of its `WindowContext` ([shell.md](shell.md#52-windowcontext)). While the project's Main is not
connected, every control that sends a request is disabled, and so is every control that opens a sheet or a confirmation
dialog whose button sends one. While `store.connection` is nil, a request fails with `ProtocolError(.unavailable, "<Main
name> is offline.")`, <Main name> being the name of the Main's record in `workspace.mains`, else "Main".

Task names are trimmed of whitespace and line breaks, must not be empty, and hold no line break; they have no maximum
length ([../data/task-yml.md](../data/task-yml.md#validation-and-normalization)).

## Layout per device class

The width class is the `horizontalSizeClass`: always regular on macOS; compact on iPhone and in narrow iPad
multitasking.

| Width class     | Layout                                                                       |
|-----------------|------------------------------------------------------------------------------|
| regular, macOS  | `HSplitView`: task list (min 260, ideal 320, max 480 pt), task detail        |
| regular, iPadOS | `HStack(spacing: 0)`: task list (320 pt), `Divider`, task detail             |
| compact         | `NavigationStack` rooted at the task list; the detail is pushed (below)      |

While the Tasks section is shown, `selection.item` is the selected task id or bundle id
([../client/workspace.md](../client/workspace.md#selection)); the two never look alike
([../services/bundles.md](../services/bundles.md#bundle-id)). Choosing a row sets it. An id set from elsewhere
(search, a link) selects that task or bundle.

Several tasks can be selected at once (Multi-selection); `selection.item` is then nil.

In compact width the detail is pushed with `navigationDestination(item:)` on a binding over `selection.item`; Back sets
`selection.item` to nil. An item set from elsewhere, or already set when the section appears, pushes its detail at
once; New Task success pushes the new task. In the Select mode (Multi-selection) the binding reads nil, so choosing
rows pushes nothing; New Bundle success ends the Select mode and pushes the new bundle.

## Task list

Above the list: a search field (`magnifyingglass`, placeholder "Filter"), a filter menu button
(`line.3.horizontal.decrease.circle`, filled when a setting differs from its default) and a New Task button (`plus`).
In compact width the New Task button is in the navigation bar.

### Multi-selection

`TaskListState` holds `selectedIDs` (`Set<String>`), the selection of the list:

- Regular width: `List(selection:)` on `selectedIDs`; ⌘-click and ⇧-click add rows, as in any list.
- Compact width: a "Select" button in the navigation bar turns on the Select mode, `EditMode.active`, in which task
  rows show selection circles; "Done" turns it off and empties the selection. A bottom bar then shows "New Bundle" and
  the "Add to Bundle" menu (below), enabled when a task is selected.
- Only tasks can be selected together: when a change adds a bundle id, `selectedIDs` becomes that bundle id alone;
  broken tasks are never added to a selection of several rows.
- One id selected: `selection.item` = that id. Several: `selection.item` = nil and the detail area shows
  "<n> tasks selected", a "New Bundle…" button and the "Add to Bundle" menu. None: `selection.item` = nil. When
  `selection.item` is set from elsewhere, `selectedIDs` becomes that id alone.
- "Add to Bundle" is a `Menu` listing the bundles in `draft` or `done` status (name and id); choosing one calls
  `updateBundle` with `BundlePatch(taskIDs:)`: its tasks, then the selected tasks that are not in it, by task number.
  Without such a bundle the menu holds the disabled item "No bundle to add to".

### Filter and sort

`TaskListState` holds the settings of one window, in the state of its `TasksView`: they are kept while the Tasks
section of the same project is shown, and reset when the window shows another section or selects another project.

| Setting        | Values                                                        | Default  |
|----------------|---------------------------------------------------------------|----------|
| Statuses shown | any subset of the four statuses (menu toggles)                | all four |
| Sort           | Number, Last Updated (menu picker)                            | Number   |
| Text           | the search field                                              | empty    |

- Text: the query is split on whitespace; every word must occur, case- and diacritic-insensitive, in the task's id,
  name or description.
- Number: ascending by the integer after the last `-` of the id (the order of `store.tasks`). Last Updated: `updated`
  descending, ties by number descending.
- Broken tasks (a `TaskItem` with a `parseError`) ignore the status filter; the text filter matches their id and
  parse error.

### Sections

A Bundles section first, then sections in `TaskStatus.allCases` order (To Do, In Progress, Review, Done), then
Broken. The Bundles section lists `store.bundles` by number, filtered by the text only (every word in the bundle's id
or name); its header is `square.stack.3d.up`, "Bundles" and the count; its row is [Bundle row](#bundle-row). A task in a
bundle is also listed in its status section. A broken task is only in the
Broken section. A section with no task after filtering is hidden. Header: `TaskStatusBadge` and the count; the Broken
header is `exclamationmark.triangle`, "Broken" and the count.

### Row

- Line 1: the id (monospaced, caption, secondary); trailing, the indicators.
- Line 2: the name (body, up to 2 lines); for a broken task "Invalid task file" (red).
- Indicators, from the sessions of `store.sessions` whose `taskID` is the task: `hand.raised.fill` (orange) when one
  is `waitingPermission`, else `sparkles` (accent color) when one is `starting` or `running`; then `bubble.left` and
  the comment count when the task has comments.
- Context menu: Status ▸ the four statuses (current checked), calling `updateTask(projectID:taskID:patch:)` with
  `TaskPatch(status:)`; New Bundle from Selection… (the selected tasks, or this task when it is not selected); Add to
  Bundle ▸ (as in Multi-selection, for the same tasks); Copy ID; Delete… ([Delete a task](#delete-a-task)). A broken
  task has only Copy ID and Delete….

### Empty states

| Condition                                    | Content                                                             |
|----------------------------------------------|---------------------------------------------------------------------|
| the project has no task                      | "No tasks yet" and a "New Task" button                              |
| the filter hides every task and every bundle | "No matching tasks" and a "Clear Filter" button (restores defaults) |
| regular width, no task selected              | the detail area shows "Select a task"                               |
| the selected id is not in the store          | the detail area shows "<ID> was deleted."                           |

## New task (⌘N)

`NewTaskSheet` creates a task in the selected project.

| Field       | Control                                               | Default | Rule                              |
|-------------|-------------------------------------------------------|---------|-----------------------------------|
| Name        | text field                                            | empty   | required; trimmed; no line breaks |
| Description | `TextEditor`, monospaced body font, min height 120 pt | empty   | optional; Markdown                |
| Status      | picker, each choice drawn as its `TaskStatusBadge`    | To Do   |                                   |

- Name: when the trimmed name holds a line break, the sheet shows "Use a single line." in red under the field.
- Buttons: Cancel (Escape) and Create (⌘↩, default action), enabled when the name is valid and no request is in flight.
  Create carries the default action; a twin Create button with ⌘↩ sits behind it, invisible (opacity 0) and hidden
  from accessibility, with the same action and the same enabled state.
- Create calls `createTask(projectID:name:description:status:)`; `description` is nil when empty after trimming, else
  the text as typed. Success: the sheet dismisses itself, the window selects the new task (`selection.item`), the
  detail shows the Details segment. Failure: the message shows in red; the sheet stays open.
- Opened by the New Task buttons and by ⌘N: the menu item File ▸ New Task (⌘N) of the shell's commands
  ([shell.md](shell.md)) calls `FocusedValues.newTaskAction`, which `TasksView` publishes with `.focusedSceneValue`
  while it is shown. In other sections, and while the Main is not connected, the value is nil and the menu item is
  disabled.

## Bundles

A bundle groups tasks that Claude works on in parallel ([../services/bundles.md](../services/bundles.md)). The
requests are `createBundle`, `updateBundle`, `deleteBundle`, `startBundle` and `stopBundle` of `store.connection`
([../client/workspace.md](../client/workspace.md#functions)), through `banners.perform` outside the sheets.

### Bundle row

- Line 1: the id (monospaced, caption, secondary); trailing, `sparkles` (accent color) when the coordinator or a task
  session of the bundle is `starting` or `running`, `hand.raised.fill` (orange) when one is `waitingPermission` (both
  can show), then the `BundleStatusBadge`.
- Line 2: the name (body, up to 2 lines).
- Line 3 (caption, secondary): "<d> of <n> done", `d` the tasks of the bundle whose status is `done`.
- Context menu: Work on Bundle (`draft`) or Stop (`running`, `review`); Copy ID; Delete… (`draft`, `done`).

### New bundle sheet

`NewBundleSheet` creates a bundle from the given tasks.

- Title "New Bundle"; a Name field (required, trimmed, one line: "Use a single line." in red as in the New Task
  sheet), then the tasks, in task number order: id (monospaced) and name, each with a remove button (`minus.circle`)
  while more than one remains.
- Buttons: Cancel (Escape) and Create (⌘↩, default action), with the twin ⌘↩ button of the New Task sheet; Create is
  enabled when the name is valid and no request is in flight.
- Create calls `createBundle(projectID:name:taskIDs:)`. Success: the sheet dismisses itself, the Select mode ends,
  `selectedIDs` is emptied and `selection.item` is the new bundle (it reaches the store through `bundle.changed`,
  [../client/workspace.md](../client/workspace.md#conventions)). Failure: the message shows in red; the sheet stays
  open.

### Bundle detail

`BundleDetailView` shows the bundle `selection.item` names.

- Header: the id (monospaced, selectable); the name, a plain text field that commits like the task name (`.title2`
  semibold, `BundlePatch(name:)`); the `BundleStatusBadge`; "Created <date>" · "Updated <relative time>" as for a
  task; the actions menu `ellipsis.circle` with Add Tasks… (`draft`, `done`), Copy ID and Delete Bundle… (`draft`,
  `done`).
- Buttons under the header: "Work on Bundle" (`play.fill`, `.borderedProminent`) in `draft`, calling `startBundle`;
  "Stop" (`stop.fill`) in `running` and `review`, calling `stopBundle`; "Open Coordinator" when `coordinatorSessionID`
  is set, which calls `context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section:
  .claude, item: <coordinatorSessionID uuidString>)`.
- A caption (secondary) by status: `running` "Claude works on the tasks in parallel and reports in the coordinator's
  session."; `review` "The coordinator waits for your agreement in its session."; `done` "The work of this bundle was
  brought in."; none in `draft`.
- Tasks, in the bundle's order. Each row: the id (monospaced), the name (a deleted task: "Deleted task", secondary),
  its `TaskStatusBadge`, and, when its `sessionID` names a session of the store, its `SessionStatusIndicator` and an
  "Open Session" button that navigates to section `.claude` with that session. Choosing a row navigates to section
  `.tasks` with the task id. In `draft` and `done`, rows can be reordered (`onMove`) and have the context menu item
  "Remove from Bundle", disabled while the bundle has one task; both call `updateBundle` with `BundlePatch(taskIDs:)`.
- Delete Bundle…: a confirmation "Delete <ID>?" with the message "Its worktrees are removed, and the branches whose
  work was brought in are deleted. Its tasks and sessions are kept." and the buttons Delete (destructive) and Cancel;
  Delete calls `deleteBundle`; after success `selection.item` is cleared.

### Add tasks sheet

`AddBundleTasksSheet`: title "Add Tasks to <ID>", a search field (the task filter's text rule), then the project's
tasks that are not broken and not in the bundle, by task number, each a row with a checkmark when chosen. Buttons:
Cancel (Escape) and Add (⌘↩, default action, twin ⌘↩ button), enabled when a task is chosen. Add calls `updateBundle`
with `BundlePatch(taskIDs:)`: the bundle's tasks, then the chosen ones by task number. Success dismisses the sheet;
failure shows the message in red.

## Task detail

### Header

- Id: monospaced, selectable.
- Segment: a `Picker` with `.segmented` style, Details and Claude. Regular width: trailing in the header's first row.
  Compact width: the navigation bar's principal item.
- Actions: a menu `ellipsis.circle` with Copy ID and Delete Task….
- Name: a plain text field, `.title2` semibold. It commits on Return or when it loses focus, with
  `updateTask(projectID:taskID:patch:)` and `TaskPatch(name:)`; the name is trimmed; a name that is empty or holds a
  line break is not sent and the field reverts; Escape (`.onKeyPress(.escape)`, and `.onExitCommand` on macOS)
  reverts; the header disappearing commits like a focus loss. While it has focus, incoming changes do not replace its
  text.
- Status: a `Menu` whose label is the `TaskStatusBadge`; its items are the four statuses (current checked) and send
  `TaskPatch(status:)`. The badge shows the chosen status at once and returns to the stored status when the request
  fails.
- Dates: "Created <date>" (abbreviated date, shortened time) · "Updated <relative time>" (refreshed every minute; the
  absolute date in the help tag).

The segment is Details when a task gets selected. It switches to Claude after a session is started from the
[new session sheet](#new-session-sheet). In compact width, the Claude segment hides the header and the navigation title
is the task id; in the Details segment the header scrolls with the content.

### Details segment

A `ScrollView` with the Description section then the Comments section; the comment composer is pinned under it with
`safeAreaInset(edge: .bottom)`.

### Description

- View: a "Description" header with an "Edit" button, then the description rendered by the HephMarkdown view
  ([markdown.md](markdown.md)). Link rules: an http(s) link opens a new web tab in the project
  (`openTab(projectID:url:title: nil, locked: nil)`, through `banners.perform`), then the window shows the returned
  tab `tab` ([web.md](web.md#navigation-and-selection)):

  ```swift
  context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .web, item: tab.id.uuidString)
  ```

  A link with another scheme (for example `mailto:`) opens with the environment's `openURL`. Relative links and
  relative images are not resolved (their text or alt text is shown).
- Empty description: "No description" (secondary) and an "Add Description" button that enters edit mode.
- Edit mode: a `TextEditor` with the Markdown text (monospaced body font, min height 160 pt) and the buttons Cancel and
  Save; ⌘↩ saves and Escape cancels while the editor has keyboard focus ([Keyboard shortcuts](#keyboard-shortcuts)).
  Save sends `TaskPatch(description:)` (an empty text is sent as `""`). Success: view mode. Failure: the error banner;
  edit mode stays.
- When the stored description changes while editing (it differs from the text at the start of the edit), a notice
  shows above the editor: "The description was changed on another device." with a "Use Theirs" button that replaces
  the editor text with the stored description and makes it the new base. Save always sends the editor text.

### Broken task

The detail of a broken task shows the id, "This task file cannot be read.", the parse error (monospaced, selectable),
the file path `.hephaestus/tasks/<ID>.yml` and a "Delete Task…" button. It has no segment, no comments and no composer.

## Comments

### Rendering

A "Comments" header with the count, then `task.comments` (oldest first). Each `TaskComment` shows:

- Author: `sparkles` and "Claude" when the author is "Claude"; otherwise `person.crop.circle` and the author.
- Time: the relative creation time (absolute in the help tag); "· edited" when `edited` is set (the edit date in its
  help tag).
- Body: the HephMarkdown view, with the link rules of the description.
- Attachments, under the body in a wrapping flow. A `TaskAttachment` whose `type` starts with `image/` is an image
  thumbnail of [media.md](media.md), at most 240 × 180 pt, that opens the zoomable image viewer. Any other is an
  attachment chip of [media.md](media.md) (name and size) that opens Quick Look after download. Both download the file
  with `downloadAttachment(projectID:taskID:fileName:size:progress:)` on `store.connection`
  ([../client/workspace.md](../client/workspace.md#transfers)) into the device's attachment cache, show the download
  progress, and show the error with a Retry button when it fails ([media.md](media.md#loading-and-caching)); the
  `cacheKey` is "<projectID>/<taskID>/<file>". Attachments have no size limit.
- Actions: a menu (`ellipsis`; on macOS shown while the pointer is over the comment) and the context menu, both with
  the same items. A comment written from a device has Edit and Delete…. A comment whose `author` is "Claude" (made
  through the MCP tools) has Delete… only: Claude's comments cannot be edited
  ([../protocol/methods.md](../protocol/methods.md#tasksupdatecomment)).

When a comment arrives while the comments are scrolled to the bottom, the view scrolls to show it.

### Editing and deleting

- Edit (comments of devices only): the body is replaced by a `TextEditor` (monospaced body font, min height 80 pt)
  with Cancel and Save; ⌘↩ saves and Escape cancels while the editor has keyboard focus
  ([Keyboard shortcuts](#keyboard-shortcuts)). Save calls `updateComment(projectID:taskID:commentID:body:)`; it is
  disabled when the trimmed text is empty and the comment has no attachment. Attachments cannot be changed; the comment
  keeps its author.
- Delete… (every comment, Claude's included): a confirmation "Delete this comment?" with the message "Its attached
  files are deleted too. This cannot be undone." and the buttons Delete (destructive) and Cancel. Delete calls
  `deleteComment(projectID:taskID:commentID:)`.

### Composer

The comment composer is `MessageComposer` ([sessions.md](sessions.md#message-composer)) with the placeholder "Add a
comment", `mainDeviceID: store.mainDeviceID`, `projectID: store.projectID` and no Stop action. Its attachments come
from the pickers of [media.md](media.md#attachment-picking) (file importer, drag and drop, paste, Photos picker on iOS
and iPadOS), as in every `MessageComposer`: each one uploads at once, with a progress bar and a Cancel button in its
chip, and Send waits until every upload is complete. Send calls `addComment(projectID:taskID:body:attachments:)` with
the trimmed text and `draft.uploads`. Success clears the draft; failure keeps it, with its uploads.

## Delete a task

From the detail's actions menu, the row's context menu and the broken-task detail. Confirmation dialog: title "Delete
<ID>?", message "“<name>” and its attachments are deleted. This cannot be undone." (a broken task: "The file
.hephaestus/tasks/<ID>.yml is deleted. This cannot be undone."), buttons Delete (destructive) and Cancel. Delete calls
`deleteTask(projectID:taskID:)`. The task's sessions are kept. After success, `selection.item` is cleared when it was
this task.

## Claude segment

`TaskClaudeView` shows the Claude sessions of the task: the sessions of `store.sessions` with kind `task` and `taskID`
equal to the task id, in the store's order (by `created`).

- Tab strip (horizontal scroll): one tab per session, with `SessionStatusIndicator(status:)`, the status indicator of
  [sessions.md](sessions.md#labels) (this screen has no copy of it), and the title (one line, at most 200 pt wide).
  The selected tab is highlighted. A trailing `plus` button opens the [new session sheet](#new-session-sheet). Tab
  context menu: the session context menu of [sessions.md](sessions.md#session-context-menu).
- Selected tab: remembered per task while `TasksView` exists; by default the session with the latest `updated`. A
  session started elsewhere (another device, or Claude through `start_task_session`) adds a tab that is not selected.
  When the selected session is removed, the tab on its left is selected, or the first tab.
- Content: `SessionView(store:sessionID:showsTaskLink: false)` ([sessions.md](sessions.md#session-view)).
- No session: "No Claude session for this task yet." and a "New Session…" button.

### New session sheet

`NewTaskSessionSheet` starts a task session.

- Title "New Claude Session for <ID>".
- Mode: five selectable rows (checkmark on the chosen one), each with the mode's `displayName` and a description;
  default Implement.

| `SessionMode` | Description                                                                                                |
|---------------|------------------------------------------------------------------------------------------------------------|
| `implement`   | Implement the task, keep the docs in sync, build and test, comment a summary and set the status to Review. |
| `debug`       | Find the root cause, explain it, and propose or apply a fix after your confirmation.                       |
| `review`      | Review the work done for the task and comment the findings.                                                |
| `plan`        | Write a plan as a comment, without changing code.                                                          |
| `custom`      | Follow your instructions.                                                                                  |

- Custom adds an "Instructions" `TextEditor` (min height 100 pt); it is required (not empty after trimming).
- Buttons: Cancel (Escape) and Start (⌘↩, default action), with the twin ⌘↩ button of the New Task sheet.
- Start calls `startSession(projectID:kind: .task, taskID:mode:title: nil, message:permissionMode: nil, model: nil)`;
  `message` is the trimmed instructions for Custom, nil otherwise. The Main titles the session ("<mode> <task id>"),
  builds the first message and starts Claude at once ([../protocol/methods.md](../protocol/methods.md#sessionsstart),
  [../claude/prompts.md](../claude/prompts.md)).
- Success: the sheet dismisses itself, the new session's tab is selected and the segment switches to Claude. Failure:
  the message shows in red; the sheet stays open.

## Status style

Titles are `TaskStatus.displayName` ([../protocol/types.md](../protocol/types.md#taskstatus)). `TaskStatusStyle`
gives the symbol and the tint, used everywhere a status is drawn (the Tasks screen, the Overview counts).

| `TaskStatus` | Symbol                   | Tint   |
|--------------|--------------------------|--------|
| `todo`       | `circle`                 | gray   |
| `inProgress` | `circle.lefthalf.filled` | blue   |
| `review`     | `eye.circle`             | orange |
| `done`       | `checkmark.circle.fill`  | green  |

`TaskStatusBadge` draws a capsule: symbol and title in the tint color, caption font, the tint at 15 % opacity as
background. `BundleStatusBadge`, in `BundleRow.swift`, draws the same capsule for a `BundleStatus`
([../protocol/types.md](../protocol/types.md#bundlestatus)):

| `BundleStatus` | Symbol                  | Tint   |
|----------------|-------------------------|--------|
| `draft`        | `square.dashed`         | gray   |
| `running`      | `sparkles`              | blue   |
| `review`       | `eye.circle`            | orange |
| `done`         | `checkmark.circle.fill` | green  |

## Keyboard shortcuts

| Shortcut | Where                                                                                      | Action                    |
|----------|--------------------------------------------------------------------------------------------|---------------------------|
| ⌘N       | Tasks section shown                                                                        | open the New Task sheet   |
| ⌘↩       | the comment composer, the focused description or comment editor, the sheets of this screen | send, save, create, start |
| Escape   | the focused description or comment editor, sheets                                          | cancel                    |

- The description editor and a comment editor handle ⌘↩ (Save) and Escape (Cancel) only while their `TextEditor` has
  keyboard focus (`@FocusState`). The `TextEditor` carries `.onKeyPress(.return, phases: .down)`, which saves and
  returns `.handled` when the press's `modifiers` contain `.command` and returns `.ignored` otherwise, and
  `.onKeyPress(.escape)`, which cancels and returns `.handled`. Their Save and Cancel buttons have no
  `.keyboardShortcut`.
- The composer's ⌘↩ is handled by `ComposerTextView` ([sessions.md](sessions.md#message-composer)).
- Only the sheets (New Task, New Session, New Bundle, Add Tasks) put keyboard shortcuts on their buttons.

## Swift API

All views are `@MainActor`. They read the `Workspace`, the window's `WindowContext` and its `WindowBanners` from the
environment.

```swift
/// The Tasks section of the project held by `store`.
public struct TasksView: View {
    public init(store: ProjectStore)
}

/// Capsule with the status symbol and `displayName`.
public struct TaskStatusBadge: View {
    public init(status: TaskStatus)
}

/// The same capsule for a bundle status.
public struct BundleStatusBadge: View {
    public init(status: BundleStatus)
}

public enum TaskStatusStyle {
    public static func symbolName(_ status: TaskStatus) -> String
    public static func tint(_ status: TaskStatus) -> Color
}

/// Published by TasksView with .focusedSceneValue; bound to File ▸ New Task (⌘N) by the shell's commands.
public struct NewTaskActionKey: FocusedValueKey {
    public typealias Value = () -> Void
}

extension FocusedValues {
    public var newTaskAction: (() -> Void)? { get set }
}
```

`TasksView` ends its file with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

- [../client/workspace.md](../client/workspace.md): `MainConnection` request functions, `ProjectStore` (`mainDeviceID`,
  `projectID`, `tasks`, `bundles`, `sessions`, `connection`), `Selection` (`item`).
- [../services/bundles.md](../services/bundles.md): what a bundle does; `BundleItem`, `BundleStatus` and `BundlePatch`
  in [../protocol/types.md](../protocol/types.md).
- [../protocol/types.md](../protocol/types.md): `TaskItem` (with `parseError`), `TaskComment`, `TaskAttachment`,
  `TaskStatus`, `TaskPatch`, `UploadRef`, `SessionInfo`, `SessionMode`, `SessionKind`.
- [../protocol/methods.md](../protocol/methods.md): `tasks.*`, `attachments.read`, `uploads.*`, `tabs.open`,
  `sessions.start`. [../client/workspace.md](../client/workspace.md#transfers): `downloadAttachment`, `upload`.
- [sessions.md](sessions.md): `MessageComposer`, `SessionView`, `SessionStatusIndicator`, session context menu.
- [markdown.md](markdown.md): HephMarkdown view. [media.md](media.md): image thumbnail, zoomable image viewer,
  attachment chip, Quick Look, attachment pickers. [web.md](web.md): the Web section showing a tab.
- [shell.md](shell.md): `WindowContext` (`navigate`), `WindowBanners` (`perform`), File ▸ New Task menu item.
