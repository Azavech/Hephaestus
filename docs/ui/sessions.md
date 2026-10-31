# Claude sessions UI

files:
- HephaestusKit/Sources/HephClient/SessionModel.swift
- HephaestusKit/Sources/HephUI/Claude/ClaudeView.swift
- HephaestusKit/Sources/HephUI/Claude/SessionListView.swift
- HephaestusKit/Sources/HephUI/Claude/NewChatView.swift
- HephaestusKit/Sources/HephUI/Claude/SessionView.swift
- HephaestusKit/Sources/HephUI/Claude/SessionHeaderView.swift
- HephaestusKit/Sources/HephUI/Claude/SessionOptionsMenu.swift
- HephaestusKit/Sources/HephUI/Claude/SessionContextMenu.swift
- HephaestusKit/Sources/HephUI/Claude/SessionStatusLine.swift
- HephaestusKit/Sources/HephUI/Claude/TranscriptView.swift
- HephaestusKit/Sources/HephUI/Claude/TranscriptRows.swift
- HephaestusKit/Sources/HephUI/Claude/ToolUseRow.swift
- HephaestusKit/Sources/HephUI/Claude/ToolSummary.swift
- HephaestusKit/Sources/HephUI/Claude/PermissionCard.swift
- HephaestusKit/Sources/HephUI/Claude/PermissionIndicator.swift
- HephaestusKit/Sources/HephUI/Claude/PermissionBanner.swift
- HephaestusKit/Sources/HephUI/Claude/ClaudeLabels.swift
- HephaestusKit/Sources/HephUI/Claude/ClaudeOptionPickers.swift
- HephaestusKit/Sources/HephUI/Claude/MessageComposer.swift
- HephaestusKit/Sources/HephUI/Claude/ComposerTextView.swift
- HephaestusKit/Sources/HephUI/Claude/AttachmentDraft.swift

---

This doc covers every view of a Claude session (project chats, task sessions, Forge sessions), the permission UI, the
message composer shared with task comments, and the client models of sessions: `SessionModel` (one transcript) and
`SessionCenter` (pending permissions across the app). The session process and the events it produces are in
[../claude/cli.md](../claude/cli.md); the events' client rules in [../protocol/events.md](../protocol/events.md).

Requests use the request functions of the project's `MainConnection` (`store.connection`,
[../client/workspace.md](../client/workspace.md#request-api)), run through `banners.perform` of the window's
`WindowBanners` (`@Environment(WindowBanners.self)`, [shell.md](shell.md#81-windowbanners)), which shows a failure as an
error banner, unless stated otherwise. The window's selection is the `Selection` of its `WindowContext`, which changes
it with `navigate(mainDeviceID:projectID:section:item:)` ([shell.md](shell.md#52-windowcontext)). Views reach the
`SessionCenter` through `workspace.sessionCenter`. While `store.connection` is nil, a request fails with
`ProtocolError(.unavailable, "<Main name> is offline.")`, <Main name> being the name of the Main's record in
`workspace.mesh`, else "Main".

## Labels

`ClaudeLabels` holds the titles below; every view uses them. `SessionMode` titles are its `displayName`.

| `SessionStatus`     | Title                  | Indicator                  |
|---------------------|------------------------|----------------------------|
| `idle`              | Idle                   | green dot                  |
| `starting`          | Starting…              | small `ProgressView`       |
| `running`           | Running                | small `ProgressView`       |
| `waitingPermission` | Waiting for permission | `hand.raised.fill`, orange |
| `stopped`           | Stopped                | gray dot                   |
| `failed`            | Failed                 | `xmark.octagon.fill`, red  |

`SessionStatusIndicator(status:)` (internal, in `ClaudeLabels.swift`) draws the indicator: the dots are circles 8 pt
wide, the `ProgressView` has `.controlSize(.small)`, and its accessibility label is the title. The session list and the
session tabs of a task ([tasks.md](tasks.md#claude-segment)) use it.

A session has a live CLI process when its status is `idle`, `starting`, `running` or `waitingPermission`.

| `PermissionMode`    | Title              |
|---------------------|--------------------|
| `manual`            | Manual             |
| `acceptEdits`       | Accept Edits       |
| `auto`              | Auto               |
| `plan`              | Plan               |
| `bypassPermissions` | Bypass Permissions |

| `SessionKind`  | Title        |
|----------------|--------------|
| `project`      | Chat         |
| `task`         | Task         |
| `feedback`     | Feedback     |
| `regeneration` | Regeneration |
| `bundle`       | Bundle       |

Models: the aliases offered are `opus`, `sonnet` and `haiku`; any other model name can be typed; an empty model means
the default.

`PermissionModePicker` is a menu-style `Picker`: when it has a default label, its first choice is nil with that label,
then the five modes in the table order. `ClaudeModelField` is a text field (placeholder given) with a trailing `Menu`
(`chevron.down`) listing `opus`, `sonnet`, `haiku` and "Clear"; choosing an item sets the text and commits; the field
also commits on Return and when it loses focus. Both hide their own label (`.labelsHidden()`): the caller labels them,
for example with `LabeledContent`.

## Claude section

`ClaudeView` is the project section Claude (⌘6). It lists the sessions of the project and shows one.

| Width class     | Layout                                                                    |
|-----------------|---------------------------------------------------------------------------|
| regular, macOS  | `HSplitView`: session list (min 220, ideal 280, max 400 pt), session area |
| regular, iPadOS | `HStack(spacing: 0)`: session list (300 pt), `Divider`, session area      |
| compact         | `NavigationStack` rooted at the session list (below)                      |

macOS: the session list and the session area each extend under the window's toolbar
([shell.md](shell.md#92-toolbar-material-macos)).

While the Claude section is shown, `selection.item` is the selected session id as a UUID string
([../client/workspace.md](../client/workspace.md#selection)). `isNewChatPresented` (view state of `ClaudeView`) is true
while the new chat is shown ([New chat](#new-chat)); it becomes false when `selection.item` becomes non-nil.

In compact width, while `selection.item` names a session, its `SessionView` is pushed: `navigationDestination(item:)`
on a binding that reads `selection.item` as a UUID and writes its `uuidString`; Back writes nil. While
`isNewChatPresented` is true, `NewChatView` is pushed instead (`navigationDestination(isPresented:)`); Back sets it to
false. An item set from elsewhere (search, the Forge feedback flow, a permission's Show), or already set when the
section appears, pushes its session at once.

### Session list

Sessions come from `store.sessions`, in groups; a group without sessions is hidden; inside a group, by `updated`
descending.

| Group   | Sessions                           | Row line 2 (caption, secondary)                          |
|---------|------------------------------------|----------------------------------------------------------|
| Chats   | kind `project`                     | relative `updated`                                       |
| Tasks   | kind `task`                        | "<task id> · <mode> · <relative updated>"                |
| Bundles | kind `bundle`                      | "<bundle id> · <relative updated>"                       |
| Forge   | kind `feedback` and `regeneration` | "<kind title> · <task id when set> · <relative updated>" |

- Row line 1: the title (one line) and, trailing, the status indicator.
- Context menu: the [session context menu](#session-context-menu).
- A "New Chat" button (`square.and.pencil`) sits in the list header (regular) or the navigation bar (compact).
- No session: "No sessions yet" and a "New Chat" button. Regular width with nothing selected: the session area shows
  "Select a session or start a new chat."

### New chat

"New Chat" clears `selection.item` and sets `isNewChatPresented`: the session area shows `NewChatView` (compact: it
is pushed).

- Header "New Chat" and an options menu with only Permission Mode (first choice "Project Default") and Model (first
  choice "Project Default", then the aliases, then "Other…"). Both start at Project Default, which passes nil.
- Body: "Chat with Claude about <project name>. Claude can plan, create and update tasks, edit code and more."
  (secondary, centered).
- A `MessageComposer` (placeholder "Message Claude", the project's Main and identifier), focused when the view
  appears.
- Send: `startSession(projectID:kind: .project, taskID: nil, mode: nil, title: nil, message: <trimmed text, nil when
  empty>, attachments: draft.uploads, permissionMode:model:)`; the Main titles the session ("Chat <n>"), stores the
  attachments and starts Claude with the message and its files
  ([../protocol/methods.md](../protocol/methods.md#sessionsstart)). Once the first message with text is sent, the
  Main replaces "Chat <n>" with a short title generated from it; the list and the header show it when its
  `session.changed` arrives, while Claude answers or later. Claude also renames the session when the user asks it to
  (`rename_session`).
- Success: the draft is cleared, `isNewChatPresented` becomes false, then `selection.item` becomes the new session's
  id (the Workspace has inserted the returned `SessionInfo` into the store). A failure leaves nothing created and keeps
  the draft, with its uploads, for the next Send.

### Session context menu

`SessionContextMenu(store:session:)` (internal) is the context menu of the rows of the session list and of the session
tabs of a task ([tasks.md](tasks.md#claude-segment)). It is a `ViewModifier`, so the sheets and the confirmation it
presents stay attached to the row or the tab: it is applied with `.sessionContextMenu(store:session:)`, an extension of
`View`, or `.modifier(SessionContextMenu(store:session:))`. A row or a tab has no `SessionModel`, so its items call the
request functions of `store.connection` directly, through `banners.perform`:

| Item                                                                 | Shown            | Request                                                                                    |
|----------------------------------------------------------------------|------------------|--------------------------------------------------------------------------------------------|
| Rename…                                                              | always           | the rename sheet, then `updateSession(projectID:sessionID:patch:)`, `SessionPatch(title:)` |
| Stop Process                                                         | live CLI process | `stopSession(projectID:sessionID:)`                                                        |
| Delete Session…                                                      | always           | the delete confirmation, then `deleteSession(projectID:sessionID:)`                        |
| Permission Mode ▸ the five modes, current checked                    | always           | `updateSession` with `SessionPatch(permissionMode:)`                                       |
| Allow All Tools (checked when `allowsAllTools` is true)              | always           | `updateSession` with `SessionPatch(allowsAllTools:)`, the opposite of the current value    |
| Model ▸ Default, `opus`, `sonnet`, `haiku` (current checked), Other… | always           | `updateSession` with `SessionPatch(model:)`; Default sends `""`                            |

The rename sheet, the Other… model sheet and the delete confirmation are those of the [options menu](#options-menu).
While the project's Main is not connected, every item is disabled: each sends a request or opens a sheet or a
confirmation dialog whose button sends one ([shell.md](shell.md#63-detail)).

## Session view

`SessionView(store:sessionID:showsTaskLink:)` shows one session: header, transcript, status line and composer, top to
bottom. The Claude section, the Claude segment of a task ([tasks.md](tasks.md#claude-segment)) and every session shown
through the selection (the Forge feedback flow, [../forge/feedback.md](../forge/feedback.md)) use it. Each view creates
its own `SessionModel` when it appears, calls `appear()` in `onAppear` and `disappear()` in `onDisappear`.

- While `model.info` is nil and the store is not loaded, the header shows "Loading…" and the composer is disabled.
- When `model.isRemoved` is true, the view shows only "This session was deleted." (secondary, centered).

### Header

- Title: the session title (headline, one line).
- Context (secondary): task session "<task id> · <mode>", followed by " · <bundle id>" for a task session of a bundle;
  feedback "Feedback · <task id>"; regeneration "Regeneration"; bundle "Bundle · <bundle id>". With `showsTaskLink` and
  a task id, the task id is a link that calls `context.navigate(mainDeviceID: store.mainDeviceID, projectID:
  store.projectID, section: .tasks, item: <task id>)`.
- Capsules: the permission mode title; the model, or "Default model" when nil; "All Tools Allowed" when
  `allowsAllTools` is true.
- Options: `SessionOptionsMenu` (button `ellipsis.circle`).

macOS: the header is in `.safeAreaInset(edge: .top, spacing: 0)` of the transcript's `ScrollView`, with a `.bar`
background and a `Divider` at its bottom. It stays pinned below the window's toolbar, and only the transcript scrolls
under it and under the toolbar ([shell.md](shell.md#92-toolbar-material-macos)). The states of the
[transcript](#transcript) without items keep the header pinned the same way. iPadOS and iOS keep the header above the
transcript.

### Options menu

| Item                                                                 | Enabled          | Action                                                       |
|----------------------------------------------------------------------|------------------|--------------------------------------------------------------|
| Permission Mode ▸ the five modes, current checked                    | open session     | `update(permissionMode:)`                                    |
| Allow All Tools (checked when `allowsAllTools` is true)              | open session     | `update(allowsAllTools:)`, the opposite of the current value |
| Model ▸ Default, `opus`, `sonnet`, `haiku` (current checked), Other… | open session     | `update(model:)`; Default sends `""`                         |
| Rename…                                                              | always           | rename sheet, then `update(title:)`                          |
| Stop Process                                                         | live CLI process | `stop()`                                                     |
| Delete Session…                                                      | always           | confirmation, then `delete()`                                |

- While the project's Main is not connected, every item is disabled, as in the
  [session context menu](#session-context-menu).
- "Open session": `closed` is nil. In a closed session, which never starts Claude again, Permission Mode, Allow All
  Tools and Model are disabled, and so are those of the session context menu.
- Model ▸ Other… opens a sheet with a model text field (trimmed, required), Cancel and Set.
- The rename sheet has a Title field prefilled with the title, Cancel and Save (disabled when the trimmed title is
  empty or holds a line break; a title has no maximum length).
- Both sheets close on Set or Save; the request then runs through `banners.perform`, so a failure shows in the
  window's error banner.
- The sheets of this doc and [skills.md](skills.md) share one layout, `EditSheetLayout` (internal,
  in `SessionOptionsMenu.swift`): the fields in a `Form`, the sheet's error message in red under them, then, trailing,
  Cancel (Escape) and the confirm button (default action); ⌘↩ is a twin confirm button behind it, invisible (opacity
  0) and hidden from accessibility, with the same action and enabled state; 20 pt padding; at least 420 pt wide on
  macOS.
- The menu ends with the disabled text "Mode and model changes apply when Claude next starts."
- Delete confirmation: title "Delete “<title>”?", message "Its transcript and the files attached to its messages are
  deleted. This cannot be undone.", buttons Delete (destructive) and Cancel. After success, a window whose
  `selection.item` is that session clears it.

### Transcript

`TranscriptView` renders `model.items` in a `ScrollView` with a `LazyVStack(alignment: .leading, spacing: 12)` and
16 pt horizontal padding.

The transcript opens on the latest page of events and loads the earlier pages as the user scrolls up
([Loading the transcript](#loading-the-transcript)); there is no button for it.

- Trigger: while `model.hasEarlier` is true, the view loads the previous page when the user scrolls to within one
  screen height of the top: `onScrollGeometryChange` reports a distance from the top of the content
  (`contentOffset.y + contentInsets.top`) below `containerSize.height`. It then calls `model.loadEarlier()` through
  `banners.perform`; nothing is started while `model.isLoadingEarlier`.
- While `model.isLoadingEarlier`, the first row is a spinner row: a small `ProgressView`, centered, 32 pt high.
- Position: the `LazyVStack` is marked `.scrollTargetLayout()`, and `onScrollTargetVisibilityChange(idType:
  String.self)` keeps `topItemID`, the id of the first visible item. When the earlier events are inserted, the view
  calls `scrollTo(id: topItemID, anchor: .top)` on its `ScrollPosition`, so the message the user was reading stays at
  the top of the visible area.
- A failure shows the error banner once; the view tries again the next time the scroll position enters the top zone
  after leaving it, and after `reload()`.
- When the loaded events do not fill one screen height above the visible area, the next page loads at once, until
  `hasEarlier` is false.

Rendering per item:

- `.user`: a trailing bubble, at most 85 % of the width, accent color at 15 % opacity, corner radius 12, 12 pt
  horizontal and 8 pt vertical padding, holding the text (plain, selectable) and, under it in a wrapping flow, the
  attachments. Each attachment (`TaskAttachment`) is an
  `AttachmentView` of [media.md](media.md) with `fileName: file`, `mimeType: type`, `size: size`, the `cacheKey`
  "<projectID>/sessions/<session id>/<file>" and a `download` that calls
  `downloadSessionAttachment(projectID:sessionID:fileName:size:progress:)` on `store.connection`
  ([../client/workspace.md](../client/workspace.md#transfers)), which shows the download progress and a Retry after a
  failure ([media.md](media.md#loading-and-caching)). Under the bubble, the caption "<device name> · <time>"
  (`deviceID` resolved in `workspace.mains` and the mesh records, omitted when unknown; shortened time).
- `.assistant`: a leading bubble, styled like the user's bubble (at most 85 % of the width, corner radius 12, 12 pt
  horizontal and 8 pt vertical padding) but filled with the neutral `Color.secondary.opacity(0.15)`, holding the
  HephMarkdown view ([markdown.md](markdown.md)) with the link rules of [tasks.md](tasks.md#description) and
  `selection: .acrossBlocks`, so the user can select and copy any range of the reply up to a table
  ([markdown.md](markdown.md#selection-across-blocks)). No caption
  under it. Only `.assistant` and `.streaming` items of kind `text` have this bubble; thinking rows, tool rows,
  permission cards, turn end captions, system and error rows stay outside any bubble.
- `.thinking`: a collapsed row, `brain`, "Thinking" (secondary) and a disclosure chevron; expanded, the text in
  secondary color.
- `.tool`: `ToolUseRow` ([Tool rows](#tool-rows)).
- `.permission`: `PermissionCard` ([Permission cards](#permission-cards)).
- `.turnEnd`: a centered caption between two hairlines ([Turn end captions](#turn-end-captions)).
- `.system`: a centered caption, secondary.
- `.error`: `exclamationmark.triangle.fill` and the text, red.
- `.streaming`, kind `text`: like `.assistant`, from the partial text. Kind `thinking`: like `.thinking`, titled
  "Thinking…". Kind `toolInput`: a row `wrench.and.screwdriver`, "Preparing a tool call…" (secondary) and a
  disclosure; expanded, the partial input in monospaced font.

Scrolling:

- The transcript opens at the bottom.
- The view is at the bottom when the end of the content is within 40 pt of the visible bottom edge
  (`onScrollGeometryChange`). When items are added or grow while at the bottom, it scrolls to the bottom
  (`ScrollPosition.scrollTo(edge: .bottom)`).
- Not at the bottom: a "Jump to Latest" button (`arrow.down.circle.fill`) floats at the bottom trailing corner.
- When `sessionCenter.revealRequestID(mainID:sessionID:)` is set for this session, the view scrolls to that permission
  card and calls `sessionCenter.clearReveal(mainID:sessionID:)`.

| `model.phase`                  | Display                                                                                           |
|--------------------------------|---------------------------------------------------------------------------------------------------|
| `loading` and no items         | centered `ProgressView`                                                                           |
| `failed(message)` and no items | the message and a "Retry" button (`reload()`), centered                                           |
| `failed(message)` and items    | the items, under a bar (8 pt padding, `.bar` background) holding the message and the Retry button |
| `loaded` and no items          | "No messages yet." (secondary, centered)                                                          |

#### Turn end captions

| `result` event          | Caption                                                                                             |
|-------------------------|-----------------------------------------------------------------------------------------------------|
| `isError` true          | "Failed", plus ": <stopReason>" when set (red)                                                      |
| `stopReason` nil        | none, the row is not drawn: an interrupted turn, whose `system` event before it shows "Interrupted" |
| `stopReason` `end_turn` | "Done in <duration>", or "Done" when `durationMS` is nil                                            |
| any other `stopReason`  | "Stopped (<stopReason>) after <duration>", or "Stopped (<stopReason>)" when `durationMS` is nil     |

`<duration>` is `Duration.milliseconds(durationMS)` formatted with `.units(allowed: [.hours, .minutes, .seconds],
width: .narrow)`.

### Tool rows

`ToolUseRow` shows one tool call. It is collapsed by default; clicking the row toggles it.

- Symbol: from the tool name (table below).
- Name (bold): `mcp__<server>__<tool>` shows `<tool>` followed by `<server>` as a secondary caption; any other name is
  shown as is. A `.tool` item without name (a result whose call is unknown) is titled "Tool result".
- Summary: `ToolSummary.summary(toolName:inputJSON:projectRoot:)`, monospaced, secondary, one line.
- State, trailing: without result while the session is `running` or `waitingPermission`, a small `ProgressView`; with
  a result, `checkmark.circle` (green); with an error result, `xmark.octagon.fill` (red); otherwise nothing.
- Expanded: "Input", the input pretty-printed (sorted keys) in a monospaced box, max height 240 pt, scrollable; then
  "Result", the result text in a monospaced box, max height 300 pt, red when `isError`, or "No result".
- A result longer than 20,000 characters is shown cut there, followed by "… <n> more characters" and a "Copy Full
  Result" button.

| Tool name                           | Symbol                   |
|-------------------------------------|--------------------------|
| `Bash`                              | `terminal`               |
| `Read`                              | `doc.text`               |
| `Write`                             | `square.and.pencil`      |
| `Edit`, `MultiEdit`, `NotebookEdit` | `pencil`                 |
| `Grep`, `Glob`                      | `magnifyingglass`        |
| `WebFetch`, `WebSearch`             | `globe`                  |
| `Task`, `Agent`                     | `person.2`               |
| `TodoWrite`                         | `checklist`              |
| `mcp__hephaestus__*`                | `hammer`                 |
| other `mcp__*`                      | `puzzlepiece.extension`  |
| any other                           | `wrench.and.screwdriver` |

`ToolSummary` (also used by permission cards, the indicator and the banner) parses the input JSON text as an object;
any other input gives an empty summary.

| Tool name                            | Summary                                                                     |
|--------------------------------------|-----------------------------------------------------------------------------|
| `Bash`                               | first line of `command`                                                     |
| `Read`, `Write`, `Edit`, `MultiEdit` | `file_path`                                                                 |
| `NotebookEdit`                       | `notebook_path`                                                             |
| `Grep`                               | `pattern`, plus " in <path>" when `path` is set                             |
| `Glob`                               | `pattern`                                                                   |
| `WebFetch`                           | `url`                                                                       |
| `WebSearch`                          | `query`                                                                     |
| `Task`, `Agent`                      | `description`                                                               |
| `TodoWrite`                          | "<n> items", n = number of elements of `todos`                              |
| `mcp__hephaestus__*`                 | the first string value among `task`, `project`, `name`, `query`, `url`      |
| any other                            | the first string value of the top-level keys in alphabetical order, else "" |

- `file_path`, `notebook_path` and `path` values that start with `<projectRoot>/` are shown relative to it
  (`projectRoot` = `store.project?.rootPath`).
- At most 200 characters, cut with "…".

### Status line

`SessionStatusLine` sits between the transcript and the composer, one line high; the failed details expand it.

| Condition           | Content                                                                                    |
|---------------------|--------------------------------------------------------------------------------------------|
| Main not connected  | gray dot · "<Main name> is offline" (replaces every other line)                            |
| `idle`              | green dot · "Idle"                                                                         |
| `starting`          | `ProgressView` · "Starting Claude…"                                                        |
| `running`           | `ProgressView` · "Running", plus " — <statusLine>" when set                                |
| `waitingPermission` | `hand.raised.fill` orange · "Waiting for permission" · "Review" button                     |
| `stopped`           | gray dot · "Stopped. Sending a message restarts Claude."                                   |
| `failed`            | `xmark.octagon.fill` red · "Failed" · "Details" disclosure, shown only when `error` is set |

- `statusLine` and `error` are fields of `SessionInfo` ([../protocol/types.md](../protocol/types.md#sessioninfo)).
- Review scrolls to the first pending permission card.
- Details shows `error` in monospaced red text, selectable, at most 12 lines visible, scrollable.

### Permission cards

A `.permission` item holds the request (`requestID`, `toolName`, `input`, `description`, `suggestions`,
`blockedPath`) and, once known, its decision (`decision`, `deviceID`, time).

| Card state | Condition                                                                                       |
|------------|-------------------------------------------------------------------------------------------------|
| pending    | no decision is known and `model.info?.pendingPermissions` holds a request with that `requestID` |
| resolved   | a decision is known                                                                             |
| expired    | neither                                                                                         |

The card is a rounded rectangle with 12 pt padding and a 1 pt border (orange when pending, separator color
otherwise). Rows, top to bottom:

1. Title: `hand.raised.fill` (orange) and "Claude wants to use <tool display name>" (headline).
2. Summary: the `ToolSummary` (monospaced), when not empty.
3. Description: `description` (secondary), when set and different from the summary.
4. Path: "Path: <blockedPath>" (secondary, monospaced), when set.
5. Input: an "Input" disclosure, collapsed, with the input pretty-printed (sorted keys) in monospaced font.
6. Pending only, the buttons: "Allow Once" (`.borderedProminent`); "Always Allow" (`.bordered`, only when the
   suggestions summary is not empty); "Allow All" (`.bordered`); "Deny" (a `Menu` whose primary action is Deny, with
   the item "Deny with Message…"). Then, when the suggestions summary is not empty, the caption "Always Allow adds:
   <suggestions summary>".
7. Resolved only, the outcome: `checkmark.circle.fill` (green) "Allowed once" or "Always allowed", or
   `xmark.circle.fill` (red) "Denied", followed by " from <device name> · <time>"; for decision `allowAll`,
   `checkmark.circle.fill` (green) "Allowed automatically" alone. Expired only: "No longer pending" (secondary).

Behavior:

- Allow Once sends decision `allow`, Always Allow `allowAlways`, Deny `deny` with a nil message. Deny with Message…
  shows a "Message to Claude" text field with Deny and Cancel buttons inside the card; that Deny sends `deny` with the
  trimmed message (nil when empty).
- Allow All calls `model.update(allowsAllTools: true)`: the Main answers this card and every other pending request of
  the session with `allowAll`, and answers the later ones itself
  ([../claude/cli.md](../claude/cli.md#44-allow-all-tools)). The cards turn resolved when their decisions arrive.
- The request is `model.respond(requestID:decision:message:)`, or `model.update(allowsAllTools:)` for Allow All. While
  it runs, the buttons are disabled and a `ProgressView` shows. The card turns resolved when the decision arrives
  (`permissionDecision` event or `permission.resolved`), from whichever device answered first. Errors `conflict` and
  `notFound` (the request is no longer pending, or the session is gone) show the card as expired until a decision
  arrives; every error shows the error banner.
- Device name: the name of `deviceID` in the mesh records, "another device" when unknown. A request the Main cancelled
  (end of the turn or of the process) is recorded as `deny` from the Main's own device id
  ([../claude/cli.md](../claude/cli.md)). Time: the decision event's `at`, else the reception time of
  `permission.resolved`; shortened time style.
- Suggestions summary: `suggestions` is JSON text holding an array of objects. The objects whose `type` is `addRules` or
  `addDirectories` are the suggestions that Always Allow applies ([../claude/cli.md](../claude/cli.md)); other objects
  are ignored. The sessions that work in the public repository send none, so their cards have no Always Allow, only
  Allow All ([../claude/cli.md](../claude/cli.md#35-sessions-in-the-public-repository)). The summary has one part per
  element of the list of each such object (table), in the order of the objects and of their elements; a `rules` element
  that is not an object with a string `toolName`, and a `directories` element that is not a string, give no part. Parts
  are joined with " · ". The summary is empty when `suggestions` is nil, not an array, or gives no part:

| `type` of the object | Elements                | Part of an element                                                          |
|----------------------|-------------------------|-----------------------------------------------------------------------------|
| `addRules`           | the array `rules`       | "<toolName>(<ruleContent>)", or "<toolName>" without a string `ruleContent` |
| `addDirectories`     | the array `directories` | "access to <directory>"                                                     |

### Composer

The session's composer is `MessageComposer` ([Message composer](#message-composer)) with the placeholder "Message
Claude", `mainDeviceID: store.mainDeviceID` and `projectID: store.projectID`.

- Closed session (`model.info?.closed` set, [../claude/cli.md](../claude/cli.md#511-closing-a-session)): no composer.
  In its place, the text "This conversation is over" (secondary, centered, with the vertical padding of the composer).
  A closed session cannot be reopened, so nothing else is offered; the transcript stays as it is. The draft of the
  view is discarded when the session becomes closed while it is shown.

- Send is possible when the Main is connected and `model.info` is known, whatever the status: a message sent during a
  turn is queued by the CLI ([../protocol/methods.md](../protocol/methods.md#sessionssend)). Send calls
  `model.send(text:attachments:)` with the trimmed text and `draft.uploads`.
- While the status is `starting`, `running` or `waitingPermission`, the Stop button shows next to Send and calls
  `model.interrupt()`: the turn ends with an "Interrupted" caption and the process stays alive.
- The draft is state of the view: it is reset when the view shows another session.

## Pending permissions across the app

### Toolbar indicator

`PermissionIndicator()` is placed by the shell in every window's toolbar ([shell.md](shell.md#9-toolbar)).

- Listed requests: `sessionCenter.pendingPermissions` ([SessionCenter](#sessioncenter)).
- Unlisted requests of a project: for each project `P` (sub projects included) in the tree (`projects`) of each
  connected Main `M`, `n(P)` = `P.pendingPermissionCount` minus the number of listed requests of `M` and `P`, when
  positive. These are requests that were pending when this device connected, in sessions whose `SessionInfo` this
  device has not received since.
- The count is the number of listed requests plus the sum of the `n(P)`.

It is hidden when the count is 0; otherwise it is `hand.raised.fill` (orange) with the count as a badge at its top
trailing corner: white `.caption2` bold digits on a red capsule at least 16 × 16 pt. The badge lies entirely inside
the indicator's toolbar item, so the toolbar never clips it, on macOS, iPadOS and iOS (regular and compact width): the
symbol gets `.padding(.top, 6)` and `.padding(.trailing, 6)`, and the badge is an `.overlay(alignment: .topTrailing)`
of that padded frame, with no `.offset`. Clicking it opens a popover (at
least 360 pt wide, ideal 420 pt, at most 520 pt high; a sheet in compact width) titled "Waiting for Permission": one
row per listed request, oldest first, then one row per project with `n(P)` > 0, in path bar order of the Mains
([shell.md](shell.md#7-path-bar)) and tree order.

Request rows, one per `PendingPermission` `pending`:

- Line 1: the tool symbol, the tool display name and the summary (monospaced, one line).
- Line 2: "<Main name> ▸ <project name> ▸ <session title>" (secondary). Main name:
  `workspace.connection(pending.mainID)?.name`. Project name:
  `workspace.summary(of: pending.projectID, on: pending.mainID)?.name`, else the identifier. Session title: the
  `title` of `session(pending.sessionID)` of
  `workspace.projectStore(mainDeviceID: pending.mainID, projectID: pending.projectID)`, else "Claude".
- Buttons: Allow Once and Deny call `sessionCenter.respond(to: pending, decision: .allow or .deny, message: nil)`
  through `banners.perform`. Show closes the popover, then:

  ```swift
  context.navigate(mainDeviceID: pending.mainID, projectID: pending.projectID, section: .claude,
                   item: pending.sessionID.uuidString)
  sessionCenter.reveal(mainID: pending.mainID, sessionID: pending.sessionID, requestID: pending.request.requestID)
  ```

Project rows: "<n> requests in <project name>" ("1 request in <project name>" when `n(P)` is 1) and a Show button that
closes the popover and calls `context.navigate(mainDeviceID: M, projectID: P, section: .claude, item: nil)`.

### Banner

`.permissionBanner()` is applied by the shell to every window's root view. When `sessionCenter.bannerPermission` is
set and the window is active (macOS: the key window, environment value `appearsActive`; iOS and iPadOS: the scene
phase is `.active`), a banner shows at the top center of the content:

- `hand.raised.fill` (orange), "Claude wants to use <tool display name>" (headline), then "<project name> ▸ <session
  title> · <summary>" (secondary, one line); the buttons Show (as in the indicator) and close (`xmark`, calls
  `dismissBanner()`).
- Regular material background, corner radius 12, shadow, max width 520 pt; it slides in from the top.
- It goes away after 10 s, on close, on Show, or when the request leaves `pendingPermissions`.

## Message composer

`MessageComposer` is the composer of sessions and of task comments ([tasks.md](tasks.md#composer)). It uploads each
attachment to the project's Main as soon as it is added, so that Send only names the uploads. Layout, top to bottom:
the attachment tray (when there are attachments), then a row with the `AttachmentPickerButton` of
[media.md](media.md#attachment-picking) (`paperclip`), the text view, the Stop button (when given) and the Send button.
The composer has no outer padding: the views that contain it add their own.

- Row: an `HStack(alignment: .bottom, spacing: 8)`. Its items have no padding of their own: the bottom of each button
  (attach, Stop, Send) is the bottom of the text view's box, at every height of the text view.
- Text view: `ComposerTextView` in a box: a rounded rectangle of corner radius 8, filled with the secondary color at
  8 % opacity, with a 1 pt border in the separator color. It grows from 1 to 8 lines, then scrolls; placeholder in
  secondary color; Return inserts a line break; ⌘↩ sends when Send is enabled.
- Tray: a horizontal scroll of chips, one per attachment, in the order they were added. A chip has a 40 × 40 pt
  thumbnail (images: decoded from the source with `ImageDecoding`, [media.md](media.md#loading-and-caching)) or the
  `doc` symbol, the name (one line, middle truncation, at most 160 pt), then a line and buttons by state:

| `AttachmentDraft.State` | Line under the name                                                                                                                                                                      | Buttons                                                                      |
|-------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|
| `uploading(progress)`   | a linear `ProgressView(value: progress.fraction)` 120 pt wide (indeterminate while `progress` is nil), then "<completed> of <total>" (`ByteCountFormatter`, `.file`, caption, secondary) | Cancel (`xmark.circle.fill`, help "Cancel Upload")                           |
| `uploaded(_:at:)`       | the size (`ByteCountFormatter`, `.file`, caption, secondary)                                                                                                                             | Remove (`xmark.circle.fill`, help "Remove")                                  |
| `failed(message)`       | `exclamationmark.triangle.fill` and "Upload failed" (caption, red); the message in the help tag and as accessibility value                                                               | Retry (`arrow.clockwise`, help "Retry Upload"), Remove (`xmark.circle.fill`) |

- Send (`arrow.up.circle.fill`): enabled when `canSend` is true, the trimmed text or the attachments are not empty,
  every attachment is `uploaded`, and no send is in flight. While an attachment is `uploading`, Send stays disabled
  with the help tag "Waiting for uploads…". It shows a `ProgressView` while sending. Send calls `onSend(draft)`:
  `true` clears the draft, `false` keeps it.
- Stop (`stop.circle.fill`, red): shown when `onStop` is not nil; calls it.

Attachments come from the pickers of [media.md](media.md#attachment-picking), which produce `AttachmentInput` values
(choosing, reading and naming the files and images is theirs):

| Source                     | Picker of media.md                                                               |
|----------------------------|----------------------------------------------------------------------------------|
| the `paperclip` button     | `AttachmentPickerButton(onAdd:)`: file importer; Photos picker on iOS and iPadOS |
| a drop on the composer     | `attachmentDrop(onAdd:)`, applied to the whole composer                          |
| a paste into the text view | `AttachmentPasteboard.attachments(from:)`, called by `ComposerTextView` (below)  |

Uploads ([../client/workspace.md](../client/workspace.md#transfers)):

- Each `AttachmentInput` becomes an `AttachmentDraft` with a new `id`, its `fileName`, `source` and `size`, `isImage`
  true when the `UTType` of the file name's extension conforms to `.image`, and state `uploading(nil)`. Attachments
  have no size limit.
- A task of the composer uploads it at once: `upload(fileName:projectID:source:progress:)` on
  `workspace.connection(mainDeviceID)` for `projectID`; each progress report sets `uploading(progress)`. Several
  attachments upload at the same time. Success: `uploaded(ref, at: <now>)`. Failure: `failed(<the error's message>)`;
  without a connection: `failed("<Main name> is offline.")`. A cancelled task changes nothing.
- Cancel cancels the task (`upload` then cancels the upload on the Main) and removes the attachment. Remove removes it
  and, when it is `uploaded`, sends `cancelUpload(uploadID:)` without waiting (its error ignored). Retry starts a new
  upload of the same source.
- Send: an attachment uploaded more than 55 minutes before (the Main deletes an upload that no request used for an
  hour, [../protocol/methods.md](../protocol/methods.md#using-uploads)) is uploaded again first: it goes back to
  `uploading(nil)`, the send is in flight meanwhile, and `onSend` runs once every attachment is `uploaded`; a failed
  upload ends the send without calling `onSend`.
- While it is shown, the composer iterates `workspace.events()`: a `connected(mainDeviceID:)` of its Main sets every
  `uploaded(ref, at:)` attachment to `uploaded(ref, at: .distantPast)`, so the next Send uploads it again. The Main may
  have restarted, and a Main forgets its uploads when its host stops or starts
  ([../services/files.md](../services/files.md#71-store)).
- `ComposerDraft.uploads` is the `UploadRef` of every attachment, in tray order: the caller sends it with the trimmed
  text. After `onSend` returned `true` the Main has used the uploads: the draft is cleared and nothing is cancelled.
  After `false` the attachments stay `uploaded` and the next Send names the same uploads (a failed request leaves its
  uploads usable).
- An attachment that leaves the draft otherwise (Remove, Cancel, the caller replacing the draft) and every attachment
  when the composer disappears: its task is cancelled and, when it is `uploaded`, `cancelUpload(uploadID:)` is sent
  without waiting. When the composer disappears, its attachments are also removed from the draft; the text stays.
- An attachment that leaves the draft in any way passes its source to `AttachmentFiles.discard(_:)`, which deletes the
  temporary copy a picker made ([media.md](media.md#attachment-picking)).

`ComposerTextView` wraps the platform text view:

- macOS: `NSTextView` in an `NSScrollView`: plain text, undo on, automatic quote and dash substitution off, body font,
  transparent background. `keyDown`: ⌘↩ calls send. `paste(_:)`: calls
  `AttachmentPasteboard.attachments(from: .general)` ([media.md](media.md#pastes)); a non-nil result, even empty, is
  added as attachments and no text is pasted; nil runs the normal paste.
- iOS and iPadOS: `UITextView` with the body font. `keyCommands`: ⌘↩ calls send. `paste(_:)`: as on macOS, with
  `UIPasteboard.general`. `canPerformAction` allows paste when the pasteboard has images or strings.
- It reports its height to SwiftUI from the laid-out text, clamped to 1–8 lines.

## Session models

`HephaestusKit/Sources/HephClient/SessionModel.swift` holds `SessionCenter`, `SessionModel`, `TranscriptItem` and its
payload types, `TranscriptBuilder` and `PendingPermission`. `SessionCenter` and `SessionModel` are `@MainActor
@Observable` classes; the other types are `Sendable` value types, so `TranscriptBuilder` is unit-tested without
networking.

### SessionModel

One `SessionModel` per `SessionView`, for the session `sessionID` of the project of `store`; `mainID` is
`store.mainDeviceID`. It uses `workspace.sessionCenter`.

- `info` is `store.session(sessionID)`, kept current by the Workspace from `session.changed`.
- `isRemoved` is true when `store.isRemoved`, or when the store is loaded and has no session `sessionID`.
- `appear()` (once until `disappear()`):
  1. `sessionCenter.sessionDidAppear(mainID:sessionID:)`.
  2. A stream from `workspace.events()` is taken and a task iterates it, buffering what concerns the session.
  3. A task awaits `workspace.subscribe(.session(sessionID), on: mainID)`, keeps the `TopicSubscription`, then runs
     step 4.
  4. Load ([Loading the transcript](#loading-the-transcript)).
- `disappear()`: cancels the tasks and the subscription; `sessionCenter.sessionDidDisappear(mainID:sessionID:)`.
- `WorkspaceEvent.connected(mainDeviceID:)` of the session's Main: load again, buffering events meanwhile (the
  Workspace has subscribed again, [../client/workspace.md](../client/workspace.md#subscriptions)). `reload()` does the
  same.
- Publishing: event effects update `items` at once; deltas update the builder at once and `items` at most every
  100 ms.

Events applied (`WorkspaceEvent.event(mainDeviceID:_:)` from the session's Main, for this session):

| `ServerEvent`          | Effect                                                                                       |
|------------------------|----------------------------------------------------------------------------------------------|
| `sessionEvent`         | `event` is appended to `loadedEvents` unless its `id` is there; `apply(_:)` of `event`       |
| `sessionDelta`         | `applyDelta(messageID:index:kind:text:)`                                                     |
| `permissionRequested`  | `applyPermissionRequest(_:at:)`, `at` = reception time                                       |
| `permissionResolved`   | `applyPermissionDecision(requestID:decision:deviceID:at:)`, `at` = reception time            |
| `sessionChanged`       | `clearStreaming()` when the status is not `starting`, `running` or `waitingPermission`       |

#### Loading the transcript

`sessions.history` returns one page of the session's log
([../protocol/methods.md](../protocol/methods.md#sessionshistory)). The model keeps `loadedEvents` (the events of the
pages loaded, then every `session.event` applied since) and `firstIndex` (the log index of the first loaded event).
Rebuilding the builder applies `loadedEvents` in order to a new `TranscriptBuilder`.

- Load (appear, reconnection, `reload()`): phase `loading` (items stay visible);
  `sessionHistory(projectID:sessionID:before: nil, limit: nil)` → `SessionsHistoryResult {events, firstIndex, total}`,
  the latest 1,000 events. Result: `loadedEvents` = `events`, `firstIndex` = the result's `firstIndex` (earlier pages
  loaded before are dropped); the builder is rebuilt from `loadedEvents`, then the buffered events are applied in
  order, then events are applied as they come; phase `loaded`. Failure: phase `failed(message)`; events keep being
  applied.
- `hasEarlier` is `firstIndex > 0`.
- `loadEarlier()`, when `hasEarlier` and no earlier page is loading: `isLoadingEarlier` is true while
  `sessionHistory(projectID:sessionID:before: firstIndex, limit: nil)` runs. Result: its `events` are put before
  `loadedEvents`, `firstIndex` takes the result's `firstIndex`, and the builder is rebuilt from `loadedEvents` with
  the `.streaming` items it held put back at the end. A result that arrives after a load started meanwhile is ignored.
  Failure: thrown; nothing changes.

Requests:

| Method                                               | Request function                                                             |
|------------------------------------------------------|------------------------------------------------------------------------------|
| `send(text:attachments:)`                            | `sendMessage(projectID:sessionID:text:attachments:)`                         |
| `interrupt()`                                        | `interruptSession(projectID:sessionID:)`                                     |
| `stop()`                                             | `stopSession(projectID:sessionID:)`                                          |
| `respond(requestID:decision:message:)`               | `respondToPermission(projectID:sessionID:requestID:decision:message:)`       |
| `update(title:permissionMode:allowsAllTools:model:)` | `updateSession(projectID:sessionID:patch:)`, `SessionPatch` of the arguments |
| `delete()`                                           | `deleteSession(projectID:sessionID:)`                                        |

`update(model: "")` clears the session's model.

### Building the transcript

`TranscriptBuilder` turns `SessionEvent`s ([../protocol/types.md](../protocol/types.md#sessionevent)) and deltas into
`[TranscriptItem]`, following the client rules of [../protocol/events.md](../protocol/events.md#sessionevent).
"Append" inserts before the first `.streaming` item, or at the end when there is none.

- An event whose `id` is already applied is not appended again. Its streaming effect (below) still applies.
- Streaming effect: each `assistant`, `thinking` or `toolUse` event removes the `.streaming` item
  `stream:<messageID>:<index>` of its `messageID` and `index` (when both are set); each `result` and `error` event
  removes every `.streaming` item.

| `SessionEvent` type  | Effect (besides the streaming effect)                                                                                                                                                      |
|----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `user`               | append `.user` (`text`, `attachments`, `deviceID`)                                                                                                                                         |
| `assistant`          | append `.assistant`                                                                                                                                                                        |
| `thinking`           | append `.thinking` when its trimmed text is not empty                                                                                                                                      |
| `toolUse`            | append `.tool` (`toolUseID`, `name`, `input`); when a `.tool` item with that `toolUseID` exists (its result came first), it takes the call's time, `name` and `input` and keeps its result |
| `toolResult`         | set the result (`text`, `isError`) of the `.tool` item with that `toolUseID`, else append a `.tool` item without name holding it                                                           |
| `permission`         | append `.permission`, unless an item with that `requestID` exists                                                                                                                          |
| `permissionDecision` | set the decision (`decision`, `deviceID`, `at`) of the `.permission` item with that `requestID`; ignored when there is none                                                                |
| `result`             | append `.turnEnd` (`isError`, `durationMS`, `costUSD`, `stopReason`)                                                                                                                       |
| `system`             | append `.system`                                                                                                                                                                           |
| `error`              | append `.error`                                                                                                                                                                            |

- `applyDelta`: appends `text` to the `.streaming` item `stream:<messageID>:<index>`, created at the end with that
  kind when missing. A view that subscribes while a block streams shows the block from the first fragment received.
- `applyPermissionRequest`: appends `.permission` unless that `requestID` exists. `applyPermissionDecision`: as the
  `permissionDecision` event.
- `clearStreaming()`: removes every `.streaming` item.
- Item ids: event items use the event `id`; `.tool` uses `tool:<toolUseID>`; `.permission` uses
  `permission:<requestID>`; `.streaming` uses `stream:<messageID>:<index>`.

### SessionCenter

One `SessionCenter` per `Workspace`, created by `Workspace.init` with `init(workspace:)` (it keeps a weak reference to
the Workspace) and used as `workspace.sessionCenter`; it is not put in the environment
([../client/workspace.md](../client/workspace.md)).

`pendingPermissions` lists the requests waiting for an answer on the connected Mains, oldest first (by `receivedAt`).
It is rebuilt from `SessionInfo.pendingPermissions` ([../protocol/types.md](../protocol/types.md#sessioninfo)) and kept
current by the events. The Workspace makes these calls, `mainDeviceID` being the sending Main
([../client/workspace.md](../client/workspace.md#events)):

| Call                                                                                      | Effect                                                                                                      |
|-------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| `handleSessions(mainDeviceID:projectID:sessions:)`                                        | the listed requests of that Main and project become the `pendingPermissions` of `sessions`                  |
| `handleSessionChanged(mainDeviceID:projectID:session:)`                                   | the listed requests of that Main and session become `session.pendingPermissions`                            |
| `handleSessionRemoved(mainDeviceID:projectID:sessionID:)`                                 | the requests of that session are removed                                                                    |
| `handlePermissionRequested(mainDeviceID:projectID:sessionID:request:)`                    | the request is added unless the same Main and `requestID` are listed; `bannerPermission` may change (below) |
| `handlePermissionResolved(mainDeviceID:projectID:sessionID:requestID:decision:deviceID:)` | the request with that Main and `requestID` is removed                                                       |
| `handleSessionEvent(mainDeviceID:projectID:sessionID:event:)`                             | nothing                                                                                                     |
| `handleSessionDelta(mainDeviceID:projectID:sessionID:messageID:index:kind:text:)`         | nothing                                                                                                     |
| `mainDidConnect(_:)`                                                                      | nothing: the stores of that Main reload and call `handleSessions`                                           |
| `mainDidDisconnect(_:)`                                                                   | the requests of that Main are removed                                                                       |

- The Workspace calls `handleSessions` after each load of a store, once the events queued during the load are
  applied, with the store's `sessions`.
- "Become": a request already listed (same Main and `requestID`) keeps its entry and `receivedAt`; a new one gets the
  current time, in the order of the list; the listed requests of that scope that are not in the list are removed.
- On `handlePermissionRequested`, when no `SessionModel` of that session is visible on this device (below),
  `bannerPermission` becomes that request, whether or not it was already listed.
- The pending requests of sessions whose `SessionInfo` this device has not received since it connected (a project
  without a loaded store) are counted by the toolbar indicator from `ProjectSummary.pendingPermissionCount`
  ([Toolbar indicator](#toolbar-indicator)).
- `bannerPermission` becomes nil on `dismissBanner()` and when its request leaves `pendingPermissions`.
- `respond(to:decision:message:)` calls `respondToPermission(projectID:sessionID:requestID:decision:message:)` on
  `workspace.connection(pending.mainID)`; errors `conflict` and `notFound` remove the request, then every error is
  rethrown.

Visibility and reveal:

- `sessionDidAppear` and `sessionDidDisappear` count the visible models per (Main, session); a session is visible when
  its count is above 0.
- `reveal(mainID:sessionID:requestID:)` records the request to scroll to; `revealRequestID(mainID:sessionID:)` returns
  it; `clearReveal(mainID:sessionID:)` removes it.

## Swift API

```swift
// HephClient/SessionModel.swift

@MainActor @Observable
public final class SessionCenter {
    public init(workspace: Workspace)                       // by Workspace.init; weak reference to it

    public private(set) var pendingPermissions: [PendingPermission]
    public private(set) var bannerPermission: PendingPermission?
    public func respond(to pending: PendingPermission, decision: PermissionDecision, message: String?) async throws
    public func dismissBanner()

    // Called by the Workspace (client/workspace.md).
    public func handleSessions(mainDeviceID: UUID, projectID: String, sessions: [SessionInfo])
    public func handleSessionChanged(mainDeviceID: UUID, projectID: String, session: SessionInfo)
    public func handleSessionRemoved(mainDeviceID: UUID, projectID: String, sessionID: UUID)
    public func handleSessionEvent(mainDeviceID: UUID, projectID: String, sessionID: UUID, event: SessionEvent)
    public func handleSessionDelta(mainDeviceID: UUID, projectID: String, sessionID: UUID, messageID: String,
                                   index: Int, kind: SessionDeltaKind, text: String)
    public func handlePermissionRequested(mainDeviceID: UUID, projectID: String, sessionID: UUID,
                                          request: PermissionRequest)
    public func handlePermissionResolved(mainDeviceID: UUID, projectID: String, sessionID: UUID, requestID: String,
                                         decision: PermissionDecision, deviceID: UUID)
    public func mainDidConnect(_ mainDeviceID: UUID)
    public func mainDidDisconnect(_ mainDeviceID: UUID)

    public func sessionDidAppear(mainID: UUID, sessionID: UUID)
    public func sessionDidDisappear(mainID: UUID, sessionID: UUID)
    public func reveal(mainID: UUID, sessionID: UUID, requestID: String)
    public func revealRequestID(mainID: UUID, sessionID: UUID) -> String?
    public func clearReveal(mainID: UUID, sessionID: UUID)
}

@MainActor @Observable
public final class SessionModel {
    public enum Phase: Equatable, Sendable { case idle, loading, loaded, failed(String) }

    public init(workspace: Workspace, store: ProjectStore, sessionID: UUID)
    public var mainID: UUID { get }                         // store.mainDeviceID
    public var projectID: String { get }                    // store.projectID
    public let sessionID: UUID
    public var info: SessionInfo? { get }
    public var isRemoved: Bool { get }
    public private(set) var items: [TranscriptItem]
    public private(set) var phase: Phase
    public private(set) var firstIndex: Int                 // log index of the first loaded event
    public var hasEarlier: Bool { get }                     // firstIndex > 0
    public private(set) var isLoadingEarlier: Bool

    public func appear()
    public func disappear()
    public func reload() async
    public func loadEarlier() async throws
    public func send(text: String, attachments: [UploadRef]) async throws
    public func interrupt() async throws
    public func stop() async throws
    public func respond(requestID: String, decision: PermissionDecision, message: String?) async throws
    public func update(title: String? = nil, permissionMode: PermissionMode? = nil, allowsAllTools: Bool? = nil,
                       model: String? = nil) async throws
    public func delete() async throws
}

public struct PendingPermission: Identifiable, Equatable, Sendable {
    public var id: String { get }                           // "<mainID>/<requestID>"
    public let mainID: UUID
    public let projectID: String
    public let sessionID: UUID
    public let request: PermissionRequest
    public let receivedAt: Date
}

public enum TranscriptItem: Identifiable, Equatable, Sendable {
    case user(UserMessageItem)
    case assistant(TextItem)
    case thinking(TextItem)
    case tool(ToolItem)
    case permission(PermissionItem)
    case turnEnd(TurnEndItem)
    case system(TextItem)
    case error(TextItem)
    case streaming(StreamingItem)
    public var id: String { get }
}

public struct TextItem: Equatable, Sendable {
    public let id: String; public let at: Date; public let text: String
}
public struct UserMessageItem: Equatable, Sendable {
    public let id: String; public let at: Date; public let text: String
    public let attachments: [TaskAttachment]                // files of .hephaestus/sessions/<session id>/
    public let deviceID: UUID?
}
public struct ToolItem: Equatable, Sendable {
    public let toolUseID: String; public let at: Date; public let name: String
    public let input: String                                // JSON text
    public var result: ToolResultItem?
}
public struct ToolResultItem: Equatable, Sendable {
    public let text: String; public let isError: Bool
}
public struct PermissionItem: Equatable, Sendable {
    public let requestID: String; public let at: Date; public let toolName: String
    public let input: String                                // JSON text
    public let description: String?
    public let suggestions: String?                         // JSON text
    public let blockedPath: String?
    public var decision: PermissionDecisionItem?
}
public struct PermissionDecisionItem: Equatable, Sendable {
    public let decision: PermissionDecision; public let deviceID: UUID?; public let at: Date
}
public struct TurnEndItem: Equatable, Sendable {
    public let id: String; public let at: Date; public let isError: Bool
    public let durationMS: Int?; public let costUSD: Double?; public let stopReason: String?
}
public struct StreamingItem: Equatable, Sendable {
    public let messageID: String; public let index: Int; public let kind: SessionDeltaKind; public var text: String
}

public struct TranscriptBuilder: Sendable {
    public init()
    public private(set) var items: [TranscriptItem]
    public mutating func apply(_ event: SessionEvent)
    public mutating func applyDelta(messageID: String, index: Int, kind: SessionDeltaKind, text: String)
    public mutating func applyPermissionRequest(_ request: PermissionRequest, at: Date)
    public mutating func applyPermissionDecision(requestID: String, decision: PermissionDecision, deviceID: UUID?,
                                                 at: Date)
    public mutating func clearStreaming()
}
```

```swift
// HephUI/Claude — views are @MainActor; they read the Workspace, the window's WindowContext and its WindowBanners
// from the environment, and reach the SessionCenter through workspace.sessionCenter.

public struct ClaudeView: View { public init(store: ProjectStore) }

public struct SessionView: View {
    public init(store: ProjectStore, sessionID: UUID, showsTaskLink: Bool = true)
}

public struct PermissionIndicator: View { public init() }            // toolbar item of every window
extension View { public func permissionBanner() -> some View }        // root view of every window

public struct PermissionModePicker: View {
    public init(selection: Binding<PermissionMode?>, defaultLabel: String?)
}
public struct ClaudeModelField: View {
    public init(model: Binding<String>, placeholder: String, onCommit: @escaping () -> Void)
}
public enum ClaudeLabels {
    public static func title(_ status: SessionStatus) -> String
    public static func title(_ mode: PermissionMode) -> String
    public static func title(_ kind: SessionKind) -> String
}

public struct AttachmentDraft: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case uploading(TransferProgress?)        // nil until the first progress report
        case uploaded(UploadRef, at: Date)       // at: when the upload completed
        case failed(String)                      // the error's message
    }
    public let id: UUID
    public var fileName: String
    public var source: UploadSource
    public var size: Int
    public var isImage: Bool
    public var state: State
}
public struct ComposerDraft: Equatable, Sendable {
    public var text: String = ""
    public var attachments: [AttachmentDraft] = []
    /// The UploadRef of every uploaded attachment, in tray order.
    public var uploads: [UploadRef] { get }
    /// Every attachment is uploaded.
    public var isUploaded: Bool { get }
}
/// Uploads its attachments to `projectID` on the Main `mainDeviceID` as they are added (Message composer).
public struct MessageComposer: View {
    public init(placeholder: String, draft: Binding<ComposerDraft>, mainDeviceID: UUID, projectID: String,
                canSend: Bool, focusOnAppear: Bool = false, onStop: (() -> Void)? = nil,
                onSend: @escaping (ComposerDraft) async -> Bool)
}
```

`ClaudeView` ends its file with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

- [../client/workspace.md](../client/workspace.md): `Workspace` (`sessionCenter`, the calls of its Events table,
  `events()`, `WorkspaceEvent`, `subscribe(_:on:)`, `TopicSubscription`, `projectStore(mainDeviceID:projectID:)`,
  `connection(_:)`, `connections`, `summary(of:on:)`, `mains`), `MainConnection` (request functions, among them
  `sessionHistory(projectID:sessionID:before:limit:)`; `projects`, `isConnected`, `name`), `ProjectStore`
  (`mainDeviceID`, `projectID`, `sessions`, `session(_:)`, `phase`, `isRemoved`, `project`, `connection`),
  `Selection`.
- [../protocol/types.md](../protocol/types.md): `SessionInfo` (`statusLine`, `error`, `pendingPermissions`),
  `ProjectSummary` (`pendingPermissionCount`), `SessionEvent`, `SessionEventType`, `TaskAttachment`,
  `PermissionRequest`, `PermissionDecision`, `SessionStatus`, `SessionKind`, `SessionMode`, `PermissionMode`,
  `SessionPatch`, `SessionDeltaKind`, `UploadRef`.
- [../protocol/events.md](../protocol/events.md): `ServerEvent` and the `session.*` and `permission.*` payloads.
  [../protocol/envelope.md](../protocol/envelope.md): `Topic`. [../protocol/methods.md](../protocol/methods.md):
  `sessions.*` (`SessionsHistoryResult`), `sessions.readAttachment`, `uploads.*` (through the transfers of
  [../client/workspace.md](../client/workspace.md#transfers): `upload`, `downloadSessionAttachment`, `cancelUpload`).
- [../claude/cli.md](../claude/cli.md): statuses, interrupt and stop, permission answers (the suggestions Always
  Allow applies) and cancellations.
- [markdown.md](markdown.md): HephMarkdown view. [media.md](media.md): `AttachmentView`, image viewer, Quick Look,
  `AttachmentPickerButton`, `attachmentDrop(onAdd:)`, `AttachmentPasteboard`, `AttachmentInput`, `AttachmentFiles`,
  `ImageDecoding`.
- [shell.md](shell.md): toolbar, window root, `WindowContext` (`navigate`), `WindowBanners` (`perform`).
