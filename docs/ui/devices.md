# Devices screen

files:
- HephaestusKit/Sources/HephUI/Devices/DevicesView.swift
- HephaestusKit/Sources/HephUI/Devices/DeviceRow.swift
- HephaestusKit/Sources/HephUI/Devices/RenameDeviceSheet.swift
- HephaestusKit/Sources/HephUI/Devices/PairingCodeSheet.swift
- HephaestusKit/Sources/HephUI/Devices/JoinMeshView.swift
- HephaestusKit/Sources/HephUI/Devices/JoinMeshModel.swift
- HephaestusKit/Sources/HephUI/Devices/PairingCodeField.swift

---

The Devices section (workspace section of the sidebar, [shell.md](shell.md#4-sections)) lists every device of the
mesh with its role and online state, and holds the device actions: Pair a New Device, Rename, Revoke and Leave Mesh.
The same view is the Devices tab of the macOS Settings ([settings.md](settings.md)). This doc also holds the join
flow used by onboarding ([onboarding.md](onboarding.md)). Roles: [../devices/roles.md](../devices/roles.md); pairing,
registry and revocation: [../devices/mesh.md](../devices/mesh.md).

Requests go through the Workspace request API ([../client/workspace.md](../client/workspace.md#request-api)). A failed
request shows the window's error banner ([shell.md](shell.md#8-banners)), except in sheets, which show the error
message in red above their buttons.

## Device list

`DevicesView` is a `List` titled "Devices" (`.navigationTitle`):

- Source: the records of `workspace.mesh` that are not revoked, with the merged presence `workspace.presence[id]`.
  "This device" is the record whose id is `workspace.device.id`.
- Two sections: "Mains" (records with `isMain`) and "Remotes" (the others). In each, this device first, then by name
  (`localizedStandardCompare`). A section without devices is hidden. Without a mesh snapshot: `EmptyStateView(symbol:
  "laptopcomputer.and.iphone", title: "No devices")`.
- While `selection.section` is `.devices`, the list's selection is `selection.item` (the device id as `uuidString`):
  choosing a row selects it; an item set from elsewhere (search) selects and scrolls to that row
  ([shell.md](shell.md#4-sections)). Otherwise the list's selection is view state (`@State var selectedID: String?`)
  and `selection.item` is neither read nor written: in the Devices tab of the macOS Settings (its selection has no
  section) and in the sheet that shows `DevicesView` over another section (Devices… of the No Main online state,
  [shell.md](shell.md#10-no-main-online)).

### Row

`DeviceRow` is an `HStack(spacing: 12)`:

| Part    | Content                                                                                                                                                          |
|---------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| icon    | `PlatformIcon(platform:)`, `.title2`, 32 pt wide                                                                                                                 |
| line 1  | the name (headline); for this device a "This Device" capsule (caption, accent color text on the accent color at 15 % opacity)                                    |
| line 2  | caption, secondary: "Main" or "Remote", " · ", a `PresenceLabel(isOnline:lastSeen:)` from the merged presence, " · ", "Version <appVersion> (<build>)"           |
| line 3  | Mains only; caption, monospaced, secondary, selectable: the record's `addresses` joined with ", ", then " · port <port>"; "No address" when `addresses` is empty |
| actions | trailing `Menu` (`ellipsis.circle`, `.borderless`, `.menuIndicator(.hidden)`) with the actions below; the row's context menu holds the same actions              |

| Action      | Shown for          | Enabled when                                                                  |
|-------------|--------------------|-------------------------------------------------------------------------------|
| Rename…     | every device       | `appModel.renameConnection` is not nil ([shell.md](shell.md#32-device-names)) |
| Revoke…     | every other device | a revoking connection exists ([Revoke](#revoke))                              |
| Leave Mesh… | this device        | always                                                                        |

### Toolbar

`.primaryAction`:

- "Pair a New Device…" (`plus`), following [../devices/roles.md](../devices/roles.md#what-the-ui-shows-per-role):
  - this device is a Main (`appModel.identity.isMain`): a button that opens the [pairing sheet](#pairing-code-sheet)
    on this Mac: `mainDeviceID` is `workspace.device.id`, whose connection is the loopback one
    (`workspace.localConnection`);
  - otherwise, with the connected Mains of `workspace.mains`: none → a disabled button with the help "No Main is
    online."; one → a button for that Main; several → a `Menu` titled "Pair a New Device…" listing them by name.
- iOS and iPadOS: "Settings" (`gearshape`), which presents `SettingsSheet()` ([settings.md](settings.md)).

## Rename

`RenameDeviceSheet(deviceID:)`:

- Title "Rename <name>"; a text field "Name" prefilled with the current name and focused. The current name is the
  name of the device's record in `workspace.mesh`. macOS: min width 360 pt.
- Buttons: Cancel (Escape) and Rename (default action), enabled when the trimmed text is not empty, differs from the
  current name, and no request runs.
- Rename calls `try await appModel.renameDevice(deviceID, to: <text>)` ([shell.md](shell.md#32-device-names)).
  Success dismisses the sheet; failure shows the message in red above the buttons.

## Revoke

- The revoking connection for device X: `workspace.localConnection` when it is connected (this Mac is a Main, and X
  is another device); else the connection of the first Main of `workspace.mains` that is connected and is not X. A Main
  cannot revoke itself ([../devices/mesh.md](../devices/mesh.md#revoking)).
- Confirmation alert: title "Revoke “<name>”?", message "<name> is removed from the mesh and can no longer connect. The
  mesh key is replaced: the devices connected now receive the new key and reconnect by themselves; the devices that are
  offline now will have to pair again.", buttons "Revoke" (destructive) and "Cancel".
- Revoke sends `revokeDevice(<id>)` (`mesh.revokeDevice`) on the revoking connection. The row disappears when the
  registry update arrives (`mesh.changed`). When no revoking connection remains once the alert is confirmed, the error
  banner shows "No Main is online." (`ProtocolError(.unavailable, "No Main is online.")`).

## Leave mesh

The procedure of [../devices/roles.md](../devices/roles.md#leaving-the-mesh):

1. On a Main, when `await appModel.isMigrationActive()`: the alert "A project is being moved. Try again when the move
   has finished." and nothing else.
2. Confirmation alert: title "Leave the mesh?", message "This device forgets the mesh key and the device list. Its
   record stays on the other devices until one of them revokes it. To come back, pair it again.", buttons "Leave Mesh"
   (destructive) and "Cancel".
3. Leave Mesh calls `try await appModel.leaveMesh()` ([shell.md](shell.md#34-mesh-membership)); every window then
   shows onboarding. A failure shows the error banner.

## Pairing code sheet

`PairingCodeSheet(mainDeviceID:)` opens a pairing window on a Main and shows its code. macOS: min width 420 pt; iOS and
iPadOS: `.presentationDetents([.medium])`.

1. On appear: `openPairing()` (`pairing.open`) on that Main's connection. While it runs: `ProgressView` and "Opening a
   pairing window…". A failure shows the message in red with the buttons "Try Again" and "Close". Without a connection
   to that Main, step 1 fails with "<Main name> is offline.".
2. Showing the code:
   - Title "Pair a New Device", subtitle "On <Main name>".
   - The code as "123 456" (the six digits, a space after the third), `.system(size: 44, weight: .semibold, design:
     .monospaced)`, selectable.
   - "Expires in <m:ss>" (secondary), from `expiresAt`, refreshed every second (`TimelineView(.periodic(from: .now,
     by: 1))`).
   - "On the new device, open Hephaestus and choose Join a Mesh. Select <Main name>, or enter <address>:<port>, then
     type this code.", where `<address>` is the first entry of the Main's record `addresses`, in brackets when it
     contains `:` (`[<address>]:<port>`, the form the address field of the join flow reads), and `<port>` the result's
     `port`; without an address the sentence omits ", or enter <address>:<port>".
   - Button "Cancel": `closePairing()` (`pairing.close`, a failure is ignored), then the sheet dismisses itself once
     the request has ended; Cancel is disabled meanwhile.
3. Success: when `workspace.mesh` holds a non-revoked record, other than the Main, whose `pairedAt` is not earlier than
   `expiresAt − 300 s` (the moment the Main opened the window, by the Main's clock), the content becomes
   `checkmark.circle.fill` (green, 44 pt), "<name> joined the mesh." and a "Done" button. No `pairing.close` is sent:
   the window closed itself ([../devices/mesh.md](../devices/mesh.md#pairing-window-main)).
4. Expiry: when the countdown reaches 0 without success: "The code has expired." with "New Code" (step 1 again) and
   "Close".
5. When the Main's connection leaves `connected` while the sheet shows a code: "<Main name> went offline." and
   "Close".

Steps 3–5 are checked only while the code shows; the state they lead to stays, whatever the registry or the connection
does afterwards.

A window also closes after 5 wrong codes; there is no event for it, so the sheet keeps counting down
([../devices/mesh.md](../devices/mesh.md#pairing-window-main)).

## Join flow

`JoinMeshView` is pushed by onboarding, the only place where a device pairs
([../devices/mesh.md](../devices/mesh.md#credentials)). It sets its navigation title, "Join a Mesh". Its state is a
`JoinMeshModel`. Two steps, shown in a `Form` with `.formStyle(.grouped)`:

### Step 1: choose a Main

| Section             | Content                                                                                                                                                                                                  |
|---------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Mains Ready to Pair | `workspace.seenHosts` values with `pairingOpen`, sorted by name; each row: `desktopcomputer`, the name (headline), the host (caption, secondary). Empty: a small `ProgressView` and "Looking for Mains…" |
| Enter an Address    | a text field (placeholder "Sams-Mac-mini.local or 192.0.2.10:47101", no autocorrection or capitalization, URL keyboard on iOS) and a "Continue" button; Return continues                                 |

- Footer of the first section: "On a Main, open Devices and choose Pair a New Device. A Main on another network can be
  reached by its address."
- Choosing a row: target = the row's name, its `host`, and its `pairingPort` (47101 when nil).
- The address (trimmed) is `host`, `host:port`, `[ipv6]` or `[ipv6]:port`; a text with more than one `:` and no
  brackets is an IPv6 host without port. The port is 1–65535 and defaults to 47101
  ([../devices/mesh.md](../devices/mesh.md#joining-pairingclient)); the host is not empty and holds no whitespace or
  `/`.
  While the text is not empty and breaks this rule, "Enter a host name or an IP address, optionally followed by
  :port." shows in red and Continue is disabled. Continue: target = no name, that host and port.
- A chosen target moves to step 2, with an empty code and no error message.

### Step 2: enter the code

- Text: "Enter the 6-digit code shown on <target name, else host>."
- `PairingCodeField(code:)`: a text field titled "Code" with its label hidden (`.labelsHidden()`),
  `.system(size: 28, design: .monospaced)`, centered, focused on appear; it keeps the digits of what is typed or
  pasted, at most 6; iOS: `.keyboardType(.numberPad)` and `.textContentType(.oneTimeCode)`.
- "Device name": a text field prefilled with `identity.name`; while the trimmed text is empty, "Enter a device name."
  shows in red, and while it is `Claude` in any letter case, "Claude is a reserved name." does.
- Buttons: "Back" (to step 1; cancels a running join) and "Join" (default action), enabled when the code has 6 digits,
  the name is valid and no join runs.
- Join, in a task kept by the model:
  1. `try appModel.setLocalName(<name>)` ([shell.md](shell.md#32-device-names)), so the Main records this name.
  2. `_ = try await PairingClient.join(host:port:code:device: appModel.identity.deviceInfo, credentialStore:
     KeychainCredentialStore.shared, appSupport: appModel.appSupport)`
     ([../devices/mesh.md](../devices/mesh.md#joining-pairingclient)): it stores the credentials and the registry
     snapshot.
  3. `appModel.didJoinMesh()`: every window shows the shell.
- While it runs: the fields and buttons are disabled except Back, and a small `ProgressView` with "Joining…" replaces
  the Join button.
- Failure: the error's message ([shell.md](shell.md#81-windowbanners) mapping; `PairingError` gives the texts of
  [../devices/mesh.md](../devices/mesh.md#joining-pairingclient)) shows in red under the code field; the code is
  cleared for `PairingError.rejected` and `.invalidCode`; the step stays.
- A join that Back cancelled shows no error. When it still completes (the credentials are stored), it calls
  `appModel.didJoinMesh()` all the same.

On iOS and iPadOS the first Bonjour browse shows the system's local network permission prompt
([../architecture.md](../architecture.md#appinfoplist)); when it is denied the first section stays empty and the address
field still works for addresses the system allows.

## Swift API

```swift
// HephUI/Devices — @MainActor; read AppModel, Workspace, Selection and WindowBanners from the environment.

/// The Devices section; also the Devices tab of the macOS Settings.
public struct DevicesView: View { public init() }

/// The join flow, pushed by onboarding.
public struct JoinMeshView: View { public init() }

struct DeviceRow: View { init(record: DeviceRecord, isThisDevice: Bool) }
struct RenameDeviceSheet: View { init(deviceID: UUID) }
struct PairingCodeSheet: View { init(mainDeviceID: UUID) }
struct PairingCodeField: View { init(code: Binding<String>) }

@MainActor @Observable
final class JoinMeshModel {
    enum Step: Equatable { case chooseMain, enterCode }
    struct Target: Equatable { var name: String?; var host: String; var port: Int }
    var step: Step                      // .chooseMain
    var target: Target?
    var address: String                 // the manual address field
    var code: String
    var deviceName: String
    private(set) var isJoining: Bool
    private(set) var errorMessage: String?
    init(appModel: AppModel)
    /// Parses `address` with the rule of step 1; nil when invalid.
    static func parseAddress(_ text: String) -> Target?
    func choose(_ advert: BonjourAdvert)
    func continueWithAddress()
    func back()
    func join()                          // starts the join task
}
```

`DevicesView` and `JoinMeshView` end their files with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

| Name                                                                                                                                                                                                                                                                | Defined in                                                                                     |
|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| `AppModel` (`identity`, `appSupport`, `renameDevice`, `renameConnection`, `setLocalName`, `didJoinMesh`, `leaveMesh`, `isMigrationActive`), `WindowBanners`, `PlatformIcon`, `PresenceLabel`, `EmptyStateView`, `AppModel.preview()`, `previewWindow(_:selection:)` | [shell.md](shell.md)                                                                           |
| `Workspace` (`device`, `mesh`, `presence`, `mains`, `seenHosts`, `localConnection`, `connection(_:)`), `MainConnection` (`openPairing`, `closePairing`, `revokeDevice`), `Selection`                                                                                | [../client/workspace.md](../client/workspace.md)                                               |
| `PairingClient`, `PairingError`, `BonjourAdvert`, pairing window rules, revocation                                                                                                                                                                                  | [../devices/mesh.md](../devices/mesh.md)                                                       |
| `KeychainCredentialStore`                                                                                                                                                                                                                                           | [../data/app-storage.md](../data/app-storage.md)                                               |
| roles, Leave mesh procedure and texts                                                                                                                                                                                                                               | [../devices/roles.md](../devices/roles.md)                                                     |
| `DeviceRecord`, `Presence`, `DevicePlatform`, `PairingOpenResult`                                                                                                                                                                                                   | [../protocol/types.md](../protocol/types.md), [../protocol/methods.md](../protocol/methods.md) |
| `SettingsSheet`                                                                                                                                                                                                                                                     | [settings.md](settings.md)                                                                     |
