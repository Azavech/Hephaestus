# Tickets screen

files:
- HephaestusKit/Sources/HephUI/Tickets/TicketsView.swift
- HephaestusKit/Sources/HephUI/Tickets/TicketListView.swift
- HephaestusKit/Sources/HephUI/Tickets/TicketListState.swift
- HephaestusKit/Sources/HephUI/Tickets/TicketRow.swift
- HephaestusKit/Sources/HephUI/Tickets/NewTicketSheet.swift
- HephaestusKit/Sources/HephUI/Tickets/TicketDetailView.swift
- HephaestusKit/Sources/HephUI/Tickets/TicketHeaderView.swift
- HephaestusKit/Sources/HephUI/Tickets/TicketDescriptionView.swift
- HephaestusKit/Sources/HephUI/Tickets/CommentsView.swift
- HephaestusKit/Sources/HephUI/Tickets/CommentView.swift
- HephaestusKit/Sources/HephUI/Tickets/TicketClaudeView.swift
- HephaestusKit/Sources/HephUI/Tickets/NewTicketSessionSheet.swift
- HephaestusKit/Sources/HephUI/Tickets/TicketStatusStyle.swift
- HephaestusKit/Sources/HephUI/Tickets/BundleRow.swift
- HephaestusKit/Sources/HephUI/Tickets/BundleDetailView.swift
- HephaestusKit/Sources/HephUI/Tickets/NewBundleSheet.swift
- HephaestusKit/Sources/HephUI/Tickets/AddBundleTicketsSheet.swift

---

The Tickets section (⌘2) lists the tickets and the bundles of the selected project and shows one ticket, with its
fields, description, comments and Claude sessions, or one bundle ([Bundles](#bundles)). Ticket data:
[../data/ticket-yml.md](../data/ticket-yml.md) and `TicketItem` in
[../protocol/types.md](../protocol/types.md#ticketitem).

Requests use the request functions of the project's `MainConnection` (`store.connection`,
[../client/workspace.md](../client/workspace.md#request-api)), run through `banners.perform` of the window's
`WindowBanners` (`@Environment(WindowBanners.self)`, [shell.md](shell.md#81-windowbanners)), which shows a failure as an
error banner. Sheets call the functions directly and show a failure's message in red above their buttons. The screen
observes the `ProjectStore` (`tickets`, `bundles`, `sessions`), which the Workspace keeps current from `ticket.changed`,
`ticket.removed`, `bundle.changed`, `bundle.removed`, `session.changed` and `session.removed`. The window's selection is
the `Selection` of its `WindowContext` ([shell.md](shell.md#52-windowcontext)). While the project's Main is not
connected, every control that sends a request is disabled, and so is every control that opens a sheet or a confirmation
dialog whose button sends one. While `store.connection` is nil, a request fails with `ProtocolError(.unavailable, "<Main
name> is offline.")`, <Main name> being the name of the Main's record in `workspace.mains`, else "Main".

Ticket names are trimmed of whitespace and line breaks, must not be empty, and hold no line break; they have no maximum
length ([../data/ticket-yml.md](../data/ticket-yml.md#validation-and-normalization)).

## Layout per device class

The width class is the `horizontalSizeClass`: always regular on macOS; compact on iPhone and in narrow iPad
multitasking.

| Width class     | Layout                                                                       |
|-----------------|------------------------------------------------------------------------------|
| regular, macOS  | `HSplitView`: ticket list (min 260, ideal 320, max 480 pt), ticket detail    |
| regular, iPadOS | `HStack(spacing: 0)`: ticket list (320 pt), `Divider`, ticket detail         |
| compact         | `NavigationStack` rooted at the ticket list; the detail is pushed (below)    |

While the Tickets section is shown, `selection.item` is the selected ticket id or bundle id
([../client/workspace.md](../client/workspace.md#selection)); the two never look alike
([../services/bundles.md](../services/bundles.md#bundle-id)). Choosing a row sets it. An id set from elsewhere
(search, a link) selects that ticket or bundle.

Several tickets can be selected at once (Multi-selection); `selection.item` is then nil.

In compact width the detail is pushed with `navigationDestination(item:)` on a binding over `selection.item`; Back sets
`selection.item` to nil. An item set from elsewhere, or already set when the section appears, pushes its detail at
once; New Ticket success pushes the new ticket. In the Select mode (Multi-selection) the binding reads nil, so choosing
rows pushes nothing; New Bundle success ends the Select mode and pushes the new bundle.

## Ticket list

Above the list: a search field (`magnifyingglass`, placeholder "Filter"), a filter menu button
(`line.3.horizontal.decrease.circle`, filled when a setting differs from its default) and a New Ticket button (`plus`).
In compact width the New Ticket button is in the navigation bar.

### Multi-selection

`TicketListState` holds `selectedIDs` (`Set<String>`), the selection of the list:

- Regular width: `List(selection:)` on `selectedIDs`; ⌘-click and ⇧-click add rows, as in any list.
- Compact width: a "Select" button in the navigation bar turns on the Select mode, `EditMode.active`, in which ticket
  rows show selection circles; "Done" turns it off and empties the selection. A bottom bar then shows "New Bundle" and
  the "Add to Bundle" menu (below), enabled when a ticket is selected.
- Only tickets can be selected together: when a change adds a bundle id, `selectedIDs` becomes that bundle id alone;
  broken tickets are never added to a selection of several rows.
- One id selected: `selection.item` = that id. Several: `selection.item` = nil and the detail area shows
  "<n> tickets selected", a "New Bundle…" button and the "Add to Bundle" menu. None: `selection.item` = nil. When
  `selection.item` is set from elsewhere, `selectedIDs` becomes that id alone.
- "Add to Bundle" is a `Menu` listing the bundles in `draft` status (name and id), in the order of the Bundles section
  ([Sections](#sections)); a `done` bundle's tickets are frozen ([Bundle detail](#bundle-detail)). Choosing one calls
  `updateBundle` with `BundlePatch(ticketIDs:)`: its tickets, then the selected tickets that are not in it, by ticket
  number. Without such a bundle the menu holds the disabled item "No bundle to add to".

### Filter and sort

`TicketListState` holds the settings of one window, in the state of its `TicketsView`: they are kept while the Tickets
section of the same project is shown, and reset when the window shows another section or selects another project.

| Setting        | Values                                                        | Default  |
|----------------|---------------------------------------------------------------|----------|
| Statuses shown | any subset of the four statuses (menu toggles)                | all four |
| Sort           | Number, Last Updated (menu picker)                            | Number   |
| Text           | the search field                                              | empty    |

- Text: the query is split on whitespace; every word must occur, case- and diacritic-insensitive, in the ticket's id,
  name or description.
- Number: ascending by the integer after the last `-` of the id (the order of `store.tickets`). Last Updated: `updated`
  descending, ties by number descending.
- Broken tickets (a `TicketItem` with a `parseError`) ignore the status filter; the text filter matches their id and
  parse error.

### Sections

A Bundles section first, then sections in `TicketStatus.allCases` order (To Do, In Progress, Review, Done), then
Broken. The Bundles section lists `store.bundles` most recently updated first, whatever the Sort setting: by update
time descending, ties by number descending. A bundle's update time is the latest of its own `updated` and the
`updated` of its tickets found in `store.tickets` (a deleted ticket does not count). The section is filtered by the text
only (every word in the bundle's id or name); its header is `square.stack.3d.up`, "Bundles" and the count; its row is
[Bundle row](#bundle-row). A ticket in a bundle is also listed in its status section. A broken ticket is only in the
Broken section. A section with no ticket after filtering is hidden. Header: `TicketStatusBadge` and the count; the
Broken header is `exclamationmark.triangle`, "Broken" and the count.

### Row

- Line 1: the id (monospaced, caption, secondary); trailing, the indicators.
- Line 2: the name (body, up to 2 lines); for a broken ticket "Invalid ticket file" (red).
- Indicators, from the sessions of `store.sessions` whose `ticketID` is the ticket: `hand.raised.fill` (orange) when one
  is `waitingPermission`, else `sparkles` (accent color) when one is `starting` or `running`; then `bubble.left` and
  the comment count when the ticket has comments.
- Context menu: Status ▸ the four statuses (current checked), calling `updateTicket(projectID:ticketID:patch:)` with
  `TicketPatch(status:)`; New Bundle from Selection… (the selected tickets, or this ticket when it is not selected); Add
  to Bundle ▸ (as in Multi-selection, for the same tickets); Copy ID; Delete… ([Delete a ticket](#delete-a-ticket)). A
  broken ticket has only Copy ID and Delete….

### Empty states

| Condition                                      | Content                                                               |
|------------------------------------------------|-----------------------------------------------------------------------|
| the project has no ticket                      | "No tickets yet" and a "New Ticket" button                            |
| the filter hides every ticket and every bundle | "No matching tickets" and a "Clear Filter" button (restores defaults) |
| regular width, no ticket selected              | the detail area shows "Select a ticket"                               |
| the selected id is not in the store            | the detail area shows "<ID> was deleted."                             |

## New ticket (⌘N)

`NewTicketSheet` creates a ticket in the selected project.

| Field       | Control                                               | Default | Rule                              |
|-------------|-------------------------------------------------------|---------|-----------------------------------|
| Name        | text field                                            | empty   | required; trimmed; no line breaks |
| Description | `TextEditor`, monospaced body font, min height 120 pt | empty   | optional; Markdown                |
| Status      | picker, each choice drawn as its `TicketStatusBadge`  | To Do   |                                   |

- Name: when the trimmed name holds a line break, the sheet shows "Use a single line." in red under the field.
- Buttons: Cancel (Escape) and Create (⌘↩, default action), enabled when the name is valid and no request is in flight.
  Create carries the default action; a twin Create button with ⌘↩ sits behind it, invisible (opacity 0) and hidden
  from accessibility, with the same action and the same enabled state.
- Create calls `createTicket(projectID:name:description:status:)`; `description` is nil when empty after trimming, else
  the text as typed. Success: the sheet dismisses itself, the window selects the new ticket (`selection.item`), the
  detail shows the Details segment. Failure: the message shows in red; the sheet stays open.
- Opened by the New Ticket buttons and by ⌘N: the menu item File ▸ New Ticket (⌘N) of the shell's commands
  ([shell.md](shell.md)) calls `FocusedValues.newTicketAction`, which `TicketsView` publishes with `.focusedSceneValue`
  while it is shown. In other sections, and while the Main is not connected, the value is nil and the menu item is
  disabled.

## Bundles

A bundle groups tickets that Claude works on in parallel ([../services/bundles.md](../services/bundles.md)). The
requests are `createBundle`, `updateBundle`, `deleteBundle`, `startBundle` and `stopBundle` of `store.connection`
([../client/workspace.md](../client/workspace.md#functions)), through `banners.perform` outside the sheets.

### Bundle row

- Line 1: the id (monospaced, caption, secondary); trailing, `sparkles` (accent color) when the coordinator or a ticket
  session of the bundle is `starting` or `running`, `hand.raised.fill` (orange) when one is `waitingPermission` (both
  can show), then the `BundleStatusBadge`.
- Line 2: the name (body, up to 2 lines).
- Line 3 (caption, secondary): "<d> of <n> done", `d` the tickets of the bundle whose status is `done`.
- Context menu: Work on Bundle (`draft`) or Stop (`running`, `review`); Copy ID; Delete… (`draft`, `done`).

### New bundle sheet

`NewBundleSheet` creates a bundle from the given tickets.

- Title "New Bundle"; a Name field (required, trimmed, one line: "Use a single line." in red as in the New Ticket
  sheet), then the tickets, in ticket number order: id (monospaced) and name, each with a remove button (`minus.circle`)
  while more than one remains.
- Buttons: Cancel (Escape) and Create (⌘↩, default action), with the twin ⌘↩ button of the New Ticket sheet; Create is
  enabled when the name is valid and no request is in flight.
- Create calls `createBundle(projectID:name:ticketIDs:)`. Success: the sheet dismisses itself, the Select mode ends,
  `selectedIDs` is emptied and `selection.item` is the new bundle (it reaches the store through `bundle.changed`,
  [../client/workspace.md](../client/workspace.md#conventions)). Failure: the message shows in red; the sheet stays
  open.

### Bundle detail

`BundleDetailView` shows the bundle `selection.item` names.

- Header: the id (monospaced, selectable); the name, a plain text field that commits like the ticket name (`.title2`
  semibold, `BundlePatch(name:)`); the `BundleStatusBadge`; "Created <date>" · "Updated <relative time>" as for a
  ticket; the actions menu `ellipsis.circle` with Add Tickets… (`draft`), Copy ID and Delete Bundle… (`draft`, `done`).
- Buttons under the header: "Work on Bundle" (`play.fill`, `.borderedProminent`) in `draft`, calling `startBundle`;
  "Stop" (`stop.fill`) in `running` and `review`, calling `stopBundle`; "Open Coordinator" when `coordinatorSessionID`
  is set, which calls `context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section:
  .claude, item: <coordinatorSessionID uuidString>)`.
- A caption (secondary) by status: `running` "Claude works on the tickets in parallel and reports in the coordinator's
  session."; `review` "The coordinator waits for your agreement in its session."; `done` "The work of this bundle was
  brought in."; none in `draft`.
- Tickets, in the bundle's order. Each row: the id (monospaced), the name (a deleted ticket: "Deleted ticket",
  secondary), its `TicketStatusBadge`, and, when its `sessionID` names a session of the store, its
  `SessionStatusIndicator` and an "Open Session" button that navigates to section `.claude` with that session. Choosing
  a row navigates to section `.tickets` with the ticket id. In `draft`, rows can be reordered (`onMove`) and have the
  context menu item "Remove from Bundle", disabled while the bundle has one ticket; both call `updateBundle` with
  `BundlePatch(ticketIDs:)`. In the other statuses the ticket list cannot be changed; a `done` bundle can still be
  renamed and deleted.
- Delete Bundle…: a confirmation "Delete <ID>?" with the message "Its worktrees are removed, and the branches whose
  work was brought in are deleted. Its tickets and sessions are kept." and the buttons Delete (destructive) and Cancel;
  Delete calls `deleteBundle`; after success `selection.item` is cleared.

### Add tickets sheet

`AddBundleTicketsSheet`: title "Add Tickets to <ID>", a search field (the ticket filter's text rule), then the project's
tickets that are not broken and not in the bundle, by ticket number, each a row with a checkmark when chosen. Buttons:
Cancel (Escape) and Add (⌘↩, default action, twin ⌘↩ button), enabled when a ticket is chosen. Add calls `updateBundle`
with `BundlePatch(ticketIDs:)`: the bundle's tickets, then the chosen ones by ticket number. Success dismisses the
sheet; failure shows the message in red.

## Ticket detail

### Header

- Id: monospaced, selectable.
- Segment: a `Picker` with `.segmented` style, Details and Claude. Regular width: trailing in the header's first row.
  Compact width: the navigation bar's principal item.
- Actions: a menu `ellipsis.circle` with Copy ID and Delete Ticket….
- Name: a plain text field, `.title2` semibold. It commits on Return or when it loses focus, with
  `updateTicket(projectID:ticketID:patch:)` and `TicketPatch(name:)`; the name is trimmed; a name that is empty or holds
  a line break is not sent and the field reverts; Escape (`.onKeyPress(.escape)`, and `.onExitCommand` on macOS)
  reverts; the header disappearing commits like a focus loss. While it has focus, incoming changes do not replace its
  text.
- Status: a `Menu` whose label is the `TicketStatusBadge`; its items are the four statuses (current checked) and send
  `TicketPatch(status:)`. The badge shows the chosen status at once and returns to the stored status when the request
  fails. The Main also sets the status itself: In Progress when a Claude session of the ticket starts a turn, Review
  when it ends its turn, stops or fails. A feedback ticket stays To Do while its feedback session works, stays In
  Progress when the turn of a session implementing it ends, and goes to Review when the regeneration holding its fix is
  pushed ([../services/host.md](../services/host.md#81-status-of-a-ticket-while-its-sessions-work)); only the user sets
  Done.
- Dates: "Created <date>" (abbreviated date, shortened time) · "Updated <relative time>" (refreshed every minute; the
  absolute date in the help tag).

The segment is Details when a ticket gets selected. It switches to Claude after a session is started from the
[new session sheet](#new-session-sheet). In compact width, the Claude segment hides the header and the navigation title
is the ticket id; in the Details segment the header scrolls with the content.

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
  Save sends `TicketPatch(description:)` (an empty text is sent as `""`). Success: view mode. Failure: the error banner;
  edit mode stays.
- When the stored description changes while editing (it differs from the text at the start of the edit), a notice
  shows above the editor: "The description was changed on another device." with a "Use Theirs" button that replaces
  the editor text with the stored description and makes it the new base. Save always sends the editor text.

### Broken ticket

The detail of a broken ticket shows the id, "This ticket file cannot be read.", the parse error (monospaced,
selectable), the file path `.hephaestus/tickets/<ID>.yml` and a "Delete Ticket…" button. It has no segment, no comments
and no composer.

## Comments

### Rendering

A "Comments" header with the count, then `ticket.comments` (oldest first). Each `TicketComment` shows:

- Author: `sparkles` and "Claude" when the author is "Claude"; otherwise `person.crop.circle` and the author.
- Time: the relative creation time (absolute in the help tag); "· edited" when `edited` is set (the edit date in its
  help tag).
- Body: the HephMarkdown view, with the link rules of the description.
- Attachments, under the body in a wrapping flow. A `TicketAttachment` whose `type` starts with `image/` is an image
  thumbnail of [media.md](media.md), at most 240 × 180 pt, that opens the zoomable image viewer. Any other is an
  attachment chip of [media.md](media.md) (name and size) that opens Quick Look after download. Both download the file
  with `downloadAttachment(projectID:ticketID:fileName:size:progress:)` on `store.connection`
  ([../client/workspace.md](../client/workspace.md#transfers)) into the device's attachment cache, show the download
  progress, and show the error with a Retry button when it fails ([media.md](media.md#loading-and-caching)); the
  `cacheKey` is "<projectID>/<ticketID>/<file>". Attachments have no size limit.
- Actions: a menu (`ellipsis`; on macOS shown while the pointer is over the comment) and the context menu, both with
  the same items. A comment written from a device has Edit and Delete…. A comment whose `author` is "Claude" (made
  through the MCP tools) has Delete… only: Claude's comments cannot be edited
  ([../protocol/methods.md](../protocol/methods.md#ticketsupdatecomment)).

When a comment arrives while the comments are scrolled to the bottom, the view scrolls to show it.

### Editing and deleting

- Edit (comments of devices only): the body is replaced by a `TextEditor` (monospaced body font, min height 80 pt)
  with Cancel and Save; ⌘↩ saves and Escape cancels while the editor has keyboard focus
  ([Keyboard shortcuts](#keyboard-shortcuts)). Save calls `updateComment(projectID:ticketID:commentID:body:)`; it is
  disabled when the trimmed text is empty and the comment has no attachment. Attachments cannot be changed; the comment
  keeps its author.
- Delete… (every comment, Claude's included): a confirmation "Delete this comment?" with the message "Its attached
  files are deleted too. This cannot be undone." and the buttons Delete (destructive) and Cancel. Delete calls
  `deleteComment(projectID:ticketID:commentID:)`.

### Composer

The comment composer is `MessageComposer` ([sessions.md](sessions.md#message-composer)) with the placeholder "Add a
comment", `mainDeviceID: store.mainDeviceID`, `projectID: store.projectID` and no Stop action. Its attachments come
from the pickers of [media.md](media.md#attachment-picking) (file importer, drag and drop, paste, Photos picker on iOS
and iPadOS), as in every `MessageComposer`: each one uploads at once, with a progress bar and a Cancel button in its
chip, and Send waits until every upload is complete. Send calls `addComment(projectID:ticketID:body:attachments:)` with
the trimmed text and `draft.uploads`. Success clears the draft; failure keeps it, with its uploads.

## Delete a ticket

From the detail's actions menu, the row's context menu and the broken-ticket detail. Confirmation dialog: title "Delete
<ID>?", message "“<name>” and its attachments are deleted. This cannot be undone." (a broken ticket: "The file
.hephaestus/tickets/<ID>.yml is deleted. This cannot be undone."), buttons Delete (destructive) and Cancel. Delete calls
`deleteTicket(projectID:ticketID:)`. The ticket's sessions are kept. After success, `selection.item` is cleared when it
was this ticket.

## Claude segment

`TicketClaudeView` shows the Claude sessions of the ticket: the sessions of `store.sessions` with kind `ticket` and
`ticketID` equal to the ticket id, in the store's order (by `created`).

- Tab strip (horizontal scroll): one tab per session, with `SessionStatusIndicator(status:)`, the status indicator of
  [sessions.md](sessions.md#labels) (this screen has no copy of it), and the title (one line, at most 200 pt wide).
  The selected tab is highlighted. A trailing `plus` button opens the [new session sheet](#new-session-sheet). Tab
  context menu: the session context menu of [sessions.md](sessions.md#session-context-menu).
- Selected tab: remembered per ticket while `TicketsView` exists; by default the session with the latest `updated`. A
  session started elsewhere (another device, or Claude through `start_ticket_session`) adds a tab that is not selected.
  When the selected session is removed, the tab on its left is selected, or the first tab.
- Content: `SessionView(store:sessionID:showsTicketLink: false)` ([sessions.md](sessions.md#session-view)). macOS: the
  session's header (title, context, capsules, options menu) is in the window's toolbar while the segment shows it
  ([sessions.md](sessions.md#header)); the ticket header and the tab strip stay above the transcript.
- No session: "No Claude session for this ticket yet." and a "New Session…" button.

### New session sheet

`NewTicketSessionSheet` starts a ticket session.

- Title "New Claude Session for <ID>".
- Mode: five selectable rows (checkmark on the chosen one), each with the mode's `displayName` and a description;
  default Implement.

| `SessionMode` | Description                                                                          |
|---------------|--------------------------------------------------------------------------------------|
| `implement`   | Implement the ticket, keep the docs in sync, build and test, and comment a summary.  |
| `debug`       | Find the root cause, explain it, and propose or apply a fix after your confirmation. |
| `review`      | Review the work done for the ticket and comment the findings.                        |
| `plan`        | Write a plan as a comment, without changing code.                                    |
| `custom`      | Follow your instructions.                                                            |

- Custom adds an "Instructions" `TextEditor` (min height 100 pt); it is required (not empty after trimming).
- Buttons: Cancel (Escape) and Start (⌘↩, default action), with the twin ⌘↩ button of the New Ticket sheet.
- Start calls `startSession(projectID:kind: .ticket, ticketID:mode:title: nil, message:permissionMode: nil, model:
  nil)`; `message` is the trimmed instructions for Custom, nil otherwise. The Main titles the session ("<mode> <ticket
  id>"), builds the first message and starts Claude at once
  ([../protocol/methods.md](../protocol/methods.md#sessionsstart), [../claude/prompts.md](../claude/prompts.md)).
- Success: the sheet dismisses itself, the new session's tab is selected and the segment switches to Claude. Failure:
  the message shows in red; the sheet stays open.

## Status style

Titles are `TicketStatus.displayName` ([../protocol/types.md](../protocol/types.md#ticketstatus)). `TicketStatusStyle`
gives the symbol and the tint, used everywhere a status is drawn (the Tickets screen, the Overview counts).

| `TicketStatus` | Symbol                   | Tint   |
|----------------|--------------------------|--------|
| `todo`         | `circle`                 | gray   |
| `inProgress`   | `circle.lefthalf.filled` | blue   |
| `review`       | `eye.circle`             | orange |
| `done`         | `checkmark.circle.fill`  | green  |

`TicketStatusBadge` draws a capsule: symbol and title in the tint color, caption font, the tint at 15 % opacity as
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
| ⌘N       | Tickets section shown                                                                      | open the New Ticket sheet |
| ⌘↩       | the comment composer, the focused description or comment editor, the sheets of this screen | send, save, create, start |
| Escape   | the focused description or comment editor, sheets                                          | cancel                    |

- The description editor and a comment editor handle ⌘↩ (Save) and Escape (Cancel) only while their `TextEditor` has
  keyboard focus (`@FocusState`). The `TextEditor` carries `.onKeyPress(.return, phases: .down)`, which saves and
  returns `.handled` when the press's `modifiers` contain `.command` and returns `.ignored` otherwise, and
  `.onKeyPress(.escape)`, which cancels and returns `.handled`. Their Save and Cancel buttons have no
  `.keyboardShortcut`.
- The composer's ⌘↩ is handled by `ComposerTextView` ([sessions.md](sessions.md#message-composer)).
- Only the sheets (New Ticket, New Session, New Bundle, Add Tickets) put keyboard shortcuts on their buttons.

## Swift API

All views are `@MainActor`. They read the `Workspace`, the window's `WindowContext` and its `WindowBanners` from the
environment.

```swift
/// The Tickets section of the project held by `store`.
public struct TicketsView: View {
    public init(store: ProjectStore)
}

/// Capsule with the status symbol and `displayName`.
public struct TicketStatusBadge: View {
    public init(status: TicketStatus)
}

/// The same capsule for a bundle status.
public struct BundleStatusBadge: View {
    public init(status: BundleStatus)
}

public enum TicketStatusStyle {
    public static func symbolName(_ status: TicketStatus) -> String
    public static func tint(_ status: TicketStatus) -> Color
}

/// Published by TicketsView with .focusedSceneValue; bound to File ▸ New Ticket (⌘N) by the shell's commands.
public struct NewTicketActionKey: FocusedValueKey {
    public typealias Value = () -> Void
}

extension FocusedValues {
    public var newTicketAction: (() -> Void)? { get set }
}
```

`TicketsView` ends its file with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

- [../client/workspace.md](../client/workspace.md): `MainConnection` request functions, `ProjectStore` (`mainDeviceID`,
  `projectID`, `tickets`, `bundles`, `sessions`, `connection`), `Selection` (`item`).
- [../services/bundles.md](../services/bundles.md): what a bundle does; `BundleItem`, `BundleStatus` and `BundlePatch`
  in [../protocol/types.md](../protocol/types.md).
- [../protocol/types.md](../protocol/types.md): `TicketItem` (with `parseError`), `TicketComment`, `TicketAttachment`,
  `TicketStatus`, `TicketPatch`, `UploadRef`, `SessionInfo`, `SessionMode`, `SessionKind`.
- [../protocol/methods.md](../protocol/methods.md): `tickets.*`, `attachments.read`, `uploads.*`, `tabs.open`,
  `sessions.start`. [../client/workspace.md](../client/workspace.md#transfers): `downloadAttachment`, `upload`.
- [sessions.md](sessions.md): `MessageComposer`, `SessionView`, `SessionStatusIndicator`, session context menu.
- [markdown.md](markdown.md): HephMarkdown view. [media.md](media.md): image thumbnail, zoomable image viewer,
  attachment chip, Quick Look, attachment pickers. [web.md](web.md): the Web section showing a tab.
- [shell.md](shell.md): `WindowContext` (`navigate`), `WindowBanners` (`perform`), File ▸ New Ticket menu item.
