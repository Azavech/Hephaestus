# Application storage

files:
- HephaestusKit/Sources/HephCore/Storage/AppSupport.swift
- HephaestusKit/Sources/HephCore/Storage/AtomicFile.swift
- HephaestusKit/Sources/HephCore/Storage/DataError.swift
- HephaestusKit/Sources/HephCore/Storage/JSONFile.swift
- HephaestusKit/Sources/HephCore/Storage/DeviceFile.swift
- HephaestusKit/Sources/HephCore/Storage/ProjectsFile.swift
- HephaestusKit/Sources/HephCore/Storage/MigrationJournal.swift
- HephaestusKit/Sources/HephCore/Storage/RegistryCache.swift
- HephaestusKit/Sources/HephCore/Storage/SettingsStore.swift
- HephaestusKit/Sources/HephCore/Storage/MeshCredentialStore.swift
- HephaestusKit/Sources/HephCore/Storage/WindowStateKeys.swift
- HephaestusKit/Sources/HephCore/Model/DeviceSettings.swift

---

What a device keeps outside project folders: its Application Support folder, one Keychain item, the state of each
window, and a cache of downloaded attachments ([Caches](#caches)). Project data is in the project folders
([project-yml.md](project-yml.md), [task-yml.md](task-yml.md), [sessions.md](sessions.md)).

## Folder

`AppSupport.standard()` is `<Application Support>/Hephaestus/`, where `<Application Support>` is
`FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)`.
The folder is created when missing. When the folder cannot be found or created, `standard()` throws
`.io("Hephaestus: <reason>")`.

| Platform        | Folder                                                                  |
|-----------------|-------------------------------------------------------------------------|
| macOS           | `~/Library/Application Support/Hephaestus/`                             |
| iOS and iPadOS  | `Library/Application Support/Hephaestus/` inside the app's container    |

Content:

| Entry                      | Devices      | Content                                                         | Defined in                                                                                               |
|----------------------------|--------------|-----------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `device.json`              | every device | identity of this device: id and name                            | this doc                                                                                                 |
| `settings.json`            | every device | device settings                                                 | this doc                                                                                                 |
| `registry.json`            | every device | last known `MeshSnapshot` of the mesh                           | this doc                                                                                                 |
| `projects.json`            | Main         | absolute paths of the top-level projects this Main hosts        | this doc                                                                                                 |
| `projects.json.unreadable` | Main         | the last `projects.json` that could not be read                 | this doc                                                                                                 |
| `migrations.json`          | Main         | migration journal: moves sent from and received by this Main    | this doc; [devices/migration.md](../devices/migration.md#journal)                                        |
| `Uploads/`                 | Main         | one file per upload in progress (`Uploads/<uploadID>`)          | [services/files.md](../services/files.md#7-uploads)                                                      |
| `forge.json`               | Forge host   | state of the Forge pipeline                                     | [forge/pipeline.md](../forge/pipeline.md)                                                                |
| `private-terms.txt`        | Forge host   | words the personal data check refuses, one per line             | [public-repository.md](../public-repository.md#private-terms), [forge/pipeline.md](../forge/pipeline.md) |
| `Skills/`                  | Main         | skills library                                                  | [claude/skills.md](../claude/skills.md)                                                                  |
| `SessionPlugins/`          | Main         | per session (`<sessionID>/`): plugin folder, `system-prompt.md` | [claude/skills.md](../claude/skills.md), [claude/cli.md](../claude/cli.md)                               |
| `Updates/`                 | macOS        | downloaded updates                                              | [forge/update.md](../forge/update.md)                                                                    |

A file or folder is created the first time it is written. Nothing else is stored in this folder.

`private-terms.txt` lists personal words and never enters a repository. The Forge creates it and builds its URL from
`root` (`AppSupport` has no member for it); apart from creating it, the app changes the file only when the user adds or
dismisses a suggested term ([forge/pipeline.md](../forge/pipeline.md#private-terms)). The personal data check of the
repository's git hooks reads it at this place ([public-repository.md](../public-repository.md#private-terms)).

`AppSupport` holds the root URL and the function that moves items to the Trash, so tests can run on a temporary folder
with a Trash of their own (`AppSupport(root:trashItem:)`); the app uses `AppSupport.standard()` once at launch and
passes the value to every component that needs it. The updater is the exception: it calls `AppSupport.standard()`
itself each time it reads `settings.json` or uses the Updates folder ([forge/update.md](../forge/update.md)).

## Trash

`appSupport.trashItem(url)` moves a file or folder to the Trash. `AppSupport.standard()` and `AppSupport(root:)` use
`AppSupport.defaultTrashItem`: `FileManager.default.trashItem(at: url, resultingItemURL: nil)`. Tests pass a function
that moves the item into a temporary folder.

The host moves items to the Trash only through `appSupport.trashItem`: `files.delete`
([services/files.md](../services/files.md)), `projects.remove` ([services/host.md](../services/host.md)), the deletes
and the sync of the skills library ([claude/skills.md](../claude/skills.md)), and the source's cleanup after a
migration, during the move or after a restart ([devices/migration.md](../devices/migration.md)).

The updater is not part of the host: at launch it moves the previous app, `Updates/previous/Hephaestus.app`, when it
exists, to the Trash with `FileManager.default.trashItem` ([forge/update.md](../forge/update.md#after-a-restart)).

## JSON files

`device.json`, `settings.json`, `registry.json`, `projects.json`, `migrations.json` and `forge.json` are written by
`JSONFile.write`:

- The encoder is `WireCoding.makeEncoder()` ([protocol/envelope.md](../protocol/envelope.md#encoding)) with
  `.prettyPrinted` added to its `outputFormatting`: sorted keys, slashes not escaped, dates in ISO 8601 UTC with
  milliseconds, `Data` in base64, UUIDs in uppercase.
- The file is written with `AtomicFile.write`. A value that cannot be encoded throws `.io("<file name>: <reason>")`.

`JSONFile.read` decodes with `WireCoding.makeDecoder()`. It returns `nil` when the file does not exist, throws
`.io("<file name>: <reason>")` when the file cannot be read and `.unreadable("<file name>: <decoding error>")` when it
cannot be decoded.

## device.json

The identity of this device ([devices/roles.md](../devices/roles.md) creates and changes it).

| Key    | JSON type | Meaning                                                                  |
|--------|-----------|--------------------------------------------------------------------------|
| `id`   | string    | Device id, a UUID generated once and never changed.                      |
| `name` | string    | Device name, as shown on every device of the mesh.                       |

```json
{
  "id" : "4A7C2E91-0B3D-4F5E-8C6A-1D2E3F4A5B6C",
  "name" : "Sam's MacBook Pro"
}
```

- The platform, app version and build of `DeviceInfo` are not stored: they come from the running app.
- The device name edited in Settings ▸ General is this `name`; a rename is also sent to the mesh
  (`mesh.renameDevice`, [devices/roles.md](../devices/roles.md)), and a rename received from another device is written
  here.
- What happens when the file is missing or unreadable is defined in [devices/roles.md](../devices/roles.md).

## settings.json

The settings of this device. Nested keys are JSON objects: `forge.enabled` is `{"forge": {"enabled": …}}`.

| Key                       | JSON type        | Default              | Used on    | Meaning                                                                           | Used by                                                                                                   |
|---------------------------|------------------|----------------------|------------|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| `isMain`                  | boolean          | `false`              | macOS      | This Mac is a Main.                                                               | [devices/roles.md](../devices/roles.md)                                                                   |
| `projectsFolder`          | string           | `~/Developer`        | Main       | Folder where new projects and moved-in projects are created.                      | [services/host.md](../services/host.md)                                                                   |
| `listenerPort`            | integer          | `47100`              | Main       | TCP port of the mesh listener.                                                    | [devices/mesh.md](../devices/mesh.md)                                                                     |
| `pairingPort`             | integer          | `47101`              | Main       | TCP port of the pairing listener.                                                 | [devices/mesh.md](../devices/mesh.md)                                                                     |
| `additionalAddresses`     | array of strings | `[]`                 | Main       | Extra host names or IP addresses of this Main, added to its device record.        | [devices/mesh.md](../devices/mesh.md)                                                                     |
| `claudePath`              | string           | `""`                 | Main       | Path of the Claude CLI. Empty: found automatically.                               | [claude/cli.md](../claude/cli.md)                                                                         |
| `defaultModel`            | string           | `""`                 | Main       | Model of new sessions when the project sets none. Empty: no `--model`.            | [claude/cli.md](../claude/cli.md)                                                                         |
| `defaultPermissionMode`   | string           | `acceptEdits`        | Main       | Permission mode of new sessions when the project sets none.                       | [claude/cli.md](../claude/cli.md)                                                                         |
| `sessionIdleMinutes`      | integer          | `15`                 | Main       | A session process with no activity for this long is stopped.                      | [claude/cli.md](../claude/cli.md)                                                                         |
| `autosave`                | boolean          | `true`               | every      | The editors save 1.5 s after the last edit.                                       | [ui/code.md](../ui/code.md)                                                                               |
| `showHiddenFiles`         | boolean          | `false`              | every      | The file browser shows hidden files and folders.                                  | [ui/code.md](../ui/code.md)                                                                               |
| `forge.enabled`           | boolean          | `false`              | Main       | This Main is the Forge. Onboarding turns it on for the Mac that creates the mesh. | [forge/pipeline.md](../forge/pipeline.md), [ui/onboarding.md](../ui/onboarding.md#use-this-mac-as-a-main) |
| `forge.sourceProjectID`   | string           | `HEPH`               | Main       | Identifier of the project holding the Hephaestus source.                          | [forge/pipeline.md](../forge/pipeline.md)                                                                 |
| `forge.branch`            | string           | `main`               | Main       | Branch the Forge pushes to and watches.                                           | [forge/pipeline.md](../forge/pipeline.md)                                                                 |
| `forge.autoRegenerate`    | boolean          | `true`               | Main       | Regenerate automatically when the docs are ahead of the code.                     | [forge/pipeline.md](../forge/pipeline.md)                                                                 |
| `updates.enabled`         | boolean          | `true`               | macOS      | New builds install automatically. False: this Mac only checks and offers Install. | [forge/update.md](../forge/update.md)                                                                     |
| `updates.signingIdentity` | string           | `""`                 | macOS      | Code signing identity applied to updates. Empty: chosen automatically.            | [forge/update.md](../forge/update.md)                                                                     |

"Main" settings are read only when `isMain` is true; on other devices they keep their stored values. The Settings
screen is [ui/settings.md](../ui/settings.md). The `forge` settings other than `enabled` make the `ForgeConfig`
([protocol/types.md](../protocol/types.md#forgeconfig)) that the Forge host reports, whose `repository` is the
constant `ForgeConfig.publicRepository`: the GitHub repository is not a setting.

### Rules

`DeviceSettings.normalize()` then `DeviceSettings.validate()` run on every change; the rules are checked in the order
of the table, and the first broken rule fails the change with `.invalid(<message>)`. Trimming removes
`.whitespacesAndNewlines`.

| Key                                         | Normalization                                                              | Rule                                                             | Message                                                                             |
|---------------------------------------------|----------------------------------------------------------------------------|------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| `isMain`                                    | none                                                                       | false on iOS and iPadOS                                          | `only a Mac can be a Main`                                                          |
| `projectsFolder`                            | whitespace trimmed                                                         | starts with `/` or `~/`, or is `~`                               | `the projects folder must be an absolute path`                                      |
| `listenerPort`                              | none                                                                       | 1024 to 65535                                                    | `the listener port must be between 1024 and 65535`                                  |
| `pairingPort`                               | none                                                                       | 1024 to 65535, not equal to `listenerPort`                       | `the pairing port must be between 1024 and 65535 and differ from the listener port` |
| `additionalAddresses`                       | each trimmed; empty entries and repeats removed (first kept)               | no whitespace inside an entry                                    | `an address must not contain spaces`                                                |
| `claudePath`                                | whitespace trimmed                                                         | empty, or starts with `/` or `~/`                                | `the Claude CLI path must be absolute`                                              |
| `defaultModel`                              | whitespace trimmed                                                         | no line break                                                    | `the model must be on one line`                                                     |
| `defaultPermissionMode`                     | none                                                                       | a `PermissionMode` value                                         | `invalid permission mode`                                                           |
| `sessionIdleMinutes`                        | none                                                                       | 1 to 1440                                                        | `the idle timeout must be between 1 and 1440 minutes`                               |
| `forge.sourceProjectID`                     | `ProjectIdentifier.normalize`                                              | `^[A-Z]{2,8}$`                                                   | `the identifier must be 2 to 8 letters A to Z`                                      |
| `forge.branch`                              | whitespace trimmed                                                         | not empty, no whitespace                                         | `the branch must not be empty or contain spaces`                                    |
| `updates.signingIdentity`                   | whitespace trimmed                                                         | no line break                                                    | `the signing identity must be on one line`                                          |

Paths starting with `~` are expanded with `NSString.expandingTildeInPath` where they are used:
`DeviceSettings.projectsFolderURL` and `DeviceSettings.claudeURL` (nil when `claudePath` is empty).

### Reading and writing

- `SettingsStore` reads the file once, at launch. Each key is read on its own: a missing key, a value of the wrong
  type, or a value that breaks its rule after normalization takes the default of that key. A missing or unreadable
  file gives every default. On iOS and iPadOS `isMain` is read as `false`.
- `listenerPort` is read before `pairingPort`. When the `pairingPort` read this way equals `listenerPort` (the stored
  `listenerPort` is `47101`, the default of `pairingPort`), `pairingPort` is `47100`, the default of `listenerPort`, so
  the settings read always pass their rules.
- `SettingsStore.update` applies a change, normalizes and validates it, writes the whole file, then publishes the new
  value. When validation or the write fails, it throws and the current settings stay as they were.
- Keys that are not in the table are ignored when the file is read and dropped at the next write. A `settings.json`
  written by an earlier build may still hold `forge.repository`, which is no longer a setting
  ([forge/pipeline.md](../forge/pipeline.md#forge-host-configuration)): the file loads as if the key were absent, and
  the next `SettingsStore.update` writes it without the key.

```json
{
  "additionalAddresses" : [
    "203.0.113.7"
  ],
  "autosave" : true,
  "claudePath" : "",
  "defaultModel" : "",
  "defaultPermissionMode" : "acceptEdits",
  "forge" : {
    "autoRegenerate" : true,
    "branch" : "main",
    "enabled" : true,
    "sourceProjectID" : "HEPH"
  },
  "isMain" : true,
  "listenerPort" : 47100,
  "pairingPort" : 47101,
  "projectsFolder" : "~/Developer",
  "sessionIdleMinutes" : 15,
  "showHiddenFiles" : false,
  "updates" : {
    "enabled" : true,
    "signingIdentity" : ""
  }
}
```

## registry.json

The last `MeshSnapshot` ([protocol/types.md](../protocol/types.md)) this device knows: `meshID`, `devices`
(`DeviceRecord` values) and `presence`, in the wire JSON form.

- Written by `RegistryCache.save` each time the device's snapshot changes: `hello` reply, `mesh.changed`, and on a Main
  every change of its registry.
- Read by `RegistryCache.load` at launch. It returns `nil` when the file is missing or unreadable (logged).
- On a Main it is the registry the Main serves and syncs; on other devices it is a cache shown while no Main is
  reachable ([devices/mesh.md](../devices/mesh.md)). The presence it holds is what was last known: the reader treats
  every device as offline with its stored `lastSeen` until fresh reports arrive
  ([client/workspace.md](../client/workspace.md)).
- `RegistryCache.delete` removes it when the device leaves the mesh ([devices/roles.md](../devices/roles.md)).

## projects.json

Main only. The top-level projects the Main hosts; sub projects are found through their parent's `subprojects`.

| Key        | JSON type        | Meaning                                                                       |
|------------|------------------|-------------------------------------------------------------------------------|
| `projects` | array of strings | Absolute paths of the project roots, in the order they were registered.       |

```json
{
  "projects" : [
    "/Users/user/Developer/Hephaestus",
    "/Users/user/Developer/Atlas"
  ]
}
```

- A path is stored as `URL.standardizedFileURL.path`: absolute, `~` expanded, no trailing `/`, symlinks not resolved.
  A path already in the list is not added again.
- Written when a project is registered (`projects.create` of a top-level project, `projects.import`, a project moved
  in) and unregistered (`projects.remove`, a project moved out) ([services/host.md](../services/host.md),
  [devices/migration.md](../devices/migration.md)).
- Missing: no projects.
- Unreadable (`JSONFile.read` throws): the file is renamed to `projects.json.unreadable` with `rename(2)`, which
  replaces an older `projects.json.unreadable`, and the error is logged. `ProjectsFile.load` returns no projects with
  `wasReset` true: the registry starts empty, and the Main's own app shows the error banner "projects.json was
  unreadable and has been reset; folders are untouched" ([services/host.md](../services/host.md),
  [ui/shell.md](../ui/shell.md)). Project folders are not touched. When the rename fails, the failure is logged and the
  result is the same; the next write then replaces the file.
- A path whose folder is missing or whose `project.yml` is invalid stays in the list and is not listed
  ([project-yml.md](project-yml.md#invalid-file)).

## migrations.json

Main only. The migration journal: each move of a top-level project that this Main sends, from just before
`migration.begin` until its cleanup ends, and each move it received, for 30 days. `MigrationService` is its only
writer; when each entry is written and how a restarted Main uses it:
[devices/migration.md](../devices/migration.md#journal).

The file is a JSON array of entries:

| Key              | JSON type | Present            | Meaning                                                                                                               |
|------------------|-----------|--------------------|-----------------------------------------------------------------------------------------------------------------------|
| `migrationID`    | string    | always             | Migration id (UUID)                                                                                                   |
| `projectID`      | string    | always             | Identifier of the moved top-level project                                                                             |
| `rootPath`       | string    | always             | Source entry: the project root on this Main, as `projects.json` holds it. `received` entry: the new root on this Main |
| `targetDeviceID` | string    | source entries     | Device id of the destination Main                                                                                     |
| `sourceDeviceID` | string    | `received` entries | Device id of the source Main                                                                                          |
| `state`          | string    | always             | Source entries: `transferring`, `committing` or `committed`. Destination entries: `received`                          |
| `updatedAt`      | string    | always             | Time of the last change of the entry                                                                                  |

```json
[
  {
    "migrationID" : "6F1A2B3C-4D5E-4F60-8A7B-9C0D1E2F3A4B",
    "projectID" : "HEPH",
    "rootPath" : "/Users/user/Developer/Hephaestus",
    "state" : "committing",
    "targetDeviceID" : "2D4F6A8C-1B3E-4D5F-9A7C-6E8B0D2F4A1C",
    "updatedAt" : "2026-10-29T21:12:40.512Z"
  },
  {
    "migrationID" : "0C9D8E7F-6A5B-4C3D-9E2F-1A0B9C8D7E6F",
    "projectID" : "API",
    "rootPath" : "/Users/user/Developer/API",
    "sourceDeviceID" : "9B8A7C6D-5E4F-4A3B-8C2D-1E0F9A8B7C6D",
    "state" : "received",
    "updatedAt" : "2026-10-20T09:03:11.007Z"
  }
]
```

- A Main has at most one entry per `migrationID`.
- `MigrationJournal.load` returns the entries in file order. A missing file gives no entry. An unreadable file
  (`JSONFile.read` throws) is logged and gives no entry; the next write replaces it.
- `MigrationJournal.save` writes every entry with `JSONFile.write`; an empty journal is written as an empty array,
  which the pretty-printing encoder writes as `[`, an empty line and `]`.
- Both leave out the `received` entries whose `updatedAt` is more than 30 days before `now`. Source entries never
  expire: they are removed by the steps of [devices/migration.md](../devices/migration.md#journal).

## forge.json

Exists only on the Forge host. Its content is defined in [forge/pipeline.md](../forge/pipeline.md). It is written with
`JSONFile.write` at `AppSupport.forgeFile`.

## Keychain

The mesh credentials (`MeshCredentials`, [devices/mesh.md](../devices/mesh.md#credentials)) are loaded, saved and
deleted through a `MeshCredentialStore`:

| Store                     | Used by                                    | Keeps the credentials in                     |
|---------------------------|--------------------------------------------|----------------------------------------------|
| `KeychainCredentialStore` | the app, through its one instance `shared` | one Keychain item ([below](#keychain-item))  |
| `InMemoryCredentialStore` | tests and previews                         | memory                                       |

### Credential store

- `load()` returns the credentials, or `nil` when the device has no mesh.
- `save(_:)` replaces the credentials: a device holds at most one mesh. It is used when a mesh is created, when pairing
  stores credentials, and when `mesh.rekey` replaces the key.
- `delete()` removes the credentials ("Leave mesh").
- `changes()` returns a new stream with an unbounded buffer. After each successful `save(_:)` or `delete()` made
  through the same instance, the store yields the new value (`nil` after a delete) to every stream it has returned. A
  failed call yields nothing. A stream ends when the task iterating it is cancelled; its continuation is then removed.
- Each store keeps its continuations in a `Mutex` (Synchronization module); `InMemoryCredentialStore` keeps its
  credentials in the same `Mutex`. `InMemoryCredentialStore(_:)` starts with the given credentials; its calls never
  throw.
- The app creates no store other than `KeychainCredentialStore.shared`. The app wiring passes it to
  `WorkspaceEnvironment.live(...)` ([client/workspace.md](../client/workspace.md)) and to `HostService`
  ([services/host.md](../services/host.md)), and every load, save and delete of the mesh credentials in the app goes
  through it, so `MeshService`, which observes its `changes()`, sees a key stored by the Workspace
  ([devices/mesh.md](../devices/mesh.md)).

### Keychain item

`KeychainCredentialStore` keeps the credentials in one generic password item:

| Attribute                 | Value                                                                                          |
|---------------------------|------------------------------------------------------------------------------------------------|
| `kSecClass`               | `kSecClassGenericPassword`                                                                     |
| `kSecAttrService`         | the store's `service`: `ca.azavech.hephaestus.mesh` (`KeychainCredentialStore.defaultService`) |
| `kSecAttrAccount`         | `meshID.uuidString`                                                                            |
| `kSecAttrAccessible`      | `kSecAttrAccessibleAfterFirstUnlock`                                                           |
| `kSecAttrSynchronizable`  | not set (the item stays on this device)                                                        |
| `kSecValueData`           | the `MeshCredentials` value encoded with `WireCoding.makeEncoder()`                            |

- `save(_:)` deletes every item of the service, then adds the new item. Deleting every item of the service calls
  `SecItemDelete` with the class and the service until it returns `errSecItemNotFound`, at most 64 times.
- The value is `{"meshID":"<UUID>","meshKey":"<base64 of the 32-byte key>"}`.
- `load()` queries the service with `kSecMatchLimitOne` and `kSecReturnData`, and decodes the data with
  `WireCoding.makeDecoder()`. `errSecItemNotFound` gives `nil`; data that does not decode throws
  `.unreadable("Keychain item: <decoding error>")`.
- `delete()` deletes every item of the service. `errSecItemNotFound` from a delete is a success.
- On macOS the item is in the login keychain: `kSecUseDataProtectionKeychain` is not set. A build whose code signature
  differs from the one of the build that created the item makes macOS ask once whether Hephaestus may use it ("Always
  Allow" stops it); until it is answered the Keychain call waits ([forge/update.md](../forge/update.md#re-signing)).
- A Keychain call that returns another status throws `.io("Keychain error <status>")`.
- `init(service:)` makes the service name injectable; `shared` is `KeychainCredentialStore(service: defaultService)`.

## Caches

Every device keeps the files it downloaded from the Mains in `<Caches>/Hephaestus/Attachments/`, where `<Caches>` is
`FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]`. The folders are created by the downloads
that write in them.

| Platform       | Folder                                                              |
|----------------|---------------------------------------------------------------------|
| macOS          | `~/Library/Caches/Hephaestus/Attachments/`                          |
| iOS and iPadOS | `Library/Caches/Hephaestus/Attachments/` inside the app's container |

- Content: task attachments, files attached to session messages, and the large project files opened in the image
  viewer or Quick Look, under `<mainDeviceID>/<projectID>/`. Layout, reuse and writing: `AttachmentCache` and the
  download functions of [client/workspace.md](../client/workspace.md#transfers).
- The system may delete the folder's content (iOS and iPadOS do when storage runs low); a missing file is downloaded
  again. The app replaces a cached file when a download writes it again, and deletes nothing else there.

## Per-window state

Each window keeps its selection with `@SceneStorage` ([ui/shell.md](../ui/shell.md)), under these keys
(`WindowStateKeys`):

| Key                      | Value                                                                    |
|--------------------------|--------------------------------------------------------------------------|
| `selection.mainDeviceID` | `Selection.mainDeviceID`: device id of the selected Main                 |
| `selection.projectID`    | `Selection.projectID`: identifier of the selected project or sub project |
| `selection.section`      | `Selection.section`: raw value of the selected section                   |
| `selection.item`         | `Selection.item`: the selected item within the section                   |

- Values are strings: a UUID is stored as its `uuidString`, and an empty string stores `nil`. `Selection` and the
  meaning of its fields are defined in [client/workspace.md](../client/workspace.md).
- A window restored with values that no longer exist drops them: a removed project once its Main's projects are
  loaded, a revoked Main at the next registry change ([ui/shell.md](../ui/shell.md#53-stored-selection-and-defaults)).
- No other UI state is persisted: per-device preferences are settings.

## Atomic writes

`AtomicFile.write(_:to:)` writes every file of the data docs (`project.yml`, task files, session metadata, and the JSON
files of this doc); task and session attachments are moved into place from uploads
([services/files.md](../services/files.md#7-uploads)):

1. The destination is resolved through symlinks (`URL.resolvingSymlinksInPath()`), so writing to a symlink replaces the
   file it points to.
2. The parent folder is created when missing, with its intermediate folders.
3. The data is written to a temporary file in the same folder, named `.` + destination name + `.` + 8 random lowercase
   hex digits + `.tmp` (for example `.project.yml.3fa9c1d2.tmp`), created exclusively. Its permissions are those of the
   destination when it exists, else `0644`.
4. The temporary file is renamed over the destination with `rename(2)`.
5. On any failure the temporary file is removed and `.io("<file name>: <reason>")` is thrown.

The data is not flushed with `fsync`. `AtomicFile.isTemporaryName(_:)` is true for names of the form
`^\..+\.[0-9a-f]{8}\.tmp$`; the host's file watcher ignores those names ([services/host.md](../services/host.md)).

Appends to a session's `.jsonl` file are not atomic writes ([sessions.md](sessions.md#writing-events)).

## Errors

The data code throws `DataError`. Its message is shown to the user as it is (error banners, broken task rows).
`DataError` is not a `LocalizedError`, so its `localizedDescription` is Foundation's generic text: code that shows,
logs or sends a `DataError` uses its `message`, and the host maps it to a protocol error before answering
([services/host.md](../services/host.md) §6.9, [ui/shell.md](../ui/shell.md)).

| Case          | Meaning                                                              | Protocol error code |
|---------------|----------------------------------------------------------------------|---------------------|
| `.notFound`   | the file or item does not exist                                      | `notFound`          |
| `.invalid`    | a value breaks a rule, in a request or in a file                     | `badRequest`        |
| `.refused`    | the app does not write over an invalid file                          | `conflict`          |
| `.unreadable` | a file is not valid UTF-8, YAML or JSON, or not of the expected form | `unavailable`       |
| `.io`         | a file system or Keychain operation failed                           | `internal`          |

When a request fails because of a `DataError`, the host answers with the code of the table and the error's message
([protocol/envelope.md](../protocol/envelope.md)). The message of `.refused` is `The file is invalid: <parse error>`,
the parse error being the `DataError` message of the file (`<file name>: <problem>`,
[project-yml.md](project-yml.md#read-modify-write), [task-yml.md](task-yml.md#broken-files)). When a file read at
load time is `.unreadable` or `.invalid`, the file is broken or skipped as its doc says.

## Logging

The storage code logs with `Log.core` ([architecture.md](../architecture.md#logging)): `error` for an unreadable
`settings.json`, `registry.json`, `projects.json` or `migrations.json` (the file name and the `DataError` message; for
`projects.json`, also the rename to `projects.json.unreadable` or its failure) and for a failed Keychain call (its
status). Keys and settings values are never logged.

## Swift API

`SettingsStore` is `@MainActor`. The other functions are synchronous, not isolated to an actor, and do blocking I/O;
they are safe to call from any actor.

```swift
public struct AppSupport: Sendable {
    public let root: URL
    /// Moves a file or folder to the Trash (Trash section).
    public let trashItem: @Sendable (URL) throws -> Void
    /// Tests pass a temporary root and a trashItem that moves items into a temporary folder.
    public init(root: URL, trashItem: @escaping @Sendable (URL) throws -> Void = AppSupport.defaultTrashItem)
    /// FileManager.default.trashItem(at: url, resultingItemURL: nil)
    public static let defaultTrashItem: @Sendable (URL) throws -> Void
    /// <Application Support>/Hephaestus, created when missing, with defaultTrashItem.
    public static func standard() throws -> AppSupport
    public var deviceFile: URL            // device.json
    public var settingsFile: URL          // settings.json
    public var registryFile: URL          // registry.json
    public var projectsFile: URL          // projects.json
    public var migrationsFile: URL        // migrations.json
    public var forgeFile: URL             // forge.json
    public var skillsFolder: URL          // Skills/
    public var sessionPluginsFolder: URL  // SessionPlugins/
    public var uploadsFolder: URL         // Uploads/
    public var updatesFolder: URL         // Updates/
}

public enum DataError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case invalid(String)
    case refused(String)
    case unreadable(String)
    case io(String)
    /// The associated message.
    public var message: String { get }
    public var description: String { get }
}

public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws
    public static func isTemporaryName(_ name: String) -> Bool
}

public enum JSONFile {
    /// nil when the file does not exist.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T?
    public static func write<T: Encodable>(_ value: T, to url: URL) throws
}

public struct DeviceFile: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String)
    /// nil when device.json does not exist.
    public static func load(_ appSupport: AppSupport) throws -> DeviceFile?
    public func save(_ appSupport: AppSupport) throws
}

public struct ProjectsFile: Codable, Sendable, Equatable {
    public var projects: [String]
    public init(projects: [String])
    /// No projects when missing. When unreadable: renamed to projects.json.unreadable (logged), no projects, and
    /// wasReset true.
    public static func load(_ appSupport: AppSupport) -> (file: ProjectsFile, wasReset: Bool)
    public func save(_ appSupport: AppSupport) throws
    /// Standardizes the path and appends it when it is not in the list.
    public mutating func add(_ path: String)
    public mutating func remove(_ path: String)
}

public enum MigrationJournalState: String, Codable, Sendable, CaseIterable {
    case transferring, committing, committed   // entries of the source
    case received                              // entries of the destination
}

/// One entry of migrations.json.
public struct MigrationJournalEntry: Codable, Sendable, Equatable, Identifiable {
    public var migrationID: UUID
    public var projectID: String
    public var rootPath: String
    public var targetDeviceID: UUID?       // source entries
    public var sourceDeviceID: UUID?       // received entries
    public var state: MigrationJournalState
    public var updatedAt: Date
    public var id: UUID { get }            // migrationID
    public init(migrationID: UUID, projectID: String, rootPath: String, targetDeviceID: UUID?, sourceDeviceID: UUID?,
                state: MigrationJournalState, updatedAt: Date)
}

public enum MigrationJournal {
    /// received entries older than 30 days before `now` are left out.
    public static let receivedRetention: TimeInterval   // 30 days: 2_592_000 s
    /// The entries, in file order; [] when missing or unreadable (logged).
    public static func load(_ appSupport: AppSupport, now: Date = Date()) -> [MigrationJournalEntry]
    public static func save(_ entries: [MigrationJournalEntry], _ appSupport: AppSupport, now: Date = Date()) throws
}

public enum RegistryCache {
    /// nil when missing or unreadable (logged).
    public static func load(_ appSupport: AppSupport) -> MeshSnapshot?
    public static func save(_ snapshot: MeshSnapshot, _ appSupport: AppSupport) throws
    public static func delete(_ appSupport: AppSupport) throws
}

public struct DeviceSettings: Codable, Sendable, Equatable {
    public struct Forge: Codable, Sendable, Equatable {
        public var enabled: Bool = false
        public var sourceProjectID: String = "HEPH"
        public var branch: String = "main"
        public var autoRegenerate: Bool = true
        public init()
    }
    public struct Updates: Codable, Sendable, Equatable {
        public var enabled: Bool = true
        public var signingIdentity: String = ""
        public init()
    }
    public var isMain: Bool = false
    public var projectsFolder: String = "~/Developer"
    public var listenerPort: Int = 47100
    public var pairingPort: Int = 47101
    public var additionalAddresses: [String] = []
    public var claudePath: String = ""
    public var defaultModel: String = ""
    public var defaultPermissionMode: PermissionMode = .acceptEdits
    public var sessionIdleMinutes: Int = 15
    public var autosave: Bool = true
    public var showHiddenFiles: Bool = false
    public var forge = Forge()
    public var updates = Updates()

    public init()
    /// Reads each key on its own; a bad or missing key takes its default.
    public init(from decoder: Decoder) throws
    public mutating func normalize()
    /// Throws DataError.invalid with the first broken rule's message.
    public func validate() throws
    public var projectsFolderURL: URL { get }
    public var claudeURL: URL? { get }
}

@MainActor @Observable
public final class SettingsStore {
    public private(set) var settings: DeviceSettings
    /// Reads settings.json.
    public init(appSupport: AppSupport)
    /// Applies, normalizes, validates and writes; publishes the new value. Throws without changing anything on failure.
    public func update(_ change: (inout DeviceSettings) -> Void) throws
    /// A new stream that yields the settings after each successful update.
    public func changes() -> AsyncStream<DeviceSettings>
}

public struct MeshCredentials: Codable, Sendable, Equatable {
    public var meshID: UUID
    /// 32 bytes; JSON base64.
    public var meshKey: Data
    public init(meshID: UUID, meshKey: Data)
}

/// Where a device keeps its mesh credentials (Credential store).
public protocol MeshCredentialStore: AnyObject, Sendable {
    /// nil when the device has no mesh.
    func load() throws -> MeshCredentials?
    /// Replaces the credentials, then yields them to every changes() stream.
    func save(_ credentials: MeshCredentials) throws
    /// Removes the credentials ("Leave mesh"), then yields nil to every changes() stream.
    func delete() throws
    /// A new stream (unbounded buffer) yielding the credentials after each successful save or delete made through
    /// this instance. It ends when the iterating task is cancelled.
    func changes() -> AsyncStream<MeshCredentials?>
}

/// The Keychain item of the Keychain section.
public final class KeychainCredentialStore: MeshCredentialStore {
    /// "ca.azavech.hephaestus.mesh"
    public static let defaultService: String
    /// KeychainCredentialStore(service: defaultService): the only store the app creates.
    public static let shared: KeychainCredentialStore
    /// kSecAttrService of the item.
    public let service: String
    public init(service: String = KeychainCredentialStore.defaultService)
}

/// Tests and previews: the credentials in memory; never throws.
public final class InMemoryCredentialStore: MeshCredentialStore {
    public init(_ credentials: MeshCredentials? = nil)
}

public enum WindowStateKeys {
    public static let mainDeviceID = "selection.mainDeviceID"
    public static let projectID = "selection.projectID"
    public static let section = "selection.section"
    public static let item = "selection.item"
}
```

`MeshSnapshot` and `PermissionMode` are defined in [protocol/types.md](../protocol/types.md).
