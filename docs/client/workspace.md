# Client workspace (HephClient)

files:
- HephaestusKit/Sources/HephClient/Workspace.swift
- HephaestusKit/Sources/HephClient/WorkspaceEnvironment.swift
- HephaestusKit/Sources/HephClient/MainConnection.swift
- HephaestusKit/Sources/HephClient/MainConnection+Requests.swift
- HephaestusKit/Sources/HephClient/MainConnection+Transfers.swift
- HephaestusKit/Sources/HephClient/AttachmentCache.swift
- HephaestusKit/Sources/HephClient/ProjectStore.swift
- HephaestusKit/Sources/HephClient/Selection.swift
- HephaestusKit/Sources/HephClient/PresenceModel.swift
- HephaestusKit/Sources/HephClient/TopicSubscription.swift
- HephaestusKit/Sources/HephClient/PreviewData.swift

---

`HephClient` mirrors on every device the state of every Main of the mesh, and it is the only way the UI talks to the
Mains. One `Workspace` exists per process ([ui/shell.md](../ui/shell.md)). Every window observes it and has its own
`Selection`. On a Main, the Workspace reaches the local host service through a loopback connection, exactly as it
reaches the other Mains over the network ([architecture.md](../architecture.md#process-model)).

The Workspace creates and feeds three models specified by other docs: `SessionCenter`
([ui/sessions.md](../ui/sessions.md#sessioncenter)), `RunOutputCenter` ([ui/runs.md](../ui/runs.md#runoutputcenter))
and `ForgeModel` ([ui/forge.md](../ui/forge.md#forgemodel)). Other client models use its API: `SessionModel`
([ui/sessions.md](../ui/sessions.md)), `RunOutputModel` ([ui/runs.md](../ui/runs.md)), `FileTreeModel` and
`EditorDocument` ([ui/code.md](../ui/code.md)), `SearchModel` ([services/search.md](../services/search.md)). All the
code of this doc logs with `Log.client` ([architecture.md](../architecture.md#logging)).

## Types

| Type                   | Kind                                 | File                             | Role                                                                         |
|------------------------|--------------------------------------|----------------------------------|------------------------------------------------------------------------------|
| `Workspace`            | `@MainActor @Observable final class` | `Workspace.swift`                | Identity, merged registry and presence, connections, stores, mirrors, events |
| `WorkspaceEvent`       | `enum`                               | `Workspace.swift`                | What `Workspace.events()` delivers                                           |
| `WorkspaceEnvironment` | `struct` of closures                 | `WorkspaceEnvironment.swift`     | What the Workspace needs from outside: storage, transport, Bonjour, time     |
| `LocalHostLink`        | `protocol`                           | `WorkspaceEnvironment.swift`     | In-process link to this Mac's `HostService`                                  |
| `MainConnection`       | `@MainActor @Observable final class` | `MainConnection.swift`           | One per Main: connection state, handshake, projects and skills lists         |
| `ConnectionState`      | `enum`                               | `MainConnection.swift`           | State of a `MainConnection`                                                  |
| request API            | `extension MainConnection`           | `MainConnection+Requests.swift`  | One async function per protocol method the UI calls                          |
| transfers              | `extension MainConnection`           | `MainConnection+Transfers.swift` | Uploads and downloads in chunks, with progress ([Transfers](#transfers))     |
| `UploadSource`         | `enum`                               | `MainConnection+Transfers.swift` | What an upload reads: bytes in memory or a local file                        |
| `TransferProgress`     | `struct`                             | `MainConnection+Transfers.swift` | Bytes done and total of an upload or a download                              |
| `AttachmentCache`      | `struct`                             | `AttachmentCache.swift`          | The device's cache of downloaded files: folder and paths                     |
| `ProjectStore`         | `@MainActor @Observable final class` | `ProjectStore.swift`             | One per opened project: project, tasks, sessions, runs                       |
| `Selection`            | `@MainActor @Observable final class` | `Selection.swift`                | What one window shows: Main, project, section, item                          |
| `SidebarSection`       | `enum`                               | `Selection.swift`                | The sidebar sections                                                         |
| `PresenceModel`        | `enum` of static functions           | `PresenceModel.swift`            | Registry merge and presence merge (pure functions)                           |
| `TopicSubscription`    | `@MainActor final class`             | `TopicSubscription.swift`        | A held subscription to a topic                                               |
| `PreviewData`          | `enum`                               | `PreviewData.swift`              | Sample data and the answers of `Workspace.preview()`                         |

Types used from other docs: the wire types of [protocol/types.md](../protocol/types.md), the params and results of
[protocol/methods.md](../protocol/methods.md), `ServerEvent` and the event payloads of
[protocol/events.md](../protocol/events.md), `ProtocolError`, `Topic`, `WireCoding`, `MessageChannel`, `RPCPeer`,
`InboundRequest`, `InboundEvent` and `EmptyPayload` ([protocol/envelope.md](../protocol/envelope.md)), `AppSupport`,
`MeshCredentials`, `RegistryCache`, `MeshCredentialStore`, `KeychainCredentialStore` and `InMemoryCredentialStore`
([data/app-storage.md](../data/app-storage.md)), `MeshCrypto`, `WebSocketChannel`, `BonjourBrowser` and
`BonjourAdvert` ([devices/mesh.md](../devices/mesh.md)), `DeviceIdentityStore`
([devices/roles.md](../devices/roles.md)). Where a name in this doc differs from those docs, those docs win.

## Dependencies

### WorkspaceEnvironment

```swift
public struct WorkspaceEnvironment: Sendable {
    public var loadCredentials: @Sendable () -> MeshCredentials?
    public var saveCredentials: @Sendable (MeshCredentials) throws -> Void
    public var loadRegistry: @Sendable () -> MeshSnapshot?
    public var saveRegistry: @Sendable (MeshSnapshot) -> Void
    public var saveDevice: @MainActor @Sendable (DeviceInfo) -> Void
    public var openChannel: @Sendable (_ url: URL, _ credentials: MeshCredentials) async throws -> any MessageChannel
    public var browse: @Sendable (_ onChange: @escaping @Sendable ([BonjourAdvert]) -> Void) -> @Sendable () -> Void
    public var sleep: @Sendable (_ duration: Duration) async throws -> Void
    public var now: @Sendable () -> Date
    public var attachmentCache: AttachmentCache

    public init(...)   // memberwise: one labeled parameter per property above, in the same order
    public static func live(appSupport: AppSupport, credentialStore: any MeshCredentialStore,
                            identityStore: DeviceIdentityStore) -> WorkspaceEnvironment
    public static var preview: WorkspaceEnvironment { get }
}
```

| Closure           | `live(appSupport:credentialStore:identityStore:)`                                                                                              | `preview`                                                                     |
|-------------------|------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------|
| `loadCredentials` | `credentialStore.load()`; nil when it throws (logged)                                                                                          | `PreviewData.credentials`                                                     |
| `saveCredentials` | `credentialStore.save(_:)`                                                                                                                     | does nothing                                                                  |
| `loadRegistry`    | `RegistryCache.load(appSupport)`                                                                                                               | nil                                                                           |
| `saveRegistry`    | `RegistryCache.save(_:appSupport)`; a failure is logged                                                                                        | does nothing                                                                  |
| `saveDevice`      | `identityStore.save(_:)` ([devices/roles.md](../devices/roles.md))                                                                             | does nothing                                                                  |
| `openChannel`     | `WebSocketChannel.connect(url:credentials:timeout: .seconds(5))` ([devices/mesh.md](../devices/mesh.md#websocketchannel))                      | throws `ProtocolError(.unavailable, "Not available in previews")`             |
| `browse`          | A new `BonjourBrowser`: `start(onChange:)`, and `stop()` when the returned function is called ([devices/mesh.md](../devices/mesh.md#browsing)) | returns a function that does nothing                                          |
| `sleep`           | `Task.sleep(for:)`                                                                                                                             | `Task.sleep(for:)`                                                            |
| `now`             | `Date()`                                                                                                                                       | `Date()`                                                                      |
| `attachmentCache` | `AttachmentCache.standard()` ([Transfers](#transfers))                                                                                         | `AttachmentCache(root: <temporary directory>/Hephaestus-Preview/Attachments)` |

The app passes `KeychainCredentialStore.shared`; tests pass an `InMemoryCredentialStore` or build their own
environment: in-memory credentials and registry, channels from `LoopbackChannel` pairs, a `sleep` that records the
durations and returns at once, a fixed `now`, an attachment cache in a temporary folder ([testing.md](../testing.md)).

### LocalHostLink

```swift
public protocol LocalHostLink: Sendable {
    /// Returns the client end of a new in-process channel whose other end the local HostService serves.
    func makeChannel() async throws -> any MessageChannel
}
```

The app wiring implements it on macOS (`HostServiceLink`, [ui/shell.md](../ui/shell.md#33-main-toggle)) with
`HostService.makeLoopbackChannel()` ([services/host.md](../services/host.md)).

### App wiring

`AppModel` ([ui/shell.md](../ui/shell.md)) creates the `Workspace` once with `init(device:environment:)`, passing the
device identity ([devices/roles.md](../devices/roles.md)) and
`WorkspaceEnvironment.live(appSupport:credentialStore:identityStore:)`, and reads `errorReports()` for the life of the
app. Afterwards:

| Moment                                                 | Call                    |
|--------------------------------------------------------|-------------------------|
| Launch, after the host started when this Mac is a Main | `start()`               |
| The app becomes active (scene phase `active`)          | `retryNow()`            |
| This Mac's host started, or stopped                    | `setLocalHostLink(_:)`  |
| The device identity changed (name, Main role, version) | `updateLocalDevice(_:)` |
| Pairing completed (credentials and registry saved)     | `restart()`             |
| The device left the mesh                               | `reset()`               |
| The app quits                                          | `stop()`                |
| A window is created                                    | `makeSelection()`       |

## Workspace

### State

| Property           | Type                               | Meaning                                                                                                                 |
|--------------------|------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| `device`           | `DeviceInfo`                       | This device                                                                                                             |
| `hasMesh`          | `Bool`                             | Mesh credentials are loaded                                                                                             |
| `mesh`             | `MeshSnapshot?`                    | Merged registry and merged presence; nil without a mesh                                                                 |
| `presence`         | `[UUID: Presence]`                 | Merged presence by device id                                                                                            |
| `connections`      | `[UUID: MainConnection]`           | One per Main, by the Main's device id, the local one included                                                           |
| `seenHosts`        | `[UUID: BonjourAdvert]`            | Mains currently seen by Bonjour, by device id; the join screen lists those with `pairingOpen`                           |
| `migrations`       | `[UUID: MigrationProgressPayload]` | Latest `migration.progress` per migration id, from every connected Main, kept while the app runs                        |
| `topologyRevision` | `Int`                              | Incremented when the registry, the set of connections, a connection state, a projects list or a migration state changes |
| `sessionCenter`    | `SessionCenter`                    | Created by `init`, fed by the Workspace's calls ([ui/sessions.md](../ui/sessions.md#sessioncenter))                     |
| `runOutputCenter`  | `RunOutputCenter`                  | Created by `init`, fed by the Workspace's calls ([ui/runs.md](../ui/runs.md#runoutputcenter))                           |
| `forge`            | `ForgeModel`                       | Created by `init`, fed by the Workspace's calls ([ui/forge.md](../ui/forge.md#forgemodel))                              |
| `isPreview`        | `Bool`                             | True for `Workspace.preview()`                                                                                          |

| Computed            | Type              | Value                                                                                                  |
|---------------------|-------------------|--------------------------------------------------------------------------------------------------------|
| `mains`             | `[DeviceRecord]`  | Registry records with `isMain` and not `revoked`, sorted by name (`localizedStandardCompare`), then id |
| `localConnection`   | `MainConnection?` | The loopback connection to this Mac's host service                                                     |
| `onlineDeviceCount` | `Int`             | Number of `presence` entries that are online, this device included                                     |

Outside `HephClient` every property is read-only. `sessionCenter`, `runOutputCenter` and `forge` are implicitly
unwrapped and `@ObservationIgnored`: their initializers take the Workspace, so `init` sets them after every other
stored property ([Swift API summary](#swift-api-summary)).

### Lifecycle

| Function                                         | Behavior                                                                                                                                                                                                                                                                                                                                                                              |
|--------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `init(device:environment:)`                      | Stores its arguments, then creates `sessionCenter`, `runOutputCenter` and `forge`. No I/O, no connection.                                                                                                                                                                                                                                                                             |
| `start()`                                        | Does nothing when started. Loads the credentials; when present, loads the cached registry and keeps it when its `meshID` equals the credentials' `meshID` (compared as UUIDs); its presence `lastSeen` values seed the last-seen table. Starts browsing. Creates the connections (the loopback one too while a local host link is set) and starts connecting them.                    |
| `stop()`                                         | Stops browsing, closes every connection (state `disconnected`), cancels the Workspace's tasks, writes a pending registry save. Keeps the data.                                                                                                                                                                                                                                        |
| `restart()`                                      | `stop()`, then forgets the mirrored state (as `reset()`), then `start()`: credentials and registry are read again.                                                                                                                                                                                                                                                                    |
| `reset()`                                        | Closes every connection and forgets the mirrored state: credentials (`hasMesh` false), registry, presence, last-seen table, reports, migrations, connections (the loopback one included) and stores (each store gets `isRemoved = true`). The local host link stays set: the `start()` of a later `restart()` creates the loopback connection again. Browsing continues when started. |
| `retryNow()`                                     | Every connection in state `failed` starts an attempt now, whatever its `retryAt`.                                                                                                                                                                                                                                                                                                     |
| `setLocalHostLink(_ link: (any LocalHostLink)?)` | With a link: loads the credentials again (a Mac that just became a Main may have created the mesh), creates or replaces the connection for `device.id` as a loopback connection using `link`, and connects it when started. With nil: closes and removes that connection and its stores.                                                                                              |
| `updateLocalDevice(_ device: DeviceInfo)`        | Replaces `device`; the next handshakes send it. No reconnection.                                                                                                                                                                                                                                                                                                                      |
| `makeSelection() -> Selection`                   | Returns a new empty `Selection` and keeps a weak reference to it ([Selection](#selection)).                                                                                                                                                                                                                                                                                           |
| `errorReports() -> AsyncStream<String>`          | A new stream of the messages of failures of work the Workspace starts by itself ([Error reports](#error-reports)).                                                                                                                                                                                                                                                                    |

### Registry merge

`PresenceModel.mergeRegistry(_ current: [DeviceRecord], with incoming: [DeviceRecord]) -> [DeviceRecord]`: for every
device id present in either list, the record with the later `updatedAt` wins; on equal `updatedAt` the current record
stays. The result is sorted by name (`localizedStandardCompare`), then id.

The Workspace merges the `mesh.devices` of every `hello` result, the `snapshot.devices` of every `mesh.changed`, the
result of `meshSnapshot()`, and the `DeviceRecord` returned by `renameDevice` and `setAddresses`. A snapshot whose
`meshID` differs from the credentials' `meshID` is ignored and logged.

After a merge that changed the registry:

1. **Own name.** When the merged record of `device.id` has a name different from `device.name`, `device.name` takes
   the record's name and `environment.saveDevice(device)` is called: the registry name wins
   ([devices/roles.md](../devices/roles.md)).
2. **Connections** are reconciled ([Connections](#connections)) and **selections** checked
   ([Selection](#selection), rule 1).
3. **Presence** is recomputed ([Presence merge](#presence-merge)).
4. **Persistence**: the registry save is scheduled ([Registry persistence](#registry-persistence)).
5. `topologyRevision` is incremented.

### Presence merge

`PresenceModel.mergePresence(devices: [DeviceRecord], reports: [[Presence]], lastSeen: [UUID: Date], localDeviceID: UUID, now: Date) -> [UUID: Presence]`
implements the merge of [devices/mesh.md](../devices/mesh.md):

- Revoked devices are left out.
- This device: `online` true, `lastSeen` = `now`, `via` = `[]`.
- Every other device: take every entry for its id in every report. `online` is true when any entry is online.
  `lastSeen` is the most recent of the entries' `lastSeen` and `lastSeen[id]`; with neither, the record's `pairedAt`.
  `via` is the union of the entries' `via`, sorted by `uuidString`.
- With no report (no Main connected), every other device is offline with its cached `lastSeen`.

The Workspace keeps one report per connected Main: the `presence` of the latest snapshot received on that connection
(`hello` result, `mesh.changed`, `meshSnapshot()`). It keeps a last-seen table: each stored report raises
`lastSeen[id]` to the entry's `lastSeen`; when a connection leaves `connected`, every device its report showed online
gets `lastSeen[id] = now`, then the report is dropped. `presence` and `mesh.presence` (sorted by device id) are
recomputed after each of these changes.

### Registry persistence

Without a local host link, the Workspace saves `mesh` with `environment.saveRegistry` 1 s after the last change of its
devices or presence, and at `stop()` when a save is pending. With a local host link (this Mac is a Main), the
Workspace never saves the registry: the `HostService` owns `registry.json` ([devices/mesh.md](../devices/mesh.md)).

The 1 s delay is a `Task.sleep(for:)`, not `environment.sleep`: the backoff is the only user of `environment.sleep`, so
the sleeps a test records are backoff delays only ([testing.md](../testing.md)). `environment.saveRegistry` runs off
the main actor, one save at a time, in the order the saves start.

### Connections

- The network Mains are the `mains` other than this device. Each gets one `MainConnection` while credentials are
  loaded. The local connection exists only while a `LocalHostLink` is set.
- After a registry change: a Main without a connection gets one, which starts connecting when the Workspace is
  started; a network connection whose device is no longer in `mains` is closed and removed, with its report and its
  stores (`isRemoved = true`).
- `connection(_ mainDeviceID: UUID) -> MainConnection?` returns the connection of a Main.

### Bonjour-seen hosts

Each list from `browse` replaces `seenHosts`. The lists go through an `AsyncStream` consumed by one main-actor task, so
they apply in order. When a list adds or changes the advert of a Main whose connection is `failed` with a `retryAt`
that is not nil, that connection starts an attempt now; so does a change of the Main's record `addresses` or `port`.

### Error reports

`errorReports()` returns a new stream with an unbounded buffer; it ends when the task iterating it is cancelled. The
Workspace yields one message per failure of the work it starts by itself; `AppModel` shows each in the active window's
error banner ([ui/shell.md](../ui/shell.md)).

| Failure                                      | Message                                               |
|----------------------------------------------|-------------------------------------------------------|
| `projects.list` after a handshake            | `Could not load the projects of <Main name>: <error>` |
| `projects.snapshot` of a store that had data | `Could not refresh <projectID>: <error>`              |
| Storing the key of `mesh.rekey`              | `Could not store the mesh key: <error>`               |

`<error>` is the `ProtocolError` message, the `DataError` message
([data/app-storage.md](../data/app-storage.md#errors)), or else the error's `localizedDescription`. Errors of request
functions are thrown to their caller, which shows them in its window ([ui/shell.md](../ui/shell.md)).

## MainConnection

```swift
@MainActor @Observable
public final class MainConnection: Identifiable {
    public nonisolated let id: UUID                       // the Main's device id
    public let isLoopback: Bool
    public private(set) var state: ConnectionState
    public private(set) var serverDevice: DeviceInfo?     // from the last hello result
    public private(set) var hostInfo: HostInfoResult?     // host.info, fetched after each handshake
    public private(set) var projects: [ProjectSummary]    // top-level projects, sub projects in `children`
    public private(set) var projectsLoaded: Bool          // `projects` reflects this Main since the last handshake
    public private(set) var skills: [SkillSummary]        // the Main's skills library
    public private(set) var skillsLoaded: Bool
    public private(set) var connectedAddress: String?     // host used by the current connection
    public var name: String { get }                       // registry name, else serverDevice name, else "Main"
    public var isConnected: Bool { get }                  // state == .connected
    public func refreshHostInfo() async                   // host.info again; a failure is logged
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected                             // not trying: before start, after stop or close
    case connecting(attempt: Int)                 // an attempt is running; attempt = consecutive failures + 1
    case connected                                // handshake done
    case failed(message: String, retryAt: Date?)  // waiting for the next attempt; nil = no automatic retry
}
```

### Addresses

A network connection tries, in order, without duplicates:

1. The `host` and `port` of `seenHosts[id]`, when the Main is currently seen with `protocolVersion` equal to
   `WireCoding.protocolVersion` and a `meshTag` equal to `MeshCrypto.meshTag(credentials)`.
2. Each entry of the Main's record `addresses`, with the record's `port`.

The URL is `WebSocketChannel.url(host:port:path: "/hephaestus")` (`wss://<host>:<port>/hephaestus`). With no
address, the attempt fails with "No address for <name>".

### Attempt

An attempt tries the addresses one after the other. For one address:

1. `environment.openChannel(url, credentials)` (the live channel gives up after 5 s).
2. An `RPCPeer` is created on the channel ([protocol/envelope.md](../protocol/envelope.md#rpcpeerswift-hephnet)).
   `setRequestHandler` installs the handler that answers `mesh.rekey` ([Incoming requests](#incoming-requests)); a task
   iterates `peer.events` and awaits the main-actor handling of each event, so events are applied one at a time in
   arrival order ([Events](#events)). `Task { await peer.run() }` starts the peer.
3. Request `hello` with `HelloParams(device: device, protocolVersion: WireCoding.protocolVersion)`. Events that
   arrive before the `hello` result are queued and applied right after step 2 of the reconnect sequence.
4. The outcome:

| Outcome                                       | Action                                                                                          |
|-----------------------------------------------|-------------------------------------------------------------------------------------------------|
| Result whose `device.id` is the connection id | Success: the [reconnect sequence](#reconnect-sequence) runs                                     |
| Result from another device                    | Close; error "Reached <result device name> instead of <name>"; next address                     |
| Error `unauthorized`                          | Close; the attempt stops; state `failed("This device was removed from the mesh", retryAt: nil)` |
| Error `badRequest`                            | Close; the attempt stops and fails with "Incompatible version" (the backoff applies)            |
| `MeshTransportError.authenticationFailed`     | Close; the attempt stops and fails with "The mesh key was not accepted" (the backoff applies)   |
| Any other failure                             | Close; the error is kept; next address                                                          |

When every address failed, the attempt fails with the message of the last error.

A loopback connection's attempt has one step instead of the address loop: `LocalHostLink.makeChannel()`, then steps
2–4.

### Backoff

`failures` counts the failed attempts and the drops since the last successful handshake. After a failed attempt or a
drop: `failures += 1`, delay = `[1, 2, 5, 10, 30][min(failures, 5) - 1]` seconds, state
`failed(message, retryAt: now + delay)`, `environment.sleep(delay)`, then a new attempt (state
`connecting(attempt: failures + 1)`). A successful handshake sets `failures = 0`. The first attempt after `start()`,
`retryNow()`, a new Bonjour sighting or a rekey starts at once. A failure with `retryAt: nil` waits for `retryNow()`
or a rekey ([Incoming requests](#incoming-requests)); a Bonjour sighting or a change of the Main's record does not
start an attempt ([Bonjour-seen hosts](#bonjour-seen-hosts)).

### Drops

Keep-alive pings every 10 s and the closing of a connection without inbound traffic for 30 s are done by the client
channel ([devices/mesh.md](../devices/mesh.md)); the loopback channel has neither. When `peer.run()` returns while the
connection is connected (a drop): pending requests have failed with `unavailable` (`RPCPeer`), the presence report is
dropped, `sessionCenter.mainDidDisconnect(_:)` and `forge.mainDidDisconnect(_:)` are called,
`WorkspaceEvent.disconnected(mainDeviceID:)` is emitted, and the backoff applies with the message "Connection lost".
Stores, `projects` and `skills` keep their data until the next handshake refreshes them.

### Incoming requests

A Main sends one request to its clients: `mesh.rekey` (`MeshRekeyParams {meshKey}`,
[devices/mesh.md](../devices/mesh.md)). On any connection:

1. A `meshKey` that is not 32 bytes is answered with `badRequest` "The mesh key must be 32 bytes."; without loaded
   credentials, the request is answered with `internal` "Could not store the mesh key" and logged (not reported); a
   key equal to the current one is answered `{}` and nothing else happens.
2. `environment.saveCredentials(MeshCredentials(meshID: <current meshID>, meshKey: <new key>))`. When it throws, the
   request is answered with `internal` "Could not store the mesh key" and the failure is reported
   ([Error reports](#error-reports)).
3. The result is `EmptyPayload()`.
4. Right after the response frame has been handed to the connection's channel (`MessageChannel.send`), the Workspace
   uses the new credentials, and every network connection closes and starts an attempt at once with `failures = 0`.
   The loopback connection is not affected.

Any other request gets `badRequest` "Unknown method <name>." ([protocol/methods.md](../protocol/methods.md#callers)).

### Closing

Closing a connection (by `stop()`, `reset()`, reconciliation or rekey) cancels its attempt and sleep tasks, closes the
peer, drops the presence report and sets state `disconnected`; when it was connected, it makes the calls of a drop
(`mainDidDisconnect`, `disconnected` event) without the backoff.

### Reconnect sequence

After a successful `hello` result:

1. `serverDevice` and `connectedAddress` are set; `failures = 0`; `projectsLoaded` and `skillsLoaded` become false
   (`projects` and `skills` keep their data until step 5 or an event replaces them).
2. The result's `mesh` is merged ([Registry merge](#registry-merge)); this connection's report becomes its
   `mesh.presence`. The events queued during the handshake are applied.
3. When the Workspace holds topics for this Main, one `subscribe` request with all of them is sent and awaited; a
   failure is logged. Topics that became held while it was in flight are subscribed the same way, with another
   request, until none is left; then step 4.
4. State `connected`; `topologyRevision` is incremented; `sessionCenter.mainDidConnect(_:)`,
   `runOutputCenter.mainDidConnect(_:)` and `forge.mainDidConnect(_:)` are called;
   `WorkspaceEvent.connected(mainDeviceID:)` is emitted.
5. Concurrently: `host.info` sets `hostInfo` (a failure is logged); `projects.list` sets `projects` and
   `projectsLoaded` (a failure is reported); `skills.list` sets `skills` and `skillsLoaded` (a failure is logged);
   every `ProjectStore` of this Main reloads.

Every other model reloads what it shows when it learns that its Main connected: the centers through `mainDidConnect`,
the others through `WorkspaceEvent.connected`. No missed event is replayed
([protocol/envelope.md](../protocol/envelope.md#delivery-rules)). Pending permission requests come back with the
projects tree and the stores ([Projects list](#projects-list)).

## Request API

### Conventions

- Each function sends one request with `RPCPeer.request` and returns the decoded result. Params are built with the
  params types of [protocol/methods.md](../protocol/methods.md); a function whose method result is a wrapper with one
  field returns that field.
- The requests that carry or return file content, or attach uploads, pass `timeout: .seconds(120)`:
  `uploads.chunk`, `tasks.addComment`, `sessions.start`, `sessions.send`, `forge.feedback`, `files.write`,
  `files.read`, `attachments.read`, `sessions.readAttachment`, `skills.readFile` and `skills.writeFile`. A frame of up
  to 48 MiB can take longer than the default 30 s to cross a slow link, and a request that attaches uploads waits while
  the Main moves their files, which copies them when the project is on another volume
  ([protocol/envelope.md](../protocol/envelope.md#timeouts), [services/files.md](../services/files.md#7-uploads)). The
  other requests use the default.
- Errors are `ProtocolError` values, plus `CancellationError` when the calling task is cancelled:

| Situation                                | Error                                                                                   |
|------------------------------------------|-----------------------------------------------------------------------------------------|
| The connection is not `connected`        | `ProtocolError(.unavailable, "<name> is offline.")`; nothing is sent                    |
| Error response, timeout, connection lost | As thrown by `RPCPeer.request` ([protocol/envelope.md](../protocol/envelope.md#errors)) |

- Results update client state only as follows: a `TaskItem`, `SessionInfo` or `RunInfo` returned for a project whose
  store does not contain that id yet is inserted into the store (an existing element is never replaced: events bring
  updates); `listProjects()` and `listSkills()` replace `projects` and `skills` ([Projects list](#projects-list));
  `meshSnapshot()`, `renameDevice` and `setAddresses` results are merged into the registry; `hostInfo()` sets
  `hostInfo`. A `BundleItem` result is never inserted: the bundle reaches the store through `bundle.changed`, which
  the Main sends before its response ([services/bundles.md](../services/bundles.md#bundleservice)).
- In a preview workspace, `PreviewData.respond` answers instead of a peer ([Previews](#previews)).

### Functions

All are `async throws` methods of `MainConnection` in `MainConnection+Requests.swift`. Optional parameters default to
nil and `attachments` to `[]`.

| Group    | Swift function                                                                                                                                                                                                        | Method                    |
|----------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------|
| Mesh     | `meshSnapshot() -> MeshSnapshot`                                                                                                                                                                                      | `mesh.snapshot`           |
| Mesh     | `renameDevice(_ deviceID: UUID, to name: String) -> DeviceRecord`                                                                                                                                                     | `mesh.renameDevice`       |
| Mesh     | `revokeDevice(_ deviceID: UUID)`                                                                                                                                                                                      | `mesh.revokeDevice`       |
| Mesh     | `setAddresses(_ addresses: [String]) -> DeviceRecord`                                                                                                                                                                 | `mesh.setAddresses`       |
| Pairing  | `openPairing() -> PairingOpenResult`                                                                                                                                                                                  | `pairing.open`            |
| Pairing  | `closePairing()`                                                                                                                                                                                                      | `pairing.close`           |
| Host     | `hostInfo() -> HostInfoResult`                                                                                                                                                                                        | `host.info`               |
| Host     | `listDirectories(path: String) -> HostListDirectoriesResult`                                                                                                                                                          | `host.listDirectories`    |
| Projects | `listProjects() -> [ProjectSummary]`                                                                                                                                                                                  | `projects.list`           |
| Projects | `projectSnapshot(projectID: String) -> ProjectsSnapshotResult`                                                                                                                                                        | `projects.snapshot`       |
| Projects | `createProject(name: String, identifier: String, parentID: String?, folderName: String?, description: String?) -> ProjectSummary`                                                                                     | `projects.create`         |
| Projects | `importProject(path: String, name: String?, identifier: String?) -> ProjectSummary`                                                                                                                                   | `projects.import`         |
| Projects | `updateProject(projectID: String, patch: ProjectPatch) -> Project`                                                                                                                                                    | `projects.update`         |
| Projects | `removeProject(projectID: String, moveToTrash: Bool)`                                                                                                                                                                 | `projects.remove`         |
| Projects | `migrateProject(projectID: String, to targetDeviceID: UUID) -> UUID` (the migration id)                                                                                                                               | `projects.migrate`        |
| Tasks    | `createTask(projectID: String, name: String, description: String?, status: TaskStatus?) -> TaskItem`                                                                                                                  | `tasks.create`            |
| Tasks    | `updateTask(projectID: String, taskID: String, patch: TaskPatch) -> TaskItem`                                                                                                                                         | `tasks.update`            |
| Tasks    | `deleteTask(projectID: String, taskID: String)`                                                                                                                                                                       | `tasks.delete`            |
| Uploads  | `beginUpload(projectID: String, fileName: String, size: Int) -> UUID` (the upload id)                                                                                                                                 | `uploads.begin`           |
| Uploads  | `uploadChunk(uploadID: UUID, offset: Int, data: Data)`                                                                                                                                                                | `uploads.chunk`           |
| Uploads  | `cancelUpload(uploadID: UUID)`                                                                                                                                                                                        | `uploads.cancel`          |
| Tasks    | `addComment(projectID: String, taskID: String, body: String, attachments: [UploadRef]) -> TaskItem`                                                                                                                   | `tasks.addComment`        |
| Tasks    | `updateComment(projectID: String, taskID: String, commentID: UUID, body: String) -> TaskItem`                                                                                                                         | `tasks.updateComment`     |
| Tasks    | `deleteComment(projectID: String, taskID: String, commentID: UUID) -> TaskItem`                                                                                                                                       | `tasks.deleteComment`     |
| Tasks    | `readAttachment(projectID: String, taskID: String, fileName: String, offset: Int?, length: Int?) -> AttachmentsReadResult`                                                                                            | `attachments.read`        |
| Bundles  | `createBundle(projectID: String, name: String, taskIDs: [String]) -> BundleItem`                                                                                                                                      | `bundles.create`          |
| Bundles  | `updateBundle(projectID: String, bundleID: String, patch: BundlePatch) -> BundleItem`                                                                                                                                 | `bundles.update`          |
| Bundles  | `deleteBundle(projectID: String, bundleID: String)`                                                                                                                                                                   | `bundles.delete`          |
| Bundles  | `startBundle(projectID: String, bundleID: String) -> BundleItem`                                                                                                                                                      | `bundles.start`           |
| Bundles  | `stopBundle(projectID: String, bundleID: String) -> BundleItem`                                                                                                                                                       | `bundles.stop`            |
| Files    | `listFiles(projectID: String, path: String) -> [FileEntry]`                                                                                                                                                           | `files.list`              |
| Files    | `readFile(projectID: String, path: String, offset: Int?, length: Int?) -> FilesReadResult` (a whole read when both are nil)                                                                                           | `files.read`              |
| Files    | `writeFile(projectID: String, path: String, data: Data, baseRevision: String?) -> String` (the new revision)                                                                                                          | `files.write`             |
| Files    | `createFile(projectID: String, path: String, isDirectory: Bool) -> FileEntry`                                                                                                                                         | `files.create`            |
| Files    | `renameFile(projectID: String, from: String, to: String)`                                                                                                                                                             | `files.rename`            |
| Files    | `deleteFile(projectID: String, path: String)`                                                                                                                                                                         | `files.delete`            |
| Web tabs | `openTab(projectID: String, url: String, title: String?, locked: Bool?) -> WebTab`                                                                                                                                    | `tabs.open`               |
| Web tabs | `updateTab(projectID: String, tabID: UUID, patch: WebTabPatch) -> WebTab`                                                                                                                                             | `tabs.update`             |
| Web tabs | `closeTab(projectID: String, tabID: UUID)`                                                                                                                                                                            | `tabs.close`              |
| Web tabs | `moveTab(projectID: String, tabID: UUID, toIndex: Int)`                                                                                                                                                               | `tabs.move`               |
| Sessions | `startSession(projectID: String, kind: SessionKind, taskID: String?, mode: SessionMode?, title: String?, message: String?, attachments: [UploadRef], permissionMode: PermissionMode?, model: String?) -> SessionInfo` | `sessions.start`          |
| Sessions | `sessionHistory(projectID: String, sessionID: UUID, before: Int?, limit: Int?) -> SessionsHistoryResult` (`events`, `firstIndex`, `total`)                                                                            | `sessions.history`        |
| Sessions | `readSessionAttachment(projectID: String, sessionID: UUID, fileName: String, offset: Int?, length: Int?) -> AttachmentsReadResult`                                                                                    | `sessions.readAttachment` |
| Sessions | `sendMessage(projectID: String, sessionID: UUID, text: String, attachments: [UploadRef])`                                                                                                                             | `sessions.send`           |
| Sessions | `interruptSession(projectID: String, sessionID: UUID)`                                                                                                                                                                | `sessions.interrupt`      |
| Sessions | `stopSession(projectID: String, sessionID: UUID)`                                                                                                                                                                     | `sessions.stop`           |
| Sessions | `respondToPermission(projectID: String, sessionID: UUID, requestID: String, decision: PermissionDecision, message: String?)`                                                                                          | `sessions.respond`        |
| Sessions | `updateSession(projectID: String, sessionID: UUID, patch: SessionPatch) -> SessionInfo`                                                                                                                               | `sessions.update`         |
| Sessions | `deleteSession(projectID: String, sessionID: UUID)`                                                                                                                                                                   | `sessions.delete`         |
| Runs     | `startRun(projectID: String, name: String) -> RunInfo`                                                                                                                                                                | `runs.start`              |
| Runs     | `stopRun(projectID: String, runID: UUID)`                                                                                                                                                                             | `runs.stop`               |
| Runs     | `runOutput(projectID: String, runID: UUID) -> RunsOutputResult`                                                                                                                                                       | `runs.output`             |
| Search   | `search(query: String, scopes: [SearchScope]?, projectID: String?, limit: Int?) -> [SearchResult]`                                                                                                                    | `search.query`            |
| Skills   | `listSkills() -> [SkillSummary]`                                                                                                                                                                                      | `skills.list`             |
| Skills   | `createSkill(name: String, description: String) -> SkillSummary`                                                                                                                                                      | `skills.create`           |
| Skills   | `skillFiles(name: String) -> [SkillFile]`                                                                                                                                                                             | `skills.files`            |
| Skills   | `readSkillFile(name: String, path: String) -> Data`                                                                                                                                                                   | `skills.readFile`         |
| Skills   | `writeSkillFile(name: String, path: String, data: Data)`                                                                                                                                                              | `skills.writeFile`        |
| Skills   | `deleteSkillFile(name: String, path: String)`                                                                                                                                                                         | `skills.deleteFile`       |
| Skills   | `renameSkill(name: String, to newName: String) -> SkillSummary`                                                                                                                                                       | `skills.rename`           |
| Skills   | `deleteSkill(name: String)`                                                                                                                                                                                           | `skills.delete`           |
| Forge    | `sendFeedback(screenshot: UploadRef?, comment: String, context: FeedbackContext) -> ForgeFeedbackResult`                                                                                                              | `forge.feedback`          |
| Forge    | `forgeStatus() -> ForgeState`                                                                                                                                                                                         | `forge.status`            |
| Forge    | `regenerate()`                                                                                                                                                                                                        | `forge.regenerate`        |
| Forge    | `retryForge(itemTaskID: String)`                                                                                                                                                                                      | `forge.retry`             |

Not in this API: `hello` (the handshake), `subscribe` and `unsubscribe` ([Subscriptions](#subscriptions)), the
client-side `mesh.rekey`, and the Main↔Main methods `mesh.sync`, `skills.manifest` and `migration.*`. The Forge
functions are called by `ForgeModel` on the connection of its Forge host ([ui/forge.md](../ui/forge.md)).

## Transfers

`MainConnection+Transfers.swift` sends files to a Main in chunks and reads them back in ranges, with progress.
Attachments have no size limit ([protocol/methods.md](../protocol/methods.md#uploads)).

```swift
/// What an upload reads.
public enum UploadSource: Sendable, Hashable {
    case data(Data)    // bytes in memory: pasted and dropped images, photos, the feedback screenshot
    case file(URL)     // a local file, read chunk by chunk: chosen and dropped files
}

/// Progress of one transfer, in bytes.
public struct TransferProgress: Sendable, Hashable {
    public var completed: Int
    public var total: Int
    public init(completed: Int, total: Int)
    public var fraction: Double { get }   // completed / total; 1 when total is 0
}

extension MainConnection {
    /// Sends the file as an upload of `projectID`; returns the reference that a request attaches.
    public func upload(fileName: String, projectID: String, source: UploadSource,
                       progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> UploadRef
    /// A task attachment in the attachment cache, downloaded unless the cache has it with `size` bytes.
    public func downloadAttachment(projectID: String, taskID: String, fileName: String, size: Int,
                                   progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> URL
    /// A file attached to a session message, likewise.
    public func downloadSessionAttachment(projectID: String, sessionID: UUID, fileName: String, size: Int,
                                          progress: @escaping @MainActor (TransferProgress) -> Void) async throws
        -> URL
    /// A project file, downloaded each time (project files change).
    public func downloadFile(projectID: String, path: String,
                             progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> URL
}

public struct AttachmentCache: Sendable {
    public let root: URL
    public init(root: URL)
    /// <Caches>/Hephaestus/Attachments (data/app-storage.md).
    public static func standard() -> AttachmentCache
    public func taskAttachment(mainDeviceID: UUID, projectID: String, taskID: String, fileName: String) -> URL
    public func sessionAttachment(mainDeviceID: UUID, projectID: String, sessionID: UUID, fileName: String) -> URL
    public func projectFile(mainDeviceID: UUID, projectID: String, path: String) -> URL
}
```

`progress` is called on the main actor. The transfer functions send their requests with the request API, so its
errors and timeouts apply ([Conventions](#conventions)); without a connection they throw `unavailable` "<name> is
offline." before anything is sent.

### Uploading

`upload(fileName:projectID:source:progress:)`:

1. Size: the `count` of `.data`. For `.file(url)`: `url.startAccessingSecurityScopedResource()` (stopped at the end
   when it returned true), the file's size (`FileManager.default.attributesOfItem(atPath:)`, `.size`), and a
   `FileHandle(forReadingFrom:)`, closed at the end. A file that cannot be read throws its error.
2. `beginUpload(projectID:fileName:size:)` gives the upload id; `progress(TransferProgress(completed: 0, total:
   size))`.
3. While `offset < size`: the next `min(MethodLimits.maxChunkSize, size − offset)` bytes, a slice of the data or read
   from the handle (a read that returns fewer bytes throws `ProtocolError(.conflict, "<fileName> changed while it was
   uploaded.")`); `uploadChunk(uploadID:offset:data:)`; `offset` grows by the chunk's size; `progress(offset of
   size)`. One chunk at a time.
4. Returns `UploadRef(uploadID:fileName:)`.

- A failure after step 2, and the cancellation of the calling task, send `cancelUpload(uploadID:)` without waiting
  (its error ignored), then the error is rethrown.
- `upload` never retries by itself. Retrying is calling it again, which begins a new upload
  ([ui/sessions.md](../ui/sessions.md#message-composer)).
- An upload not attached within an hour of its last chunk is deleted by the Main, and a Main forgets every upload when
  its host stops or starts; a request that attaches it then fails with `notFound`
  ([protocol/methods.md](../protocol/methods.md#using-uploads), [services/files.md](../services/files.md#71-store)).

### Downloading

The three download functions fill a file of the attachment cache with ranged reads:

| Function                    | Ranged reads                                                             | Cached at                | Reused when                           |
|-----------------------------|--------------------------------------------------------------------------|--------------------------|---------------------------------------|
| `downloadAttachment`        | `readAttachment(projectID:taskID:fileName:offset:length: nil)`           | `taskAttachment(...)`    | a file exists there with `size` bytes |
| `downloadSessionAttachment` | `readSessionAttachment(projectID:sessionID:fileName:offset:length: nil)` | `sessionAttachment(...)` | a file exists there with `size` bytes |
| `downloadFile`              | `readFile(projectID:path:offset:length: nil)`                            | `projectFile(...)`       | never: the file is downloaded again   |

The cache paths take the connection's `id` as `mainDeviceID`.

1. Reuse: when the cache has the file, `progress(size of size)` and its URL is returned; nothing is sent.
2. The parent folders are created; `<destination>.download` is created empty, replacing an older one.
3. Reads in order, from offset 0, with the default `length` (`maxChunkSize`): the first result's `size` is the total;
   each next read starts at the number of bytes written; after each, the bytes are appended and `progress(written of
   total)` is called. A result whose `size` differs from the first one's, or an empty `data` before the total is
   reached, throws `ProtocolError(.conflict, "<fileName> changed during the download.")`. A file of size 0 takes one
   read.
4. The partial file replaces the destination (`FileManager.default.replaceItemAt(_:withItemAt:)`, a move when there is
   none) and the destination's URL is returned.

- A failure, and the cancellation of the calling task, delete the partial file and rethrow.
- One download per destination at a time: a call for a destination that a download is filling waits for that download
  to end, then starts over at step 1 (an attachment that download completed is reused).
- The cache keeps the files until the system deletes them or a download replaces them
  ([data/app-storage.md](../data/app-storage.md#caches)).

### Cache paths

`AttachmentCache.standard()` is `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]` +
`Hephaestus/Attachments` (it does not throw; the folders are created by the downloads, step 2 above). Paths under
`root`:

| Function            | Path                                                                       |
|---------------------|----------------------------------------------------------------------------|
| `taskAttachment`    | `<mainDeviceID>/<projectID>/tasks/<taskID>/<fileName>`                     |
| `sessionAttachment` | `<mainDeviceID>/<projectID>/sessions/<session id in lowercase>/<fileName>` |
| `projectFile`       | `<mainDeviceID>/<projectID>/files/<path>`                                  |

`<mainDeviceID>` is written in canonical uppercase form. `fileName` is a stored attachment name, one path component
([data/task-yml.md](../data/task-yml.md#naming)); `path` is a project path
([protocol/methods.md](../protocol/methods.md#paths)).

## Projects list

- `MainConnection.projects` is the Main's tree of `ProjectSummary` (top-level projects, sub projects in `children`).
  It is set by `projects.list` after each handshake and replaced by each `projects.changed` whose `deviceID` is that
  Main; both set `projectsLoaded = true`. The same holds for `skills`, from `skills.list` and `skills.changed`.
- The events for the mirror a list request loads are queued while it is in flight: the `projects.changed` events of
  that Main during its `projects.list`, the `skills.changed` events of that Main during its `skills.list`. They are
  applied in arrival order right after the result is stored, or after the request failed; other events are applied
  at once ([protocol/envelope.md](../protocol/envelope.md#delivery-rules)).
- After a tree is replaced: a store of that Main whose `projectID` is no longer in the tree gets `isRemoved = true`
  and is dropped; the selection rules 3 and 4 run ([Selection](#selection-rules)); then, for each project of the new
  tree, sub projects included, whose `pendingPermissionCount` is above 0, `projectStore(mainDeviceID:projectID:)` is
  called. It creates the store when it is missing, and a new store loads when its Main is connected, so the
  `pendingPermissions` of the project's sessions reach `sessionCenter.handleSessions` after every handshake, whether or
  not the project was opened on this device ([ProjectStore](#projectstore)).
- `Workspace.summary(of projectID: String, on mainDeviceID: UUID) -> ProjectSummary?` finds a project in a Main's tree.
- `Workspace.projectPath(of projectID: String, on mainDeviceID: UUID) -> [String]?` returns the chain of project ids
  from the top-level project down to `projectID`; the path bar uses it ([ui/shell.md](../ui/shell.md)).

## ProjectStore

```swift
@MainActor @Observable
public final class ProjectStore {
    public enum Phase: Equatable, Sendable { case idle, loading, loaded, failed(String) }
    public let mainDeviceID: UUID
    public let projectID: String
    public private(set) var phase: Phase
    public private(set) var project: Project?
    public private(set) var tasks: [TaskItem]        // by task number, ascending
    public private(set) var bundles: [BundleItem]    // by bundle number, ascending
    public private(set) var sessions: [SessionInfo]  // by created, then id
    public private(set) var runs: [RunInfo]          // by startedAt, then id; trimmed to 20 (running runs stay)
    public private(set) var isRemoved: Bool
    public var connection: MainConnection? { get }
    public func reload() async
    public func task(_ id: String) -> TaskItem?
    public func bundle(_ id: String) -> BundleItem?
    public func session(_ id: UUID) -> SessionInfo?
    public func run(_ id: UUID) -> RunInfo?
}
```

- `Workspace.projectStore(mainDeviceID: UUID, projectID: String) -> ProjectStore` returns the store of a project,
  creating it with phase `idle` when missing; a new store starts loading when its Main is connected. A store stays
  until its project leaves its Main's tree or its Main leaves the registry; `reset()` drops every store.
- `reload()` returns at once while a load runs. Otherwise: phase `loading` (the data stays visible) and request
  `projects.snapshot`; events for this store that arrive meanwhile are queued. On success `project`, `tasks`, `bundles`,
  `sessions` and `runs` are replaced (sorted, runs trimmed), the queued events are applied in order, phase `loaded`,
  then `sessionCenter.handleSessions(mainDeviceID:projectID:sessions:)` gets the store's `sessions`
  ([ui/sessions.md](../ui/sessions.md#sessioncenter)). On failure the queued events are dropped; `notFound` sets
  `isRemoved = true` and drops the store; otherwise a store that never loaded gets phase `failed(message)`, and a store
  that had data returns to `loaded` and the failure is reported ([Error reports](#error-reports)).
- Sorting: tasks by the number after the last `-` of the id (ids without a number last, by id); bundles by the number
  after the last `-B` of the id (ids without a number last, by id); sessions by `created`,
  then id; runs by `startedAt`, then id. Runs trim: while more than 20 runs are kept, the oldest run whose state is
  not `running` is dropped, as the Main does ([services/runs.md](../services/runs.md#7-history)); a `running` run is
  never dropped, so more than 20 can stay.

## Events

The events task of each connection ([Attempt](#attempt), step 2) decodes each `InboundEvent` with `ServerEvent.decode`
([protocol/events.md](../protocol/events.md)); nil (an unknown event) is ignored, a decoding error is logged and
ignored. Events are applied in arrival order, per connection. For an event from the Main `M`, "the store" is the store
of `(M, projectID of the event)` when it exists.

| Event                  | Workspace and stores                                                                                                      | Forwarded to                              |
|------------------------|---------------------------------------------------------------------------------------------------------------------------|-------------------------------------------|
| `mesh.changed`         | Registry merge of `snapshot.devices`; the connection's report becomes `snapshot.presence`                                 |                                           |
| `projects.changed`     | `projects` of the connection of `deviceID` replaced                                                                       |                                           |
| `project.changed`      | The store's `project` replaced; when `M`'s projects are loaded and the id is not in its tree, `projects.list` again       |                                           |
| `task.changed`         | Upsert of `task` in the store                                                                                             |                                           |
| `task.removed`         | The task removed from the store (nothing when absent)                                                                     |                                           |
| `bundle.changed`       | Upsert of `bundle` in the store                                                                                           |                                           |
| `bundle.removed`       | The bundle removed from the store (nothing when absent)                                                                   |                                           |
| `session.changed`      | Upsert of `session` in the store                                                                                          | `sessionCenter.handleSessionChanged`      |
| `session.removed`      | The session removed from the store                                                                                        | `sessionCenter.handleSessionRemoved`      |
| `session.event`        | When the store is loaded and lacks the session id, the store reloads                                                      | `sessionCenter.handleSessionEvent`        |
| `session.delta`        | Same as `session.event`                                                                                                   | `sessionCenter.handleSessionDelta`        |
| `permission.requested` | Same as `session.event`                                                                                                   | `sessionCenter.handlePermissionRequested` |
| `permission.resolved`  | Same as `session.event`                                                                                                   | `sessionCenter.handlePermissionResolved`  |
| `run.changed`          | Upsert of `run` in the store, then the runs trim                                                                          |                                           |
| `run.output`           | When the store is loaded and lacks the run id, the store reloads                                                          | `runOutputCenter.handleRunOutput`         |
| `skills.changed`       | `skills` of `M` replaced                                                                                                  |                                           |
| `migration.progress`   | `migrations[migrationID]` replaced; on a state change `topologyRevision` is incremented; on `completed`, selection rule 2 |                                           |
| `forge.changed`        | Nothing                                                                                                                   | `forge.apply(_:from:)` with `M`           |
| `files.changed`        | Nothing                                                                                                                   |                                           |

- The forwarded calls take `mainDeviceID: M` and the payload's fields, with the signatures of
  [ui/sessions.md](../ui/sessions.md#sessioncenter), [ui/runs.md](../ui/runs.md#runoutputcenter) and
  [ui/forge.md](../ui/forge.md#forgemodel). Forwarding does not depend on stores.
- An upsert replaces the element with the same id or inserts it at its sorted position. Applying the same event twice
  gives the same state.
- After applying and forwarding an event, the Workspace yields `.event(mainDeviceID: M, event)` to every `events()`
  stream.

### WorkspaceEvent

```swift
public enum WorkspaceEvent: Sendable {
    case connected(mainDeviceID: UUID)      // after the handshake and the re-subscription
    case disconnected(mainDeviceID: UUID)   // the connection left `connected`
    case event(mainDeviceID: UUID, ServerEvent)
}

extension Workspace {
    public func events() -> AsyncStream<WorkspaceEvent>
}
```

Each call returns a new stream with an unbounded buffer that receives everything emitted after the call. The stream
ends when the task iterating it is cancelled (its `onTermination` unregisters it). Models the Workspace does not own
iterate it in a task they own, as their docs say: `SessionModel` ([ui/sessions.md](../ui/sessions.md)),
`FileTreeModel` and `EditorDocument` ([ui/code.md](../ui/code.md)), `SearchModel`
([services/search.md](../services/search.md)).

## Subscriptions

```swift
extension Workspace {
    public func subscribe(_ topic: Topic, on mainDeviceID: UUID) async -> TopicSubscription
}

@MainActor
public final class TopicSubscription {
    public let mainDeviceID: UUID
    public let topic: Topic
    public func cancel()   // idempotent
}
```

- Topics are `Topic.session(id)` and `Topic.run(id)` ([protocol/envelope.md](../protocol/envelope.md#subscriptions)).
- The Workspace counts holders per `(mainDeviceID, topic)`. The first holder makes the topic held; the last `cancel()`
  releases it.
- The `subscribe` and `unsubscribe` requests of a Main go through one serial queue per Main: each request is sent once
  the previous one has been answered, so the Main receives them in the order the topics were held and released. When
  its turn comes, a request is sent only when the connection is connected and the request is still needed: `subscribe`
  when the topic is held, `unsubscribe` when it is not. A failure is logged and leaves the topic held or released.
  Otherwise, the `unsubscribe` sent when a view of a session disappears could reach the Main after the `subscribe` of
  the view that replaces it, and the session's events would stop arriving.
- The first holder waits for the answer to its `subscribe`, queued behind any earlier request of that Main, before
  `subscribe(_:on:)` returns. The last `cancel()` does not wait.
- Closing the connection drops the requests still queued: the handshake subscribes to the held topics again
  (reconnect sequence step 3).
- A `TopicSubscription` released without `cancel()` cancels itself (its `deinit` schedules the cancel on the main
  actor).
- On every handshake the held topics of that Main are subscribed again (reconnect sequence step 3), before the
  `mainDidConnect` calls and the `connected` event: after a reconnect, models only fetch again.
- `SessionModel` holds the subscription of its session and `RunOutputModel` the one of its run while they are visible,
  taken where their docs send `subscribe` and cancelled where they send `unsubscribe`
  ([ui/sessions.md](../ui/sessions.md), [ui/runs.md](../ui/runs.md)). A model subscribes first, then fetches, then
  applies events.

## Selection

```swift
public enum SidebarSection: String, Codable, CaseIterable, Sendable {
    case overview, tasks, code, docs, web, claude, runs   // project sections, ⌘1–⌘7 in this order
    case devices, skills, forge                           // workspace sections
    public var isProjectSection: Bool { get }             // true for the first seven
}

@MainActor @Observable
public final class Selection {
    public var mainDeviceID: UUID?
    public var projectID: String?          // the selected project or sub project
    public var section: SidebarSection?    // nil: no section chosen (compact: the sidebar list is shown)
    public var item: String?               // the item selected in the section
    public init(mainDeviceID: UUID? = nil, projectID: String? = nil, section: SidebarSection? = nil,
                item: String? = nil)
    public var feedbackSelection: FeedbackSelection { get }   // section as its raw value
}
```

- A window gets its selection from `Workspace.makeSelection()`. The shell stores the four fields under the
  `WindowStateKeys` ([data/app-storage.md](../data/app-storage.md#per-window-state)), drops a restored project that
  its Main no longer holds, fills empty fields with its defaults and clears `item` when the section changes
  ([ui/shell.md](../ui/shell.md)). Setting a field changes nothing else.
- `feedbackSelection` is `FeedbackSelection(mainDeviceID:, projectID:, section: section?.rawValue, item:)`
  ([forge/feedback.md](../forge/feedback.md)).

| Section    | `item`                                                                                                                  |
|------------|-------------------------------------------------------------------------------------------------------------------------|
| `overview` | none                                                                                                                    |
| `tasks`    | Task id (`HEPH-12`) or bundle id (`HEPH-B3`, [services/bundles.md](../services/bundles.md#bundle-id))                   |
| `code`     | Path of the active file, relative to the project root, optionally followed by `#L<line>` ([File items](#file-items))    |
| `docs`     | Path of the shown document, relative to the project root, optionally followed by `#L<line>` ([File items](#file-items)) |
| `web`      | Web tab id                                                                                                              |
| `claude`   | Session id                                                                                                              |
| `runs`     | Name of the selected run configuration ([ui/runs.md](../ui/runs.md#selection))                                          |
| `devices`  | Device id                                                                                                               |
| `skills`   | `<skill name>` or `<skill name>/<file path>` ([ui/skills.md](../ui/skills.md))                                          |
| `forge`    | Task id of the pipeline item                                                                                            |

UUIDs are written in canonical uppercase form.

### File items

A `code` or `docs` item is `<path>` or `<path>#L<line>`, `<line>` being a 1-based line number. An item that ends with
`#L` and a decimal number of at least 1 is read as `<path>#L<line>`; any other item is a plain path
(`ProjectPath.splitLineSuffix(_:)`, [ui/code.md](../ui/code.md#projectfiles)). Search results set `#L<line>`
([ui/search.md](../ui/search.md#opening-a-result)). The Code and Docs sections open `<path>`, scroll to
the line and select it, then set `item` to the plain `<path>` ([ui/code.md](../ui/code.md#navigation-and-selection),
[ui/docs.md](../ui/docs.md#navigation-and-selection)).

### Selection rules

The Workspace applies these rules to every selection made by `makeSelection()` that is still alive. Moving a
selection to another Main keeps `projectID`, `section` and `item`.

1. **Main gone.** After a registry change, a selection whose `mainDeviceID` is not the id of a Main of `mains` (nor of
   the local connection) gets `mainDeviceID`, `projectID` and `item` set to nil.
2. **Project moved.** On `migration.progress` with state `completed` (project `P`, from `S` to `D`): a selection on `S`
   whose project is `P`, is under `P` in `S`'s tree, or waits on this migration (rule 3) moves to `D`
   ([protocol/events.md](../protocol/events.md#migrationprogress)).
3. **Project gone.** When the tree of a Main `M` is replaced, each selection on `M` whose `projectID` was in the old
   tree and is not in the new one:
   1. When the project is in the tree of another connected Main: moves there.
   2. Else, when `migrations` holds a migration from `M` (`fromDeviceID`) of the top-level project of its old chain,
      with state `preparing`, `transferring`, `committing` or `completed`: unchanged; rule 2 or 4 moves it.
   3. Else (the project was removed): `projectID` becomes the deepest project of its old chain that is still in the new
      tree, or nil; `item` becomes nil.
4. **Project appeared.** When the tree of a Main `X` is replaced, a selection on another Main whose `projectID` is not
   in its Main's loaded tree and is in `X`'s new tree moves to `X`.

## Previews

```swift
extension Workspace {
    public static func preview() -> Workspace
}

public enum PreviewData {
    public static let credentials: MeshCredentials
    public static func respond(mainDeviceID: UUID, method: String, params: Data) throws -> Data
}
```

`Workspace.preview()` builds a Workspace with `WorkspaceEnvironment.preview` and `isPreview = true`. It is never
started: no browsing, no network, no file. Its state is set synchronously from the sample data below: `device`,
`mesh`, `presence`, both Mains' connections in state `connected` with `hostInfo`, `projects` and `skills`, and the
stores of `HEPH` and `API` loaded. This device, Sam's MacBook Pro, is a Main: its connection is the loopback one
(`isLoopback` true, so it is `localConnection`). Each connection's `serverDevice` is the `DeviceInfo` of its Main's
record. The sessions of each store go to `sessionCenter.handleSessions(mainDeviceID:projectID:sessions:)`, and the
`forge.status` answer of Studio to `forge.apply(_:from:)`, synchronously too: the screens that use the centers show
the state a real connection would give them. Every request of the request API is answered by
`PreviewData.respond(mainDeviceID:method:params:)`, which takes the params JSON and returns the result JSON, both
encoded as on the wire ([protocol/envelope.md](../protocol/envelope.md#encoding)). No event ever arrives. The SwiftUI
preview of every screen and the snapshot tests use it ([testing.md](../testing.md)).

| Method                                           | `PreviewData.respond` answer                                                                                                                                                                     |
|--------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `mesh.snapshot`                                  | The sample mesh                                                                                                                                                                                  |
| `host.info`                                      | The Main's host info                                                                                                                                                                             |
| `projects.list`                                  | The Main's projects                                                                                                                                                                              |
| `projects.snapshot`                              | The project with its tasks, sessions and runs                                                                                                                                                    |
| `sessions.history`                               | The session's events, paged as [protocol/methods.md](../protocol/methods.md#sessionshistory) says: with `before` and `limit` nil, `{events: <all of them>, firstIndex: 0, total: <their count>}` |
| `files.list`, `files.read`                       | The sample files of `HEPH` (`revision` = first 16 hex characters of the SHA-256 of the content); `API` has none: its root lists no entries                                                       |
| `attachments.read`, `sessions.readAttachment`    | The range asked of a 160 × 100 PNG filled with sRGB (0.95, 0.42, 0.18), `size` the PNG's size, `mimeType` `image/png`                                                                            |
| `runs.output`                                    | The run's output, `seq` 1                                                                                                                                                                        |
| `skills.list`, `skills.files`, `skills.readFile` | The sample skill                                                                                                                                                                                 |
| `search.query`                                   | No results                                                                                                                                                                                       |
| `forge.status`                                   | Studio: a `ForgeState` of Studio, `enabled`, with its `forge` config and no items. Sam's MacBook Pro: `enabled` false, `hostDeviceID` `#002`, no config, no items                                |
| `subscribe`, `unsubscribe`                       | `{}`                                                                                                                                                                                             |
| Any other method                                 | `ProtocolError(.unavailable, "Not available in previews")`                                                                                                                                       |

A request about something the sample data does not hold gets the error of the service that would answer it: a project
that is not on that Main (`projects.snapshot`, `sessions.history`, `files.list`, `files.read`, `runs.output`):
`notFound` "Project <id> is not hosted on this Main."; an unknown session: `notFound` "session <id> not found"; an
unknown run: `notFound` "Run <id> does not exist."; a missing file or folder: `notFound` "No file at <path>." or "No
folder at <path>."; a folder read as a file or a file listed as a folder: `badRequest` "<path> is a folder." or "<path>
is a file."; an unknown skill: `notFound` "Skill <name> does not exist."; a skill file other than `SKILL.md`:
`notFound` "No file at <path>.".

### Sample data

Fields are those of [protocol/types.md](../protocol/types.md); a field not given is empty, false, zero or nil. UUIDs
are `00000000-0000-4000-8000-000000000NNN`, written `#NNN`. Times are on 2026-10-29, UTC, unless written in full.

Mesh `#100`, credentials key: 32 zero bytes.

| Id     | Name              | Platform | Main | Addresses                           | Presence                    | Note                     |
|--------|-------------------|----------|------|-------------------------------------|-----------------------------|--------------------------|
| `#001` | Studio            | `macOS`  | yes  | `Sams-Mac-mini.local`, `192.0.2.10` | online                      | hosts `HEPH` and `API`   |
| `#002` | Sam's MacBook Pro | `macOS`  | yes  | `198.51.100.2`                      | online                      | this device, no projects |
| `#003` | Sam's iPad        | `iPadOS` | no   |                                     | offline, last seen 18:30:00 |                          |

Every record: `port` 47100 for the Mains and 0 for Sam's iPad, `appVersion` `1.0`, `build` 42, `pairedAt`
2026-10-01T09:00:00.000Z, `updatedAt` 08:00:00, not revoked. Presence: the two online Mains have `lastSeen` 21:00:00,
and every entry has `via` `[]`. Host info of both Mains: `projectsFolder` `/Users/user/Developer`, `claudeAvailable`
true, `claudePath` `/Users/user/.local/bin/claude`, `gitAvailable` true; Studio's `forge` is
`ForgeConfig(sourceProjectID: "HEPH", repository: "Azavech/Hephaestus", branch: "main", autoRegenerate: true)`.

Projects (on Studio, `created` 2026-10-01T09:00:00.000Z, `code` `.`, `docs` `docs`):

| Id     | Name           | Description                    | `rootPath`                                      | Sub projects           | Runs                                                               |
|--------|----------------|--------------------------------|-------------------------------------------------|------------------------|--------------------------------------------------------------------|
| `HEPH` | Hephaestus     | Multi-device project workbench | `/Users/user/Developer/Hephaestus`              | `services/api` (`API`) | Build macOS: `./scripts/build.sh macos`; Test: `./scripts/test.sh` |
| `API`  | Hephaestus API | Sync service                   | `/Users/user/Developer/Hephaestus/services/api` |                        | Run: `go run .`                                                    |

`HEPH`: `taskCounter` 4, `feedbackCounter` 0, `claude` model `opus` and permission mode `acceptEdits`, web tabs
`#201` "GitHub" `https://github.com/Azavech/Hephaestus` locked and `#202` "Swift Forums" `https://forums.swift.org` not
locked, `pendingPermissionCount` 1 in its `ProjectSummary`. `API`: `taskCounter` 1, `feedbackCounter` 0,
`pendingPermissionCount` 0.

Tasks:

| Id       | Name                    | Status       | Created  | Updated  | Description                                    |
|----------|-------------------------|--------------|----------|----------|------------------------------------------------|
| `HEPH-1` | Set up the repository   | `done`       | 09:00:00 | 10:00:00 | Create the Xcode project and the package.      |
| `HEPH-2` | Sidebar breaks on iPad  | `inProgress` | 11:00:00 | 20:40:00 | The sidebar overlaps the editor in split view. |
| `HEPH-3` | Review the pairing flow | `review`     | 12:00:00 | 19:00:00 | Check the 6-digit code flow on every platform. |
| `HEPH-4` | Add Go highlighting     | `todo`       | 20:10:00 | 20:10:00 | Keywords, strings, raw strings and comments.   |
| `API-1`  | Define the endpoints    | `todo`       | 13:00:00 | 13:00:00 | List the endpoints of the sync service.        |

Comments of `HEPH-2`: `#211` by "Sam's iPad" at 11:05:00, body "Screenshot attached.", attachment `screenshot.png`
(`image/png`, 18000 bytes); `#212` by "Claude" at 20:40:00, body "Fixed the width of the sidebar column; please
review.".

Sessions of `HEPH` (permission mode `acceptEdits`, `updated` = the time of their last event):

| Id     | Kind      | Task     | Mode        | Title            | Status              | Created  |
|--------|-----------|----------|-------------|------------------|---------------------|----------|
| `#301` | `project` |          |             | Plan the release | `idle`              | 20:00:00 |
| `#302` | `task`    | `HEPH-2` | `implement` | Implement HEPH-2 | `waitingPermission` | 20:30:00 |

`#302` has `pendingPermissions` = [the request of its `perm-1` event: `requestID` `perm-1`, `toolName` `Bash`, `input`
`{"command":"./scripts/build.sh ios"}`, `suggestions` `[]`]; `#301` has none.

Events of `#301`, ids `#401`–`#406`, one second apart from 20:00:01: `user` "Plan the 1.1 release and create the
tasks." (device `#002`); `assistant` "I will create the missing task."; `toolUse` `toolu_1`
`mcp__hephaestus__create_task` input `{"project":"HEPH","name":"Add Go highlighting"}`; `toolResult` `toolu_1`
"Created HEPH-4", not an error; `assistant` "Created HEPH-4."; `result` not an error, `durationMS` 8200, `costUSD`
0.04, `stopReason` `end_turn`.

Events of `#302`, ids `#411`–`#415`, one second apart from 20:30:01: `user` "Work on HEPH-2: Sidebar breaks on iPad
(implement)." (device `#002`); `assistant` "The sidebar width is fixed at 320 pt; I will make it flexible."; `toolUse`
`toolu_2` `Edit` input `{"file_path":"/Users/user/Developer/Hephaestus/Sources/App.swift"}`; `toolResult` `toolu_2`
"The file has been updated.", not an error; `permission` request `perm-1`, tool `Bash`, input
`{"command":"./scripts/build.sh ios"}`, suggestions `[]`, not answered.

Runs of `HEPH`:

| Id     | Name        | Command                    | Started  | Ended    | Exit code | State       | Output                                                                |
|--------|-------------|----------------------------|----------|----------|-----------|-------------|-----------------------------------------------------------------------|
| `#501` | Test        | `./scripts/test.sh`        | 20:00:00 | 20:01:10 | 0         | `succeeded` | "Test Suite 'All tests' passed.\nExecuted 42 tests, with 0 failures." |
| `#502` | Build macOS | `./scripts/build.sh macos` | 20:55:00 |          |           | `running`   | "Building Hephaestus for macOS…"                                      |

Files of `HEPH` (folders `docs` and `Sources`; every entry modified at 20:00:00):

| Path                | Content                                                                                                                         |
|---------------------|---------------------------------------------------------------------------------------------------------------------------------|
| `README.md`         | `# Hephaestus\n\nMulti-device project workbench.\n`                                                                             |
| `docs/README.md`    | `# Documentation\n\n- [Tasks](tasks.md)\n- Code\n`                                                                              |
| `docs/tasks.md`     | `# Tasks\n\nEvery task has an id, a name and a status.\n`                                                                       |
| `Sources/App.swift` | `import SwiftUI\n\n@main\nstruct DemoApp: App {\n    var body: some Scene {\n        WindowGroup { Text("Hello") }\n    }\n}\n` |

Skill (on both Mains, modified 2026-10-28T12:00:00.000Z): `release-notes`, description "Write release notes from the
done tasks", one file `SKILL.md` with the content
`---\nname: release-notes\ndescription: Write release notes from the done tasks\n---\n\nList the tasks done since the last release, one line per task.\n`.

## Swift API summary

```swift
@MainActor @Observable public final class Workspace {
    public init(device: DeviceInfo, environment: WorkspaceEnvironment)
    public private(set) var device: DeviceInfo
    public private(set) var hasMesh: Bool
    public private(set) var mesh: MeshSnapshot?
    public private(set) var presence: [UUID: Presence]
    public private(set) var connections: [UUID: MainConnection]
    public private(set) var seenHosts: [UUID: BonjourAdvert]
    public private(set) var migrations: [UUID: MigrationProgressPayload]
    public private(set) var topologyRevision: Int
    @ObservationIgnored public private(set) var sessionCenter: SessionCenter!       // set by init, after the others
    @ObservationIgnored public private(set) var runOutputCenter: RunOutputCenter!   // set by init, after the others
    @ObservationIgnored public private(set) var forge: ForgeModel!                  // set by init, after the others
    public let isPreview: Bool
    public var mains: [DeviceRecord] { get }
    public var localConnection: MainConnection? { get }
    public var onlineDeviceCount: Int { get }
    public func start()
    public func stop()
    public func restart()
    public func reset()
    public func retryNow()
    public func setLocalHostLink(_ link: (any LocalHostLink)?)
    public func updateLocalDevice(_ device: DeviceInfo)
    public func makeSelection() -> Selection
    public func errorReports() -> AsyncStream<String>
    public func connection(_ mainDeviceID: UUID) -> MainConnection?
    public func projectStore(mainDeviceID: UUID, projectID: String) -> ProjectStore
    public func summary(of projectID: String, on mainDeviceID: UUID) -> ProjectSummary?
    public func projectPath(of projectID: String, on mainDeviceID: UUID) -> [String]?
    public func subscribe(_ topic: Topic, on mainDeviceID: UUID) async -> TopicSubscription
    public func events() -> AsyncStream<WorkspaceEvent>
    public static func preview() -> Workspace
}

public enum PresenceModel {
    public static func mergeRegistry(_ current: [DeviceRecord], with incoming: [DeviceRecord]) -> [DeviceRecord]
    public static func mergePresence(devices: [DeviceRecord], reports: [[Presence]], lastSeen: [UUID: Date],
                                     localDeviceID: UUID, now: Date) -> [UUID: Presence]
}
```
