# Wire protocol: events

files:
- HephaestusKit/Sources/HephCore/Protocol/Events.swift

---

Events are sent by a Main to the connections it accepted, to tell every device about changes as they happen. Delivery
rules (broadcast and subscribers, ordering, no replay, how clients apply events around fetches):
[envelope.md](envelope.md#delivery-rules). Shared types: [types.md](types.md). Uploads have no events: their progress
is known to the device that sends them ([methods.md](methods.md#uploads)); a request that uses an upload causes the
events of its method.

## Event table

| Event                  | `EventName` case      | Payload                      | Delivery                             | Emitted by                       |
|------------------------|-----------------------|------------------------------|--------------------------------------|----------------------------------|
| `mesh.changed`         | `meshChanged`         | `MeshChangedPayload`         | broadcast                            | every Main                       |
| `projects.changed`     | `projectsChanged`     | `ProjectsChangedPayload`     | broadcast                            | the Main hosting the projects    |
| `project.changed`      | `projectChanged`      | `ProjectChangedPayload`      | broadcast                            | the hosting Main                 |
| `task.changed`         | `taskChanged`         | `TaskChangedPayload`         | broadcast                            | the hosting Main                 |
| `task.removed`         | `taskRemoved`         | `TaskRemovedPayload`         | broadcast                            | the hosting Main                 |
| `bundle.changed`       | `bundleChanged`       | `BundleChangedPayload`       | broadcast                            | the hosting Main                 |
| `bundle.removed`       | `bundleRemoved`       | `BundleRemovedPayload`       | broadcast                            | the hosting Main                 |
| `files.changed`        | `filesChanged`        | `FilesChangedPayload`        | broadcast                            | the hosting Main                 |
| `session.changed`      | `sessionChanged`      | `SessionChangedPayload`      | broadcast                            | the hosting Main                 |
| `session.removed`      | `sessionRemoved`      | `SessionRemovedPayload`      | broadcast                            | the hosting Main                 |
| `session.event`        | `sessionEvent`        | `SessionEventPayload`        | subscribers of `session:<sessionID>` | the hosting Main                 |
| `session.delta`        | `sessionDelta`        | `SessionDeltaPayload`        | subscribers of `session:<sessionID>` | the hosting Main                 |
| `permission.requested` | `permissionRequested` | `PermissionRequestedPayload` | broadcast                            | the hosting Main                 |
| `permission.resolved`  | `permissionResolved`  | `PermissionResolvedPayload`  | broadcast                            | the hosting Main                 |
| `run.changed`          | `runChanged`          | `RunChangedPayload`          | broadcast                            | the hosting Main                 |
| `run.output`           | `runOutput`           | `RunOutputPayload`           | subscribers of `run:<runID>`         | the hosting Main                 |
| `skills.changed`       | `skillsChanged`       | `SkillsChangedPayload`       | broadcast                            | every Main                       |
| `migration.progress`   | `migrationProgress`   | `MigrationProgressPayload`   | broadcast                            | the source Main                  |
| `forge.changed`        | `forgeChanged`        | `ForgeChangedPayload`        | broadcast                            | a Main whose Forge state changed |

"The hosting Main" is the Main that hosts the project the event is about.

## Swift API

```swift
public enum EventName: String, CaseIterable, Sendable {
    case meshChanged = "mesh.changed"
    // … one case per row of the event table, in table order, raw value = event name
    case forgeChanged = "forge.changed"

    public var delivery: EventDelivery { get }   // Delivery column
}

public enum EventDelivery: Sendable {
    case broadcast, subscribers
}

public enum ServerEvent: Sendable, Hashable {
    case meshChanged(MeshChangedPayload)
    case projectsChanged(ProjectsChangedPayload)
    case projectChanged(ProjectChangedPayload)
    case taskChanged(TaskChangedPayload)
    case taskRemoved(TaskRemovedPayload)
    case bundleChanged(BundleChangedPayload)
    case bundleRemoved(BundleRemovedPayload)
    case filesChanged(FilesChangedPayload)
    case sessionChanged(SessionChangedPayload)
    case sessionRemoved(SessionRemovedPayload)
    case sessionEvent(SessionEventPayload)
    case sessionDelta(SessionDeltaPayload)
    case permissionRequested(PermissionRequestedPayload)
    case permissionResolved(PermissionResolvedPayload)
    case runChanged(RunChangedPayload)
    case runOutput(RunOutputPayload)
    case skillsChanged(SkillsChangedPayload)
    case migrationProgress(MigrationProgressPayload)
    case forgeChanged(ForgeChangedPayload)

    public var name: EventName { get }
    /// The topic of a subscriber event (`session.event`, `session.delta`: `.session(sessionID)`;
    /// `run.output`: `.run(runID)`); `nil` for broadcast events.
    public var topic: Topic? { get }
    /// The complete event frame (`WireCoding.encodeEvent(name: name.rawValue, params: payload)`).
    public func encodeFrame() throws -> Data
    /// Decodes a received event. Returns `nil` for an event name this build does not know; throws
    /// `ProtocolError(.badRequest, …)` when the payload does not decode.
    public static func decode(_ event: InboundEvent) throws -> ServerEvent?
}
```

- Payload structs are declared in Events.swift like the types of [types.md](types.md#conventions):
  `public struct <Name>: Codable, Sendable, Hashable`, `public var` fields in table order, a public memberwise `init`
  with optional parameters defaulting to `nil`.
- `decode` decodes the payload with `InboundEvent.decodeParams`.
- A Main sends an event by encoding it once (`encodeFrame()`, or `WireCoding.encodeEvent` with the event name and
  payload) and passing the frame to `RPCPeer.emit(frame:)` of every connection that should receive it: all
  authenticated connections for a broadcast event, the connections subscribed to its topic for a subscriber event
  ([services/host.md](../services/host.md)).
- A client reads the `events` stream of each `RPCPeer`, passes every `InboundEvent` to `ServerEvent.decode` and
  switches on the result ([client/workspace.md](../client/workspace.md)). An event that fails to decode is logged and
  ignored.

## Events

### mesh.changed

`MeshChangedPayload`:

| Field      | Type           | Meaning                                 |
|------------|----------------|-----------------------------------------|
| `snapshot` | `MeshSnapshot` | The Main's registry and presence report |

- Emitted when the Main's registry or presence report changes: a device paired, renamed, revoked or updated by
  `hello`, a registry merge by `mesh.sync`, an address change, a connection opened or closed, a relayed report changed
  ([devices/mesh.md](../devices/mesh.md)).
- Client: replaces its copy of that Main's snapshot, merges the presence of all Mains it is connected to (a device is
  online when any report says so, `lastSeen` is the most recent), saves the registry cache, and adopts its own
  record's name when it differs from its local name ([devices/roles.md](../devices/roles.md)).

### projects.changed

`ProjectsChangedPayload`:

| Field      | Type               | Meaning                                                 |
|------------|--------------------|---------------------------------------------------------|
| `deviceID` | `UUID`             | The Main                                                |
| `projects` | `[ProjectSummary]` | Its top-level projects, as `projects.list` returns them |

- Emitted when the Main's project tree changes: a project created, imported, removed, moved away or received; a name
  or description changed; a sub project added or removed; `migrating`, `parseError` or `pendingPermissionCount`
  changed.
- Client: replaces its list of that Main's projects. A selection whose project disappeared is handled by the shell
  ([ui/shell.md](../ui/shell.md)); after a migration, by `migration.progress`.

### project.changed

`ProjectChangedPayload`:

| Field     | Type      | Meaning                      |
|-----------|-----------|------------------------------|
| `project` | `Project` | The project after the change |

- Emitted when the project's `.hephaestus/project.yml` changed, whatever changed it (app, Claude, an editor, git), or
  when `migrating` or `parseError` changed.
- Client: replaces its `Project` mirror when it holds one for that project. Devices showing a web tab whose stored URL
  changed navigate to it ([ui/web.md](../ui/web.md)).

### task.changed

`TaskChangedPayload`:

| Field       | Type       | Meaning                   |
|-------------|------------|---------------------------|
| `projectID` | `String`   | Project                   |
| `task`      | `TaskItem` | The task after the change |

- Emitted when a task file is created or changed, whatever changed it; a file that does not parse gives a broken task.
- Client: inserts or replaces the task in its mirror of that project.

### task.removed

`TaskRemovedPayload`:

| Field       | Type     | Meaning      |
|-------------|----------|--------------|
| `projectID` | `String` | Project      |
| `taskID`    | `String` | Removed task |

- Emitted when a task file is deleted, whatever deleted it.
- Client: removes the task from its mirror; a detail view showing it shows that the task was deleted
  ([ui/tasks.md](../ui/tasks.md)).

### bundle.changed

`BundleChangedPayload`:

| Field       | Type         | Meaning                     |
|-------------|--------------|-----------------------------|
| `projectID` | `String`     | Project                     |
| `bundle`    | `BundleItem` | The bundle after the change |

- Emitted when `BundleService` creates or changes a bundle ([services/bundles.md](../services/bundles.md)).
- Client: inserts or replaces the bundle in its mirror of that project.

### bundle.removed

`BundleRemovedPayload`:

| Field       | Type     | Meaning        |
|-------------|----------|----------------|
| `projectID` | `String` | Project        |
| `bundleID`  | `String` | Removed bundle |

- Emitted when `bundles.delete` deletes a bundle.
- Client: removes the bundle from its mirror.

### files.changed

`FilesChangedPayload`:

| Field       | Type       | Meaning                                                                   |
|-------------|------------|---------------------------------------------------------------------------|
| `projectID` | `String`   | Project                                                                   |
| `paths`     | `[String]` | Project-relative paths of the changed files and folders, each listed once |

- Emitted by the Main's file watcher: the FSEvents of the project folder, whatever their source, coalesced over 300 ms
  into one event per project ([services/host.md](../services/host.md)).
- A folder path means that the folder's content changed. `""` is the project root.
- Not reported: paths with a component `.git`, `.build`, `DerivedData` or `node_modules`, files named `.DS_Store`,
  paths under `.hephaestus/sessions/` (session events report those), and the temporary files of atomic writes
  ([services/files.md](../services/files.md)). No event is sent when no path remains.
- More than 1,000 paths for one project in one batch are sent as `paths: [""]`: the client refreshes everything it
  shows of that project.
- A change inside a sub project is reported for the sub project and for every project that contains it, each event
  with paths relative to its own project root.
- Client: a file tree reloads its loaded folders that contain a listed path or are listed. An open document whose path
  is listed reads the file again and compares revisions: the same revision changes nothing (for example its own save);
  otherwise an unmodified document reloads and a modified one shows "Changed on the Main"
  ([ui/code.md](../ui/code.md)).

### session.changed

`SessionChangedPayload`:

| Field       | Type          | Meaning                      |
|-------------|---------------|------------------------------|
| `projectID` | `String`      | Project                      |
| `session`   | `SessionInfo` | The session after the change |

- Emitted when a session is created and when any field of its `SessionInfo` changes, `pendingPermissions` included (a
  permission request added, answered or cancelled). When only `statusLine` changed, the Main sends at most one event per
  second per session, with the latest value.
- Client: inserts or replaces the session in its mirror. When the status leaves `starting`, `running` and
  `waitingPermission`, a client showing the session clears its streamed fragments (see `session.delta`).

### session.removed

`SessionRemovedPayload`:

| Field       | Type     | Meaning         |
|-------------|----------|-----------------|
| `projectID` | `String` | Project         |
| `sessionID` | `UUID`   | Deleted session |

- Emitted when a session is deleted.
- Client: removes it from its mirror and closes its views.

### session.event

`SessionEventPayload`:

| Field       | Type           | Meaning                              |
|-------------|----------------|--------------------------------------|
| `projectID` | `String`       | Project                              |
| `sessionID` | `UUID`         | Session                              |
| `event`     | `SessionEvent` | The event appended to the transcript |

- Emitted to the subscribers of `session:<sessionID>` each time an event is appended to the session's transcript.
- Client: appends the event to the transcript it shows, unless an event with the same `id` is already there (it may
  have come with `sessions.history`). An `assistant`, `thinking` or `toolUse` event replaces the streamed block with
  the same `messageID` and `index` (see `session.delta`). A `result` or `error` event removes every streamed block of
  the session.

### session.delta

`SessionDeltaPayload`:

| Field       | Type               | Meaning                                                                     |
|-------------|--------------------|-----------------------------------------------------------------------------|
| `projectID` | `String`           | Project                                                                     |
| `sessionID` | `UUID`             | Session                                                                     |
| `messageID` | `String`           | Id of the Claude message being streamed ([claude/cli.md](../claude/cli.md)) |
| `index`     | `Int`              | Index of the content block within the message, from 0                       |
| `kind`      | `SessionDeltaKind` | What the fragment belongs to                                                |
| `text`      | `String`           | The fragment to append                                                      |

- Emitted to the subscribers of `session:<sessionID>` for each streamed fragment of the CLI (`text_delta`,
  `thinking_delta`, `input_json_delta`; [claude/cli.md](../claude/cli.md)). Fragments are not stored.
- Client: appends `text` to the streamed block identified by `messageID` and `index` (a new block starts empty) and
  shows the streamed blocks after the transcript, as the message being written. The final `assistant`, `thinking` or
  `toolUse` event of a block carries the same `messageID` and `index` and replaces it. A turn that ends without
  completing a block (an interrupt) leaves blocks that the `result` event removes. A client that subscribed during a
  block shows that block from the first fragment it received ([ui/sessions.md](../ui/sessions.md)).

### permission.requested

`PermissionRequestedPayload`:

| Field       | Type                | Meaning     |
|-------------|---------------------|-------------|
| `projectID` | `String`            | Project     |
| `sessionID` | `UUID`              | Session     |
| `request`   | `PermissionRequest` | The request |

- Emitted when the CLI asks for a permission. The request is added to the session's `pendingPermissions` and its
  status becomes `waitingPermission` (`session.changed`); the project's `pendingPermissionCount` grows
  (`projects.changed`).
- Client: shows the permission card in that session ([ui/sessions.md](../ui/sessions.md)); the answer is sent with
  `sessions.respond`. A client that connects or loads later finds the pending requests in
  `SessionInfo.pendingPermissions` (`projects.snapshot`, `session.changed`) and their number per project in
  `ProjectSummary.pendingPermissionCount` (`projects.list`, `projects.changed`).

### permission.resolved

`PermissionResolvedPayload`:

| Field       | Type                 | Meaning                          |
|-------------|----------------------|----------------------------------|
| `projectID` | `String`             | Project                          |
| `sessionID` | `UUID`               | Session                          |
| `requestID` | `String`             | The answered request             |
| `decision`  | `PermissionDecision` | The answer                       |
| `deviceID`  | `UUID`               | The device whose answer was used |

- Emitted when the first answer to a request is accepted, and when a pending request is cancelled (by the CLI, by the
  end of the turn or of the process): a cancellation has `decision` `deny` and the Main's own id as `deviceID`
  ([claude/cli.md](../claude/cli.md)). The request leaves the session's `pendingPermissions` (`session.changed`) and
  the project's `pendingPermissionCount` (`projects.changed`).
- Client: removes the permission card and shows the decision with the device's name.

### run.changed

`RunChangedPayload`:

| Field       | Type      | Meaning                  |
|-------------|-----------|--------------------------|
| `projectID` | `String`  | Project                  |
| `run`       | `RunInfo` | The run after the change |

- Emitted when a run starts and when it ends.
- Client: inserts or replaces the run in its mirror, then trims the mirror as
  [client/workspace.md](../client/workspace.md#projectstore) says: while more than 20 runs are kept, the oldest run
  that is not `running` is dropped ([ui/runs.md](../ui/runs.md)).

### run.output

`RunOutputPayload`:

| Field       | Type     | Meaning                                                  |
|-------------|----------|----------------------------------------------------------|
| `projectID` | `String` | Project                                                  |
| `runID`     | `UUID`   | Run                                                      |
| `text`      | `String` | Output text (standard output and error merged) to append |
| `seq`       | `Int`    | Number of this batch within the run: 1, 2, 3…            |

- Emitted to the subscribers of `run:<runID>` as the run writes output, in batches
  ([services/runs.md](../services/runs.md)). `seq` lets a client drop the output that a `runs.output` result already
  contains.
- Client: subscribes to `run:<runID>`, then calls `runs.output`; it keeps the events received meanwhile, replaces its
  console text with the result's `text`, and appends the events whose `seq` is greater than the result's `seq`,
  ignoring the others. Afterwards it appends each event whose `seq` is greater than the last one applied
  ([ui/runs.md](../ui/runs.md)).

### skills.changed

`SkillsChangedPayload`:

| Field    | Type             | Meaning                                                                |
|----------|------------------|------------------------------------------------------------------------|
| `skills` | `[SkillSummary]` | The Main's whole library after the change, as `skills.list` returns it |

- Emitted when the Main's skills library changes: a `skills.*` method, the MCP tool `save_skill`, or a sync pull
  ([claude/skills.md](../claude/skills.md)).
- Client: replaces its list of that Main's skills. A peer Main receiving it compares manifests and pulls newer skills
  ([claude/skills.md](../claude/skills.md)).

### migration.progress

`MigrationProgressPayload`:

| Field          | Type             | Meaning                                   |
|----------------|------------------|-------------------------------------------|
| `migrationID`  | `UUID`           | Migration                                 |
| `projectID`    | `String`         | Moved project                             |
| `fromDeviceID` | `UUID`           | Source Main                               |
| `toDeviceID`   | `UUID`           | Destination Main                          |
| `state`        | `MigrationState` | State                                     |
| `bytesDone`    | `Int`            | Bytes transferred so far                  |
| `bytesTotal`   | `Int`            | Bytes to transfer (files and transcripts) |
| `error`        | `String?`        | When `state` is `failed`: what failed     |

- Emitted by the source Main on each state change and, while `transferring`, at most every 500 ms
  ([devices/migration.md](../devices/migration.md)). A source that restarted during a commit emits `completed` or
  `failed`, with `bytesDone` and `bytesTotal` 0, when the outcome check of its migration journal resolves the move
  ([devices/migration.md](../devices/migration.md#outcome-checks)).
- Client: shows the progress sheet; on `completed`, every window whose selection is the project (or one of its sub
  projects) selects it on the destination Main; on `failed`, shows the error ([ui/overview.md](../ui/overview.md)).

### forge.changed

`ForgeChangedPayload`:

| Field   | Type         | Meaning                          |
|---------|--------------|----------------------------------|
| `state` | `ForgeState` | The Forge state after the change |

- Emitted by the Forge host after every change of its `ForgeState`, and by a Main whose Forge is enabled or disabled
  (once, with `enabled` false, when disabled) ([forge/pipeline.md](../forge/pipeline.md)).
- Client: keeps the state of each Main; the Forge host is the Main whose state has `enabled` true. The Forge screen
  shows it ([ui/forge.md](../ui/forge.md)). When the cycle reaches `released` or `latestRelease` changes, a Mac checks
  for an update at once ([forge/update.md](../forge/update.md)).
