# App shell

files:
- App/HephaestusApp.swift
- HephaestusKit/Sources/HephUI/App/AppModel.swift
- HephaestusKit/Sources/HephUI/App/AppDelegate.swift
- HephaestusKit/Sources/HephUI/App/HostServiceLink.swift
- HephaestusKit/Sources/HephUI/App/PreviewWindow.swift
- HephaestusKit/Sources/HephUI/App/RootView.swift
- HephaestusKit/Sources/HephUI/App/WindowContext.swift
- HephaestusKit/Sources/HephUI/Shell/MainShell.swift
- HephaestusKit/Sources/HephUI/Shell/SidebarView.swift
- HephaestusKit/Sources/HephUI/Shell/SidebarSection+UI.swift
- HephaestusKit/Sources/HephUI/Shell/DetailView.swift
- HephaestusKit/Sources/HephUI/Shell/SelectionDefaults.swift
- HephaestusKit/Sources/HephUI/Shell/PathBar.swift
- HephaestusKit/Sources/HephUI/Shell/CompactPathButton.swift
- HephaestusKit/Sources/HephUI/Shell/PathPickerSheet.swift
- HephaestusKit/Sources/HephUI/Shell/ShellToolbar.swift
- HephaestusKit/Sources/HephUI/Shell/PresenceIndicator.swift
- HephaestusKit/Sources/HephUI/Shell/NoMainOnlineView.swift
- HephaestusKit/Sources/HephUI/Shell/Banners.swift
- HephaestusKit/Sources/HephUI/Shell/BannerOverlay.swift
- HephaestusKit/Sources/HephUI/Shell/HephaestusCommands.swift
- HephaestusKit/Sources/HephUI/Shell/ShellFocusedValues.swift
- HephaestusKit/Sources/HephUI/Components/StatusDot.swift
- HephaestusKit/Sources/HephUI/Components/PresenceLabel.swift
- HephaestusKit/Sources/HephUI/Components/EmptyStateView.swift
- HephaestusKit/Sources/HephUI/Components/PlatformIcon.swift
- HephaestusKit/Sources/HephUI/Components/ChipToggle.swift

---

The shell is everything around the screens of the sections: the scenes and windows, the app wiring (`AppModel`), the
toolbar with the path bar, the sidebar, the layout per device class, the keyboard shortcuts and menus, the error
banners, the offline states, and the small views shared by every screen. The screens of the sections are in their own
docs ([§4](#4-sections)).

## 1. Device classes

| Class           | Condition                                                             | Layout                                                                    |
|-----------------|-----------------------------------------------------------------------|---------------------------------------------------------------------------|
| Mac             | `os(macOS)`                                                           | sidebar and detail side by side; toolbar path bar; menus; several windows |
| iPad regular    | `os(iOS)` and `horizontalSizeClass == .regular`                       | as Mac, without the menu bar; several windows                             |
| iPhone, compact | `os(iOS)` and `horizontalSizeClass == .compact` (iPhone, narrow iPad) | the split view collapses into one navigation stack; compact path button   |

"Regular" below means Mac or iPad regular; "compact" means the third row. A window that changes class (iPad
multitasking) switches layout at once; the selection is kept.

## 2. Scenes: App/HephaestusApp.swift

This is the only Swift file of the App target. It imports `SwiftUI` and `HephUI` (everything it uses is public API
of `HephUI`). Exact content:

```swift
import SwiftUI
import HephUI

@main
struct HephaestusApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(HephaestusAppDelegate.self) private var appDelegate
    #endif
    private let appModel = AppModel.shared

    var body: some Scene {
        WindowGroup("Hephaestus", id: AppModel.mainWindowID) {
            RootView()
                .environment(appModel)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
        .commands { HephaestusCommands(appModel: appModel) }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appModel)
        }
        #endif
    }
}
```

- One window type. macOS allows any number of windows (File ▸ New Window, ⌥⌘N); iPadOS allows several windows
  (`UIApplicationSupportsMultipleScenes`, [../architecture.md](../architecture.md#appinfoplist)); iPhone has one.
- Each window has its own `WindowContext` and so its own `Selection` ([§5](#5-windows)).
- macOS: the Settings scene is [settings.md](settings.md).

### 2.1 HephaestusAppDelegate (macOS)

`HephaestusAppDelegate` (`AppDelegate.swift`, macOS only) is a public `NSObject` subclass conforming to
`NSApplicationDelegate`:

| Method                                            | Behavior                                                                                                                                                                                                           |
|---------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `applicationShouldTerminateAfterLastWindowClosed` | `false`: a Main keeps serving its devices with no window open                                                                                                                                                      |
| `applicationShouldTerminate`                      | `.terminateLater`, then in a main-actor `Task`: `await AppModel.shared.shutdown()` and `NSApp.reply(toApplicationShouldTerminate: true)`; a second call while waiting returns `.terminateLater` and starts nothing |

`shutdown()` waits at most 10 s: after 10 s the reply is sent even if the host has not finished stopping.

The app calls `terminate` only from the run loop: the Quit menu item, an Apple event, or a timer such as the one of
the self-update ([../forge/update.md](../forge/update.md#steps)). It never calls it inside a main-actor job: the reply
comes from a main-actor task, which does not start while that job waits in AppKit's nested event loop.

## 3. AppModel

`AppModel` (`@MainActor @Observable`, `AppModel.shared`) is the root object. It owns what lives as long as the app and
does the app wiring asked of the shell by [../client/workspace.md](../client/workspace.md#app-wiring),
[../devices/roles.md](../devices/roles.md), [../forge/update.md](../forge/update.md) and [forge.md](forge.md).

| Property        | Type                  | Platforms | Meaning                                                                                                                                                        |
|-----------------|-----------------------|-----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `appSupport`    | `AppSupport`          | all       | `AppSupport.standard()` ([../data/app-storage.md](../data/app-storage.md))                                                                                     |
| `settings`      | `SettingsStore`       | all       | `SettingsStore(appSupport:)`                                                                                                                                   |
| `identity`      | `DeviceIdentityStore` | all       | `DeviceIdentityStore(appSupport:settings:)` ([../devices/roles.md](../devices/roles.md#deviceidentitystore))                                                   |
| `workspace`     | `Workspace`           | all       | `Workspace(device: identity.deviceInfo, environment: .live(appSupport: appSupport, credentialStore: KeychainCredentialStore.shared, identityStore: identity))` |
| `banners`       | `AppBannerRouter`     | all       | posts banners to the active window ([§8.2](#82-appbannerrouter))                                                                                               |
| `phase`         | `AppModel.Phase`      | all       | computed, below                                                                                                                                                |
| `graceElapsed`  | `Bool`                | all       | 3 s have passed since `workspace.start()` and since the last `WorkspaceEvent.disconnected` ([§10](#10-no-main-online))                                         |
| `host`          | `HostService`         | macOS     | the result of `HostService.makeShared` (below, [../services/host.md](../services/host.md)); running while this Mac is a Main                                   |
| `listenerError` | `String?`             | macOS     | copy of `host.listenerError`, read after `host.start()` and `host.restartListener()`, and by `refreshListenerError()`                                          |
| `updateModel`   | `UpdateModel`         | macOS     | `UpdateModel()` ([../forge/update.md](../forge/update.md#swift-api))                                                                                           |
| `updater`       | `UpdateService`       | macOS     | `UpdateService(model: updateModel, isBusy:)`; `isBusy` returns `await host.hasActiveWork()` while this Mac is a Main, else `false`                             |

`phase` is `.launching` until `start()` has finished; then `.onboarding` while `workspace.hasMesh` is false and either
`identity.isMain` is false or `becomeMain()` runs
([../devices/roles.md](../devices/roles.md#what-the-ui-shows-per-role), [§3.3](#33-main-toggle)); else `.ready`.

`AppModel.mainWindowID` is the constant `"main"`. `AppModel.shared` is `AppModel(appSupport: AppSupport.standard())`;
when `AppSupport.standard()` throws, the app stops with `fatalError("Application Support is not available: <error>")`.
`AppModel.shared` is the only caller of `init(appSupport:)`, which creates the stored properties in the order of the
table. On macOS it creates `host`, after `settings` and before `updater`, with
`HostService.makeShared(appSupport: appSupport, settings: settings, credentialStore: KeychainCredentialStore.shared)`,
which also sets `HostService.shared`: the shared host is created once, before any use. Previews and snapshot tests use
`AppModel.preview()` instead ([§5.4](#54-previews)).

### 3.1 start()

`RootView` calls `await appModel.start()` in its `.task`; only the first call runs, later calls return at once. The
first call runs the steps below in a `Task` of their own and awaits it, so the launch finishes even when the window
whose `.task` called it closes meanwhile.

| Step | Action                                                                                                                                                                                                                                                                                                                                                                                                                        |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1    | macOS, `identity.isMain`: `try await host.start()`, then `workspace.setLocalHostLink(HostServiceLink(host: host))` and `listenerError = await host.listenerError`; when `await host.projectsFileWasReset` is true, posts the error banner "projects.json was unreadable and has been reset; folders are untouched". A thrown error posts the error banner "This Mac could not start as a Main: <message>"; the next steps run |
| 2    | `workspace.start()`; a timer `Task` sets `graceElapsed` to true 3 s later. Another `Task` reads `workspace.events()` for the life of the app: each `.disconnected` sets `graceElapsed` to false, cancels the pending timer `Task` and starts a new one                                                                                                                                                                        |
| 3    | a `Task` reads `workspace.errorReports()` for the life of the app and posts each message as an error banner ([../client/workspace.md](../client/workspace.md#error-reports))                                                                                                                                                                                                                                                  |
| 4    | macOS: `await updater.start()`; `workspace.forge.releaseObserver = { build in Task { await updater.releaseNoticed(build: build) } }` ([forge.md](forge.md#forgemodel))                                                                                                                                                                                                                                                        |
| 5    | macOS, `listenerError` set: posts the error banner "This Mac cannot accept connections from other devices: <listenerError>"                                                                                                                                                                                                                                                                                                   |
| 6    | the launch is finished: `phase` leaves `.launching`                                                                                                                                                                                                                                                                                                                                                                           |

Banners are posted with `banners.post(Banner(style: .error, message: <text>))`. `host.projectsFileWasReset` is true
when the `start()` that just ran found `projects.json` unreadable, kept it as `projects.json.unreadable` and started
with no projects ([../services/host.md](../services/host.md)).

### 3.2 Device names

| Member                                | Behavior                                                                                                                                                                                                                                         |
|---------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `setLocalName(_ name:) throws`        | Before the device belongs to a mesh: `try identity.setName(name)`, then `workspace.updateLocalDevice(identity.deviceInfo)`                                                                                                                       |
| `renameDevice(_ id:to:) async throws` | `DeviceIdentityStore.validateName(_:)`, then `renameDevice(id, to:)` on `renameConnection`; the Workspace merges the returned record and, when `id` is this device, adopts and saves the name ([../devices/roles.md](../devices/roles.md#names)) |
| `renameConnection: MainConnection?`   | `workspace.localConnection` when it is connected, else the connection of the first of `workspace.mains` that is connected, else nil; with nil, `renameDevice` throws `ProtocolError(.unavailable, "No Main is online.")`                         |

### 3.3 Main toggle

macOS only. The procedures are those of [../devices/roles.md](../devices/roles.md#turning-main-on-macos); `AppModel`
runs them for onboarding ([onboarding.md](onboarding.md)) and Settings ([settings.md](settings.md)).

`becomeMain() async throws`:

1. `try identity.setIsMain(true)`.
2. `try await host.start()`. When it throws: `try? identity.setIsMain(false)` and rethrow; the caller shows the alert
   "This Mac could not become a Main" with the error message.
3. `workspace.setLocalHostLink(HostServiceLink(host: host))` (it reloads the credentials, so a mesh created by
   `host.start()` is picked up); `workspace.updateLocalDevice(identity.deviceInfo)`;
   `listenerError = await host.listenerError`.
4. When `await host.projectsFileWasReset` is true: posts the error banner "projects.json was unreadable and has been
   reset; folders are untouched" ([§3.1](#31-start)).

While `becomeMain()` runs on a device without a mesh, `phase` stays `.onboarding` ([§3](#3-appmodel)): onboarding
keeps its progress indicator and shows the failure alert ([onboarding.md](onboarding.md#use-this-mac-as-a-main)). Step
3 loads the mesh that `host.start()` created, so `phase` is `.ready` once `becomeMain()` has returned.

`isMigrationActive() async -> Bool` returns `await host.migration.isActive()`. The UI calls it before asking to stop
being a Main or to leave the mesh, and refuses with the alert of [../devices/roles.md](../devices/roles.md) when it is
true.

`resignMain() async throws`, called after the caller's confirmation:

1. `await host.mesh.resignMain()`.
2. `await host.stop()`.
3. `try identity.setIsMain(false)`; `workspace.setLocalHostLink(nil)`;
   `workspace.updateLocalDevice(identity.deviceInfo)`; `listenerError = nil`.

`HostServiceLink` (`HostServiceLink.swift`, macOS, internal) implements `LocalHostLink`
([../client/workspace.md](../client/workspace.md#localhostlink)): `makeChannel()` returns
`await host.makeLoopbackChannel()`.

`restartListener() async`: `await host.restartListener()`, then `listenerError = await host.listenerError`. Settings
calls it after the listener port changes.

`refreshListenerError() async`: `listenerError = await host.listenerError`. Settings ▸ General calls it when it appears
([settings.md](settings.md#other-controls)): `MeshService` sets or clears `host.listenerError` when it replaces the
listener after a key change ([../devices/mesh.md](../devices/mesh.md#receiving-a-new-key)).

### 3.4 Mesh membership

| Method                     | Called by                                                                   | Behavior                                                                                                                                                                                                                                      |
|----------------------------|-----------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `didJoinMesh()`            | the join flow ([devices.md](devices.md#join-flow)), after pairing succeeded | `workspace.restart()` (pairing stored the credentials and the registry); `phase` becomes `.ready`; `restart()` runs `workspace.start()` again, so `graceElapsed` becomes false and the 3 s timer of [§3.1](#31-start) step 2 starts again     |
| `leaveMesh() async throws` | "Leave Mesh…" ([devices.md](devices.md#leave-mesh)), after its confirmation | steps 3–5 of [../devices/roles.md](../devices/roles.md#leaving-the-mesh): on a Main `resignMain()`; `try KeychainCredentialStore.shared.delete()`; `try RegistryCache.delete(appSupport)`; `workspace.reset()`; `phase` becomes `.onboarding` |

### 3.5 Other app wiring

- When a window's scene phase becomes `.active`: `workspace.retryNow()`.
- `shutdown() async` (macOS): `workspace.stop()`, `await updater.stop()`, then `await host.stop()` when this Mac is a
  Main.
- `privateTermsCount() -> Int` (macOS): `host.forge.privateTermsCount()`, the number of private terms
  ([../forge/pipeline.md](../forge/pipeline.md#private-terms)); Settings ▸ Forge & Updates shows it
  ([settings.md](settings.md)).
- `editPrivateTerms() async throws` (macOS): `let url = try await host.forge.preparePrivateTerms()`, which writes the
  pre-filled file when it is missing, then `NSWorkspace.shared.open(url)`, which opens it in the default editor of
  text files.
- `privateTermSuggestions() async -> [String]` (macOS): `await host.forge.privateTermSuggestions()`, the suggested
  private terms the file neither holds nor dismisses ([../forge/pipeline.md](../forge/pipeline.md#private-terms)).
- `addPrivateTerm(_ term: String) async throws` and `dismissPrivateTerm(_ term: String) async throws` (macOS):
  `try await host.forge.addPrivateTerm(term)` and `try await host.forge.dismissPrivateTerm(term)`.

## 4. Sections

`SidebarSection` and its raw values are declared with `Selection` in
[../client/workspace.md](../client/workspace.md#selection); the raw value is what the window stores and what
`FeedbackSelection.section` carries. `SidebarSection+UI.swift` adds the presentation:

| Case       | Group     | Title    | SF Symbol                                 | Shortcut |
|------------|-----------|----------|-------------------------------------------|----------|
| `overview` | project   | Overview | `info.circle`                             | ⌘1       |
| `tasks`    | project   | Tasks    | `checklist`                               | ⌘2       |
| `code`     | project   | Code     | `chevron.left.forwardslash.chevron.right` | ⌘3       |
| `docs`     | project   | Docs     | `book.closed`                             | ⌘4       |
| `web`      | project   | Web      | `globe`                                   | ⌘5       |
| `claude`   | project   | Claude   | `bubble.left.and.bubble.right`            | ⌘6       |
| `devices`  | workspace | Devices  | `laptopcomputer.and.iphone`               |          |
| `skills`   | workspace | Skills   | `wand.and.stars`                          |          |
| `forge`    | workspace | Forge    | `hammer`                                  |          |

### Sections

The detail of each section is a view of another doc. Project sections get the `ProjectStore` of the selected project,
`workspace.projectStore(mainDeviceID:projectID:)` ([../client/workspace.md](../client/workspace.md#projectstore)).

| Section    | View                        | `Selection.item`                                                               | Doc                        |
|------------|-----------------------------|--------------------------------------------------------------------------------|----------------------------|
| `overview` | `OverviewView(store:)`      | none                                                                           | [overview.md](overview.md) |
| `tasks`    | `TasksView(store:)`         | task id                                                                        | [tasks.md](tasks.md)       |
| `code`     | `CodeView(store:)`          | project-relative path of the active file, optionally followed by `#L<line>`    | [code.md](code.md)         |
| `docs`     | `DocsView(store:)`          | project-relative path of the shown document, optionally followed by `#L<line>` | [docs.md](docs.md)         |
| `web`      | `WebTabsView(store:)`       | web tab id                                                                     | [web.md](web.md)           |
| `claude`   | `ClaudeView(store:)`        | session id                                                                     | [sessions.md](sessions.md) |
| `devices`  | `DevicesView()`             | device id                                                                      | [devices.md](devices.md)   |
| `skills`   | `SkillsView(mainDeviceID:)` | `<skill name>` or `<skill name>/<file path>`                                   | [skills.md](skills.md)     |
| `forge`    | `ForgeView()`               | task id of the pipeline item                                                   | [forge.md](forge.md)       |

UUIDs are written as `uuidString`. A section view that finds an item set from elsewhere (search, a link) opens that
item. `#L<line>` is set by search results ([search.md](search.md#opening-a-result)) and parsed by the Code and Docs
sections ([code.md](code.md#navigation-and-selection)).

## 5. Windows

### 5.1 RootView

`RootView` is the root view of every window. On its first appearance it creates the window's context with
`WindowContext(selection: appModel.workspace.makeSelection())` (the Workspace keeps a weak reference to apply its
selection rules, [../client/workspace.md](../client/workspace.md#selection-rules)); on iOS and iPadOS it sets the
context's `isCompact` from `horizontalSizeClass` right away, so that rule 3 of [§5.3](#53-stored-selection-and-defaults)
sees the window's class (an iPhone does not launch with Overview pushed); then it restores the stored selection
([§5.3](#53-stored-selection-and-defaults)). Until then it shows nothing.

| Condition                                                                       | Content                                             |
|---------------------------------------------------------------------------------|-----------------------------------------------------|
| `appModel.phase == .launching`                                                  | a centered `ProgressView`                           |
| `appModel.phase == .onboarding`                                                 | `OnboardingView()` ([onboarding.md](onboarding.md)) |
| `.ready`, this device is not a Main, no connection is connected, `graceElapsed` | `NoMainOnlineView()` ([§10](#10-no-main-online))    |
| `.ready`, otherwise                                                             | `MainShell()`                                       |

Modifiers on the content, from inner to outer:

1. `.feedbackSupport()` ([../forge/feedback.md](../forge/feedback.md#window-binding)).
2. `.migrationProgressPresenter()` ([overview.md](overview.md#presentation-in-every-window)).
3. `.permissionBanner()` ([sessions.md](sessions.md)).
4. `.overlay(alignment: .bottom) { BannerOverlay() }` ([§8.3](#83-banneroverlay)).
5. `.focusedSceneValue(\.windowContext, context)`, only while `phase` is `.ready`.
6. `.environment(context)`, `.environment(context.selection)`, `.environment(context.banners)`,
   `.environment(appModel.workspace)`, `.environment(appModel.settings)`, and on macOS
   `.environment(appModel.updateModel)` ([forge.md](forge.md#updatestatusview)).

Also on `RootView`:

- `.task { await appModel.start() }` ([§3.1](#31-start)).
- When the window becomes active (macOS: `controlActiveState == .key`; iOS and iPadOS: `scenePhase == .active`):
  `appModel.banners.activate(context.banners)` ([§8.2](#82-appbannerrouter)).
- When `scenePhase` becomes `.active`: `appModel.workspace.retryNow()`.

### 5.2 WindowContext

`WindowContext` (`@MainActor @Observable`) holds the state of one window. Menu commands reach it through the focused
scene value `windowContext` ([§11.3](#113-focused-values)).

| Member              | Type            | Meaning                                                                                                                                    |
|---------------------|-----------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| `selection`         | `Selection`     | Main, project, section and item shown by the window                                                                                        |
| `banners`           | `WindowBanners` | the window's banners ([§8.1](#81-windowbanners))                                                                                           |
| `sheet`             | `ShellSheet?`   | the shell sheet presented by `MainShell`                                                                                                   |
| `isSearchPresented` | `Bool`          | regular: the search palette is shown ([search.md](search.md))                                                                              |
| `isCompact`         | `Bool`          | the window is compact; set from `horizontalSizeClass` by `RootView` when it creates the context and by `MainShell` (always false on macOS) |

| Method                                           | Behavior                                                                                                                                                                                                                                                                                                                                                 |
|--------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `select(_ section: SidebarSection)`              | When `section` differs from `selection.section`: `selection.section = section` and `selection.item = nil`                                                                                                                                                                                                                                                |
| `navigate(mainDeviceID:projectID:section:item:)` | When `mainDeviceID` is not nil and differs from the selected Main: `selection.mainDeviceID = mainDeviceID` and `selection.projectID = projectID`; else, when `projectID` is not nil, `selection.projectID = projectID`. Then `selection.section = section`, `selection.item = item`, `isSearchPresented = false`, and `sheet = nil` when it is `.search` |
| `openSearch()`                                   | compact: `sheet = .search`; regular: `isSearchPresented = true` (already shown: nothing changes)                                                                                                                                                                                                                                                         |

`ShellSheet` cases: `.pathPicker`, `.newProject(mainDeviceID:)`, `.addExistingFolder(mainDeviceID:)`, `.search`.

`Selection` changes only the field that is set ([../client/workspace.md](../client/workspace.md#selection)); the shell
keeps it consistent: `select(_:)` clears the item when the section changes, the path bar clears the project and the
item when the Main changes and the item when the project changes ([§7](#7-path-bar)).

### 5.3 Stored selection and defaults

The window stores its selection with `@SceneStorage`, under the keys of `WindowStateKeys`
([../data/app-storage.md](../data/app-storage.md#per-window-state)); values are strings, `""` meaning nil.

- Restore, once, when the context is created: `mainDeviceID` = `UUID(uuidString:)` of the stored string; `projectID`
  and `item` = the stored strings; `section` = `SidebarSection(rawValue:)` of the stored string, nil for a section
  this version does not have (`runs` of earlier versions). A restored Main that is no longer a Main is cleared by rule
  1 of the Workspace's selection rules at the next registry change
  ([../client/workspace.md](../client/workspace.md#selection-rules)); a restored project by the check below.
- Restored project check, made by `RootView` in a window that restored a `projectID`: the first time the defaults
  run (below) while the selection's Main is connected with `projectsLoaded`, the check runs before them: when
  `projectID` is set and `workspace.summary(of: projectID, on: mainDeviceID)` is nil, `projectID` and `item` become
  nil, and rule 2 then selects a project. Whatever its outcome, the check is not made again. A window restored while
  that Main's tree is loaded checks at once; at launch the check waits for the tree.
- Save: every change of one of the four fields writes its key (`mainDeviceID` as `uuidString`), the changes made by
  the check and the defaults while the context is created included.

`SelectionDefaults.apply(to:workspace:isCompact:)` fills empty fields; it never replaces a field that is set. It runs
after the restore and after every change of `workspace.topologyRevision`, `selection.mainDeviceID`,
`selection.projectID` and `context.isCompact`.

| Rule | When                                                                                                     | Sets                                                                                                                                |
|------|----------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| 1    | `mainDeviceID` is nil                                                                                    | the first connected Main in [path bar order](#7-path-bar); with none connected, the first Main in that order; with no Main, nothing |
| 2    | `mainDeviceID` is set, `projectID` is nil, that Main is connected with `projectsLoaded` and has projects | `projectID` = the first top-level project by name (`localizedStandardCompare`)                                                      |
| 3    | regular and `section` is nil                                                                             | `section = .overview`                                                                                                               |

In compact width `section` nil means the sidebar list is shown.

### 5.4 Previews

Every screen has a SwiftUI preview built on the preview workspace
([../client/workspace.md](../client/workspace.md#previews)); the screen snapshots of
[../testing.md](../testing.md#hephuisnapshottests) use the same two helpers.

`AppModel.preview()` (`AppModel.swift`) returns a new `AppModel` that starts nothing and uses neither the Keychain nor
the app's Application Support folder. It does not call `HostService.makeShared`.

| Property                         | Value                                                                                                                                                                                                                                                                                                                                   |
|----------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `appSupport`                     | `AppSupport(root:)` of a new folder `HephaestusPreview-<UUID>` in `FileManager.default.temporaryDirectory`, created                                                                                                                                                                                                                     |
| `settings`, `identity`           | as in [§3](#3-appmodel), on that folder: default settings, and the identity of the sample data's this device: `DeviceFile(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, name: "Sam's MacBook Pro").save(appSupport)` runs before `DeviceIdentityStore` is created, so no preview or snapshot shows this Mac's own name |
| `workspace`                      | `Workspace.preview()`                                                                                                                                                                                                                                                                                                                   |
| `banners`                        | `AppBannerRouter()`                                                                                                                                                                                                                                                                                                                     |
| `host` (macOS)                   | `HostService(appSupport: appSupport, settings: settings, credentialStore: InMemoryCredentialStore())`, never started                                                                                                                                                                                                                    |
| `updateModel`, `updater` (macOS) | `UpdateModel()`; `UpdateService(model: updateModel, isBusy: { false })`, never started                                                                                                                                                                                                                                                  |

`start()` is never called on it: `phase` is computed as after a finished launch, and `graceElapsed` is true.

`previewWindow(_ appModel: AppModel, selection: Selection)` (`PreviewWindow.swift`), a `View` extension, gives a view
the environment of a window: it keeps one `WindowContext(selection: selection)` in `@State` and applies
`.environment(appModel)` and the environment of [§5.1](#51-rootview) step 6 with that context.

Every screen ends its file with a `#Preview` that shows it with `.previewWindow(appModel, selection:)`, where
`appModel` is `AppModel.preview()`. The selection is on Studio of the sample data
(`00000000-0000-4000-8000-000000000001`), with project `HEPH` for a project section, and has the screen's section when
the screen is a view of [Sections](#sections). A project section view gets
`appModel.workspace.projectStore(mainDeviceID:projectID:)` of the selection. A screen that exists on one platform only
has its preview inside the same `#if`. The screens: the views of [Sections](#sections), `MainShell`,
`NoMainOnlineView`, `PathPickerSheet`, `OnboardingView`, `JoinMeshView`, `SettingsView`, `SettingsSheet`,
`SearchPalette`, `SearchScreen`, `NewProjectSheet` and `AddExistingFolderSheet`. For example:

```swift
#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    TasksView(store: appModel.workspace.projectStore(mainDeviceID: studio, projectID: "HEPH"))
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, projectID: "HEPH", section: .tasks))
}
```

## 6. Main shell

### 6.1 Layout

`MainShell` is a `NavigationSplitView` with two columns:

```swift
NavigationSplitView(columnVisibility: $columnVisibility) {   // @State, initially .automatic
    SidebarView()
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
} detail: {
    DetailView()
}
```

| Class        | Behavior                                                                                                                                                                                        |
|--------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Mac          | sidebar and detail side by side; the sidebar is hidden and shown with the toolbar's sidebar button and View ▸ Show Sidebar / Hide Sidebar (⌃⌘S, `SidebarCommands`); window minimum 800 × 500 pt |
| iPad regular | system behavior of the split view: side by side in landscape, the sidebar over the detail in portrait                                                                                           |
| compact      | the split view collapses: the sidebar list is the root of a navigation stack; choosing a section pushes its screen; Back sets `selection.section` to nil                                        |

- Window title: `.navigationTitle` on the detail = the selected project's name, else "Hephaestus". macOS:
  `.toolbar(removing: .title)`, so the title names the window (Window menu) without taking toolbar space. iOS:
  `.navigationBarTitleDisplayMode(.inline)`.
- macOS: the toolbar is translucent and both columns extend under it ([§9.2](#92-toolbar-material-macos)).
- `MainShell` sets `context.isCompact` from `horizontalSizeClass` when it appears and when the class changes.
- Regular: `.overlay { if context.isSearchPresented { SearchPalette() } }` on the split view, so the palette covers the
  whole window ([search.md](search.md)).
- `MainShell` presents `.sheet(item: $context.sheet)`:

| `ShellSheet`                        | Content                                                                                      |
|-------------------------------------|----------------------------------------------------------------------------------------------|
| `.pathPicker`                       | `PathPickerSheet()` ([§7.4](#74-compact-path-button))                                        |
| `.newProject(mainDeviceID:)`        | `NewProjectSheet(mainDeviceID:parentID: nil)` ([overview.md](overview.md#new-project-sheet)) |
| `.addExistingFolder(mainDeviceID:)` | `AddExistingFolderSheet(mainDeviceID:)` ([overview.md](overview.md#add-existing-folder))     |
| `.search`                           | `SearchScreen()` ([search.md](search.md))                                                    |

### 6.2 Sidebar

`SidebarView` is a `List(selection:)` with `.listStyle(.sidebar)`:

1. A section whose header is the selected project's name ("Project" when none) with the six project sections, each
   `Label(<title>, systemImage: <symbol>)` tagged with its section. The rows are disabled while no project is selected.
2. A section "Workspace" with Devices, Skills and Forge.

The list's selection is a `Binding<SidebarSection?>`: it reads `selection.section`; setting a section calls
`context.select(_:)`; setting nil (compact Back) sets `selection.section = nil`. In compact width the list carries the
shell toolbar ([§9](#9-toolbar)) and the inline title of the selected project.

macOS: the top of the sidebar column shows the toolbar material, and the list scrolls under it
([§9.2](#92-toolbar-material-macos)).

### 6.3 Detail

`DetailView` shows the view of `selection.section` ([Sections](#sections)) or a state: the first row of this table that
applies. `<Main>` is the name of the selected Main: its connection's `name`, else the name of its record in
`workspace.mesh`, else "Main"; the path bar uses the same name ([§7](#7-path-bar)). `store` is the `ProjectStore` of
the selection, `workspace.projectStore(mainDeviceID:projectID:)`; asking for it creates it, so `DetailView` asks only
when `mainDeviceID` and `projectID` are set and `workspace.summary(of:on:)` is not nil.

| Condition                                                                                           | Shown                                                                                                                                                                                                            |
|-----------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `section` is nil                                                                                    | `EmptyStateView(symbol: "sidebar.left", title: "Select a section")`                                                                                                                                              |
| project section or `skills`, `mainDeviceID` is nil                                                  | `EmptyStateView(symbol: "desktopcomputer", title: "No Main selected", message: "Choose a Main in the path bar.")`                                                                                                |
| project section, `projectID` is set, `workspace.summary(of:on:)` is not nil, `store.project` is set | the section's view; while the Main's connection is not connected, the [offline bar](#offline-bar) above it                                                                                                       |
| project section, the Main's connection is missing or not connected                                  | `EmptyStateView(symbol: "desktopcomputer", title: "<Main> is offline", message: "<last seen>. Choose another Main in the path bar.")`                                                                            |
| project section, connected, `projectsLoaded` false                                                  | a centered `ProgressView`                                                                                                                                                                                        |
| project section, `projectID` is nil                                                                 | `EmptyStateView(symbol: "folder", title: "No projects on <Main>", message: "Create a project or add an existing folder.")` with the buttons New Project… and Add Existing Folder… of [§7.2](#72-project-segment) |
| project section, `workspace.summary(of:on:)` is nil                                                 | `EmptyStateView(symbol: "questionmark.folder", title: "<project id> is not on <Main>")`                                                                                                                          |
| project section, `store.phase` is `failed(message)`                                                 | `EmptyStateView(symbol: "exclamationmark.triangle", title: "Could not load <project id>", message: <message>)` with a Retry button running `Task { await store.reload() }`                                       |
| project section                                                                                     | a centered `ProgressView` (the store's first load runs)                                                                                                                                                          |
| otherwise                                                                                           | the section's view                                                                                                                                                                                               |

- `<last seen>` is `PresenceFormat.lastSeen` of the Main's merged presence ([§12](#12-shared-components)), refreshed
  every minute (`TimelineView(.everyMinute)`).
- A project section's view stays while its Main reconnects: the store and the Main's projects keep their data
  ([../client/workspace.md](../client/workspace.md#drops)), and the view keeps its own state (drafts, open tabs). Its
  controls that send requests, and those that open a sheet or a confirmation dialog whose button sends one, are
  disabled while the connection is not connected.
- A project section view gets `.id("<mainDeviceID>/<projectID>")`, so its state starts fresh when the window selects
  another project.
- `devices` and `forge` never show a state; `skills` shows only the "No Main selected" one (the Skills screen shows its
  own offline state, [skills.md](skills.md)).
- In regular width the toolbar of [§9](#9-toolbar) is attached to `DetailView`.
- macOS: every view the detail shows, the section views and the states of the table, extends under the toolbar
  ([§9.2](#92-toolbar-material-macos)).

#### Offline bar

The bar is in `.safeAreaInset(edge: .top, spacing: 0)` of the section's view, so the view keeps its identity when the
bar comes and goes. While the Main's connection is not connected it is an `HStack(spacing: 6)` with
`StatusDot(isOnline: false)` and "<Main> is offline — <last seen>. Changes are disabled until it reconnects."
(`.callout`, secondary, one line, tail truncation), padding 12 × 6, full width, background `.bar`; otherwise it is
empty.

## 7. Path bar

The path bar shows and changes `{Main} ▸ {project} ▸ {sub project}` like Xcode's jump bar. In regular width it is the
`PathBar` view in the toolbar; in compact width it is the `CompactPathButton` ([§7.4](#74-compact-path-button)).

`PathBar` is an `HStack(spacing: 4)` of segments separated by `Image(systemName: "chevron.right")` (`.caption`,
secondary), with a padding of 10 × 2 pt so that its first and last segments keep clear of the edges of the toolbar
capsule. Each segment is a `Menu` with `.menuStyle(.button)`, `.buttonStyle(.borderless)`,
`.menuIndicator(.hidden)` and `.fixedSize()`; its label is an icon and a one-line title (middle truncation, at most
220 pt wide).

- A Main is online in the path bar when this device's connection to it is connected
  (`workspace.connection(id)?.isConnected`). Its last seen time is `workspace.presence[id]?.lastSeen`.
- Path bar order of the Mains: `workspace.mains`, with this device moved first when it is one of them.

### 7.1 Main segment

- Label: `StatusDot` and `<Main>` ([§6.3](#63-detail)); "No Main" (secondary) when none is selected.
- Menu: an inline `Picker` of the Mains in path bar order. Menus draw symbols in one color, so the state is the
  symbol's shape:

| Main    | Item                                                                           |
|---------|--------------------------------------------------------------------------------|
| online  | `Label("<name>", systemImage: "circle.fill")`                                  |
| offline | `Label("<name> — <PresenceFormat.lastSeen(lastSeen)>", systemImage: "circle")` |

- Choosing another Main sets `selection.mainDeviceID` to it and `projectID` and `item` to nil; rule 2 of
  [§5.3](#53-stored-selection-and-defaults) then selects a project. An offline Main can be chosen: the detail shows its
  offline state.

### 7.2 Project segment

Shown when a Main is selected.

- Label: `folder` and the name of the selected top-level project; "No Project" (secondary) when none.
- Menu when the Main's connection is connected with `projectsLoaded`: an inline `Picker` of its top-level projects
  (`connection.projects`) sorted by name, each "<name> — <identifier>"; choosing another one sets `selection.projectID`
  to it and `item` to nil. Then a `Divider`, "New Project…" (`context.sheet = .newProject(mainDeviceID:)`) and "Add
  Existing Folder…" (`context.sheet = .addExistingFolder(mainDeviceID:)`), the sheets of [overview.md](overview.md).
- Otherwise the menu holds the disabled item "<Main> is offline" (not connected) or "Loading…" (not loaded yet), then
  the `Divider` and New Project… and Add Existing Folder…, disabled.

### 7.3 Sub project segments

The chain is `workspace.projectPath(of: projectID, on: mainDeviceID)`: the ids from the top-level project down to the
selected one ([../client/workspace.md](../client/workspace.md#projects-list)); each id's `ProjectSummary` is
`workspace.summary(of:on:)`. With the chain `[p0, p1, …, pk]` (`p0` is the project segment):

- For each `pi` with `i ≥ 1`: a segment labeled `folder` and `pi`'s name. Menu: an inline `Picker` with "None"
  (selects `p(i−1)`) then the `children` of `p(i−1)` sorted by name, each "<name> — <identifier>".
- When `pk` has children: a last segment labeled `folder` and "None" (secondary). Menu: "None" (checked) then the
  children of `pk`.
- Choosing another entry sets `selection.projectID` to it and `item` to nil. The section is kept.

### 7.4 Compact path button

`CompactPathButton` sits in the navigation bar of the compact sidebar list. Its label is a centered
`VStack(spacing: 0)`: the selected project's name (headline, one line; "Choose a Project" when none), then an
`HStack(spacing: 4)` with a 6 pt `StatusDot` and `<Main>` ("No Main" when none), caption, secondary. A
`chevron.down` (caption) follows the stack. Tapping it sets `context.sheet = .pathPicker`.

`PathPickerSheet` is a `NavigationStack` titled "Main and Project" (inline) holding a `Form`, with a Done button
(confirmationAction) and `.presentationDetents([.medium, .large])`:

| Form section | Content                                                                                                                        |
|--------------|--------------------------------------------------------------------------------------------------------------------------------|
| Main         | an inline `Picker` of the Mains in path bar order; each row: the name and a `PresenceLabel` (online as in the path bar)        |
| Project      | an inline `Picker` of the top-level projects ("<name> — <identifier>"), then the buttons New Project… and Add Existing Folder… |
| Sub Project  | one section per segment of §7.3: an inline `Picker` with "None" and the children                                               |

Choices apply at once with the rules of §7.1–§7.3. New Project… and Add Existing Folder… replace the sheet
(`context.sheet = .newProject(mainDeviceID:)` or `.addExistingFolder(mainDeviceID:)`). While the Main's projects are
not available ([§7.2](#72-project-segment)), the Project section shows the text of the project menu's disabled item
("<Main> is offline" or "Loading…", secondary) instead of the picker, and the two buttons are disabled.

## 8. Banners

Errors show as transient banners at the bottom of the window. `Banners.swift` declares the banner, the banners of a
window and the router of the app:

```swift
public struct Banner: Identifiable, Equatable, Sendable {
    public enum Style: Sendable { case error, info }
    public let id: UUID
    public var style: Style
    public var message: String
    public init(style: Style, message: String)   // id = UUID()
    static func message(of error: any Error) -> String   // the message of an error (§8.1)
}
```

### 8.1 WindowBanners

`WindowBanners` (`@MainActor @Observable`) holds the banners of one window: every main window and the macOS Settings
window have one, in their environment.

| Member                                | Behavior                                                                                                                                                          |
|---------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `banners: [Banner]`                   | the visible banners, oldest first                                                                                                                                 |
| `post(_ banner: Banner)`              | when a visible banner has the same style and message, its timer restarts and nothing is added; else the banner is appended; above 3 banners the oldest is removed |
| `showError(_ error: any Error)`       | `CancellationError`: nothing; else `post` of an error banner with the message of the table below                                                                  |
| `showError(_ message: String)`        | `post` of an error banner                                                                                                                                         |
| `showInfo(_ message: String)`         | `post` of an info banner                                                                                                                                          |
| `dismiss(_ id: Banner.ID)`            | removes the banner and cancels its timer                                                                                                                          |
| `perform(_ operation:) async -> Bool` | runs `operation` (`@MainActor () async throws -> Void`); a thrown error goes to `showError`; returns whether it succeeded (`@discardableResult`)                  |

A banner is removed 4 s after it was posted or after its timer last restarted, or when its close button is clicked.

| Error                                                                | Message                |
|----------------------------------------------------------------------|------------------------|
| `ProtocolError` ([../protocol/envelope.md](../protocol/envelope.md)) | `message`              |
| `DataError` ([../data/app-storage.md](../data/app-storage.md))       | `message`              |
| any other `LocalizedError` with an `errorDescription`                | `errorDescription`     |
| any other error                                                      | `localizedDescription` |

`Banner.message(of:)` (internal) returns the message of this table. `showError(_:)` uses it, and so does every view of
`HephUI` that shows an error's message itself (in a sheet, under a field, in an alert): none has its own copy of the
table.

A user action shows its failure with the `WindowBanners` of its window (`@Environment(WindowBanners.self)`, usually
`perform`). Work that no user action started (autosave, a refresh, the Workspace's error reports) posts with `post(_:)`
of `AppModel.banners` ([§8.2](#82-appbannerrouter)). In the app the environment's `AppModel` is `AppModel.shared`, so
both ways below reach the same router:

- A view takes the router from the `AppModel` of its environment (`@Environment(AppModel.self)`, `appModel.banners`)
  and passes it to the objects it creates for itself, such as the `SkillFileDocument` of a skill file
  ([skills.md](skills.md#file-view)). No view reads `AppModel.shared`: the first read creates the app's `AppModel`
  ([§3](#3-appmodel)), so in a preview or a snapshot test, whose environment holds `AppModel.preview()`
  ([§5.4](#54-previews)), it would use the app's Application Support folder and, on macOS, create the shared host.
- Code that has no SwiftUI environment posts with `AppModel.shared.banners.post(_:)`: the section models of Code, Docs
  and Web, which every window showing the project shares for the life of the process
  ([code.md](code.md#section-model), [docs.md](docs.md#section-model), [web.md](web.md#section-model)), and
  `AttachmentPasteboard` ([media.md](media.md#pastes)).

### 8.2 AppBannerRouter

`AppBannerRouter` (`@MainActor`, `AppModel.banners`) posts banners to the active window.

- `activate(_ banners: WindowBanners)`: the window that became active ([§5.1](#51-rootview)) becomes the target, kept
  weakly. The macOS Settings window activates its own `WindowBanners` when it becomes key
  ([settings.md](settings.md#macos-settingsview)).
- `post(_ banner: Banner)`: posts to the target. Without a live target the banner is kept (only the latest one) and
  posted at the next `activate`.

### 8.3 BannerOverlay

`BannerOverlay` draws the `banners` of the `WindowBanners` of its environment at the bottom center of the window:

- `VStack(spacing: 8)`, oldest on top, max width 560 pt, 16 pt from the bottom and the sides (inside the safe area).
- A banner is an `HStack(spacing: 10)`: the symbol (`exclamationmark.triangle.fill` red for errors, `info.circle.fill`
  accent color for info), the message (`.callout`, up to 3 lines), a `Spacer`, and a close button (`xmark`,
  `.borderless`, help "Close").
- Padding 12; background `.regularMaterial` in a rounded rectangle of corner radius 10 with a 1 pt border (red at 40 %
  opacity for errors, the separator color for info); shadow radius 8, y 2.
- Appearance and removal: `.move(edge: .bottom)` combined with `.opacity`, animated with `.easeOut(duration: 0.2)`.

## 9. Toolbar

| Class   | Attached to                       | Placement         | Items                                                                             |
|---------|-----------------------------------|-------------------|-----------------------------------------------------------------------------------|
| regular | `DetailView`                      | `.principal`      | `PathBar()`                                                                       |
| regular | `DetailView`                      | `.primaryAction`  | `PermissionIndicator()`, `PresenceIndicator()`, Search, `FeedbackToolbarButton()` |
| compact | `SidebarView` (root of the stack) | `.principal`      | `CompactPathButton()`                                                             |
| compact | `SidebarView`                     | `.topBarLeading`  | `PresenceIndicator()`                                                             |
| compact | `SidebarView`                     | `.topBarTrailing` | `PermissionIndicator()`, Search, `FeedbackToolbarButton()`                        |

- `PermissionIndicator()`: [sessions.md](sessions.md#toolbar-indicator). `FeedbackToolbarButton()`:
  [../forge/feedback.md](../forge/feedback.md#entry-points).
- Search: a button with `Label("Search", systemImage: "magnifyingglass")`, help "Search (⌘K)", calling
  `context.openSearch()`.
- In compact width the screens pushed by the sections have their own navigation bars, without these items.

### 9.1 Presence indicator

`PresenceIndicator` is a button whose label is `Label("<n>", systemImage: "laptopcomputer.and.iphone")`
(`.titleAndIcon`), `n` = `workspace.onlineDeviceCount` (this device included). Help: "<n> of <total> devices online",
`total` = the non-revoked devices of `workspace.mesh`. Clicking it calls `context.select(.devices)` (compact: pushes the
Devices screen).

### 9.2 Toolbar material (macOS)

macOS only; iPadOS and iOS keep the system bars. The window's toolbar, over the sidebar column and over the detail, is
a translucent, blurred material, and the content of both columns extends under it: scrolled content shows through,
blurred.

- `SidebarView` and `DetailView` both apply `.toolbarBackgroundVisibility(.visible, for: .windowToolbar)` and
  `.toolbarBackground(.bar, for: .windowToolbar)`, in every section and state, so the toolbar keeps the material even
  when nothing is scrolled under it.
- Neither column, nor any view between a column and its content, draws an opaque background over the top safe area,
  and no view uses `.ignoresSafeArea` on the top edge.
- A SwiftUI `ScrollView` or `List` that reaches the top of its column extends under the toolbar and keeps the default
  safe-area behavior: its first row starts below the toolbar, and only scrolled content passes under it. The sidebar
  list ([§6.2](#62-sidebar)) does so.
- A bar or header pinned above a scroll view (the [offline bar](#offline-bar), the session header of
  [sessions.md](sessions.md#header), the search scope bar of [search.md](search.md)) is in the scroll view's
  `.safeAreaInset(edge: .top)` with a `.bar` background: it stays pinned below the toolbar and the scroll view extends
  under both.
- A view hosted from AppKit or WebKit (the editor of [editor.md](editor.md), the page of a web tab of [web.md](web.md))
  and a view without a scroll view (an `EmptyStateView`, a `ProgressView`) start below the toolbar; the material then
  shows what is behind it, the column's background.

## 10. No Main online

`NoMainOnlineView` replaces the shell of a window on a device that is not a Main when none of its connections is
connected and `graceElapsed` is true. During the first 3 s after launch, and for 3 s after a connection is lost, the
shell stays, with its loading states or the section and its offline bar ([§6.3](#63-detail)). A Main never shows
it: it reaches its own host ([../devices/roles.md](../devices/roles.md#what-the-ui-shows-per-role)).

- A centered column, max width 520 pt: `desktopcomputer` (48 pt, secondary), "No Main online" (`.title2`, bold), then
  "Hephaestus reconnects by itself as soon as a Main is reachable." (secondary).
- A list of the Mains in path bar order: `PlatformIcon`, the name, a `PresenceLabel` (offline, with the last seen
  time), and under it the record's `addresses` joined with ", " followed by " · port <port>", or "port <port>" alone
  when `addresses` is empty (caption, monospaced, selectable). Without any Main: "This mesh has no Main."
- Buttons: "Devices…", which presents `NavigationStack { DevicesView() }` with a Done button in a sheet owned by this
  view; on macOS `SettingsLink { Text("Settings…") }`.
- The window shows no toolbar in this state. Feedback stays available from the menu and the shake gesture.

## 11. Keyboard shortcuts and menus

### 11.1 Shortcuts

| Shortcut | Command                | Menu (macOS) | Enabled when                                                     | Action                                                |
|----------|------------------------|--------------|------------------------------------------------------------------|-------------------------------------------------------|
| ⌘K       | Search…                | Navigate     | the key window shows the shell                                   | `context.openSearch()`                                |
| ⇧⌘F      | Send Feedback…         | Help         | see [../forge/feedback.md](../forge/feedback.md)                 | `FeedbackCommands`                                    |
| ⌘1–⌘6    | Overview … Claude      | Navigate     | the key window shows the shell and a project is selected         | `context.select(<section>)` ([§4](#4-sections))       |
|          | Devices, Skills, Forge | Navigate     | the key window shows the shell                                   | `context.select(<section>)`                           |
| ⌘N       | New Task               | File         | `newTaskAction` is set (Tasks section shown, its Main connected) | calls it ([tasks.md](tasks.md))                       |
| ⌥⌘N      | New Window             | File         | macOS only                                                       | `openWindow(id: AppModel.mainWindowID)`               |
| ⌘T       | New Web Tab            | File         | `newWebTabAction` is set (Web section shown, its Main connected) | calls it ([web.md](web.md))                           |
| ⌘S       | Save                   | File         | `saveDocumentAction` is set (a document is shown)                | calls it ([code.md](code.md#swift-api))               |
| ⌘W       | Close Tab              | File         | `closeTabAction` is set                                          | calls it: closes the current editor tab or web tab    |
| ⌘W       | Close                  | File         | macOS, `closeTabAction` is nil                                   | `NSApp.keyWindow?.performClose(nil)`                  |
| ⌘↩       | Send                   | none         | a message composer has focus                                     | sends ([sessions.md](sessions.md#message-composer))   |
| ⌘,       | Settings…              | Hephaestus   | macOS                                                            | opens the Settings scene ([settings.md](settings.md)) |
| ⌃⌘S      | Show/Hide Sidebar      | View         | macOS                                                            | `SidebarCommands`                                     |

- The key window shows the shell when `windowContext` is set (a main window in phase `.ready`) and the window is not in
  the "No Main online" state ([§10](#10-no-main-online)).
- Every command except ⌘↩ is a SwiftUI command, so the shortcuts also work on iPad with a hardware keyboard (iPadOS
  lists them while ⌘ is held). ⌘↩ belongs to the composer view itself.
- On iOS and iPadOS the ⌘W item is "Close Tab", disabled while `closeTabAction` is nil.
- Find in the editor (⌘F) is the system find of the text view ([editor.md](editor.md)); `TextEditingCommands()`
  provides its menu items on macOS.

### 11.2 Menus

`HephaestusCommands(appModel:)` (`Commands`) reads the key window's values with `@FocusedValue` and opens windows with
`@Environment(\.openWindow)`. Its body, in this order:

| Group                                | Items                                                                    |
|--------------------------------------|--------------------------------------------------------------------------|
| `CommandGroup(replacing: .appInfo)`  | macOS only: "About Hephaestus" ([About](#about))                         |
| `CommandGroup(replacing: .newItem)`  | New Window (macOS only), New Task, New Web Tab                           |
| `CommandGroup(replacing: .saveItem)` | Close Tab / Close, Save                                                  |
| `SidebarCommands()`                  | View ▸ Show Sidebar / Hide Sidebar                                       |
| `TextEditingCommands()`              | Edit ▸ Find and the other text editing items                             |
| `CommandMenu("Navigate")`            | Search…, `Divider`, Overview … Claude, `Divider`, Devices, Skills, Forge |
| `FeedbackCommands()`                 | Help ▸ Send Feedback… ([../forge/feedback.md](../forge/feedback.md))     |

When the key window is not a main window (Settings), `windowContext` is nil: the Navigate items are disabled and ⌘W
closes the key window.

#### About

macOS: "About Hephaestus" calls `NSApplication.shared.orderFrontStandardAboutPanel(options:)` with `.credits` =
`NSAttributedString("Docs <DocsHash.embedded>")` in `NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)`. The
panel shows the name, the version and the build from the bundle. iOS and iPadOS show the same values in Settings
([settings.md](settings.md#about)). `DocsHash.embedded`: [../forge/generation.md](../forge/generation.md).

### 11.3 Focused values

`ShellFocusedValues.swift` declares the focused values of the shell; `newTaskAction` and `saveDocumentAction` are
declared by [tasks.md](tasks.md) and [code.md](code.md):

```swift
extension FocusedValues {
    @Entry public var windowContext: WindowContext?        // RootView, while the phase is .ready
    public var closeTabAction: (() -> Void)? { get set }   // a closable editor tab, document or web tab is current
    public var newWebTabAction: (() -> Void)? { get set }  // the Web section is shown and its Main is connected
}

private struct CloseTabActionKey: FocusedValueKey { typealias Value = () -> Void }
private struct NewWebTabActionKey: FocusedValueKey { typealias Value = () -> Void }
```

The compiler warns that an `@Entry` storing a closure may invalidate its dependents on every update, so the two actions
are declared without `@Entry`: each has a private `FocusedValueKey` and a computed property that reads and writes
`self[<key>.self]`.

A view publishes an action with `.focusedSceneValue(\.<name>, <action>)` only while it is shown and the action is
possible; elsewhere the value is nil and the menu item is disabled.

| Value                | Declared in          | Published by                                                                                                                            | Doc                                                            |
|----------------------|----------------------|-----------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------|
| `newTaskAction`      | [tasks.md](tasks.md) | `TasksView`                                                                                                                             | [tasks.md](tasks.md)                                           |
| `saveDocumentAction` | [code.md](code.md)   | the Code and Docs sections, the skill file view                                                                                         | [code.md](code.md), [docs.md](docs.md), [skills.md](skills.md) |
| `closeTabAction`     | this doc             | the Code section (active tab), the Docs section (shown document), the Web section (active tab; a locked tab shows "This tab is locked") | [code.md](code.md), [docs.md](docs.md), [web.md](web.md)       |
| `newWebTabAction`    | this doc             | the Web section                                                                                                                         | [web.md](web.md)                                               |

## 12. Shared components

Views of `HephUI/Components`, used by every screen:

| Type             | API                                                                                                                            | Rendering                                                                                                                                                                                       |
|------------------|--------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `StatusDot`      | `StatusDot(isOnline: Bool, size: CGFloat = 8)`                                                                                 | a circle of `size`, `Color.green` when online, `Color.gray.opacity(0.6)` otherwise; accessibility label "Online" or "Offline"                                                                   |
| `PresenceLabel`  | `PresenceLabel(isOnline: Bool, lastSeen: Date?)`                                                                               | `HStack(spacing: 4)`: `StatusDot`, then "Online" or `PresenceFormat.lastSeen(lastSeen)`; caption, secondary; refreshed every minute (`TimelineView(.everyMinute)`)                              |
| `PresenceFormat` | `static func lastSeen(_ date: Date?, now: Date = .now) -> String`                                                              | "Last seen " + `Date.AnchoredRelativeFormatStyle(anchor: date, presentation: .named).format(now)`, the date relative to `now` (for example "Last seen 5 minutes ago"); nil: "Never seen online" |
| `EmptyStateView` | `EmptyStateView(symbol: String, title: String, message: String? = nil, @ViewBuilder actions: () -> Actions = { EmptyView() })` | `ContentUnavailableView` with `Label(title, systemImage: symbol)`, the message as description, and the actions                                                                                  |
| `PlatformIcon`   | `PlatformIcon(platform: DevicePlatform)`                                                                                       | `Image(systemName:)`: `desktopcomputer` (macOS), `iphone` (iOS), `ipad` (iPadOS)                                                                                                                |
| `ChipToggle`     | `ChipToggle(title: String, isOn: Bool, action: @escaping () -> Void)`                                                          | a capsule button, `.buttonStyle(.plain)`, callout font, padding 10 × 4 pt; on: accent text on the accent color at 20 % opacity; off: primary text on `.quaternary`                              |

## 13. Swift API

Everything below is `@MainActor` unless marked otherwise.

```swift
// HephUI/App
@MainActor @Observable
public final class AppModel {
    public enum Phase: Equatable, Sendable { case launching, onboarding, ready }
    public static let shared: AppModel                       // AppModel(appSupport: AppSupport.standard())
    public static let mainWindowID: String                   // "main"
    init(appSupport: AppSupport)                             // only for `shared`; macOS: HostService.makeShared (§3)
    public static func preview() -> AppModel                 // previews and snapshot tests (§5.4)

    public let appSupport: AppSupport
    public let settings: SettingsStore
    public let identity: DeviceIdentityStore
    public let workspace: Workspace
    public let banners: AppBannerRouter
    public var phase: Phase { get }
    public private(set) var graceElapsed: Bool
    #if os(macOS)
    public let host: HostService
    public private(set) var listenerError: String?
    public let updateModel: UpdateModel
    public let updater: UpdateService
    #endif

    public func start() async
    public func setLocalName(_ name: String) throws
    public func renameDevice(_ id: UUID, to name: String) async throws
    public var renameConnection: MainConnection? { get }
    public func didJoinMesh()
    public func leaveMesh() async throws
    #if os(macOS)
    public func becomeMain() async throws
    public func resignMain() async throws
    public func isMigrationActive() async -> Bool
    public func restartListener() async
    public func refreshListenerError() async
    public func shutdown() async
    public func privateTermsCount() -> Int
    public func editPrivateTerms() async throws
    public func privateTermSuggestions() async -> [String]
    public func addPrivateTerm(_ term: String) async throws
    public func dismissPrivateTerm(_ term: String) async throws
    #endif
}

#if os(macOS)
public final class HephaestusAppDelegate: NSObject, NSApplicationDelegate { public override init() }
#endif

public struct RootView: View { public init() }

extension View {
    /// The environment of a window around a preview (§5.4).
    public func previewWindow(_ appModel: AppModel, selection: Selection) -> some View
}

@MainActor @Observable
public final class WindowContext {
    public init(selection: Selection)
    public let selection: Selection
    public let banners: WindowBanners
    public var sheet: ShellSheet?
    public var isSearchPresented: Bool
    public var isCompact: Bool
    public func select(_ section: SidebarSection)
    public func navigate(mainDeviceID: UUID?, projectID: String?, section: SidebarSection, item: String?)
    public func openSearch()
}

public enum ShellSheet: Identifiable, Hashable {
    case pathPicker
    case newProject(mainDeviceID: UUID)
    case addExistingFolder(mainDeviceID: UUID)
    case search
    public var id: String { get }                            // "pathPicker", "newProject-<uuid>", …
}

// HephUI/Shell
public struct HephaestusCommands: Commands { public init(appModel: AppModel) }

public struct Banner: Identifiable, Equatable, Sendable { … }   // §8

@MainActor @Observable
public final class WindowBanners {
    public init()
    public private(set) var banners: [Banner]
    public func post(_ banner: Banner)
    public func showError(_ error: any Error)
    public func showError(_ message: String)
    public func showInfo(_ message: String)
    public func dismiss(_ id: Banner.ID)
    @discardableResult
    public func perform(_ operation: @MainActor () async throws -> Void) async -> Bool
}

@MainActor
public final class AppBannerRouter {
    public init()
    public func post(_ banner: Banner)
    public func activate(_ banners: WindowBanners)
}

public struct BannerOverlay: View { public init() }          // reads WindowBanners from the environment

extension SidebarSection {
    public var title: String { get }
    public var symbolName: String { get }
    public var shortcutKey: KeyEquivalent? { get }           // "1"…"7" for the project sections, else nil
    public static var projectSections: [SidebarSection] { get }
    public static var workspaceSections: [SidebarSection] { get }
}

public enum SelectionDefaults {
    /// Path bar order: workspace.mains with this device first when it is a Main.
    public static func orderedMains(_ workspace: Workspace) -> [DeviceRecord]
    /// The rules of §5.3.
    public static func apply(to selection: Selection, workspace: Workspace, isCompact: Bool)
}

// HephUI/Components
public struct StatusDot: View { public init(isOnline: Bool, size: CGFloat = 8) }
public struct PresenceLabel: View { public init(isOnline: Bool, lastSeen: Date?) }
public enum PresenceFormat { public static func lastSeen(_ date: Date?, now: Date = .now) -> String }
public struct EmptyStateView<Actions: View>: View {
    public init(symbol: String, title: String, message: String? = nil,
                @ViewBuilder actions: () -> Actions = { EmptyView() })
}
public struct PlatformIcon: View { public init(platform: DevicePlatform) }
public struct ChipToggle: View { public init(title: String, isOn: Bool, action: @escaping () -> Void) }
```

## 14. Depends on

| Name                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Defined in                                                                                                                               |
|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| `Workspace` (`init(device:environment:)`, `start`, `stop`, `restart`, `reset`, `retryNow`, `setLocalHostLink`, `updateLocalDevice`, `makeSelection`, `errorReports`, `events()`, `connection(_:)`, `projectStore(mainDeviceID:projectID:)`, `summary(of:on:)`, `projectPath(of:on:)`, `mains`, `localConnection`, `presence`, `onlineDeviceCount`, `mesh`, `hasMesh`, `topologyRevision`, `forge`, `preview()`), `WorkspaceEnvironment.live(appSupport:credentialStore:identityStore:)`, `WorkspaceEvent`, `MainConnection`, `ProjectStore` (`phase`, `project`, `reload()`), `LocalHostLink`, `Selection`, `SidebarSection` | [../client/workspace.md](../client/workspace.md)                                                                                         |
| `DeviceIdentityStore`, the Main toggle and leave procedures, names                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [../devices/roles.md](../devices/roles.md)                                                                                               |
| `AppSupport`, `SettingsStore`, `RegistryCache`, `WindowStateKeys`, `DataError`, `KeychainCredentialStore`, `InMemoryCredentialStore`, `DeviceFile`                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | [../data/app-storage.md](../data/app-storage.md)                                                                                         |
| `HostService` (`makeShared(appSupport:settings:credentialStore:)`, `shared`, `init(appSupport:settings:credentialStore:options:)`, `start`, `stop`, `restartListener`, `listenerError`, `projectsFileWasReset`, `makeLoopbackChannel`, `hasActiveWork`, `mesh.resignMain`, `migration.isActive`)                                                                                                                                                                                                                                                                                                                             | [../services/host.md](../services/host.md), [../devices/mesh.md](../devices/mesh.md), [../devices/migration.md](../devices/migration.md) |
| `ForgeService.privateTermsCount()`, `ForgeService.preparePrivateTerms()`, `ForgeService.privateTermSuggestions()`, `ForgeService.addPrivateTerm(_:)`, `ForgeService.dismissPrivateTerm(_:)` (`host.forge`)                                                                                                                                                                                                                                                                                                                                                                                                                   | [../forge/pipeline.md](../forge/pipeline.md#private-terms)                                                                               |
| `UpdateModel`, `UpdateService` (`init(model:isBusy:)`, `start`, `stop`, `releaseNoticed(build:)`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [../forge/update.md](../forge/update.md)                                                                                                 |
| `.feedbackSupport()`, `FeedbackToolbarButton`, `FeedbackCommands`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | [../forge/feedback.md](../forge/feedback.md)                                                                                             |
| `ForgeModel.releaseObserver`, `ForgeView`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | [forge.md](forge.md)                                                                                                                     |
| `DocsHash.embedded`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | [../forge/generation.md](../forge/generation.md)                                                                                         |
| `DeviceRecord`, `DevicePlatform`, `MeshSnapshot`, `Presence`, `ProjectSummary`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | [../protocol/types.md](../protocol/types.md)                                                                                             |
| `ProtocolError`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [../protocol/envelope.md](../protocol/envelope.md)                                                                                       |
| `OverviewView`, `NewProjectSheet`, `AddExistingFolderSheet`, `.migrationProgressPresenter()`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [overview.md](overview.md)                                                                                                               |
| `TasksView`, `newTaskAction`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [tasks.md](tasks.md)                                                                                                                     |
| `CodeView`, `saveDocumentAction`, `DocsView`, `WebTabsView`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | [code.md](code.md), [docs.md](docs.md), [web.md](web.md)                                                                                 |
| `ClaudeView`, `PermissionIndicator`, `.permissionBanner()`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | [sessions.md](sessions.md)                                                                                                               |
| `SkillsView`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | [skills.md](skills.md)                                                                                                                   |
| `OnboardingView`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | [onboarding.md](onboarding.md)                                                                                                           |
| `SettingsView`, `SettingsSheet`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [settings.md](settings.md)                                                                                                               |
| `DevicesView`, `JoinMeshView`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | [devices.md](devices.md)                                                                                                                 |
| `SearchPalette`, `SearchScreen`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | [search.md](search.md)                                                                                                                   |
