# Device roles

files:
- HephaestusKit/Sources/HephClient/DeviceIdentityStore.swift

---

Every device of the mesh is a **remote**: it connects to every Main and can view and control everything on it. A Mac
can also be a **Main**: it hosts projects and runs the host service ([../services/host.md](../services/host.md)).
Only Macs can be Mains, because Mains run the Claude CLI and the user's toolchains. Transport, pairing, registry and
presence: [mesh.md](mesh.md). Moving projects between Mains: [migration.md](migration.md).

## Roles

| Platform | Remote | Main                                     |
|----------|--------|------------------------------------------|
| macOS    | always | while "Use this Mac as a Main" is on     |
| iPadOS   | always | never                                    |
| iOS      | always | never                                    |

- A remote's `Workspace` connects to every Main of the registry ([../client/workspace.md](../client/workspace.md)).
- A Main also runs `HostService`: it listens on the listener port, advertises itself with Bonjour, connects to every
  other Main (peer links), serves its projects, runs Claude sessions and runs ([mesh.md](mesh.md),
  [../services/host.md](../services/host.md)). Its own UI reaches its host through the loopback channel, never through
  the network ([../protocol/envelope.md](../protocol/envelope.md)).
- `isMain` lives in the device settings (`settings.json` key `isMain`, [../data/app-storage.md](../data/app-storage.md)).
  At launch, the app wiring starts `HostService` when `isMain` is true ([../ui/shell.md](../ui/shell.md)).

## Identity

| Field        | Type             | Source                       | Value                                                                                            |
|--------------|------------------|------------------------------|--------------------------------------------------------------------------------------------------|
| `id`         | `UUID`           | `device.json` `id`           | `UUID()`, generated once when `device.json` is created                                           |
| `name`       | `String`         | `device.json` `name`         | default: [Default name](#default-name); set in onboarding; afterwards the registry record's      |
| `platform`   | `DevicePlatform` | the running app              | `macOS` on macOS; on iOS `iPadOS` when `UIDevice.current.userInterfaceIdiom == .pad`, else `iOS` |
| `isMain`     | `Bool`           | `settings.json` `isMain`     | default `false`; always `false` on iOS and iPadOS                                                |
| `appVersion` | `String`         | main bundle                  | `CFBundleShortVersionString` (`1.0`); `""` when missing                                          |
| `build`      | `Int`            | main bundle                  | `CFBundleVersion` parsed as `Int`; `0` when missing or not an integer                            |

The six fields form the `DeviceInfo` sent in `hello` and in pairing ([../protocol/types.md](../protocol/types.md)).

### Default name

| Platform | Default name                                                                                     |
|----------|--------------------------------------------------------------------------------------------------|
| macOS    | `SCDynamicStoreCopyComputerName(nil, nil)`; `"Mac"` when it returns nil, `""` or a reserved name |
| iPadOS   | `"iPad"`                                                                                         |
| iOS      | `"iPhone"`                                                                                       |

### device.json

Format, encoding and atomic writing: [../data/app-storage.md](../data/app-storage.md) (`DeviceFile`, keys `id` and
`name`). This doc decides when it is created:

| State at launch                                               | Action                                                                      |
|---------------------------------------------------------------|-----------------------------------------------------------------------------|
| missing                                                       | create: `id` = `UUID().uuidString`, `name` = default name; write it         |
| unreadable (`DeviceFile.load` throws), or `id` is not a UUID  | log an error; create a new identity as above and overwrite the file         |
| valid                                                         | use it                                                                      |

A device that got a new id is a new device for the mesh: when it still holds the mesh credentials, Mains add a new
record for it at its first `hello` ([mesh.md](mesh.md#admission-hello)); its old record stays until a device revokes it.
A write failure is logged; the identity stays in memory and the write is retried at the next change.

## Names

- A name is trimmed of white space and line breaks and must not be empty (`DataError.invalid("Enter a device name.")`).
- `Claude`, in any letter case, is a reserved name (`DataError.invalid("Claude is a reserved name.")`): it is the author of the comments
  made through the MCP tools, which can be deleted but not edited ([../data/task-yml.md](../data/task-yml.md)).
  Names do not need to be unique. The Bonjour service name is the name cut to 63 UTF-8 bytes ([mesh.md](mesh.md#advertising)).
- Before the device belongs to a mesh (onboarding), the name is local: `setName(_:)` writes `device.json`.
- In a mesh, the name lives in the device's registry record. `hello` never changes a record's name; only
  `mesh.renameDevice` does ([../protocol/methods.md](../protocol/methods.md#meshrenamedevice)).
- Renaming this device (Settings ▸ General ▸ Device Name, or Rename on its row of the Devices screen) sends
  `mesh.renameDevice {deviceID: <this device's id>, name}` to a connected Main: the local connection on a Main, else
  the first connected Main in the Workspace's `mains` order. The Workspace merges the returned record and adopts the
  name, which it saves with `DeviceIdentityStore.save(_:)` ([../client/workspace.md](../client/workspace.md)).
- While no Main is connected, the device name field is disabled with the caption "Connect to a Main to rename this
  device." A Main is always connected to itself.
- Any device renames any other device the same way, with that device's id.

## DeviceIdentityStore

`HephaestusKit/Sources/HephClient/DeviceIdentityStore.swift`.

```swift
@MainActor @Observable
public final class DeviceIdentityStore {
    /// Loads device.json, creating it as described above. Reads isMain from `settings`.
    public init(appSupport: AppSupport, settings: SettingsStore)

    public private(set) var id: UUID
    public private(set) var name: String
    public var isMain: Bool { get }                 // settings.settings.isMain; false on iOS and iPadOS
    public let platform: DevicePlatform
    public let appVersion: String
    public let build: Int
    /// The six identity fields.
    public var deviceInfo: DeviceInfo { get }

    /// The default name of this platform.
    public static func defaultName() -> String
    /// The trimmed name; throws DataError.invalid("Enter a device name.") when it is empty and
    /// DataError.invalid("Claude is a reserved name.") when it is Claude in any letter case.
    public static func validateName(_ name: String) throws -> String
    /// Validates, writes device.json, publishes `name`. Used before the device belongs to a mesh. Throws only the
    /// validation errors: a write failure is logged and the name stays in memory, as described above.
    public func setName(_ name: String) throws
    /// Writes device.json when `device.name` differs from `name` (WorkspaceEnvironment.saveDevice).
    /// Ignores `device` when its id is not this device's id. A write failure is logged.
    public func save(_ device: DeviceInfo)
    /// macOS only: SettingsStore.update { $0.isMain = isMain }. Throws the SettingsStore error
    /// ("only a Mac can be a Main" on iOS and iPadOS).
    public func setIsMain(_ isMain: Bool) throws
}
```

- `AppSupport`, `SettingsStore`, `DeviceFile` and `DataError` are defined in
  [../data/app-storage.md](../data/app-storage.md); `DeviceInfo` and `DevicePlatform` in
  [../protocol/types.md](../protocol/types.md).
- The app wiring creates one store at launch, before the `Workspace`, and passes it to
  `WorkspaceEnvironment.live(...)` ([../client/workspace.md](../client/workspace.md)). After `setName` or
  `setIsMain` it calls `workspace.updateLocalDevice(identity.deviceInfo)`.

## Turning Main on (macOS)

Entry points: onboarding "Use this Mac as a Main" ([../ui/onboarding.md](../ui/onboarding.md)), which first makes
this Mac the Forge of the mesh it creates (`forge.enabled`,
[../ui/onboarding.md](../ui/onboarding.md#use-this-mac-as-a-main)), and the toggle "Use this Mac as a Main" of
Settings ▸ General ([../ui/settings.md](../ui/settings.md)), which does not. The app wiring
([../ui/shell.md](../ui/shell.md)) runs, in order:

1. `identity.setIsMain(true)`.
2. `try await HostService.shared.start()` ([../services/host.md](../services/host.md#31-start)). Its first step,
   `mesh.ensureMesh()`, reads `device.json` again and creates the mesh when this Mac has no mesh credentials
   ([mesh.md](mesh.md#credentials)); this Mac's registry record then says `isMain: true` and carries its addresses and
   port, and a new record carries the name of `device.json`, the one saved in onboarding
   ([mesh.md](mesh.md#swift-api)).
3. `workspace.setLocalHostLink(<loopback link>)`, which reloads the credentials, so a mesh created in step 2 is
   picked up ([../client/workspace.md](../client/workspace.md#lifecycle)); then
   `workspace.updateLocalDevice(identity.deviceInfo)`.

When step 2 throws, the app runs `identity.setIsMain(false)`, the toggle returns to off and an alert shows "This Mac
could not become a Main" with the error message. A listener that cannot start does not fail step 2: the Main runs and
Settings shows `HostService.listenerError` (for example "Port 47100 is already in use.") under the port field.

## Turning Main off (macOS)

1. Refused while a migration runs on this Mac, as source or destination
   (`await HostService.shared.migration.isActive()`, [migration.md](migration.md#swift-api)): the toggle stays on and
   an alert shows "A project is being moved. Try again when the move has finished."
2. Confirmation alert, title "Stop using this Mac as a Main?", message "Its projects stay on this Mac but other devices
   cannot open them until you turn this back on. Running Claude sessions and runs are stopped.", buttons "Stop"
   (destructive) and "Cancel".
3. `await HostService.shared.mesh.resignMain()`: this Mac's record gets `isMain: false`, `addresses: []`, `port: 0` and
   is sent to the connected peer Mains ([mesh.md](mesh.md#resigning)).
4. `await HostService.shared.stop()`: sessions and runs stop, the listener, Bonjour and peer links close
   ([../services/host.md](../services/host.md#32-stop)).
5. `identity.setIsMain(false)`, `workspace.setLocalHostLink(nil)`, `workspace.updateLocalDevice(identity.deviceInfo)`.

The projects stay on disk and in `projects.json`; they are served again when Main is turned back on. The Mac stays in
the mesh as a remote and keeps its connections to the other Mains.

## Leaving the mesh

"Leave Mesh" on this device's row of the Devices screen ([../ui/devices.md](../ui/devices.md#leave-mesh)):

1. On a Main, refused while a migration runs (same alert as above).
2. Confirmation alert, title "Leave the mesh?", message "This device forgets the mesh key and the device list. Its
   record stays on the other devices until one of them revokes it. To come back, pair it again.", buttons "Leave Mesh"
   (destructive) and "Cancel".
3. On a Main: steps 3–5 of [Turning Main off](#turning-main-off-macos).
4. `credentialStore.delete()` ([../data/app-storage.md](../data/app-storage.md#keychain)) and
   `RegistryCache.delete(appSupport)` ([../data/app-storage.md](../data/app-storage.md)).
5. `workspace.reset()`: the Workspace forgets the mesh and has no connection, and the app shows onboarding.

The device keeps its `device.json` (same id and name). Pairing again creates a fresh record for that id
([mesh.md](mesh.md#pairing)).

## What the UI shows per role

| Element                                                                                                                          | Mac, Main                                                           | Mac, not a Main                          | iPhone, iPad                  |
|----------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------|------------------------------------------|-------------------------------|
| Onboarding (no mesh credentials and not a Main, or turning Main on from onboarding, [../ui/shell.md](../ui/shell.md#3-appmodel)) | not shown, except while `becomeMain()` runs on a Mac without a mesh | "Use this Mac as a Main", "Join a Mesh"  | "Join a Mesh"                 |
| Settings ▸ General: "Use this Mac as a Main"                                                                                     | on                                                                  | off                                      | not shown                     |
| Settings ▸ General: projects folder, listener port, addresses                                                                    | shown                                                               | not shown                                | not shown                     |
| Settings ▸ General: listener error                                                                                               | under the port field when set                                       | not shown                                | not shown                     |
| Path bar Main menu                                                                                                               | lists this Mac                                                      | does not list this Mac                   | lists Mains only              |
| "Pair a New Device"                                                                                                              | opens the window on this Mac                                        | opens it on the chosen online Main       | same as Mac, not a Main       |
| "No Main online" state                                                                                                           | never (this Mac reaches its own host)                               | when no Main is connected                | when no Main is connected     |

- On every device, the Devices screen shows each device's role as "Main" when its record has `isMain`, else "Remote",
  and shows the `addresses` of Mains ([../ui/devices.md](../ui/devices.md)).
- "Pair a New Device" on a device that is not a Main: with one connected Main it uses it; with several, a menu lists
  the connected Mains by name. It sends `pairing.open` and shows the code with a countdown to `expiresAt`
  ([mesh.md](mesh.md#pairing-window-main)).
