# Runs screen

files:
- HephaestusKit/Sources/HephClient/RunOutputModel.swift
- HephaestusKit/Sources/HephUI/Runs/RunsView.swift
- HephaestusKit/Sources/HephUI/Runs/RunConfigurationRow.swift
- HephaestusKit/Sources/HephUI/Runs/RunConfigurationSheet.swift
- HephaestusKit/Sources/HephUI/Runs/RunHistoryRow.swift
- HephaestusKit/Sources/HephUI/Runs/RunConsoleView.swift
- HephaestusKit/Sources/HephUI/Runs/ConsoleTextView.swift

---

The Runs section (⌘7) edits the run configurations of the selected project (`runs` of `project.yml`,
[../data/project-yml.md](../data/project-yml.md)), starts and stops runs, lists the recent runs and shows their
output. The Main executes runs ([../services/runs.md](../services/runs.md)).

Requests use the request functions of the project's `MainConnection` (`store.connection`,
[../client/workspace.md](../client/workspace.md#request-api)), run through `banners.perform` of the window's
`WindowBanners` (`@Environment(WindowBanners.self)`, [shell.md](shell.md#81-windowbanners)), which shows a failure as
an error banner. Sheets call the functions directly and show a failure's message in red above their buttons. The
screen observes the `ProjectStore` (`project.runs`, `runs`), which the Workspace keeps current from `project.changed`
and `run.changed`. The window's selection is the `Selection` of its `WindowContext`
([shell.md](shell.md#52-windowcontext)). While the project's Main is not connected, every control that sends a request
is disabled, and so is every control that opens a sheet or a confirmation dialog whose button sends one.

## Layout

| Width class     | Layout                                                                                |
|-----------------|---------------------------------------------------------------------------------------|
| regular, macOS  | `HSplitView`: list (min 260, ideal 320, max 480 pt), console                          |
| regular, iPadOS | `HStack(spacing: 0)`: list (320 pt), `Divider`, console                               |
| compact         | `NavigationStack` rooted at the list; the console is pushed ([Selection](#selection)) |

The list is one `List` with two sections, Configurations then History.

## Selection

While the Runs section is shown, `selection.item` is the name of the selected run configuration
([../client/workspace.md](../client/workspace.md#selection)). `RunsView` also keeps `selectedRunID` (view state, not
stored in the selection). The console shows:

1. the run `selectedRunID` when it is in `store.runs` and its `name` equals `selection.item`;
2. else the most recent run (latest `startedAt`) of `store.runs` whose `name` equals `selection.item`;
3. else nothing ([Console](#console) states).

| Action                          | `selection.item`         | `selectedRunID`       |
|---------------------------------|--------------------------|-----------------------|
| choose a configuration row      | its name                 | nil                   |
| choose a history row            | the run's `name`         | the run's id          |
| Run (row button, Run Again)     | the configuration's name | the returned run's id |

In compact width the console is pushed with `navigationDestination(item:)` on a binding over `selection.item`; Back
sets `selection.item` and `selectedRunID` to nil. Choosing a row, Run and Run Again push it; an item set from
elsewhere, or already set when the section appears, pushes it at once.

## Configurations

Rows come from `store.project?.runs` (`RunConfig {name, command, cwd?}`), in file order.

| Part     | Content                                                                                        |
|----------|------------------------------------------------------------------------------------------------|
| line 1   | name (headline)                                                                                |
| line 2   | command (monospaced, caption, secondary, one line, truncated at the tail)                      |
| line 3   | "in <cwd>" (caption, secondary), only when `cwd` is set and is not `.`                         |
| trailing | Run button (`play.fill`) when no run with this name is `running`, else Stop (`stop.fill`, red) |

- Context menu: Run or Stop, Edit…, Delete…. A double click on a row (macOS) also opens Edit… while the Main is
  connected.
- Section header: "Configurations" and a `plus` button that opens the editor for a new configuration.
- No configuration: "No run configurations" and a "New Configuration…" button.

### Configuration editor

`RunConfigurationSheet` creates or edits one configuration, in the sheet layout of
[sessions.md](sessions.md#options-menu) (`EditSheetLayout`).

| Field             | Control                                 | Rule                                                     |
|-------------------|-----------------------------------------|----------------------------------------------------------|
| Name              | text field                              | required; trimmed; no line breaks; unique in the project |
| Command           | text field, monospaced, 1–6 lines       | required (not empty after trimming)                      |
| Working directory | text field, monospaced, placeholder "." | optional; relative to the project root                   |

- Name uniqueness ignores case and the edited configuration itself. Working directory: no leading `/`, no empty, `.`
  or `..` component; `.` alone is accepted.
- Messages under the fields: "Use a single line." (the trimmed name holds a line break), "A configuration named
  “<name>” already exists.", "The working directory must be inside the project." A name has no maximum length.
- Footer text: "The command runs with /bin/zsh -lc on <Main name>, with your login environment."
- Buttons: Cancel (Escape) and Save (⌘↩, default action); Save is enabled when every rule passes and no request is in
  flight.
- Save builds the new list from the current `store.project?.runs`: a new configuration is appended; an edited one
  replaces the configuration that has its original name, or is appended when that name is no longer listed. The name
  and the working directory are saved trimmed (`cwd` is nil when the field is empty after trimming), the command as
  typed. It calls `updateProject(projectID:patch:)` with `ProjectPatch(runs:)`; the list replaces the stored one.
  Success dismisses the sheet (an edited configuration that was selected stays selected under its new name); failure
  shows the message.
- Delete…: confirmation "Delete “<name>”?" with the message "Runs already started keep running." and the buttons Delete
  (destructive) and Cancel; Delete sends `ProjectPatch(runs:)` with the list without it. The selection is left as it
  is: the console keeps showing the runs of that name.

### Run and Stop

- Run calls `startRun(projectID:name:)` and selects the returned run ([Selection](#selection)); compact width pushes
  the console.
- Stop calls `stopRun(projectID:runID:)` for every `running` run with that name.
- While the request runs, the button shows a small `ProgressView`.

## History

Rows come from `store.runs` (the Main keeps the last 20 runs of the project in memory), newest `startedAt` first. A
running run's context menu has Stop.

| Part    | Content                                                                                    |
|---------|--------------------------------------------------------------------------------------------|
| leading | state badge                                                                                |
| line 1  | name; trailing: duration                                                                   |
| line 2  | relative start time, then " · exit <exitCode>" when `exitCode` is set (caption, secondary) |

| `RunState`  | Badge                         | Title     |
|-------------|-------------------------------|-----------|
| `running`   | small `ProgressView`          | Running   |
| `succeeded` | `checkmark.circle.fill` green | Succeeded |
| `failed`    | `xmark.circle.fill` red       | Failed    |
| `stopped`   | `stop.circle.fill` secondary  | Stopped   |

- Duration: `endedAt − startedAt`; while running, now − `startedAt`, refreshed every second
  (`TimelineView(.periodic(from: .now, by: 1))`). Format: `.time(pattern: .minuteSecond)` under one hour,
  `.time(pattern: .hourMinuteSecond)` from one hour.
- No run: "No runs yet".

## Console

`RunConsoleView` shows the chosen run ([Selection](#selection)): a header, then `ConsoleTextView` filling the rest.

Header:

- Line 1: the run name (headline), the state badge and title, " · exit <exitCode>" when set.
- Line 2: the command (monospaced, secondary, selectable, one line).
- Line 3: "Started <date and time> · <duration>".
- Buttons: Stop (while running) or Run Again (when a configuration with that name exists and none of its runs is
  running); Auto-scroll toggle (`arrow.down.to.line`, on by default); Copy (`doc.on.doc`, copies the console text to
  the pasteboard); Clear (`eraser`).

Behavior:

- Clear empties this view only (`RunOutputModel.clear()`). Later output is appended. The Main's output is unchanged:
  showing the run again shows all of it.
- Auto-scroll on: after each change the view scrolls to the end. Off: the scroll position stays.
- No configuration selected (regular width), or a selected name that names no configuration and no run: "Select a run
  configuration". A configuration without runs: "“<name>” has not run yet." and a Run button.
- The console creates a `RunOutputModel` for the shown run, calls `appear()` in `onAppear` and `disappear()` in
  `onDisappear`, and replaces it when the shown run changes. Phase `loading`: a `ProgressView` over the empty console;
  `failed(message)`: the message and a "Retry" button that calls `reload()`.

### Console text view

`ConsoleTextView(model:autoScroll:)` wraps the platform text view.

- macOS: a read-only, selectable `NSTextView` in an `NSScrollView`; font `monospacedSystemFont(ofSize: 12, weight:
  .regular)`; lines wrap; text container inset 8 pt; background `textBackgroundColor`.
- iOS and iPadOS: a `UITextView` with `isEditable = false`, `isSelectable = true`, the same font, wrapping, 8 pt
  insets, background `systemBackground`.
- Updates: when `model.generation` differs from the last applied one, the whole text is replaced; otherwise the text
  after the last applied UTF-16 length is appended to the text storage. Then, with auto-scroll on, the view scrolls to
  the end.

## RunOutputModel

`HephaestusKit/Sources/HephClient/RunOutputModel.swift` holds `RunOutputModel` (`@MainActor @Observable`),
`RunOutputCenter` (`@MainActor`) and `ANSIStripper` (a `Sendable` struct, unit-tested). One model per console view and
run. The model gets the `run.output` payloads of its run and the reconnections of its Main from
`workspace.runOutputCenter` ([RunOutputCenter](#runoutputcenter)).

1. `appear()` (once until `disappear()`): the model registers with `workspace.runOutputCenter`; a task awaits
   `workspace.subscribe(.run(runID), on: mainID)`, keeps the `TopicSubscription`, then loads (step 2).
2. Load: phase `loading`; `runOutput(projectID:runID:)` → `RunsOutputResult {text, seq}`. Result: the stripper is
   reset; `text` = the stripped result text; `generation` + 1; the kept payloads whose `seq` is greater than the
   result's `seq` are appended in `seq` order and the kept payloads are dropped; `lastSeq` = the highest `seq`
   applied, the result's included; phase `loaded`. Failure: phase `failed(message)`; for `notFound` the message is
   "This run is no longer available."; the kept payloads stay.
3. Live: the center passes each `run.output` payload of the run. In phase `loaded`, a payload whose `seq` is greater
   than `lastSeq` is appended (`text` += the stripped text, `lastSeq` = its `seq`) and the others are ignored
   ([../protocol/events.md](../protocol/events.md#runoutput)); in any other phase the payload is kept for the next
   load.
4. `mainDidConnect` of the run's Main (from the center), and `reload()`: load again (step 2). After a reconnection the
   Workspace has already subscribed again ([../client/workspace.md](../client/workspace.md#subscriptions)).
5. `disappear()`: cancels the task and the subscription; the model unregisters from the center.
6. `clear()`: `text` = ""; `generation` + 1; `lastSeq` unchanged.

When `text` holds more than 5,500 lines, the first lines are removed to keep the last 5,000, and `generation` + 1.

### ANSI stripping

`ANSIStripper` cleans the output, chunk by chunk (ESC = 0x1B). It removes:

- CSI sequences: ESC `[`, any parameter bytes 0x30–0x3F, any intermediate bytes 0x20–0x2F, a final byte 0x40–0x7E.
- OSC sequences: ESC `]` up to BEL (0x07) or ESC `\`.
- DCS, SOS, PM and APC strings: ESC `P`, `X`, `^` or `_` up to ESC `\`.
- Any other escape sequence: ESC, any intermediate bytes 0x20–0x2F, a final byte 0x30–0x7E.
- C0 control characters (0x00–0x1F) other than TAB, LF and CR, and DEL (0x7F).

It turns CR LF into LF, and a CR not followed by LF into LF. A sequence, or a CR, cut by the end of a chunk stays
pending and is completed with the next chunk; a pending sequence longer than 256 characters is dropped.

## RunOutputCenter

`RunOutputCenter` delivers the `run.output` payloads and the reconnections to the live `RunOutputModel`s. One
`RunOutputCenter` per `Workspace`, created by `Workspace.init` with `init(workspace:)` (it keeps a weak reference to
the Workspace) and used as `workspace.runOutputCenter` ([../client/workspace.md](../client/workspace.md#events)).

- It keeps the registered models by (Main, run), as weak references. A model registers in `appear()` and unregisters
  in `disappear()`.
- `handleRunOutput(mainDeviceID:projectID:runID:text:seq:)`, called by the Workspace for every `run.output` of a Main:
  the models of that Main and run get the payload ([RunOutputModel](#runoutputmodel) step 3).
- `mainDidConnect(_:)`, called by the Workspace after each handshake with a Main: every model of that Main loads again
  (step 4).

## Swift API

```swift
/// The Runs section of the project held by `store`. @MainActor; reads the Workspace, the window's WindowContext and
/// its WindowBanners from the environment.
public struct RunsView: View {
    public init(store: ProjectStore)
}

@MainActor
public final class RunOutputCenter {
    public init(workspace: Workspace)                       // by Workspace.init; weak reference to it
    public func handleRunOutput(mainDeviceID: UUID, projectID: String, runID: UUID, text: String, seq: Int)
    public func mainDidConnect(_ mainDeviceID: UUID)
    func register(_ model: RunOutputModel)                  // RunOutputModel.appear()
    func unregister(_ model: RunOutputModel)                // RunOutputModel.disappear()
}

@MainActor @Observable
public final class RunOutputModel {
    public enum Phase: Equatable, Sendable { case idle, loading, loaded, failed(String) }

    public init(workspace: Workspace, mainID: UUID, projectID: String, runID: UUID)
    public let mainID: UUID
    public let projectID: String
    public let runID: UUID
    public private(set) var text: String
    public private(set) var generation: Int
    public private(set) var phase: Phase

    public func appear()
    public func disappear()
    public func reload() async
    public func clear()
}

public struct ANSIStripper: Sendable {
    public init()
    public mutating func strip(_ chunk: String) -> String
}
```

`RunsView` ends its file with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

- [../client/workspace.md](../client/workspace.md): `Workspace` (`subscribe(_:on:)`, `TopicSubscription`,
  `runOutputCenter`, the `run.output` forwarding and the `mainDidConnect` calls), `MainConnection` request functions
  (`runOutput` returning `RunsOutputResult`), `ProjectStore` (`project`, `runs`, `connection`), `Selection`.
- [../protocol/types.md](../protocol/types.md): `RunConfig`, `RunInfo`, `RunState`, `ProjectPatch`.
- [../protocol/methods.md](../protocol/methods.md): `runs.*` (`RunsOutputResult`), `projects.update`.
  [../protocol/events.md](../protocol/events.md): `run.changed`, `run.output` (`RunOutputPayload`, `seq`).
  [../protocol/envelope.md](../protocol/envelope.md): `Topic`.
- [../services/runs.md](../services/runs.md): run execution and output buffer.
- [shell.md](shell.md): `WindowContext`, `WindowBanners` (`perform`).
