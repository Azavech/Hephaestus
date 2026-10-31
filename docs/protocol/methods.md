# Wire protocol: methods

files:
- HephaestusKit/Sources/HephCore/Protocol/Methods.swift

---

Every request a device can send, with its params, result, errors, side effects and events. Frames, handshake and
error codes: [envelope.md](envelope.md). Shared types: [types.md](types.md). Events: [events.md](events.md). The
services that implement the methods on a Main are in [services/host.md](../services/host.md) and the documents linked
from each method.

## Rules for every method

### Callers

| `MethodCallers` | Served by    | Accepted from                                                                         |
|-----------------|--------------|---------------------------------------------------------------------------------------|
| `anyDevice`     | Mains        | Any authenticated connection: remotes, peer links, the Main's own loopback connection |
| `mainPeers`     | Mains        | Peer links only (connections whose `hello` had `device.isMain == true`)               |
| `servingMain`   | Every device | The Main at the other end of a connection this device opened                          |

- A request that its callers rule does not accept is answered with `unauthorized` "Main only".
- `hello` is accepted only as the first request of a connection ([envelope.md](envelope.md#handshake)); a later `hello`
  is answered with `badRequest` "Already authenticated".
- A Main answers `mesh.rekey` received on a connection it accepted with `badRequest` "mesh.rekey is not served by a
  Main". A device answers any other method received on a connection it opened with `badRequest` "Unknown method
  <name>.".

### Errors common to all methods

These are not repeated in the method sections:

| Code           | Case                                                                                              |
|----------------|---------------------------------------------------------------------------------------------------|
| `badRequest`   | The params do not decode; a name breaks the name rules below; a path breaks the path rules below  |
| `unauthorized` | The callers rule does not accept the connection                                                   |
| `notFound`     | A `projectID` that is not a project or sub project hosted by this Main                            |
| `conflict`     | The method must rewrite an invalid file: a `project.yml` that does not parse, a broken task file  |
| `locked`       | A write method (column W) on a project that is migrating, or whose top-level project is migrating |
| `tooLarge`     | The response does not fit in one frame ([envelope.md](envelope.md#frames))                        |
| `internal`     | An unexpected failure                                                                             |

The app never writes over an invalid file: `DataError.refused` maps to `conflict`
([data/app-storage.md](../data/app-storage.md#errors)), with the message "The file is invalid: <parse error>",
<parse error> being the file's `parseError` (`ProjectSummary.parseError`, `TaskItem.parseError`,
[types.md](types.md)).

### Write methods

Methods marked W in the method table change a project. They are refused with `locked` while the project (the
`projectID` param, or `parentID` for `projects.create`) or its top-level project is migrating
([devices/migration.md](../devices/migration.md)).

### Paths

- Project paths are project-relative, `/`-separated, without a leading `/`; `""` is the project root. A path that is
  absolute, contains a `.` or `..` component, or resolves (symbolic links included) outside the project root is refused
  with `badRequest` ([services/files.md](../services/files.md)).
- Skill paths follow the same rules relative to the skill folder.
- Names (project, sub project, task, run configuration, session title, device) are trimmed of surrounding white space
  and line breaks. A project name, a task name, a run configuration name and a session title must not be empty and
  must be on one line (no line break, [data/project-yml.md](../data/project-yml.md#validation-and-normalization));
  they have no maximum length. Another name is refused with `badRequest` and the message of
  [data/project-yml.md](../data/project-yml.md), [data/task-yml.md](../data/task-yml.md) or
  [data/sessions.md](../data/sessions.md). A device name must not be empty (`badRequest` "Enter a device name.",
  [devices/roles.md](../devices/roles.md#names)). Skill names: [Skills](#skills).

### Results and events

- The events listed for a method are the events its effects cause, emitted by the serving Main after the change (some
  come from its file watcher, [services/host.md](../services/host.md)). They reach every device, the caller included.
  The caller may apply the result to its mirror at once; the event then brings the same state.
- Lists in results are ordered as stated; when nothing is stated, the order carries no meaning.
- No method waits for long work. Work that continues after the response (a migration, a session turn, a run) reports
  through events.

### Limits

`MethodLimits` holds these values.

| Constant             | Value                     | Applies to                                                                                                                                                                          | Error                        |
|----------------------|---------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------|
| `maxChunkSize`       | 4,194,304 bytes (4 MiB)   | `uploads.chunk` `data`; the `length` of `attachments.read`, `sessions.readAttachment` and a ranged `files.read`: default and maximum (a larger `length` reads `maxChunkSize` bytes) | `tooLarge` (`uploads.chunk`) |
| `maxFileSize`        | 10,485,760 bytes (10 MiB) | Content of `files.read` without a range, `files.write`, `skills.readFile`, `skills.writeFile`                                                                                       | `tooLarge`                   |
| `migrationChunkSize` | 262,144 bytes (256 KiB)   | `migration.chunk` data: every chunk of a file has this size except the last                                                                                                         | `badRequest`                 |
| `maxSearchResults`   | 200                       | `search.query` `limit`: default and maximum                                                                                                                                         | none                         |

- Attachments have no size limit (comment files, message files, MCP `comment_task` files, feedback screenshots). A
  file reaches the Main in chunks through an upload ([Uploads](#uploads)) and is read back in ranges
  (`attachments.read`, `sessions.readAttachment`, a ranged `files.read`).
- Every request and response must also fit in one 48 MiB frame ([envelope.md](envelope.md#frames)). A 4 MiB chunk takes
  about 5.3 MiB once base64-encoded, and a 10 MiB file about 13.3 MiB.

## Method table

| Method                    | `RPCMethod` case         | Params                         | Result                      | Callers       | W |
|---------------------------|--------------------------|--------------------------------|-----------------------------|---------------|---|
| `hello`                   | `hello`                  | `HelloParams`                  | `HelloResult`               | `anyDevice`   |   |
| `mesh.snapshot`           | `meshSnapshot`           | `EmptyPayload`                 | `MeshSnapshot`              | `anyDevice`   |   |
| `mesh.sync`               | `meshSync`               | `MeshSyncParams`               | `MeshSyncResult`            | `mainPeers`   |   |
| `mesh.renameDevice`       | `meshRenameDevice`       | `MeshRenameDeviceParams`       | `DeviceRecord`              | `anyDevice`   |   |
| `mesh.revokeDevice`       | `meshRevokeDevice`       | `MeshRevokeDeviceParams`       | `EmptyPayload`              | `anyDevice`   |   |
| `mesh.rekey`              | `meshRekey`              | `MeshRekeyParams`              | `EmptyPayload`              | `servingMain` |   |
| `mesh.setAddresses`       | `meshSetAddresses`       | `MeshSetAddressesParams`       | `DeviceRecord`              | `anyDevice`   |   |
| `pairing.open`            | `pairingOpen`            | `EmptyPayload`                 | `PairingOpenResult`         | `anyDevice`   |   |
| `pairing.close`           | `pairingClose`           | `EmptyPayload`                 | `EmptyPayload`              | `anyDevice`   |   |
| `host.info`               | `hostInfo`               | `EmptyPayload`                 | `HostInfoResult`            | `anyDevice`   |   |
| `host.listDirectories`    | `hostListDirectories`    | `HostListDirectoriesParams`    | `HostListDirectoriesResult` | `anyDevice`   |   |
| `subscribe`               | `subscribe`              | `SubscribeParams`              | `EmptyPayload`              | `anyDevice`   |   |
| `unsubscribe`             | `unsubscribe`            | `UnsubscribeParams`            | `EmptyPayload`              | `anyDevice`   |   |
| `projects.list`           | `projectsList`           | `EmptyPayload`                 | `ProjectsListResult`        | `anyDevice`   |   |
| `projects.snapshot`       | `projectsSnapshot`       | `ProjectsSnapshotParams`       | `ProjectsSnapshotResult`    | `anyDevice`   |   |
| `projects.create`         | `projectsCreate`         | `ProjectsCreateParams`         | `ProjectSummary`            | `anyDevice`   | W |
| `projects.import`         | `projectsImport`         | `ProjectsImportParams`         | `ProjectSummary`            | `anyDevice`   |   |
| `projects.update`         | `projectsUpdate`         | `ProjectsUpdateParams`         | `Project`                   | `anyDevice`   | W |
| `projects.remove`         | `projectsRemove`         | `ProjectsRemoveParams`         | `EmptyPayload`              | `anyDevice`   | W |
| `projects.migrate`        | `projectsMigrate`        | `ProjectsMigrateParams`        | `ProjectsMigrateResult`     | `anyDevice`   | W |
| `uploads.begin`           | `uploadsBegin`           | `UploadsBeginParams`           | `UploadsBeginResult`        | `anyDevice`   |   |
| `uploads.chunk`           | `uploadsChunk`           | `UploadsChunkParams`           | `EmptyPayload`              | `anyDevice`   |   |
| `uploads.cancel`          | `uploadsCancel`          | `UploadsCancelParams`          | `EmptyPayload`              | `anyDevice`   |   |
| `tasks.create`            | `tasksCreate`            | `TasksCreateParams`            | `TaskItem`                  | `anyDevice`   | W |
| `tasks.update`            | `tasksUpdate`            | `TasksUpdateParams`            | `TaskItem`                  | `anyDevice`   | W |
| `tasks.delete`            | `tasksDelete`            | `TasksDeleteParams`            | `EmptyPayload`              | `anyDevice`   | W |
| `tasks.addComment`        | `tasksAddComment`        | `TasksAddCommentParams`        | `TaskItem`                  | `anyDevice`   | W |
| `tasks.updateComment`     | `tasksUpdateComment`     | `TasksUpdateCommentParams`     | `TaskItem`                  | `anyDevice`   | W |
| `tasks.deleteComment`     | `tasksDeleteComment`     | `TasksDeleteCommentParams`     | `TaskItem`                  | `anyDevice`   | W |
| `attachments.read`        | `attachmentsRead`        | `AttachmentsReadParams`        | `AttachmentsReadResult`     | `anyDevice`   |   |
| `bundles.create`          | `bundlesCreate`          | `BundlesCreateParams`          | `BundleItem`                | `anyDevice`   | W |
| `bundles.update`          | `bundlesUpdate`          | `BundlesUpdateParams`          | `BundleItem`                | `anyDevice`   | W |
| `bundles.delete`          | `bundlesDelete`          | `BundlesDeleteParams`          | `EmptyPayload`              | `anyDevice`   | W |
| `bundles.start`           | `bundlesStart`           | `BundlesStartParams`           | `BundleItem`                | `anyDevice`   | W |
| `bundles.stop`            | `bundlesStop`            | `BundlesStopParams`            | `BundleItem`                | `anyDevice`   | W |
| `files.list`              | `filesList`              | `FilesListParams`              | `FilesListResult`           | `anyDevice`   |   |
| `files.read`              | `filesRead`              | `FilesReadParams`              | `FilesReadResult`           | `anyDevice`   |   |
| `files.write`             | `filesWrite`             | `FilesWriteParams`             | `FilesWriteResult`          | `anyDevice`   | W |
| `files.create`            | `filesCreate`            | `FilesCreateParams`            | `FileEntry`                 | `anyDevice`   | W |
| `files.rename`            | `filesRename`            | `FilesRenameParams`            | `EmptyPayload`              | `anyDevice`   | W |
| `files.delete`            | `filesDelete`            | `FilesDeleteParams`            | `EmptyPayload`              | `anyDevice`   | W |
| `tabs.open`               | `tabsOpen`               | `TabsOpenParams`               | `WebTab`                    | `anyDevice`   | W |
| `tabs.update`             | `tabsUpdate`             | `TabsUpdateParams`             | `WebTab`                    | `anyDevice`   | W |
| `tabs.close`              | `tabsClose`              | `TabsCloseParams`              | `EmptyPayload`              | `anyDevice`   | W |
| `tabs.move`               | `tabsMove`               | `TabsMoveParams`               | `EmptyPayload`              | `anyDevice`   | W |
| `sessions.start`          | `sessionsStart`          | `SessionsStartParams`          | `SessionInfo`               | `anyDevice`   | W |
| `sessions.history`        | `sessionsHistory`        | `SessionsHistoryParams`        | `SessionsHistoryResult`     | `anyDevice`   |   |
| `sessions.readAttachment` | `sessionsReadAttachment` | `SessionsReadAttachmentParams` | `AttachmentsReadResult`     | `anyDevice`   |   |
| `sessions.send`           | `sessionsSend`           | `SessionsSendParams`           | `EmptyPayload`              | `anyDevice`   | W |
| `sessions.interrupt`      | `sessionsInterrupt`      | `SessionsInterruptParams`      | `EmptyPayload`              | `anyDevice`   |   |
| `sessions.stop`           | `sessionsStop`           | `SessionsStopParams`           | `EmptyPayload`              | `anyDevice`   |   |
| `sessions.respond`        | `sessionsRespond`        | `SessionsRespondParams`        | `EmptyPayload`              | `anyDevice`   | W |
| `sessions.update`         | `sessionsUpdate`         | `SessionsUpdateParams`         | `SessionInfo`               | `anyDevice`   | W |
| `sessions.delete`         | `sessionsDelete`         | `SessionsDeleteParams`         | `EmptyPayload`              | `anyDevice`   | W |
| `runs.start`              | `runsStart`              | `RunsStartParams`              | `RunInfo`                   | `anyDevice`   | W |
| `runs.stop`               | `runsStop`               | `RunsStopParams`               | `EmptyPayload`              | `anyDevice`   |   |
| `runs.output`             | `runsOutput`             | `RunsOutputParams`             | `RunsOutputResult`          | `anyDevice`   |   |
| `search.query`            | `searchQuery`            | `SearchQueryParams`            | `SearchQueryResult`         | `anyDevice`   |   |
| `skills.list`             | `skillsList`             | `EmptyPayload`                 | `SkillsListResult`          | `anyDevice`   |   |
| `skills.create`           | `skillsCreate`           | `SkillsCreateParams`           | `SkillSummary`              | `anyDevice`   |   |
| `skills.files`            | `skillsFiles`            | `SkillsFilesParams`            | `SkillsFilesResult`         | `anyDevice`   |   |
| `skills.readFile`         | `skillsReadFile`         | `SkillsReadFileParams`         | `SkillsReadFileResult`      | `anyDevice`   |   |
| `skills.writeFile`        | `skillsWriteFile`        | `SkillsWriteFileParams`        | `EmptyPayload`              | `anyDevice`   |   |
| `skills.deleteFile`       | `skillsDeleteFile`       | `SkillsDeleteFileParams`       | `EmptyPayload`              | `anyDevice`   |   |
| `skills.rename`           | `skillsRename`           | `SkillsRenameParams`           | `SkillSummary`              | `anyDevice`   |   |
| `skills.delete`           | `skillsDelete`           | `SkillsDeleteParams`           | `EmptyPayload`              | `anyDevice`   |   |
| `skills.manifest`         | `skillsManifest`         | `EmptyPayload`                 | `SkillsManifestResult`      | `mainPeers`   |   |
| `migration.begin`         | `migrationBegin`         | `MigrationBeginParams`         | `MigrationBeginResult`      | `mainPeers`   |   |
| `migration.chunk`         | `migrationChunk`         | `MigrationChunkParams`         | `EmptyPayload`              | `mainPeers`   |   |
| `migration.commit`        | `migrationCommit`        | `MigrationCommitParams`        | `EmptyPayload`              | `mainPeers`   |   |
| `migration.abort`         | `migrationAbort`         | `MigrationAbortParams`         | `EmptyPayload`              | `mainPeers`   |   |
| `migration.status`        | `migrationStatus`        | `MigrationStatusParams`        | `MigrationStatusResult`     | `mainPeers`   |   |
| `forge.feedback`          | `forgeFeedback`          | `ForgeFeedbackParams`          | `ForgeFeedbackResult`       | `anyDevice`   |   |
| `forge.status`            | `forgeStatus`            | `EmptyPayload`                 | `ForgeState`                | `anyDevice`   |   |
| `forge.regenerate`        | `forgeRegenerate`        | `EmptyPayload`                 | `EmptyPayload`              | `anyDevice`   |   |
| `forge.retry`             | `forgeRetry`             | `ForgeRetryParams`             | `EmptyPayload`              | `anyDevice`   |   |

## Swift API

```swift
public enum RPCMethod: String, CaseIterable, Sendable {
    case hello = "hello"
    case meshSnapshot = "mesh.snapshot"
    // … one case per row of the method table, in table order, raw value = method name
    case forgeRetry = "forge.retry"

    public var callers: MethodCallers { get }   // Callers column
    public var writesProject: Bool { get }       // W column
}

public enum MethodCallers: Sendable {
    case anyDevice, mainPeers, servingMain
}

public enum MethodLimits {
    public static let maxChunkSize = 4_194_304
    public static let maxFileSize = 10_485_760
    public static let migrationChunkSize = 262_144
    public static let maxSearchResults = 200
}
```

- The name is `RPCMethod`: a type named `Method` is ambiguous with `ObjectiveC.Method` in every file that imports
  Foundation.
- Every params and result struct of this document is declared in Methods.swift like the types of
  [types.md](types.md#conventions): `public struct <Name>: Codable, Sendable, Hashable`, `public var` fields in table
  order, a public memberwise `init` with optional parameters defaulting to `nil`.
- Callers send requests with `RPCPeer.request` ([envelope.md](envelope.md#rpcpeerswift-hephnet)), for example
  `let task = try await peer.request(.tasksCreate, TasksCreateParams(projectID: "HEPH", name: "Fix"), as: TaskItem.self)`.

## Mesh and pairing

Registry, presence, pairing and key rotation are specified in [devices/mesh.md](../devices/mesh.md); these sections
give the contract of each method.

### hello

The first request of every connection ([envelope.md](envelope.md#handshake)).

`HelloParams`:

| Field             | Type         | Meaning                      |
|-------------------|--------------|------------------------------|
| `device`          | `DeviceInfo` | The caller                   |
| `protocolVersion` | `Int`        | `WireCoding.protocolVersion` |

`HelloResult`:

| Field    | Type           | Meaning                                 |
|----------|----------------|-----------------------------------------|
| `device` | `DeviceInfo`   | The serving Main                        |
| `mesh`   | `MeshSnapshot` | The Main's registry and presence report |

- Errors, each followed by the closing of the connection: `badRequest` "Invalid hello" (params do not decode);
  `badRequest` "Unsupported protocol version <n>" (`protocolVersion` differs); `badRequest` "Only a Mac can be a Main"
  (`device.isMain` is true and `device.platform` is not `macOS`); `unauthorized` "This device was removed from the
  mesh" (`device.id` is revoked in the registry).
- Effects: the connection is authenticated, and is a peer link when `device.isMain` is true. A device id unknown to the
  registry is accepted: the TLS-PSK handshake already proves mesh membership. The device becomes a direct connection
  in the Main's presence report. Registry: an unknown `device.id` gets a new record built from `device` (`addresses`
  empty, `port` 0, `pairedAt` and `updatedAt` now, `revoked` false); for a known record, a different `platform`,
  `isMain`, `appVersion` or `build` is copied into it with `updatedAt` now. `hello` never changes a record's `name`
  (only `mesh.renameDevice` does); a device whose record name differs from its local name adopts the record's name
  ([devices/roles.md](../devices/roles.md)). Registry changes are saved and synced to the peer Mains
  ([devices/mesh.md](../devices/mesh.md)).
- Events: `mesh.changed`.

### mesh.snapshot

- Params: `EmptyPayload`. Result: `MeshSnapshot`, the Main's registry and presence report.

### mesh.sync

Registry and presence exchange between Mains, sent by a Main on its peer link when the link opens and after each
change of its registry or direct presence.

`MeshSyncParams` and `MeshSyncResult` have the same fields:

| Field      | Type             | Meaning                                                                                    |
|------------|------------------|--------------------------------------------------------------------------------------------|
| `devices`  | `[DeviceRecord]` | Params: the caller's whole registry. Result: the callee's registry after the merge         |
| `presence` | `[Presence]`     | The sender's direct entries only: itself and its direct connections, never relayed entries |

- Effects: the callee merges the records (per device, the record with the latest `updatedAt` wins), saves its registry,
  and stores the caller's direct entries as its relayed entries for the caller. The caller does the same with the
  result.
- Events: `mesh.changed` from each Main whose registry or presence report changed.

### mesh.renameDevice

`MeshRenameDeviceParams`:

| Field      | Type     | Meaning          |
|------------|----------|------------------|
| `deviceID` | `UUID`   | Device to rename |
| `name`     | `String` | New name         |

- Result: `DeviceRecord`, the renamed record.
- Errors: `notFound` (unknown device), `badRequest` "Claude is a reserved name." (`Claude` in any letter case,
  [devices/roles.md](../devices/roles.md#names)).
- Effects: sets `name` and `updatedAt` (now), saves, syncs to the peer Mains.
- Events: `mesh.changed`.

### mesh.revokeDevice

`MeshRevokeDeviceParams`:

| Field      | Type   | Meaning          |
|------------|--------|------------------|
| `deviceID` | `UUID` | Device to revoke |

- Result: `EmptyPayload`, sent once the new mesh key is stored on the serving Main.
- Errors: `notFound` (unknown device); `badRequest` when `deviceID` is the serving Main.
- Effects: marks the record `revoked` (`updatedAt` now), saves it, generates and stores a new mesh key, and answers.
  Then it closes the revoked device's connections, sends `mesh.rekey` on every other inbound connection of a non-revoked
  device, its own loopback connection included (its own UI then reconnects with the new key), and reconnects its own
  peer links with the new key ([devices/mesh.md](../devices/mesh.md)). A device may revoke itself; its connection then
  closes, possibly before the response arrives.
- Events: `mesh.changed`.

### mesh.rekey

Sent by a Main to the devices connected to it during a key rotation.

`MeshRekeyParams`:

| Field     | Type   | Meaning                    |
|-----------|--------|----------------------------|
| `meshKey` | `Data` | The new mesh key, 32 bytes |

- Result: `EmptyPayload`.
- Errors: `badRequest` when the key is not 32 bytes.
- Effects on the receiving device: a key equal to the key it uses changes nothing. Otherwise the device stores the key
  with its mesh credentials, sends the response, then closes every network connection it opened and reconnects with
  the new key ([client/workspace.md](../client/workspace.md#incoming-requests)); a Main also uses the new key for its
  listener ([devices/mesh.md](../devices/mesh.md)).
- Forwarding: a Main that receives a new key on its outgoing peer link to a Main X also sends `mesh.rekey` with the
  same key, at once, on each of its inbound connections of a remote that X was not connected to: a non-revoked device
  whose record has `isMain` false and whose presence entry `via` does not list X, and on its own loopback connection
  (its own UI). Peer Mains get nothing. There is no other condition or timer ([devices/mesh.md](../devices/mesh.md)).
- Callers: `servingMain`.

### mesh.setAddresses

Sets the additional addresses (Settings) of the serving Main.

`MeshSetAddressesParams`:

| Field       | Type       | Meaning                                                                                                  |
|-------------|------------|----------------------------------------------------------------------------------------------------------|
| `addresses` | `[String]` | The user-entered additional addresses; replaces the list. Entries are trimmed; empty entries are dropped |

- Result: `DeviceRecord`, the Main's own record with its recomputed `addresses`.
- Effects: saves the setting ([data/app-storage.md](../data/app-storage.md)), recomputes the record's `addresses`, sets
  `updatedAt`, saves, syncs to the peer Mains.
- Events: `mesh.changed`.

### pairing.open

Opens a pairing window on the serving Main.

- Params: `EmptyPayload`.
- Result `PairingOpenResult`:

| Field       | Type     | Meaning                                                |
|-------------|----------|--------------------------------------------------------|
| `code`      | `String` | The 6-digit code, as 6 characters (leading zeros kept) |
| `expiresAt` | `Date`   | When the window closes unless used before              |
| `port`      | `Int`    | The pairing port (`47101`)                             |

- Effects: when no window is open, opens one; when one is open, returns it unchanged.
- Errors: `unavailable` when the pairing listener cannot start (for example, the port is in use).
- Events: none. A device that joins causes `mesh.changed`.

### pairing.close

- Params: `EmptyPayload`. Result: `EmptyPayload`.
- Effects: closes the pairing window when one is open.

## Host

### host.info

- Params: `EmptyPayload`.
- Result `HostInfoResult`:

| Field             | Type           | Meaning                                                                                |
|-------------------|----------------|----------------------------------------------------------------------------------------|
| `device`          | `DeviceInfo`   | The serving Main                                                                       |
| `projectsFolder`  | `String`       | Absolute path of the folder where new projects are created (the setting, `~` expanded) |
| `claudeAvailable` | `Bool`         | The Claude CLI was found                                                               |
| `claudePath`      | `String`       | Absolute path of the Claude CLI in use; `""` when not found                            |
| `gitAvailable`    | `Bool`         | `git` was found ([services/host.md](../services/host.md))                              |
| `forge`           | `ForgeConfig?` | Set only while this Main is the Forge                                                  |

### host.listDirectories

Lists the folders of a folder of the Main user's home, for remote folder pickers.

`HostListDirectoriesParams`:

| Field  | Type     | Meaning                                                                                        |
|--------|----------|------------------------------------------------------------------------------------------------|
| `path` | `String` | Absolute path of a folder inside the home folder, a leading `~` allowed; `""`: the home folder |

`HostListDirectoriesResult`:

| Field     | Type               | Meaning                                                                                                                                   |
|-----------|--------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| `path`    | `String`           | Absolute path of the listed folder, symbolic links resolved                                                                               |
| `entries` | `[DirectoryEntry]` | Its subfolders whose names do not start with `.` and that resolve inside the home folder, ordered by name with `localizedStandardCompare` |

`DirectoryEntry`: `name` (`String`, folder name), `path` (`String`, absolute path: the listed `path` + `/` + `name`).

- Errors: `badRequest` when `path` is relative or resolves outside the home folder; `notFound` when it is not an
  existing folder; `unavailable` when it cannot be read (permissions, privacy protection).

## Subscriptions

### subscribe

`SubscribeParams`:

| Field    | Type       | Meaning                                          |
|----------|------------|--------------------------------------------------|
| `topics` | `[String]` | Topics to add to this connection's subscriptions |

- Result: `EmptyPayload`.
- Each topic must parse as a `Topic` ([envelope.md](envelope.md#envelopeswift-hephcore)); otherwise the request fails
  with `badRequest` "Invalid topic <topic>" and none of its topics is applied.
- Rules: [envelope.md](envelope.md#subscriptions).

### unsubscribe

`UnsubscribeParams`: `topics` (`[String]`), the topics to remove. Result: `EmptyPayload`. Errors as `subscribe`.

## Projects

Project storage: [data/project-yml.md](../data/project-yml.md). Registry of hosted projects and the file watcher:
[services/host.md](../services/host.md).

### projects.list

- Params: `EmptyPayload`.
- Result `ProjectsListResult`: `projects` (`[ProjectSummary]`), the top-level projects of this Main ordered by name
  with `localizedStandardCompare`, each with its sub projects in `children`. Each `pendingPermissionCount` tells a
  client which projects have permission requests waiting ([events.md](events.md#permissionrequested)).

### projects.snapshot

Everything a client mirrors for one project.

`ProjectsSnapshotParams`: `projectID` (`String`).

`ProjectsSnapshotResult`:

| Field      | Type            | Meaning                                                                           |
|------------|-----------------|-----------------------------------------------------------------------------------|
| `project`  | `Project`       | The project                                                                       |
| `tasks`    | `[TaskItem]`    | Its tasks, broken ones included, ordered by task number                           |
| `bundles`  | `[BundleItem]`  | Its bundles, ordered by bundle number                                             |
| `sessions` | `[SessionInfo]` | Its sessions of every kind, ordered by `created`, with their `pendingPermissions` |
| `runs`     | `[RunInfo]`     | Its runs kept in memory (at most 20), newest `startedAt` first                    |

Sub projects are not included; each has its own snapshot.

### projects.create

Creates a project, or a sub project when `parentID` is set.

`ProjectsCreateParams`:

| Field         | Type      | Meaning                                                                                                                                                             |
|---------------|-----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `name`        | `String`  | Project name                                                                                                                                                        |
| `identifier`  | `String`  | Project identifier: 2–8 letters A–Z, uppercase ([data/project-yml.md](../data/project-yml.md))                                                                      |
| `parentID`    | `String?` | Parent project on this Main; `nil`: a top-level project                                                                                                             |
| `folderName`  | `String?` | Folder, relative to the projects folder (top-level) or to the parent root (sub project); may contain `/`; default: `name` with `/` and `:` replaced by `-`, trimmed |
| `description` | `String?` | Description                                                                                                                                                         |

- Result: `ProjectSummary` of the new project.
- The folder is normalized as the relative paths of project.yml are
  ([data/project-yml.md](../data/project-yml.md#relative-paths)): `./Atlas/` becomes `Atlas`, and a folder that starts
  with `/` or `~`, has a `..` component or normalizes to `.` is refused. It must stay strictly inside its base folder,
  and its first component must not be `.hephaestus`. An existing folder without `.hephaestus/project.yml` is used as it
  is; when the creation fails, only what it created is removed ([services/host.md](../services/host.md)).
- Errors: `badRequest` (invalid name, identifier or folder name; on the Forge host, a `parentID` that is the Forge
  source project or one of its sub projects: "The Forge source project is a public repository: create this project
  elsewhere.", [services/host.md](../services/host.md#73-projectscreate)); `notFound` (`parentID`); `conflict` when the
  identifier is used by a project of this Main or of an online Main this Main is connected to, when the folder already
  holds a `.hephaestus/project.yml` ("<path> is already a project."), when something that is not a folder exists at
  its path ("<path> already exists."), or when the parent's project.yml is invalid; `locked` (parent migrating).
- Writes: the folder and its missing intermediate folders; `.hephaestus/project.yml` with `id`, `name`,
  `description`, `created` (now), `code` `.`, `docs` `docs`, `taskCounter` 0, `feedbackCounter` 0;
  `.hephaestus/tasks/`; the docs folder
  `docs/` when missing. Top-level: the root path is added to `projects.json`
  ([data/app-storage.md](../data/app-storage.md)). Sub project: the folder path is appended to the parent's
  `subprojects`. Steps and their order: [services/host.md](../services/host.md).
- Events: `projects.changed`; for a sub project also `project.changed` (parent).

### projects.import

Registers an existing folder as a top-level project.

`ProjectsImportParams`:

| Field        | Type      | Meaning                                                                |
|--------------|-----------|------------------------------------------------------------------------|
| `path`       | `String`  | Absolute path of an existing folder on the Main, a leading `~` allowed |
| `name`       | `String?` | Name, required when the folder has no `.hephaestus/project.yml`        |
| `identifier` | `String?` | Identifier, required when the folder has no `.hephaestus/project.yml`  |

- When `<path>/.hephaestus/project.yml` exists it is used as it is, with the sub projects it lists, and `name` and
  `identifier` are ignored. Otherwise a project.yml is written as by `projects.create`, without a description.
- Result: `ProjectSummary`.
- Errors: `notFound` (no folder at `path`); `badRequest` (relative `path`; project.yml missing and `name` or
  `identifier` missing or invalid; existing project.yml invalid); `conflict` (the folder equals, is inside, or contains
  the root of a project of this Main; the identifier of the project or of one of its sub projects is already used, as
  for `projects.create`).
- Writes, when the folder has no `.hephaestus/project.yml`: that file, then `.hephaestus/tasks/` and the docs folder
  `docs/` when they are missing, as `ProjectFile.create` does ([data/project-yml.md](../data/project-yml.md#new-file)).
  The path is added to `projects.json`.
- Events: `projects.changed`.

### projects.update

`ProjectsUpdateParams`:

| Field       | Type           | Meaning                                     |
|-------------|----------------|---------------------------------------------|
| `projectID` | `String`       | Project                                     |
| `patch`     | `ProjectPatch` | Changes ([types.md](types.md#projectpatch)) |

- Result: `Project` after the change.
- Errors: `badRequest` (a project or run configuration name that breaks the name rules, two run configurations with
  the same name, an empty command, a `cwd` that breaks the path rules, a skill name that is not valid
  ([claude/skills.md](../claude/skills.md)); `runs` sent by an MCP tool: "Run configurations are changed by the user
  in the app.", [services/host.md](../services/host.md#75-projectsupdate)).
- Writes: project.yml.
- Events: `project.changed`; `projects.changed` when `name` or `description` changed.

### projects.remove

`ProjectsRemoveParams`:

| Field         | Type     | Meaning                                          |
|---------------|----------|--------------------------------------------------|
| `projectID`   | `String` | Project or sub project                           |
| `moveToTrash` | `Bool`   | Also move the project folder to the Main's Trash |

- Result: `EmptyPayload`.
- Errors: `unavailable` "Could not move <path> to the Trash: <reason>." when the folder cannot be moved to the Trash;
  `conflict` when the parent's project.yml of a sub project is invalid. After a failure the project stays registered
  and its stopped processes stay stopped; nothing else changes ([services/host.md](../services/host.md)).
- Effects: stops the session processes and runs of the project and of its sub projects; with `moveToTrash`, moves the
  folder to the Trash of the Main's user; unregisters the project (top-level: removed from `projects.json`; sub
  project: removed from the parent's `subprojects`; without `moveToTrash` its folder stays as a plain folder of the
  parent).
- Events: `run.changed` and `session.changed` for what was stopped; `projects.changed`; for a sub project also
  `project.changed` (parent).

### projects.migrate

Starts moving a top-level project to another Main ([devices/migration.md](../devices/migration.md)). Called on the
Main that hosts the project.

`ProjectsMigrateParams`:

| Field            | Type     | Meaning                   |
|------------------|----------|---------------------------|
| `projectID`      | `String` | Top-level project to move |
| `targetDeviceID` | `UUID`   | Destination Main          |

`ProjectsMigrateResult`: `migrationID` (`UUID`), the id used by the `migration.*` methods and `migration.progress`.

- Errors: `badRequest` (the project is a sub project; the target is this Main or is not a Main); `notFound` (unknown
  target device); `unavailable` (this Main has no open peer link to the target); `conflict` (a session process or a
  run of the project or of its sub projects is running: the UI offers to stop them); `locked` (already migrating).
- Effects: marks the project and its sub projects `migrating`, answers, then runs the migration: `migration.begin`,
  `migration.chunk`, `migration.commit` on the target. On success the source moves its folder to its Trash and
  unregisters the project. On failure it calls `migration.abort` on the target and clears `migrating`. The source
  records the move in its migration journal (`migrations.json`, [data/app-storage.md](../data/app-storage.md)), so a
  source that restarts after a crash finishes the cleanup or clears `migrating`
  ([devices/migration.md](../devices/migration.md#recovery-after-a-restart)).
- Events: `projects.changed` and `project.changed` (migrating set), `migration.progress`, then `projects.changed` (the
  project gone, or `migrating` cleared after a failure). The target emits `projects.changed` when it registers the
  project.

## Uploads

A file attached to a comment, a message or a feedback reaches the Main before the request that attaches it: the client
begins an upload, sends the file's bytes in chunks of at most `maxChunkSize`, in order, then names the complete upload
with an `UploadRef` ([types.md](types.md#uploadref)) in the request. Files have no size limit. The Main keeps uploads
in its Application Support folder until a request uses them ([services/files.md](../services/files.md#7-uploads)). The
client side, with progress: [client/workspace.md](../client/workspace.md#transfers).

### uploads.begin

`UploadsBeginParams`:

| Field       | Type     | Meaning                                                   |
|-------------|----------|-----------------------------------------------------------|
| `projectID` | `String` | The project (or sub project) the file will be attached in |
| `fileName`  | `String` | Original file name                                        |
| `size`      | `Int`    | Size of the file in bytes, 0 or more                      |

- Result `UploadsBeginResult`: `uploadID` (`UUID`), a new id.
- Errors: `badRequest` "Invalid size." (`size` below 0), "The file name is empty." (`fileName` empty after trimming);
  `internal` (the upload file cannot be created).
- Effects: creates the empty file `Uploads/<uploadID>` in the Main's Application Support folder
  ([data/app-storage.md](../data/app-storage.md)). An upload of size 0 is complete at once.
- Accepted while the project is migrating: the request that uses the upload is refused with `locked` then.
- Events: none.

### uploads.chunk

`UploadsChunkParams`:

| Field      | Type   | Meaning                                                                    |
|------------|--------|----------------------------------------------------------------------------|
| `uploadID` | `UUID` | Upload                                                                     |
| `offset`   | `Int`  | Byte offset of `data` in the file: the number of bytes received so far     |
| `data`     | `Data` | The next bytes of the file, 1 to `maxChunkSize` bytes (base64 on the wire) |

- Result: `EmptyPayload`, once the bytes are written.
- The client sends the chunks of an upload in order, one request at a time. The upload is complete when the bytes
  received equal `size`.
- Errors: `notFound` "Upload <id> does not exist." (unknown, cancelled, expired or used); `tooLarge` "A chunk is larger
  than 4 MiB." (`data` over `maxChunkSize`); `badRequest` "The chunk is empty." (`data` empty), "Unexpected offset
  <offset> for upload <id>." (`offset` is not the number of bytes received), "The chunk goes past the size of upload
  <id>." (`offset` + the size of `data` is above `size`); `conflict` "Upload <id> is in use." (a request in progress
  uses it); `internal` (the bytes cannot be written; the upload is deleted).
- Effects: appends `data` to the upload file; the upload's last chunk time becomes now.
- Events: none.

### uploads.cancel

`UploadsCancelParams`: `uploadID` (`UUID`).

- Result: `EmptyPayload`. Effects: deletes the upload and its file. An unknown upload, and one that a request in
  progress uses, are left as they are.
- Errors: none besides the common ones.
- Events: none.

### Using uploads

`tasks.addComment`, `sessions.start`, `sessions.send` and `forge.feedback` name uploads with `UploadRef` values. Before
the request changes anything, the Main checks every `UploadRef` of the request, in order:

| Check                                               | Error                                                  |
|-----------------------------------------------------|--------------------------------------------------------|
| the request names the upload once                   | `badRequest` "Upload <id> is named twice."             |
| the upload exists                                   | `notFound` "Upload <id> does not exist."               |
| it was begun for the request's project              | `badRequest` "Upload <id> belongs to another project." |
| no other request in progress uses it                | `conflict` "Upload <id> is in use."                    |
| it is complete: the bytes received equal its `size` | `badRequest` "Upload <id> is incomplete."              |

- The request's project is its `projectID`; for `forge.feedback`, the Forge's source project.
- When the request succeeds, each upload file is moved into place under the sanitized `fileName` of its `UploadRef`
  (the task's attachments folder, the session's attachment folder) and the upload is gone.
- When the request fails, the uploads it names stay as they were, usable by another request: files already moved are
  moved back ([services/files.md](../services/files.md#7-uploads)).
- An upload that no request uses is deleted one hour after its last chunk (after `uploads.begin` when it received no
  chunk), and every upload is deleted when the Main's host stops or starts. A request naming it afterwards fails with
  `notFound`.

## Tasks

Task storage: [data/task-yml.md](../data/task-yml.md). Attachment files: [services/files.md](../services/files.md).

### tasks.create

`TasksCreateParams`:

| Field         | Type          | Meaning                 |
|---------------|---------------|-------------------------|
| `projectID`   | `String`      | Project                 |
| `name`        | `String`      | Name                    |
| `description` | `String?`     | Markdown; default empty |
| `status`      | `TaskStatus?` | Default `todo`          |

- Result: `TaskItem`, the new task (`created` and `updated` now, no comments), with a task id `<projectID>-<n>`:
  only the Forge creates feedback task ids ([forge.feedback](#forgefeedback)).
- Errors: `conflict` (project.yml is invalid, so `taskCounter` cannot be saved); `badRequest` "no task number is left
  in <projectID>" ([data/task-yml.md](../data/task-yml.md#id-allocation)).
- Writes: `taskCounter` in project.yml, then `.hephaestus/tasks/<task id>.yml` with the next task number
  ([data/task-yml.md](../data/task-yml.md)).
- Events: `project.changed`, `task.changed`.

### tasks.update

`TasksUpdateParams`:

| Field       | Type        | Meaning                                  |
|-------------|-------------|------------------------------------------|
| `projectID` | `String`    | Project                                  |
| `taskID`    | `String`    | Task                                     |
| `patch`     | `TaskPatch` | Changes ([types.md](types.md#taskpatch)) |

- Result: `TaskItem` after the change, `updated` now. When the patch leaves every field equal, nothing is written,
  `updated` keeps its value and no event is sent.
- Errors: `notFound` (task); `conflict` (broken task).
- Writes: the task file. Events: `task.changed`.

### tasks.delete

`TasksDeleteParams`: `projectID` (`String`), `taskID` (`String`).

- Result: `EmptyPayload`.
- Errors: `notFound` (task).
- Writes: deletes the task file (broken tasks included) and `.hephaestus/attachments/<task id>/`.
- Events: `task.removed`.

### tasks.addComment

`TasksAddCommentParams`:

| Field         | Type          | Meaning                                                                                                                            |
|---------------|---------------|------------------------------------------------------------------------------------------------------------------------------------|
| `projectID`   | `String`      | Project                                                                                                                            |
| `taskID`      | `String`      | Task                                                                                                                               |
| `body`        | `String`      | Markdown; may be empty when `attachments` is not                                                                                   |
| `attachments` | `[UploadRef]` | Files to attach: complete uploads of the project ([Uploads](#uploads))                                                             |
| `author`      | `String?`     | Author to record; honored on peer links only (the MCP server of another Main forwards `Claude`, [claude/mcp.md](../claude/mcp.md)) |

- Result: `TaskItem` with the new comment (new `id`, `created` now; task `updated` now). The author is `author` on a
  peer link when given, else the name of the caller's device record.
- Errors: `notFound` (task; an unknown upload); `badRequest` (empty body, after trimming, and no attachment; an upload
  named twice, of another project, or incomplete); `conflict` (broken task; an upload in use by another request).
- Writes: each upload's file moved into `.hephaestus/attachments/<task id>/` under the sanitized `fileName` of its
  `UploadRef`, with ` 2`, ` 3`… inserted before the extension on a collision
  ([data/task-yml.md](../data/task-yml.md#attachments)), recorded as a `TaskAttachment` (MIME type from the file name
  extension, size of the file); the task file. On a failure the files go back to their uploads
  ([Using uploads](#using-uploads)).
- Events: `task.changed`.

### tasks.updateComment

`TasksUpdateCommentParams`: `projectID` (`String`), `taskID` (`String`), `commentID` (`UUID`), `body` (`String`, the
new Markdown body).

- Result: `TaskItem` after the change: the comment's `body` replaced and `edited` now; task `updated` now.
- Errors: `notFound` (task or comment); `badRequest` "Claude's comments cannot be edited." (the comment's `author` is
  `Claude`); `badRequest` (empty body, after trimming, on a comment without attachments); `conflict` (broken task).
- Only the comments of devices can be edited; Claude's comments (made through the MCP tools,
  [claude/mcp.md](../claude/mcp.md)) can only be deleted.
- Writes: the task file. Events: `task.changed`.

### tasks.deleteComment

`TasksDeleteCommentParams`: `projectID` (`String`), `taskID` (`String`), `commentID` (`UUID`).

- Works on every comment, Claude's included.
- Result: `TaskItem` after the change (task `updated` now).
- Errors: `notFound` (task or comment); `conflict` (broken task).
- Writes: the task file; deletes the comment's attachment files that no other comment of the task names.
- Events: `task.changed`.

### attachments.read

Reads a range of a task attachment.

`AttachmentsReadParams`:

| Field       | Type     | Meaning                                                     |
|-------------|----------|-------------------------------------------------------------|
| `projectID` | `String` | Project                                                     |
| `taskID`    | `String` | Task                                                        |
| `fileName`  | `String` | A `TaskAttachment.file`                                     |
| `offset`    | `Int?`   | First byte to read; default 0                               |
| `length`    | `Int?`   | Number of bytes to read; default and maximum `maxChunkSize` |

`AttachmentsReadResult`:

| Field      | Type     | Meaning                                                                                                                                         |
|------------|----------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| `data`     | `Data`   | The bytes from `offset`: `min(length, size − offset)` bytes; empty when `offset` equals `size`                                                  |
| `size`     | `Int`    | Size of the whole file in bytes                                                                                                                 |
| `mimeType` | `String` | The `type` of the attachment entry that names the file, else the type of its extension ([data/task-yml.md](../data/task-yml.md#reading-a-file)) |

- A `length` above `maxChunkSize` reads `maxChunkSize` bytes. A file of any size is read in ranges: the client reads
  from offset 0, `maxChunkSize` bytes at a time, until it has `size` bytes
  ([client/workspace.md](../client/workspace.md#transfers)).
- Allowed for a broken task.
- Errors: `badRequest` (`fileName` is not a valid stored file name; `offset` below 0 or above `size`; `length` below
  1); `notFound` (no such file in `.hephaestus/attachments/<task id>/`).

## Bundles

Task bundles, their files, worktrees and coordinator: [services/bundles.md](../services/bundles.md). Every method
takes `projectID` (`String`); the statuses each one allows and its errors are in
[services/bundles.md](../services/bundles.md#methods).

| Method           | Params besides `projectID`                     | Result         | Writes                         | Events                                 |
|------------------|------------------------------------------------|----------------|--------------------------------|----------------------------------------|
| `bundles.create` | `name` (`String`), `taskIDs` (`[String]`)      | `BundleItem`   | `.hephaestus/bundles/<id>.yml` | `bundle.changed`                       |
| `bundles.update` | `bundleID` (`String`), `patch` (`BundlePatch`) | `BundleItem`   | the bundle file                | `bundle.changed`                       |
| `bundles.delete` | `bundleID` (`String`)                          | `EmptyPayload` | deletes the file, worktrees    | `bundle.removed`                       |
| `bundles.start`  | `bundleID` (`String`)                          | `BundleItem`   | the bundle file, a session     | `bundle.changed`, `session.changed`, … |
| `bundles.stop`   | `bundleID` (`String`)                          | `BundleItem`   | the bundle file                | `bundle.changed`, `session.changed`, … |

The params structs are `Bundles<Name>Params` with these fields, in this order.

## Files

File operations, path safety, atomic writes and revisions: [services/files.md](../services/files.md).

### files.list

`FilesListParams`: `projectID` (`String`), `path` (`String`, folder; `""` for the root).

- Result `FilesListResult`: `entries` (`[FileEntry]`), the content of the folder, one level, hidden files included
  (clients hide them, [ui/code.md](../ui/code.md)); folders first, then files, each group ordered by name with
  `localizedStandardCompare`.
- Errors: `notFound` (no folder at `path`); `badRequest` (`path` is a file).

### files.read

`FilesReadParams`:

| Field       | Type     | Meaning                                                                  |
|-------------|----------|--------------------------------------------------------------------------|
| `projectID` | `String` | Project                                                                  |
| `path`      | `String` | A file                                                                   |
| `offset`    | `Int?`   | Ranged read: first byte to read; default 0                               |
| `length`    | `Int?`   | Ranged read: number of bytes to read; default and maximum `maxChunkSize` |

`FilesReadResult`:

| Field      | Type     | Meaning                                                                                           |
|------------|----------|---------------------------------------------------------------------------------------------------|
| `data`     | `Data`   | The whole content; for a ranged read, the bytes from `offset`: `min(length, size − offset)` bytes |
| `revision` | `String` | First 16 lowercase hex characters of the SHA-256 of the content; `""` for a ranged read           |
| `size`     | `Int`    | Size of the whole file in bytes                                                                   |

- Without `offset` and `length`: the whole file, at most `maxFileSize` bytes. The editors use this form
  ([ui/code.md](../ui/code.md)).
- With `offset` or `length` (a ranged read): any file size, at most `maxChunkSize` bytes per call, read as
  `attachments.read` reads; the file is not hashed. The image viewer and Quick Look read large files this way
  ([ui/media.md](../ui/media.md#largefileview)).
- Errors: `notFound`; `badRequest` (`path` is a folder; `offset` below 0 or above the size; `length` below 1);
  `tooLarge` (a whole read of a file over `maxFileSize`).

### files.write

`FilesWriteParams`:

| Field          | Type      | Meaning                                                                                      |
|----------------|-----------|----------------------------------------------------------------------------------------------|
| `projectID`    | `String`  | Project                                                                                      |
| `path`         | `String`  | File                                                                                         |
| `data`         | `Data`    | New content                                                                                  |
| `baseRevision` | `String?` | Revision the edit started from; `nil` writes unconditionally (creates the file when missing) |

- Result `FilesWriteResult`: `revision` (`String`), the revision of the written content.
- Errors: `conflict` (`baseRevision` is set and the file's current revision differs, or the file no longer exists);
  `notFound` (the parent folder does not exist); `badRequest` (`path` is a folder); `tooLarge` (`data` over
  `maxFileSize`).
- Writes: the file, atomically. Events: `files.changed` (and `project.changed`, `task.changed` when the file is a
  project or task file).

### files.create

`FilesCreateParams`: `projectID` (`String`), `path` (`String`), `isDirectory` (`Bool`).

- Result: `FileEntry` of the new empty file or folder.
- Errors: `badRequest` (`path` is `""`); `conflict` (something exists at `path`); `notFound` (the parent folder does
  not exist).
- Events: `files.changed`.

### files.rename

`FilesRenameParams`: `projectID` (`String`), `from` (`String`), `to` (`String`). Both are project paths; `to` may be in
another folder (a move).

- Result: `EmptyPayload`.
- Errors: `notFound` (nothing at `from`, or the parent folder of `to` does not exist); `conflict` (something exists at
  `to`); `badRequest` (`from` or `to` is `""` or a protected path, or `to` is inside `from`).
- Protected paths, which `files.rename` and `files.delete` refuse: `.hephaestus` and `.hephaestus/project.yml`
  ([services/files.md](../services/files.md)).
- Events: `files.changed`.

### files.delete

`FilesDeleteParams`: `projectID` (`String`), `path` (`String`).

- Result: `EmptyPayload`.
- Effects: moves the file or folder to the Trash of the Main's user; nothing is deleted permanently.
- Errors: `notFound`; `badRequest` (`path` is `""` or a protected path); `unavailable` "Could not move <path> to the
  Trash: <reason>." (the item cannot be moved to the Trash).
- Events: `files.changed`.

## Web tabs

Web tabs are stored in project.yml `webTabs` ([ui/web.md](../ui/web.md)). Every method below rewrites project.yml:
each fails with `conflict` when project.yml is invalid, and emits `project.changed`.

- A `url` is trimmed of surrounding white space. It must be `about:blank`, the URL of a new empty tab
  ([ui/web.md](../ui/web.md#tabs)), or an absolute `http` or `https` URL with a host, else `badRequest` "Only http and
  https addresses can be opened".
- The default title is the URL's host (`URL(string:)?.host`), or the URL itself when it has none (`about:blank`).

### tabs.open

`TabsOpenParams`:

| Field       | Type      | Meaning                                  |
|-------------|-----------|------------------------------------------|
| `projectID` | `String`  | Project                                  |
| `url`       | `String`  | URL                                      |
| `title`     | `String?` | Title; `nil` or empty: the default title |
| `locked`    | `Bool?`   | Default `false`                          |

- Result: `WebTab`, the new tab (new `id`), appended after the last tab.

### tabs.update

`TabsUpdateParams`: `projectID` (`String`), `tabID` (`UUID`), `patch` (`WebTabPatch`).

- Result: `WebTab` after the change. An empty `title` is replaced by the default title of the tab's URL.
- Errors: `notFound` (tab).

### tabs.close

`TabsCloseParams`: `projectID` (`String`), `tabID` (`UUID`).

- Result: `EmptyPayload`. Effects: removes the tab.
- Errors: `notFound` (tab); `locked` (the tab is locked).

### tabs.move

`TabsMoveParams`: `projectID` (`String`), `tabID` (`UUID`), `toIndex` (`Int`).

- Result: `EmptyPayload`. Effects: moves the tab so that its index becomes `toIndex`, clamped to `0…count−1`.
- Errors: `notFound` (tab).

## Sessions

Session process: [claude/cli.md](../claude/cli.md). Prompts and generated messages:
[claude/prompts.md](../claude/prompts.md). Session files: [data/sessions.md](../data/sessions.md).

### sessions.start

`SessionsStartParams`:

| Field            | Type              | Meaning                                                                                                                                                                                           |
|------------------|-------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `projectID`      | `String`          | Project                                                                                                                                                                                           |
| `kind`           | `SessionKind`     | `project` or `task`                                                                                                                                                                               |
| `taskID`         | `String?`         | Task sessions: the task (required); absent for project sessions                                                                                                                                   |
| `mode`           | `SessionMode?`    | Task sessions: the mode (required); absent for project sessions                                                                                                                                   |
| `title`          | `String?`         | Default: by kind, as in [claude/cli.md](../claude/cli.md) (task sessions `<Mode> <task id>`, for example `Implement HEPH-12`; project sessions `Chat <n>`, until the generated title replaces it) |
| `message`        | `String?`         | Project sessions: the first message. Task sessions: the custom instructions (required for mode `custom`)                                                                                          |
| `attachments`    | `[UploadRef]?`    | Project sessions: files attached to the first message, complete uploads of the project ([Uploads](#uploads)); `nil` or empty: none                                                                |
| `permissionMode` | `PermissionMode?` | Default: the project's `claude.permissionMode`, else the Main's default permission mode setting                                                                                                   |
| `model`          | `String?`         | Default: the project's `claude.model`, else the Main's default model setting, else none                                                                                                           |

- Result: `SessionInfo` of the new session (new `id`), status `starting` when its process starts now, else `stopped`.
- Process: a task session starts at once with its generated first message ([claude/prompts.md](../claude/prompts.md)).
  A project session starts at once when `message` or `attachments` is given, with `message` (empty when `nil`) and the
  attachments as the first user message, as `sessions.send` sends one; otherwise on the first `sessions.send`.
- Generated title: after the first user message of a project, feedback or bundle session, the Main asks a quick model
  for a short title in the background and replaces the default title with it (project sessions: the title alone;
  feedback and bundle sessions: `<task or bundle id> · <title>`), whatever the title is then; `session.changed`
  announces it. The request does not wait for it, and the default title stays when it fails
  ([claude/cli.md](../claude/cli.md#510-generated-titles-sessiontitler)).
- Errors: `badRequest` (`kind` is `feedback` or `regeneration`: only the Forge starts those; `kind` is `bundle`:
  `bundles.start` starts those; a project session with
  `taskID` or `mode`; a task session without `taskID` or `mode`, or with `attachments`; mode `custom` without a
  `message`; an empty `title` or `model`; a `title` with a line break; an upload named twice, of another project, or
  incomplete); `notFound` (task; an unknown upload); `conflict` (the task is broken: "The file is invalid: <parse
  error>"; an upload in use by another request); `unavailable` (a process must start and the Claude CLI or the
  Hephaestus tools are not available, [claude/cli.md](../claude/cli.md)).
- Writes: `.hephaestus/sessions/<id>.yml`; `<id>.jsonl` when the first message is sent; the attachments' files moved
  into `.hephaestus/sessions/<session id in lowercase>/` ([data/sessions.md](../data/sessions.md#attachments)). When the
  request fails, nothing is created and the uploads stay as they were ([Using uploads](#using-uploads)).
- Events: `session.changed`; with a first message, `session.event` (`user`) and the status changes.

### sessions.history

One page of a session's transcript ([data/sessions.md](../data/sessions.md#reading-events)).

`SessionsHistoryParams`:

| Field       | Type     | Meaning                                                       |
|-------------|----------|---------------------------------------------------------------|
| `projectID` | `String` | Project                                                       |
| `sessionID` | `UUID`   | Session                                                       |
| `before`    | `Int?`   | Only events whose index is below it; `nil`: the latest events |
| `limit`     | `Int?`   | Maximum number of events; default 1000; clamped to 1…5000     |

`SessionsHistoryResult`:

| Field        | Type             | Meaning                                                                                                                      |
|--------------|------------------|------------------------------------------------------------------------------------------------------------------------------|
| `events`     | `[SessionEvent]` | The events of the page, in log order                                                                                         |
| `firstIndex` | `Int`            | Index of the first line of the page: the index of `events[0]`, unless that line did not decode; `end` when the page is empty |
| `total`      | `Int`            | Number of events in the log (its non-empty lines)                                                                            |

- The index of an event is the 0-based position of its line among the non-empty lines of `<id>.jsonl`; `total` is the
  number of those lines. A line that does not decode keeps its index and is left out of `events`.
- The page: `end` is `before` clamped to `0…total` (`total` when `before` is `nil`); the page holds the lines whose
  index is in `max(0, end − limit)..<end`. When those lines add up to more than 16 MiB (16,777,216 bytes, each line
  counted with its LF), its first lines are dropped until the rest fits or one line remains, so the result fits in a
  frame.
- A client shows the latest page (`before` `nil`) and, while `firstIndex > 0`, loads the previous page, requested with
  `before: firstIndex`, when the user scrolls near the top of the transcript
  ([ui/sessions.md](../ui/sessions.md#transcript)).
- Errors: `notFound` (session).

### sessions.readAttachment

Reads a range of a file attached to a message of the session, as `attachments.read` reads a task attachment.

`SessionsReadAttachmentParams`:

| Field       | Type     | Meaning                                                       |
|-------------|----------|---------------------------------------------------------------|
| `projectID` | `String` | Project                                                       |
| `sessionID` | `UUID`   | Session                                                       |
| `fileName`  | `String` | A `TaskAttachment.file` of one of the session's `user` events |
| `offset`    | `Int?`   | First byte to read; default 0                                 |
| `length`    | `Int?`   | Number of bytes to read; default and maximum `maxChunkSize`   |

- Result: `AttachmentsReadResult` ([attachments.read](#attachmentsread)) with `mimeType` the type of the file name's
  extension (`AttachmentNaming.mimeType(forFileName:)`, [data/task-yml.md](../data/task-yml.md#naming)).
- A `length` above `maxChunkSize` reads `maxChunkSize` bytes.
- Errors: `badRequest` (`fileName` is not a single path component; `offset` below 0 or above the size; `length` below
  1); `notFound` (no such file in the session's attachment folder `.hephaestus/sessions/<session id in lowercase>/`,
  [data/sessions.md](../data/sessions.md#attachments)).
- Served while the project is migrating.

### sessions.send

`SessionsSendParams`:

| Field         | Type          | Meaning                                                                              |
|---------------|---------------|--------------------------------------------------------------------------------------|
| `projectID`   | `String`      | Project                                                                              |
| `sessionID`   | `UUID`        | Session                                                                              |
| `text`        | `String`      | Message text; may be empty when `attachments` is not                                 |
| `attachments` | `[UploadRef]` | Files attached to the message: complete uploads of the project ([Uploads](#uploads)) |

- Result: `EmptyPayload`, once the message is stored and handed to the session.
- Effects: moves the uploads' files into the session's attachment folder
  `.hephaestus/sessions/<session id in lowercase>/` (sanitized `fileName`, ` 2`, ` 3`… on collision,
  [data/sessions.md](../data/sessions.md#attachments)); appends a `user` event (`text` as sent, `attachments` as
  `TaskAttachment` values, the caller's `deviceID`); starts the process when none is alive; sends the message to the
  CLI with the absolute paths of the attached files ([claude/cli.md](../claude/cli.md)). A message sent during a turn
  is queued by the CLI. When the request fails, the uploads stay as they were ([Using uploads](#using-uploads)).
- Errors: `notFound` (session; an unknown upload); `badRequest` (empty text and no attachment; an upload named twice,
  of another project, or incomplete); `conflict` (an upload in use by another request); `unavailable` (no process is
  alive and the Claude CLI or the Hephaestus tools are not available).
- Events: `session.event` (`user`), `session.changed` as the status changes, then the events of the turn.

### sessions.interrupt

`SessionsInterruptParams`: `projectID` (`String`), `sessionID` (`UUID`).

- Result: `EmptyPayload`. Effects: interrupts the turn in progress and records it; nothing when no turn is in progress
  ([claude/cli.md](../claude/cli.md)).
- Errors: `notFound` (session).
- Events: `session.event` (`system`), then the end of the turn (`result`, `session.changed`).

### sessions.stop

`SessionsStopParams`: `projectID` (`String`), `sessionID` (`UUID`).

- Result: `EmptyPayload`. Effects: stops the process (SIGTERM to its process group, SIGKILL after 5 s); status
  `stopped`. Nothing when no process is alive ([claude/cli.md](../claude/cli.md)).
- Errors: `notFound` (session).
- Events: `session.event` (`system`, when a turn was in progress), `session.changed`.

### sessions.respond

Answers a permission request. The first answer wins.

`SessionsRespondParams`:

| Field       | Type                 | Meaning                                                                                          |
|-------------|----------------------|--------------------------------------------------------------------------------------------------|
| `projectID` | `String`             | Project                                                                                          |
| `sessionID` | `UUID`               | Session                                                                                          |
| `requestID` | `String`             | `PermissionRequest.requestID`                                                                    |
| `decision`  | `PermissionDecision` | Answer: `allow`, `allowAlways` or `deny`                                                         |
| `message`   | `String?`            | Deny reason; default `Denied from <caller's device name>`; ignored for `allow` and `allowAlways` |

- Result: `EmptyPayload`.
- Errors: `notFound` (session; or "No permission request <id>." when the session's current process, or its last one
  when it has ended, never sent that request id); `conflict` "This request is not pending." (the request was already
  answered, by a device or by Allow All Tools, or cancelled); `badRequest` "Use sessions.update to allow all tools."
  (decision `allowAll`).
- Effects: answers the CLI ([claude/cli.md](../claude/cli.md)); appends a `permissionDecision` event with the caller's
  `deviceID`; removes the request from the session's `pendingPermissions`.
- Events: `permission.resolved`, `session.event` (`permissionDecision`), `session.changed` (`pendingPermissions`, and
  the status back to `running` when no other request of the session is pending), `projects.changed`
  (`pendingPermissionCount`).

### sessions.update

`SessionsUpdateParams`: `projectID` (`String`), `sessionID` (`UUID`), `patch` (`SessionPatch`).

- Result: `SessionInfo` after the change.
- Effects: saves the session file. A new title shows at once and reaches the Claude CLI at its next process start
  (`--name`); Claude renames its own session through this method (`rename_session`,
  [claude/mcp.md](../claude/mcp.md#629-rename_session)). A new `permissionMode` or `model` applies at the next process
  start; an idle process is restarted at once ([claude/cli.md](../claude/cli.md)). Every session kind accepts every
  field, Forge
  sessions included. `allowsAllTools` applies at once, without a restart; when it becomes true, every pending
  permission request of the session is answered with `allow` and recorded as `allowAll` with the Main's own device id
  ([claude/cli.md](../claude/cli.md#44-allow-all-tools)).
- Errors: `notFound` (session); `badRequest` (a title that is empty or holds a line break).
- Events: `session.changed`; for each request answered by `allowsAllTools`, `permission.resolved` and `session.event`
  (`permissionDecision`), and `projects.changed` (`pendingPermissionCount`).

### sessions.delete

`SessionsDeleteParams`: `projectID` (`String`), `sessionID` (`UUID`).

- Result: `EmptyPayload`.
- Effects: stops the process; deletes `.hephaestus/sessions/<id>.yml`, `<id>.jsonl` and the `<id>/` folder. The Claude
  CLI's own transcript is kept.
- Errors: `notFound` (session).
- Events: `session.removed`.

## Runs

Run execution and output buffering: [services/runs.md](../services/runs.md).

### runs.start

`RunsStartParams`: `projectID` (`String`), `name` (`String`, a run configuration name).

- Result: `RunInfo` of the new run, state `running`.
- Errors: `notFound` (no run configuration with that name, or its working folder does not exist); `badRequest` (its
  `cwd` breaks the path rules); `conflict` (a run of that configuration is running); `internal` "Could not start
  <name>: <error>" (the process could not be started; no run is recorded, [services/runs.md](../services/runs.md)).
- Events: `run.changed`; `run.output` to subscribers; `run.changed` when it ends.

### runs.stop

`RunsStopParams`: `projectID` (`String`), `runID` (`UUID`).

- Result: `EmptyPayload`, without waiting for the end. Effects: stops the process (SIGTERM to its process group,
  SIGKILL after 5 s); state `stopped`. Nothing when the run has ended.
- Errors: `notFound` (not among the runs kept in memory).
- Events: `run.changed`.

### runs.output

`RunsOutputParams`: `projectID` (`String`), `runID` (`UUID`).

`RunsOutputResult`:

| Field  | Type     | Meaning                                                                        |
|--------|----------|--------------------------------------------------------------------------------|
| `text` | `String` | The output kept for the run (its last 5,000 lines)                             |
| `seq`  | `Int`    | `seq` of the last `run.output` batch included in `text`; `0` before any output |

- Errors: `notFound` (not among the runs kept in memory).
- A client subscribes to `run:<runID>` before calling it, then ignores the `run.output` events whose `seq` is at most
  `seq` ([events.md](events.md#runoutput)).

## Search

### search.query

`SearchQueryParams`:

| Field       | Type             | Meaning                                                                            |
|-------------|------------------|------------------------------------------------------------------------------------|
| `query`     | `String`         | Query text                                                                         |
| `scopes`    | `[SearchScope]?` | Scopes to search; `nil`: all                                                       |
| `projectID` | `String?`        | Search only this project and its sub projects                                      |
| `limit`     | `Int?`           | Maximum results; default and maximum `maxSearchResults`; values below 1 count as 1 |

- Result `SearchQueryResult`: `results` (`[SearchResult]`), best first. A query with no word returns no result.
- Errors: `notFound` (`projectID` is not hosted by this Main).
- The client sends the query to every online Main and merges the results; matching, ranking, which Main answers the
  `devices` and `skills` scopes and how duplicates are merged: [services/search.md](../services/search.md).
- The search must answer within the request timeout.

## Skills

The skills library of each Main, its files and its synchronization: [claude/skills.md](../claude/skills.md). Skill
names are 1–64 characters among lowercase letters, digits and hyphens; another name is refused with `badRequest`.
Every method that changes the library updates `Skills/.index.json` and emits `skills.changed`.

### skills.list

- Params: `EmptyPayload`.
- Result `SkillsListResult`: `skills` (`[SkillSummary]`), the skills of this Main's library ordered by name
  (tombstones excluded).

### skills.create

`SkillsCreateParams`: `name` (`String`), `description` (`String`).

- Result: `SkillSummary` of the new skill.
- Errors: `badRequest` (invalid name or description); `conflict` (a skill with that name exists).
- Writes: `Skills/<name>/SKILL.md` from the template of [claude/skills.md](../claude/skills.md).

### skills.files

`SkillsFilesParams`: `name` (`String`).

- Result `SkillsFilesResult`: `files` (`[SkillFile]`), every file of the skill folder, sub folders included, ordered
  by path.
- Errors: `notFound` (skill).

### skills.readFile

`SkillsReadFileParams`: `name` (`String`), `path` (`String`).

- Result `SkillsReadFileResult`: `data` (`Data`), the file content.
- Errors: `notFound` (skill or file); `tooLarge` (file over `maxFileSize`).

### skills.writeFile

`SkillsWriteFileParams`: `name` (`String`), `path` (`String`), `data` (`Data`).

- Result: `EmptyPayload`.
- Effects: creates or replaces the file, atomically, creating missing folders.
- Errors: `notFound` (skill); `tooLarge` (`data` over `maxFileSize`).

### skills.deleteFile

`SkillsDeleteFileParams`: `name` (`String`), `path` (`String`).

- Result: `EmptyPayload`. Effects: moves the file to the Main's Trash.
- Errors: `notFound` (skill or file); `badRequest` (`path` is `SKILL.md`: the skill is deleted with `skills.delete`).

### skills.rename

`SkillsRenameParams`: `name` (`String`), `newName` (`String`).

- Result: `SkillSummary` under the new name.
- Effects: moves the skill folder to its new name and rewrites `name` in its SKILL.md; the old name gets a tombstone
  ([claude/skills.md](../claude/skills.md)).
- Errors: `notFound` (skill); `conflict` (`newName` exists).

### skills.delete

`SkillsDeleteParams`: `name` (`String`).

- Result: `EmptyPayload`. Effects: moves the skill folder to the Main's Trash; the name gets a tombstone.
- Errors: `notFound` (skill).

### skills.manifest

- Params: `EmptyPayload`.
- Result `SkillsManifestResult`: `skills` (`[SkillManifest]`), every entry of `Skills/.index.json`, tombstones included.
- Callers: `mainPeers`.

## Migration

Sent by the source Main to the destination Main on its peer link while it runs a `projects.migrate`, and by a source
that resolves the moves of its migration journal ([devices/migration.md](../devices/migration.md)). All five have
callers `mainPeers`. The destination aborts a migration by itself, as `migration.abort` does, when the connection that
carries it closes.

### migration.begin

`MigrationBeginParams`:

| Field         | Type              | Meaning                                                           |
|---------------|-------------------|-------------------------------------------------------------------|
| `migrationID` | `UUID`            | Migration id                                                      |
| `project`     | `ProjectSummary`  | The project as the source sees it, sub projects included          |
| `folderName`  | `String`          | Name of the project folder on the source                          |
| `manifest`    | `[ManifestEntry]` | The project's files, folders and symbolic links                   |
| `claudeFiles` | `[ManifestEntry]` | The Claude CLI transcripts of the project and of its sub projects |

- Result `MigrationBeginResult`: `destinationPath` (`String`), the absolute path of the new project root on the
  destination: `<projectsFolder>/<folderName>`, with ` 2`, ` 3`… appended when taken.
- Errors: `conflict` (the identifier of the project or of a sub project is already hosted on the destination);
  `badRequest` (a manifest path breaks the path rules, or appears twice).
- Effects: creates the destination folder and prepares to receive the files.

### migration.chunk

`MigrationChunkParams`:

| Field         | Type     | Meaning                                                                 |
|---------------|----------|-------------------------------------------------------------------------|
| `migrationID` | `UUID`   | Migration                                                               |
| `path`        | `String` | A `path` of `manifest`, or of `claudeFiles` when `transcript` is true   |
| `offset`      | `Int`    | Byte offset of `data` in the file                                       |
| `data`        | `Data`   | Content, `migrationChunkSize` bytes except for the last chunk of a file |
| `transcript`  | `Bool`   | `path` refers to `claudeFiles`                                          |

- Result: `EmptyPayload`.
- The source sends the chunks of each file in order, one request at a time; files of size 0 get no chunk.
- Errors: `notFound` (unknown migration, or a path not in the manifest); `badRequest` (`offset` is not the end of the
  data received so far for that file, or the data goes beyond the entry's `size`).

### migration.commit

`MigrationCommitParams`: `migrationID` (`UUID`).

- Result: `EmptyPayload`, once the project is registered on the destination.
- Effects: checks the size and SHA-256 of every file, creates the folders and symbolic links, restores modes and
  modification dates, installs the transcripts under the destination's own encoded folders, registers the project
  (`projects.json`). It answers within the request timeout: digests are computed while chunks arrive
  ([devices/migration.md](../devices/migration.md)).
- Errors: `notFound` (unknown migration); `badRequest` (a file is missing or its checksum differs); `conflict` (an
  identifier became taken). After a failure the destination deletes what it received.
- Events (destination): `projects.changed`.

### migration.abort

`MigrationAbortParams`: `migrationID` (`UUID`).

- Result: `EmptyPayload`. Effects: deletes the destination folder and the transcripts received. An unknown or finished
  migration changes nothing.

### migration.status

Asks the destination whether it committed a migration. The source sends it when it does not know the outcome of its
`migration.commit`: the answer was lost, or the source restarted
([devices/migration.md](../devices/migration.md#recovery-after-a-restart)).

`MigrationStatusParams`: `migrationID` (`UUID`).

`MigrationStatusResult`: `state` (`MigrationOutcome`, [types.md](types.md#migrationoutcome)): `committed` when the
destination's migration journal has a `received` entry with that id, else `unknown`.

- When a commit of that migration is in progress on the destination, the answer waits for it to end.
- Errors: none besides the common ones.
- Events: none.

## Forge

The Forge pipeline: [forge/pipeline.md](../forge/pipeline.md). A Main is the Forge while its Forge settings enable it;
`host.info` then returns its `ForgeConfig`. The methods that act fail with `unavailable` "This Main is not the Forge."
on another Main, and with `unavailable` and the check's message when a configuration check of
[forge/pipeline.md](../forge/pipeline.md) fails.

### forge.feedback

`ForgeFeedbackParams`:

| Field        | Type              | Meaning                                                                                                                                           |
|--------------|-------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| `screenshot` | `UploadRef?`      | PNG of the window, a complete upload of the Forge's source project ([forge/feedback.md](../forge/feedback.md)); `nil` when there is no screenshot |
| `comment`    | `String`          | The user's comment                                                                                                                                |
| `context`    | `FeedbackContext` | Where it was sent from                                                                                                                            |

`ForgeFeedbackResult`:

| Field       | Type     | Meaning              |
|-------------|----------|----------------------|
| `projectID` | `String` | The source project   |
| `taskID`    | `String` | The feedback task    |
| `sessionID` | `UUID`   | The feedback session |

- Errors: `unavailable` (not the Forge, or a configuration check failed); `locked` (the source project is migrating);
  `badRequest` (the comment is empty after trimming; the screenshot upload is of another project or incomplete; "no
  feedback number is left in <projectID>", [data/task-yml.md](../data/task-yml.md#id-allocation)); `notFound` (an
  unknown screenshot upload); `conflict`
  (the screenshot upload is in use by another request) ([Using uploads](#using-uploads)).
- Effects: creates the feedback task, whose id is `<projectID>-F<n>` (`feedbackCounter` in project.yml), with the
  screenshot attached to a comment, adds a Forge item in state
  `discussing`, starts the task's `feedback` session ([forge/pipeline.md](../forge/pipeline.md)). The sending device
  opens the session at once ([forge/feedback.md](../forge/feedback.md)).
- Events: `project.changed`, `task.changed`, `session.changed`, `forge.changed`.

### forge.status

- Params: `EmptyPayload`. Result: `ForgeState`; on a Main that is not the Forge, a state with `enabled` false.
- Errors: none besides the common ones.

### forge.regenerate

"Regenerate now".

- Params: `EmptyPayload`. Result: `EmptyPayload`, once the checks passed; the work continues in the background (a
  check, then a retry when the current cycle is `failed`, else a `manual` cycle,
  [forge/pipeline.md](../forge/pipeline.md#methods)).
- Errors: `unavailable` (not the Forge, or a configuration check failed); `conflict` (a cycle is active).
- Events: `forge.changed`, then the events of the regeneration session.

### forge.retry

`ForgeRetryParams`: `itemTaskID` (`String`), the `taskID` of a failed Forge item.

- Result: `EmptyPayload`, once the checks passed; the retry runs in the background, after the check of
  `forge.regenerate` ([forge/pipeline.md](../forge/pipeline.md#methods)).
- Errors: `unavailable` (not the Forge, or a configuration check failed); `notFound` (no item for that task);
  `conflict` (the item is not `failed`, or not in the current cycle).
- Events: `forge.changed`.
