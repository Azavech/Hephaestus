# Forge screen

files:
- HephaestusKit/Sources/HephClient/ForgeModel.swift
- HephaestusKit/Sources/HephUI/Forge/ForgeView.swift
- HephaestusKit/Sources/HephUI/Forge/ForgePipelineSection.swift
- HephaestusKit/Sources/HephUI/Forge/UpdateStatusView.swift

---

The Forge section (workspace section of the sidebar, [shell.md](shell.md)) shows the Forge pipeline of
[../forge/pipeline.md](../forge/pipeline.md), the docs hashes, CI, the latest release, the versions of the devices and
the update status of this device. `ForgeModel` is the client-side mirror of the Forge; the screen, the feedback sheet
([../forge/feedback.md](../forge/feedback.md)) and, on macOS, the self-update ([../forge/update.md](../forge/update.md))
use it.

## ForgeModel

`HephaestusKit/Sources/HephClient/ForgeModel.swift`, a `@MainActor @Observable` class like `SessionCenter`
([sessions.md](sessions.md#sessioncenter)). One `ForgeModel` per `Workspace`, created by the Workspace (the model keeps
a weak reference to it) and exposed as `workspace.forge` ([../client/workspace.md](../client/workspace.md)). Views reach
it through the `Workspace` of their environment. On macOS the shell sets `releaseObserver` at launch so that
`UpdateService.releaseNoticed(build:)` is called ([shell.md](shell.md),
[../forge/update.md](../forge/update.md#schedule)).

### Forge host

- `forgeConfigs`: for each connected Main whose Forge is enabled, its `ForgeConfig`, learned from `host.info`
  (`forge` set) and from `forge.changed` (`enabled`).
- `forgeHostIDs`: the Mains of `forgeConfigs`, in `workspace.mains` order (by name, then id); a Forge host that is not
  in `workspace.mains` comes after them, by `uuidString`.
- `forgeHostID`: the first of them, nil when there is none. Feedback, Regenerate Now and Retry go to it.
- `state`: the last `ForgeState` received from `forgeHostID`; nil when there is no Forge host or it has not answered
  yet.

### Inputs

| Call                    | Made by                                                                  | Effect                                                                                                                                                                                                                                                                                                                                 |
|-------------------------|--------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `mainDidConnect(_:)`    | the Workspace, when a connection to a Main completes its handshake       | `hostInfo()` on that connection; `forge` set: the Main enters `forgeConfigs`, else leaves it; then, when `forgeHostID` is not the host of `state`, `state` = nil and `refresh()`                                                                                                                                                       |
| `mainDidDisconnect(_:)` | the Workspace, when a connection to a Main is lost                       | the Main leaves `forgeConfigs`; when it was the host of `state`, `state` = nil, then `refresh()` when another Forge host remains                                                                                                                                                                                                       |
| `apply(_:from:)`        | the Workspace, for every `forge.changed`, with the sending Main's id     | `enabled`: `forgeConfigs[from]` = `config`; not enabled: removed. When `from` is `forgeHostID` (after that update), `state` = the state; when `from` is the host of `state` and was removed, `state` = nil, then `refresh()` when another Forge host remains. When the state has a `latestRelease`, `releaseObserver` gets its `build` |
| `refresh()`             | the Forge screen when it appears; the calls above                        | `forgeStatus()` on the connection of `forgeHostID`, then `apply`. `isLoading` is true meanwhile; a failure sets `loadError` to the error's message, cleared by the next success. No Forge host: `state` = nil                                                                                                                          |

### Requests

Sent with the request API of the `MainConnection` of `forgeHostID` ([../client/workspace.md](../client/workspace.md));
without a Forge host they throw `ProtocolError(.unavailable, "No Forge is online.")`. When the screenshot upload of
`sendFeedback` fails with `notFound` (the Forge host hosts no project `<ID>`: its `uploads.begin` answers
`notFound` before the Forge's own configuration checks run,
[../forge/pipeline.md](../forge/pipeline.md#registering-the-source-project)), `sendFeedback` sends no
`forge.feedback` and throws `ProtocolError(.notFound, "The Forge on <Forge host name> has no source project <ID> yet.
Its Forge screen says what is missing.")`: `<Forge host name>` is the `name` of the Forge host's connection, as
[../forge/feedback.md](../forge/feedback.md#content) names a Main, and `<ID>` the `sourceProjectID` of
`forgeConfigs[forgeHostID]`. Other upload errors are rethrown as they are.

| Function                                             | Connection call                                                                                                                                                                                                                                                                              | Method                        |
|------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|
| `regenerate()`                                       | `regenerate()`, then `refresh()`                                                                                                                                                                                                                                                             | `forge.regenerate`            |
| `retry(itemTaskID:)`                                 | `retryForge(itemTaskID:)`, then `refresh()`                                                                                                                                                                                                                                                  | `forge.retry`                 |
| `sendFeedback(screenshot:comment:context:progress:)` | with a screenshot, `upload(fileName: "screenshot.png", projectID: <sourceProjectID of forgeConfigs[forgeHostID]>, source: .data(<PNG>), progress:)` ([../client/workspace.md](../client/workspace.md#transfers)); then `sendFeedback(screenshot: <its UploadRef, or nil>, comment:context:)` | `uploads.*`, `forge.feedback` |

## Screen

`ForgeView()` is the content of the Forge section. It reads the `Workspace`, the window's `WindowContext`
([shell.md](shell.md#52-windowcontext)), whose `selection` is the window's `Selection`, and the window's
`WindowBanners` ([shell.md](shell.md#81-windowbanners)) from the environment, uses `workspace.forge`, and calls
`forge.refresh()` in `.task`. It is a `Form` with `.formStyle(.grouped)` on every platform, with these sections, in
order:

| Section        | Shown                                        |
|----------------|----------------------------------------------|
| Forge          | always                                       |
| Docs Hashes    | always                                       |
| Pipeline       | when `forgeHostID` is set                    |
| CI Run         | when `forgeHostID` is set                    |
| Latest Release | when `forgeHostID` is set                    |
| Devices        | always                                       |
| This Mac       | macOS (titled This Device on iOS and iPadOS) |

While `forgeHostID` is set and `state` is nil, Pipeline, CI Run and Latest Release each show one row: a
`ProgressView` with `Loading…`, or `loadError` in red when set.

Hashes show their first 12 characters in a monospaced font; their context menu has `Copy`, which copies the full
value. Commits show their first 8 characters as a link to `https://github.com/<repository>/commit/<sha>`, where
`<repository>` is the `repository` of the Forge's `ForgeConfig`: the Forge host always sets it to the constant
`ForgeConfig.publicRepository` ([../protocol/types.md](../protocol/types.md#forgeconfig)). Links open with the
environment's `openURL` (the default browser). Relative dates use `.relative(presentation: .named)`. Requests run
through `banners.perform` of the window's `WindowBanners`, which shows a failure in the window's error banner.

### Forge

With a Forge host, `LabeledContent` rows, from `forgeConfigs[forgeHostID]`:

| Row                      | Value                                                                                      |
|--------------------------|--------------------------------------------------------------------------------------------|
| Forge host               | the host's name, with a green `StatusDot`                                                  |
| Source project           | `sourceProjectID`, then the project's name (secondary) when the host's project tree has it |
| Repository               | link `https://github.com/<repository>`                                                     |
| Branch                   | `branch`                                                                                   |
| Regenerate automatically | `On` or `Off`                                                                              |

- Repository is a link only: the repository is a constant of the code, and nothing on this screen or in Settings
  edits it.
- Footer (caption): `Change the source project, the branch and automatic regeneration in Settings ▸ Forge & Updates
  on <host name>.`
- When `forgeHostIDs` has more than one Main, a row in orange: `Several Mains are set as the Forge: <names>. Feedback
  goes to <first name>.`

Without a Forge host: the headline `No Forge online` and the secondary text `The Forge is the Main where “Set as
Forge” is on in Settings ▸ Forge & Updates.`

### Docs Hashes

| Row                       | Value                                                                                                                                                   |
|---------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| This app                  | `DocsHash.embedded` ([../forge/generation.md](../forge/generation.md#13-docshash-hephcore))                                                             |
| Forge app                 | `state.appDocsHash`                                                                                                                                     |
| Docs at origin/`<branch>` | `state.head.docsHash`, and below it (caption): `commit <head.commit link> · checked <relative head.checkedAt>`; `Not checked yet` when `head` is nil    |
| Code (App/DocsHash.txt)   | `state.head.codeDocsHash`, or `missing` when it is empty; hidden when `head` is nil                                                                     |
| Status                    | `In sync` with a green `checkmark.circle` when `head.docsHash == head.codeDocsHash`, else `Docs ahead of the code` in orange; hidden when `head` is nil |

Without a Forge host, or before `state` arrives, only This app is shown.

### Pipeline

`ForgePipelineSection`. From top to bottom:

1. The action button, with `state.lastError` under it (caption, red) when set:

   | Cycle           | Button                     | Request        |
   |-----------------|----------------------------|----------------|
   | none, or `done` | `Regenerate Now`           | `regenerate()` |
   | active          | `Regenerate Now`, disabled | —              |
   | `failed`        | `Retry`                    | `regenerate()` |

   While its request runs the button is disabled and shows a `ProgressView`.
2. The cycle, when `state.cycle` is set:
   - its state badge (table below), the trigger text and `started <relative>`: `tool` → `Started when docs were
     pushed`, `manual` → `Started with Regenerate Now`, `automatic` → `Started automatically: docs ahead of the
     code`; `Attempt <n>` when `attempts` > 1;
   - `sessionID` set: the row `Regeneration session` with the button `Open Session`; `attempts` 0 with a
     `regenCommit`: `No regeneration needed: docs and code were in sync.`;
   - `regenCommit`: the row `Built commit` with its link;
   - `failed`: `error` in red.
3. The items (`state.items`, newest first), or `No feedback yet.`. Each row:
   - line 1: the task id (monospaced) and `title`; trailing, the state badge;
   - line 2 (caption, secondary): `docs <sha8>` when `docsCommit` is set, then `updated <relative>`, joined with
     " · ";
   - line 3, when `failed`: `error` in red;
   - actions `Open Task`, `Open Discussion`, and `Retry` when `failed` (`retry(itemTaskID:)`): borderless buttons at
     the trailing edge in regular width; in compact width a `Menu` (`ellipsis.circle`) holding them;
   - clicking the row selects it: `context.selection.item` = its task id, the Forge section's item
     ([../client/workspace.md](../client/workspace.md#selection)); the selected row's background
     (`listRowBackground`) is the accent color at 20 % opacity.

State badges: the text in white, caption font, padding 8 × 2 pt, on a capsule filled with the color:

| `ForgeStage`     | Text                | Color  |
|------------------|---------------------|--------|
| `discussing`     | Discussing          | gray   |
| `docsPushed`     | Docs pushed         | blue   |
| `regenerating`   | Regenerating        | orange |
| `regenPushed`    | Regeneration pushed | orange |
| `building`       | Building            | orange |
| `released`       | Released            | green  |
| `done`           | Done                | green  |
| `failed`         | Failed              | red    |

Each action calls `context.navigate(mainDeviceID:projectID:section:item:)` of the window's `WindowContext`
([shell.md](shell.md#52-windowcontext)) with the values of the table:

| Action          | Main          | Project                  | Section   | Item                                      |
|-----------------|---------------|--------------------------|-----------|-------------------------------------------|
| Open Session    | `forgeHostID` | `config.sourceProjectID` | `.claude` | `cycle.sessionID.uuidString`              |
| Open Task       | `forgeHostID` | the item's `projectID`   | `.tasks`  | the item's `taskID`                       |
| Open Discussion | `forgeHostID` | the item's `projectID`   | `.claude` | the item's `feedbackSessionID.uuidString` |

### CI Run

From `state.cycle.run`; without one: `No CI run yet.`

| Row    | Value                                                                                                                                                                                                                            |
|--------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Run    | `#<number>`                                                                                                                                                                                                                      |
| Status | `queued` → `Queued`, `in_progress` → `In progress`, `completed` + `success` → `Succeeded`, `completed` + other → `Failed (<conclusion>)`, `completed` without a conclusion → `Failed`, any other status → the status as received |
| Commit | `headSHA` link                                                                                                                                                                                                                   |

and the button `Open Run`, which opens `run.url`.

### Latest Release

From `state.latestRelease`: `build-<N>`, `published <relative publishedAt>`, and the button `Open Release`, which opens
`url`. Without one: `No release yet.`

### Devices

Every device of `workspace.mesh` that is not revoked, sorted by name (`localizedStandardCompare`). Each row: the
platform symbol (`desktopcomputer` for macOS, `ipad` for iPadOS, `iphone` for iOS), the name, `Main` or `Remote`
(secondary), `PresenceLabel` (online, or last seen, from `workspace.presence`), and trailing `<appVersion>
(<build>)`. When `state.latestRelease` is set and the device's `build` is lower: `Build <N> available` in orange
(caption) under the version.

### This Mac

`UpdateStatusView()`.

## UpdateStatusView

`UpdateStatusView()` reads, on macOS, the `UpdateModel` the shell puts in the environment
([../forge/update.md](../forge/update.md#swift-api)) and the `SettingsStore`, and on iOS and iPadOS the `Workspace`.
Settings ▸ Forge & Updates embeds it on macOS ([settings.md](settings.md)).

- macOS: the texts and actions of [../forge/update.md](../forge/update.md#statuses): a `ProgressView` for `checking`
  and `downloading`; `Check Now` (`model.checkNow()`) for `idle` and `failed`; `Install` (`model.install()`) for
  `idle` when `updates.enabled` is false (`settings.updates.enabled` of the `SettingsStore` in the environment,
  [../data/app-storage.md](../data/app-storage.md)), `canInstall` is true and `latestBuild` is greater than
  `currentBuild`; `Restart Now` (`model.restartNow()`) for `ready`; the `failed` message in red. `Build <N>` in the
  available text is a link to `latestReleaseURL` when it is set.
- iOS and iPadOS: `Build <build of this app>.`, then `Build <N> is available.` when
  `workspace.forge.state.latestRelease.build` is greater, else `Up to date.` when `latestRelease` is set; nothing more
  without a Forge host.

## Swift API

```swift
// HephClient/ForgeModel.swift — all platforms.

@MainActor @Observable public final class ForgeModel {
    public init(workspace: Workspace)                       // weak reference; the Workspace owns the model
    public private(set) var forgeConfigs: [UUID: ForgeConfig]
    public var forgeHostIDs: [UUID] { get }
    public var forgeHostID: UUID? { get }
    public private(set) var state: ForgeState?
    public private(set) var isLoading: Bool
    public private(set) var loadError: String?
    /// Gets the build of every latestRelease received; set by the shell on macOS (UpdateService).
    public var releaseObserver: (@MainActor (Int) -> Void)?

    // Called by the Workspace.
    public func mainDidConnect(_ mainID: UUID)
    public func mainDidDisconnect(_ mainID: UUID)
    public func apply(_ state: ForgeState, from mainID: UUID)

    public func refresh() async
    public func regenerate() async throws
    public func retry(itemTaskID: String) async throws
    /// Uploads the screenshot (when there is one) to the Forge's source project, then sends forge.feedback. An upload
    /// that fails with notFound throws "The Forge on <Forge host name> has no source project <ID> yet. …" (Requests).
    public func sendFeedback(screenshot: Data?, comment: String, context: FeedbackContext,
                             progress: @escaping @MainActor (TransferProgress) -> Void) async throws
        -> ForgeFeedbackResult
}
```

```swift
// HephUI/Forge — views are @MainActor. ForgeView reads the Workspace, the window's WindowContext and WindowBanners
// from the environment; UpdateStatusView reads the UpdateModel and the SettingsStore (macOS) or the Workspace.

/// The Forge section content.
public struct ForgeView: View { public init() }

/// This device's update status; also embedded in Settings ▸ Forge & Updates (macOS).
public struct UpdateStatusView: View { public init() }
```

`ForgeView` ends its file with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

| Name                                                                                                                                                                                                         | Defined in                                                                                       |
|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `ForgeState`, `ForgeConfig` (`publicRepository`), `ForgeCycle`, `ForgeItem`, `ForgeHead`, `ForgeRun`, `ForgeRelease`, `ForgeStage`, `ForgeTrigger`, `FeedbackContext`, `ForgeFeedbackResult`, `DeviceRecord` | [../protocol/types.md](../protocol/types.md), [../forge/pipeline.md](../forge/pipeline.md#types) |
| `forge.status`, `forge.regenerate`, `forge.retry`, `forge.feedback`, `uploads.*`, `host.info`, `forge.changed`                                                                                               | [../forge/pipeline.md](../forge/pipeline.md), [../protocol/methods.md](../protocol/methods.md)   |
| `Workspace` (`forge`, `mains`, `connection(_:)`, `mesh`, `presence`, the calls of the Inputs table), `MainConnection` (request API, `upload`, `name`), `TransferProgress`, `Selection`                       | [../client/workspace.md](../client/workspace.md)                                                 |
| `UpdateModel` (`checkNow`, `install`, `restartNow`), update texts                                                                                                                                            | [../forge/update.md](../forge/update.md)                                                         |
| `DocsHash.embedded`                                                                                                                                                                                          | [../forge/generation.md](../forge/generation.md)                                                 |
| `SettingsStore` (`updates.enabled`)                                                                                                                                                                          | [../data/app-storage.md](../data/app-storage.md)                                                 |
| sidebar section, `releaseObserver` wiring, `UpdateModel` in the environment, `WindowContext` (`selection`, `navigate`), `WindowBanners` (`perform`, error banner), `StatusDot`, `PresenceLabel`              | [shell.md](shell.md)                                                                             |
| Settings ▸ Forge & Updates                                                                                                                                                                                   | [settings.md](settings.md)                                                                       |
| `SessionCenter` (the pattern `ForgeModel` follows)                                                                                                                                                           | [sessions.md](sessions.md)                                                                       |
| `ProtocolError`                                                                                                                                                                                              | [../protocol/envelope.md](../protocol/envelope.md)                                               |
