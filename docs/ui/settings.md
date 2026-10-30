# Settings

files:
- HephaestusKit/Sources/HephUI/Settings/SettingsView.swift
- HephaestusKit/Sources/HephUI/Settings/SettingsSheet.swift
- HephaestusKit/Sources/HephUI/Settings/GeneralSettingsPane.swift
- HephaestusKit/Sources/HephUI/Settings/DeviceNameField.swift
- HephaestusKit/Sources/HephUI/Settings/AddressListEditor.swift
- HephaestusKit/Sources/HephUI/Settings/ClaudeSettingsPane.swift
- HephaestusKit/Sources/HephUI/Settings/SkillsSettingsPane.swift
- HephaestusKit/Sources/HephUI/Settings/ForgeSettingsPane.swift
- HephaestusKit/Sources/HephUI/Settings/AboutSection.swift

---

Settings edit this device: its name ([../devices/roles.md](../devices/roles.md#names)), its Main role, and the keys of
`settings.json` ([../data/app-storage.md](../data/app-storage.md#settingsjson)), read and written through
`AppModel.settings` (`SettingsStore`). What each key does is in the doc of its "Used by" column there.

| Platform       | Presentation                                                                                                            |
|----------------|-------------------------------------------------------------------------------------------------------------------------|
| macOS          | the `Settings` scene (⌘,): `SettingsView`, a `TabView` with the panes General, Devices, Claude, Skills, Forge & Updates |
| iOS and iPadOS | `SettingsSheet`, a sheet opened by the Settings button of the Devices screen ([devices.md](devices.md#toolbar))         |

## Rules for every control

- A key is written with `settings.update { … }`. `SettingsStore` normalizes and validates the change; when it throws,
  the error message (`DataError.message`) shows in red under the control and the control returns to the stored value.
- Text and number fields commit on Return and when they lose focus; a commit whose normalized value equals the stored
  value writes nothing. Toggles and pickers commit on change.
- Controls marked "Main" are shown only while this Mac is a Main (`identity.isMain`).
- The caption of a `Toggle` or of a `LabeledContent` row is the second `Text` of its label, which the grouped form
  shows under the label; the caption of a section (New Sessions, Skills, Forge) is the section's footer.

## macOS: SettingsView

`SettingsView` is a `TabView`; each tab is a pane with `.tabItem { Label(<title>, systemImage: <symbol>) }`:

| Tab             | Symbol                         | Pane                                       | Frame                     |
|-----------------|--------------------------------|--------------------------------------------|---------------------------|
| General         | `gearshape`                    | `GeneralSettingsPane`                      | width 620, min height 380 |
| Devices         | `laptopcomputer.and.iphone`    | `DevicesView()` ([devices.md](devices.md)) | width 680, height 520     |
| Claude          | `bubble.left.and.bubble.right` | `ClaudeSettingsPane`                       | width 620, min height 380 |
| Skills          | `wand.and.stars`               | `SkillsSettingsPane`                       | width 620, min height 380 |
| Forge & Updates | `hammer`                       | `ForgeSettingsPane`                        | width 620, min height 380 |

- Every pane except Devices is a `Form` with `.formStyle(.grouped)`.
- `SettingsView` creates, when it first appears, its own `WindowBanners` and its own `Selection`
  (`workspace.makeSelection()`), so the Devices pane works as in a main window ([shell.md](shell.md#8-banners)).
- Modifiers on the `TabView`, from inner to outer: `.feedbackSupport(section: "settings")`
  ([../forge/feedback.md](../forge/feedback.md#window-binding)); `.overlay(alignment: .bottom) { BannerOverlay() }`;
  `.environment` of the `WindowBanners`, the `Selection`, `appModel.workspace`, `appModel.settings` and
  `appModel.updateModel`.
- When the Settings window becomes key (`controlActiveState == .key`): `appModel.banners.activate(<its
  WindowBanners>)` ([shell.md](shell.md#82-appbannerrouter)).

## General

`GeneralSettingsPane`, top to bottom:

| Section     | Control                  | Kind                    | Edits                                        | Shown       |
|-------------|--------------------------|-------------------------|----------------------------------------------|-------------|
| This Device | Device name              | `DeviceNameField`       | the device name                              | always      |
| This Device | Save edits automatically | toggle                  | `autosave`                                   | always      |
| Main        | Use this Mac as a Main   | toggle                  | the Main role (`isMain`), through `AppModel` | macOS       |
| Main        | Projects folder          | path and Choose… button | `projectsFolder`                             | macOS, Main |
| Main        | Listener port            | number field            | `listenerPort`                               | macOS, Main |
| Main        | Additional addresses     | `AddressListEditor`     | `additionalAddresses`                        | macOS, Main |

### Device name

`DeviceNameField` is the text field "Device name" showing `identity.name`; it is also used by `SettingsSheet`.

- Without a mesh (`workspace.hasMesh` false): a commit calls `try appModel.setLocalName(<text>)`.
- In a mesh: a commit calls `try await appModel.renameDevice(identity.id, to: <text>)`
  ([shell.md](shell.md#32-device-names)), which sends `mesh.renameDevice`; while it runs, the field is disabled.
- In a mesh, while `appModel.renameConnection` is nil, the field is disabled and the caption "Connect to a Main to
  rename this device." shows under it ([../devices/roles.md](../devices/roles.md#names)).
- A failure shows its message in red under the field, and the field returns to `identity.name`.

### Other controls

- Save edits automatically: caption "Editors save 1.5 s after the last change." ([code.md](code.md)).
- Use this Mac as a Main, the procedures of [../devices/roles.md](../devices/roles.md):
  - Turning it on: `try await appModel.becomeMain()`, with a small `ProgressView` beside the toggle while it runs. A
    failure turns the toggle back off and shows the alert "This Mac could not become a Main" with the error message.
  - Turning it off: when `await appModel.isMigrationActive()`, the toggle stays on and the alert "A project is being
    moved. Try again when the move has finished." shows. Else a confirmation alert titled "Stop using this Mac as a
    Main?", message "Its projects stay on this Mac but other devices cannot open them until you turn this back on.
    Running Claude sessions and runs are stopped.", buttons "Stop" (destructive) and "Cancel". Stop calls
    `try await appModel.resignMain()` through `perform` of the Settings window's `WindowBanners`, so a failure shows
    as that window's error banner; Cancel leaves the toggle on.
- Projects folder: the stored value, monospaced, middle truncation. "Choose…" opens an `NSOpenPanel` with
  `canChooseDirectories = true`, `canChooseFiles = false`, `allowsMultipleSelection = false`,
  `canCreateDirectories = true`, `prompt = "Choose"`, `directoryURL` = `DeviceSettings.projectsFolderURL`; the chosen
  path is stored with `(path as NSString).abbreviatingWithTildeInPath`. Caption: "New projects and projects moved to
  this Mac are created here."
- Listener port: a `TextField` with an integer format without grouping separators. After a successful write it calls
  `await appModel.restartListener()` ([shell.md](shell.md#33-main-toggle)). Under the field: when
  `appModel.listenerError` is set, its text in red; else "Other devices connect to this Mac on port <listenerPort>."
  (secondary). Each time the pane appears, on a Main or not, the pane calls `await appModel.refreshListenerError()`:
  a replacement of the listener after a key change can set or clear the error
  ([../devices/mesh.md](../devices/mesh.md#receiving-a-new-key)). On a Mac that is not a Main it reads nil: the host
  has not started, or `HostService.stop()` cleared the error ([../services/host.md](../services/host.md#32-stop)).

### Additional addresses

`AddressListEditor` edits `additionalAddresses`:

- One row per address: the address (monospaced) and a remove button (`minus.circle.fill`, red, `.borderless`, help
  "Remove").
- A last row: a text field (placeholder "Host name or IP address", no autocorrection) and an "Add" button, enabled when
  the trimmed text is not empty, contains no whitespace and is not in the list yet. Return in the field adds.
- Caption: "Other devices also try these addresses to reach this Mac, for example a VPN address. The .local name and
  the IPv4 addresses of this Mac are added automatically."
- Each add or remove:
  1. `try settings.update { $0.additionalAddresses = <new list> }`; a failure shows its message and stops here.
  2. `try await workspace.localConnection?.setAddresses(settings.settings.additionalAddresses)`
     (`mesh.setAddresses`, [../protocol/methods.md](../protocol/methods.md#meshsetaddresses)), so this Mac's record and
     the other devices are updated. A failure shows "The addresses are saved but the other devices were not updated:
     <message>" in red under the list.
  While a change runs, the editor is disabled.

## Claude

`ClaudeSettingsPane`, macOS. When this Mac is not a Main the pane shows only `EmptyStateView(symbol:
"desktopcomputer", title: "This Mac is not a Main", message: "Claude runs on Mains. Turn on “Use this Mac as a Main”
in General.")`.

| Section       | Control                          | Kind                                                             | Edits                   |
|---------------|----------------------------------|------------------------------------------------------------------|-------------------------|
| Claude CLI    | Path                             | text field (prompt "Automatic", monospaced) and a Choose… button | `claudePath`            |
| Claude CLI    | Status                           | text                                                             | nothing                 |
| New Sessions  | Default model                    | `ClaudeModelField(model:placeholder: "CLI Default", onCommit:)`  | `defaultModel`          |
| New Sessions  | Default permission mode          | `PermissionModePicker(selection:defaultLabel: nil)`              | `defaultPermissionMode` |
| Idle Sessions | Stop idle Claude processes after | menu `Picker`                                                    | `sessionIdleMinutes`    |

- Path: empty means the CLI is found automatically ([../claude/cli.md](../claude/cli.md)). "Choose…" opens an
  `NSOpenPanel` with `canChooseFiles = true`, `canChooseDirectories = false`, `showsHiddenFiles = true`,
  `directoryURL` = `~/.local/bin`; the chosen path is stored with `abbreviatingWithTildeInPath`.
- Status, from `workspace.localConnection?.hostInfo`: refreshed with `refreshHostInfo()` when the pane appears and
  after each write of `claudePath`; a small `ProgressView` while it runs. `claudeAvailable` true:
  `StatusDot(isOnline: true)` and "Using <claudePath>" (monospaced, selectable). False: `StatusDot(isOnline: false)`
  and "Claude CLI not found. Install it or enter its path." in red.
- `ClaudeModelField` and `PermissionModePicker` are the controls of [sessions.md](sessions.md#labels). The model commits
  its trimmed text (empty: no `--model`). The permission mode picker has no default choice: it lists the five modes.
- Caption of New Sessions: "Used for new sessions of projects that set no model or permission mode."
- Idle choices: "5 minutes", "10 minutes", "15 minutes", "30 minutes", "1 hour", "2 hours", "4 hours" (5, 10, 15, 30,
  60, 120, 240). A stored value that is not a choice is listed as an extra item "<n> minutes".

## Skills

`SkillsSettingsPane`, macOS. When this Mac is not a Main: `EmptyStateView(symbol: "desktopcomputer", title: "This Mac
is not a Main", message: "The skills library lives on Mains. Turn on “Use this Mac as a Main” in General.")`.

- "Library folder": `appModel.appSupport.skillsFolder.path` with `abbreviatingWithTildeInPath`, monospaced,
  selectable, read-only ([../claude/skills.md](../claude/skills.md)).
- Caption: "Skills are created and edited in the Skills section. This folder is separate from ~/.claude."

## Forge & Updates

`ForgeSettingsPane`, macOS.

### Forge

Main only; on a Mac that is not a Main the section shows only the text "Available when this Mac is a Main." (caption
font, secondary) and no footer.

| Control                  | Kind                                      | Edits                                              |
|--------------------------|-------------------------------------------|----------------------------------------------------|
| This Main is the Forge   | toggle                                    | `forge.enabled`                                    |
| Source project           | menu `Picker`                             | `forge.sourceProjectID`                            |
| Repository               | text field, "owner/name"                  | `forge.repository`                                 |
| Branch                   | text field                                | `forge.branch`                                     |
| Regenerate automatically | toggle                                    | `forge.autoRegenerate`                             |
| Private terms            | the number of terms and an "Edit…" button | `private-terms.txt` of this Mac, in its own editor |

- The controls after the first are disabled while `forge.enabled` is false. Private terms is shown only while
  `forge.enabled` is true.
- Source project: the projects of this Mac's project tree (`workspace.localConnection?.projects`), depth first (sub
  projects after their parent), each "<name> — <identifier>", tagged with the identifier. A stored identifier that is
  not in the tree is listed as an extra item "<identifier> (not on this Mac)".
- Caption: "The Forge turns feedback into documentation changes, regenerates the app and follows its CI build."
- The pane only writes the settings; the host applies them ([../forge/pipeline.md](../forge/pipeline.md)).
- Private terms: the words the personal data check refuses in the public repository, kept in `private-terms.txt` in
  this Mac's Application Support folder ([../forge/pipeline.md](../forge/pipeline.md#private-terms),
  [../public-repository.md](../public-repository.md)).
  - The value is "<n> terms" ("1 term" when `n` is 1), `n` = `appModel.privateTermsCount()`, read only while the row
    is shown: when the pane appears, after "Edit…", each time the Settings window becomes key (the user edits the
    file in another app), and when `forge.enabled` or the Main role changes.
  - "Edit…" calls `try await appModel.editPrivateTerms()`, which writes the pre-filled file when it is missing and
    opens it in the default text editor. While it runs the button is disabled; a failure shows its message in red
    under the row.
  - Suggestions: `k` = the count of `await appModel.privateTermSuggestions()`, read at the same times as `n`. While `k`
    is above 0, the row shows under the value "<k> new suggestions" ("1 new suggestion" when `k` is 1) in orange and a
    "Review…" button. "Review…" opens the sheet "New Private Terms": the caption "Hephaestus found these words on this
    Mac since the file was written. Add a word the check must refuse; dismiss a word that is not private. The Forge
    pushes nothing until each one is added or dismissed.", then one row per suggestion, in order: the word
    (monospaced), an "Add" button (`try await appModel.addPrivateTerm(<word>)`) and a "Dismiss" button
    (`try await appModel.dismissPrivateTerm(<word>)`). After each, the suggestions and `n` are read again, and a
    failure shows its message in red in the sheet; the buttons are disabled from the click until the suggestions and
    `n` have been read again. "Done" (`confirmationAction`) closes the sheet, which shows "No new suggestions" once the
    list is empty.
  - Caption: "Words the personal-data check refuses in the public repository. Hephaestus never sends this file
    anywhere."

### Updates

| Control              | Kind                                                         | Edits                     |
|----------------------|--------------------------------------------------------------|---------------------------|
| Update automatically | toggle                                                       | `updates.enabled`         |
| Status               | `UpdateStatusView()` ([forge.md](forge.md#updatestatusview)) | nothing                   |
| Signing identity     | menu `Picker`                                                | `updates.signingIdentity` |

- Update automatically caption: "When off, Hephaestus checks for new builds and offers Install instead of installing
  them by itself." ([../forge/update.md](../forge/update.md)).
- Signing identity: the choices, in this order, are "Automatic" (tag `""`), "Keep the ad-hoc signature" (tag `"-"`),
  then one item per identity of `await appModel.updater.signingIdentities()`, labeled with its `name` and tagged with
  its `sha1`. The identities are loaded when the pane appears; meanwhile a small `ProgressView` shows beside the
  picker. A stored value that is not one of these tags is listed as an extra last item showing the value.
- Signing identity caption: "Automatic: the first Apple Development or Developer ID Application identity of this Mac."
  ([../forge/update.md](../forge/update.md)).

## iOS and iPadOS: SettingsSheet

`SettingsSheet` is a `NavigationStack` titled "Settings" (inline) with a Done button (confirmationAction), holding a
`Form`:

| Section     | Content                                                                   |
|-------------|---------------------------------------------------------------------------|
| This Device | `DeviceNameField` and Save edits automatically, as in [General](#general) |
| About       | `AboutSection()`                                                          |

A Mac shows its version and docs hash in the About panel instead ([shell.md](shell.md#about)).

### About

`AboutSection` is a `Section("About")`:

- "Version": "<CFBundleShortVersionString> (build <CFBundleVersion>)" of `Bundle.main`.
- "Docs": `DocsHash.embedded` ([../forge/generation.md](../forge/generation.md)), monospaced caption, selectable, up to
  2 lines.

## Swift API

```swift
// HephUI/Settings — @MainActor; read AppModel, Workspace and SettingsStore from the environment.
public struct SettingsView: View { public init() }          // macOS Settings scene
public struct SettingsSheet: View { public init() }         // iOS and iPadOS, presented by DevicesView
struct GeneralSettingsPane: View { init() }                 // macOS
struct DeviceNameField: View { init() }                     // every platform
struct AddressListEditor: View { init() }                   // every platform
struct ClaudeSettingsPane: View { init() }                  // macOS
struct SkillsSettingsPane: View { init() }                  // macOS
struct ForgeSettingsPane: View { init() }                   // macOS
struct AboutSection: View { init() }                        // every platform
```

`SettingsView` and its four panes are compiled for macOS only and `SettingsSheet` for iOS and iPadOS only, each file
inside `#if os(...)`; `DeviceNameField`, `AddressListEditor` and `AboutSection` build on every platform.

`SettingsView` and `SettingsSheet` end their files with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

| Name                                                                                                                                                                                                                                                                                                                                                                                                                                        | Defined in                                                                                                     |
|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `settings.json` keys, `SettingsStore`, `DeviceSettings`, `DataError`, `AppSupport.skillsFolder`                                                                                                                                                                                                                                                                                                                                             | [../data/app-storage.md](../data/app-storage.md)                                                               |
| device names, the Main toggle procedures and texts                                                                                                                                                                                                                                                                                                                                                                                          | [../devices/roles.md](../devices/roles.md)                                                                     |
| `AppModel` (`becomeMain`, `resignMain`, `isMigrationActive`, `restartListener`, `refreshListenerError`, `renameDevice`, `renameConnection`, `setLocalName`, `listenerError`, `updater`, `privateTermsCount`, `editPrivateTerms`, `privateTermSuggestions`, `addPrivateTerm`, `dismissPrivateTerm`), `WindowBanners`, `AppBannerRouter`, `BannerOverlay`, `StatusDot`, `EmptyStateView`, `AppModel.preview()`, `previewWindow(_:selection:)` | [shell.md](shell.md)                                                                                           |
| `private-terms.txt`, the pre-filled file, the count of terms, the suggestions                                                                                                                                                                                                                                                                                                                                                               | [../forge/pipeline.md](../forge/pipeline.md#private-terms), [../public-repository.md](../public-repository.md) |
| `DevicesView`                                                                                                                                                                                                                                                                                                                                                                                                                               | [devices.md](devices.md)                                                                                       |
| `ClaudeModelField`, `PermissionModePicker`                                                                                                                                                                                                                                                                                                                                                                                                  | [sessions.md](sessions.md)                                                                                     |
| `UpdateStatusView`                                                                                                                                                                                                                                                                                                                                                                                                                          | [forge.md](forge.md)                                                                                           |
| `Workspace` (`localConnection`, `hasMesh`, `makeSelection`), `MainConnection` (`hostInfo`, `refreshHostInfo`, `setAddresses`, `projects`), `Selection`                                                                                                                                                                                                                                                                                      | [../client/workspace.md](../client/workspace.md)                                                               |
| `.feedbackSupport(section:)`                                                                                                                                                                                                                                                                                                                                                                                                                | [../forge/feedback.md](../forge/feedback.md)                                                                   |
| `UpdateModel`, `UpdateService.signingIdentities()`, `SigningIdentity`, `updates.enabled` and signing identity values                                                                                                                                                                                                                                                                                                                        | [../forge/update.md](../forge/update.md)                                                                       |
| `DocsHash.embedded`                                                                                                                                                                                                                                                                                                                                                                                                                         | [../forge/generation.md](../forge/generation.md)                                                               |
