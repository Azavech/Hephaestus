# Host service

files:
- HephaestusKit/Sources/HephHost/HostService.swift
- HephaestusKit/Sources/HephHost/EventHub.swift
- HephaestusKit/Sources/HephHost/HostInfo.swift
- HephaestusKit/Sources/HephHost/Projects/ProjectRegistry.swift
- HephaestusKit/Sources/HephHost/Projects/ProjectService.swift
- HephaestusKit/Sources/HephHost/Projects/ProjectWriteQueue.swift
- HephaestusKit/Sources/HephHost/Projects/FileWatcher.swift
- HephaestusKit/Sources/HephHost/Tasks/TaskService.swift
- HephaestusKit/Sources/HephHost/Tabs/TabService.swift

---

The host is what a Mac runs while it is a Main: it serves the methods of
[../protocol/methods.md](../protocol/methods.md)
to every connection, owns the hosted projects, watches their folders and emits the events of
[../protocol/events.md](../protocol/events.md). Every file of `HephHost` is wrapped in `#if os(macOS)`. Everything this
doc calls "logged" is written with `Log.host` ([../architecture.md](../architecture.md)).

Related docs: files in [files.md](files.md), search in [search.md](search.md); listener,
Bonjour, registry, presence and peer links in [../devices/mesh.md](../devices/mesh.md); migration in
[../devices/migration.md](../devices/migration.md); sessions in [../claude/cli.md](../claude/cli.md); MCP server in
[../claude/mcp.md](../claude/mcp.md); skills in [../claude/skills.md](../claude/skills.md); Forge in
[../forge/pipeline.md](../forge/pipeline.md); files on disk in [../data/project-yml.md](../data/project-yml.md),
[../data/task-yml.md](../data/task-yml.md), [../data/sessions.md](../data/sessions.md),
[../data/app-storage.md](../data/app-storage.md); `RPCPeer`, `Topic` and `WireCoding` in
[../protocol/envelope.md](../protocol/envelope.md); wire types in [../protocol/types.md](../protocol/types.md).

## 1. Objects

`HostService.init` creates every host object once; they live as long as the app. `start()` activates them and
`stop()` deactivates them. The services of this doc and of [files.md](files.md) and [search.md](search.md)
are actors initialized with `host: HostService` (a strong reference, kept for the app's life)
and reach each other through the host's properties. The services of other docs are initialized as their docs say:
`SessionService`, `SkillsService` and `MCPServer` with the host as their host protocol (§12); `MeshService`,
`MigrationService` and `ForgeService` with the `HostService` itself (`MeshService` also receives `appSupport`,
`settings`, `credentialStore` and `options`, §2).

Every object is created with the host, and an actor can pass `self` only once all its stored properties are set, so
`init` runs in two phases: it sets its stored properties (`appSupport`, `settingsStore`, `credentialStore` and
`options`), then creates the objects of the table with `host: self` and stores them once, behind a lock. The
properties of the table are `nonisolated` computed properties that read that storage (§2). A property is `public` when
its type is public (`EventHub`, `UploadService`, `MeshService`, `MigrationService`, `SessionService`, `MCPServer`,
`SkillsService`, `ForgeService`); the others are internal, like their types.

| Property    | Type               | Doc                                     | Role                                             |
|-------------|--------------------|-----------------------------------------|--------------------------------------------------|
| `events`    | `EventHub`         | this doc §5                             | event delivery to connections                    |
| `registry`  | `ProjectRegistry`  | this doc §6                             | hosted projects, `projects.json`, write queues   |
| `watcher`   | `FileWatcher`      | this doc §11                            | FSEvents → events                                |
| `projects`  | `ProjectService`   | this doc §7                             | `projects.*` except `projects.migrate`           |
| `tasks`     | `TaskService`      | this doc §8                             | `tasks.*`, `attachments.read`, task cache        |
| `bundles`   | `BundleService`    | [bundles.md](bundles.md)                | `bundles.*`, worktrees, bundle coordinators      |
| `tabs`      | `TabService`       | this doc §9                             | `tabs.*`                                         |
| `hostInfo`  | `HostInfoService`  | this doc §10                            | `host.info`, `host.listDirectories`              |
| `files`     | `FileService`      | [files.md](files.md)                    | `files.*`                                        |
| `uploads`   | `UploadService`    | [files.md](files.md) §7                 | `uploads.*`, upload store                        |
| `search`    | `SearchService`    | [search.md](search.md)                  | `search.query`                                   |
| `mesh`      | `MeshService`      | [mesh.md](../devices/mesh.md)           | listener, Bonjour, pairing, registry, peer links |
| `migration` | `MigrationService` | [migration.md](../devices/migration.md) | `projects.migrate`, `migration.*`                |
| `sessions`  | `SessionService`   | [cli.md](../claude/cli.md)              | `sessions.*`, session processes                  |
| `mcp`       | `MCPServer`        | [mcp.md](../claude/mcp.md)              | loopback MCP server                              |
| `skills`    | `SkillsService`    | [skills.md](../claude/skills.md)        | `skills.*`, skills sync                          |
| `forge`     | `ForgeService`     | [pipeline.md](../forge/pipeline.md)     | `forge.*`, Forge pipeline                        |

## 2. API surface

```swift
// HostService.swift
public actor HostService {
    /// The app's instance, created at launch by makeShared before any other use.
    @MainActor public private(set) static var shared: HostService!
    @MainActor public static func makeShared(appSupport: AppSupport, settings: SettingsStore,
                                             credentialStore: any MeshCredentialStore) -> HostService
    /// Creates every host object (§1). Tests pass an AppSupport on temporary folders (with its own Trash), an
    /// InMemoryCredentialStore and test options; the app passes HostOptions().
    public init(appSupport: AppSupport, settings: SettingsStore, credentialStore: any MeshCredentialStore,
                options: HostOptions = HostOptions())

    public enum State: Sendable { case stopped, starting, running, stopping }
    public private(set) var state: State
    /// Set when the network listener could not start (§3.1) or could not be replaced after a key change (§3.3); nil
    /// otherwise.
    public private(set) var listenerError: String?
    /// True when the last start() found projects.json unreadable and reset it (§6.2); the app shows a banner.
    public private(set) var projectsFileWasReset: Bool

    public func start() async throws                 // Main toggle on, or app launch with isMain true
    public func stop() async                         // Main toggle off, leaving the mesh, app termination
    public func restartListener() async              // the listener port setting changed
    /// mesh.boundListenerPort(): the port the network listener is bound to while it runs, kept during the 50 ms tries
    /// of its replacement after a key change (§3.3); nil otherwise.
    public func boundListenerPort() async -> Int?
    /// Sets listenerError: MeshService, when it replaces the listener after a key change (§3.3).
    func setListenerError(_ message: String?)

    /// Serves one connection (network or loopback) until it closes (§4).
    public func accept(_ channel: any MessageChannel) async
    /// LoopbackChannel.makePair(): serves the server end, returns the client end for this Mac's Workspace.
    public func makeLoopbackChannel() async -> any MessageChannel

    /// A session of this Main is starting, running or waitingPermission, or a migration runs
    /// (§12.5).
    public func hasActiveWork() async -> Bool

    /// Runs a method in process exactly as if it came from a connection (§4.4); JSON params and result.
    public func perform(_ method: String, params: Data, context: RequestContext) async throws -> Data
    /// Delivers an event (§5). Every service of this doc emits through it.
    public func emit(_ event: ServerEvent) async
    /// The current device settings (SettingsStore.settings, read on the main actor).
    public func settings() async -> DeviceSettings

    public nonisolated let appSupport: AppSupport
    public nonisolated let settingsStore: SettingsStore
    public nonisolated let credentialStore: any MeshCredentialStore
    // The objects of §1, read from the storage init filled (§1); public when their type is.
    public nonisolated var events: EventHub { get }
    nonisolated var registry: ProjectRegistry { get }
    nonisolated var watcher: FileWatcher { get }
    nonisolated var projects: ProjectService { get }
    nonisolated var tasks: TaskService { get }
    nonisolated var bundles: BundleService { get }
    nonisolated var tabs: TabService { get }
    nonisolated var hostInfo: HostInfoService { get }
    nonisolated var files: FileService { get }
    public nonisolated var uploads: UploadService { get }
    nonisolated var search: SearchService { get }
    public nonisolated var mesh: MeshService { get }
    public nonisolated var migration: MigrationService { get }
    public nonisolated var sessions: SessionService { get }
    public nonisolated var mcp: MCPServer { get }
    public nonisolated var skills: SkillsService { get }
    public nonisolated var forge: ForgeService { get }
}

/// The network side of a HostService in tests (../testing.md); the app uses HostOptions().
public struct HostOptions: Sendable {
    public var listenerHost: String?   // address the network listener binds; nil: every interface
    public var listenerPort: Int?      // replaces the listenerPort setting; 0: any free port; nil: the setting
    public var bonjour: Bool           // false: no Bonjour advertisement, no Bonjour browser for the peer links
    public init(listenerHost: String? = nil, listenerPort: Int? = nil, bonjour: Bool = true)
}

/// Who sends a request. Passed to every handler.
public struct RequestContext: Sendable {
    public var device: DeviceInfo      // the hello device; this Main's DeviceInfo for in-process calls
    public var connectionID: UUID?     // nil for in-process calls
    public var author: String?         // comment author for in-process calls ("Claude" for MCP tools)
    /// An in-process call made as this Main (the MCP tools, [../claude/mcp.md](../claude/mcp.md)).
    public static func local(device: DeviceInfo, author: String?) -> RequestContext
}

/// Implemented by every service whose methods are routed to it (§4.4).
public protocol HostMethodHandler: Actor {
    /// `params`: UTF-8 JSON of the request's params object (`InboundRequest.params`). Returns UTF-8 JSON of the
    /// result object. Throws `ProtocolError`; any other error is converted with `ProtocolError.init(_:)`.
    func handle(method: String, params: Data, context: RequestContext) async throws -> Data
}

/// Any JSON value. Carries JSON through typed APIs unchanged (requests forwarded to other Mains, §12).
enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
}
```

- `makeShared` is called once by the app wiring at launch on macOS, with the app's `SettingsStore` and
  `KeychainCredentialStore.shared` ([../ui/shell.md](../ui/shell.md), [../data/app-storage.md](../data/app-storage.md));
  it creates the instance with `HostOptions()` and stores it in `shared`.
- `options` is passed to `MeshService` ([../devices/mesh.md](../devices/mesh.md#swift-api)), which applies it to the
  network listener and its peer links: `listenerHost` is the address the listener binds; a non-nil `listenerPort`
  replaces the `listenerPort` setting (`0`: any free port, read back with `boundListenerPort()`); `bonjour: false`
  turns off the Bonjour advertisement and the Bonjour browser of the peer links. The host tests pass
  `HostOptions(listenerHost: "127.0.0.1", listenerPort: 0, bonjour: false)` ([../testing.md](../testing.md)).
- The Trash is `appSupport.trashItem` ([../data/app-storage.md](../data/app-storage.md#trash)): every item that the
  services of this doc and of [files.md](files.md) move to the Trash goes through it, so tests that pass
  `AppSupport(root:trashItem:)` never touch the user's Trash.
- Handlers decode params with `WireCoding.decodeJSON` (a failure is `badRequest` "Invalid params for <method>:
  <coding path>.", or "Invalid params for <method>." when the failing member has no coding path) and encode results
  with `WireCoding.encodeJSON`.
- `perform` runs §4.4 from the `RPCMethod` lookup on, with `context`. `hello`, `subscribe` and `unsubscribe` are
  refused with `badRequest` "<method> cannot be performed in process.".
- `JSONValue` decodes a JSON number as `number`; integers up to 2^53 survive the round trip, which covers every
  number of the protocol.

## 3. Lifecycle

`start()`, `stop()` and `restartListener()` are serialized: a call made during a transition waits for it to end.
`start()` while `running` and `stop()` while `stopped` return at once.

### 3.1 start()

`state = .starting`. A Main serves its devices with no window shown, so the host keeps macOS from putting the app in
App Nap (which coalesces timers and lowers I/O priority) with an activity it holds until `stop()`, in a private
property `activity: (any NSObjectProtocol)?`:

```swift
activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                 reason: "Hephaestus is a Main")
```

Then, in this order:

| Step | Action                                                                                                                                                            |
|------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1    | `mesh.ensureMesh()`: creates the mesh when this Mac has no mesh credentials ([mesh.md](../devices/mesh.md))                                                       |
| 2    | `registry.load()` (§6.2), whose result sets `projectsFileWasReset`; then `migration.recover()` ([migration.md](../devices/migration.md#recovery-after-a-restart)) |
| 3    | `watcher.start()` (§11); `uploads.start()` ([files.md](files.md) §7)                                                                                              |
| 4    | `hostInfo.refresh()` (§10)                                                                                                                                        |
| 5    | `mcp.start()`: must run before any session process starts                                                                                                         |
| 6    | `sessions.start()`                                                                                                                                                |
| 7    | `skills.start()`                                                                                                                                                  |
| 8    | `forge.configure(<ForgeConfig>)` (§3.4)                                                                                                                           |
| 9    | `mesh.startListener(acceptor: { await self.accept($0) })`                                                                                                         |
| 10   | `mesh.startAdvertising()`: Bonjour `_hephaestus._tcp` (does nothing when `options.bonjour` is false)                                                              |
| 11   | starts the observers: settings changes (§3.4) and `mesh.peerLinkEvents()` (§12.2)                                                                                 |
| 12   | `mesh.startPeerLinks()`: outgoing links to every other Main of the registry                                                                                       |

`state = .running`.

- A failure of step 9 does not fail `start()`: `listenerError` is set to its message (for example "Port 47100 is
  already in use."), steps 10–12 still run and loopback connections are served. Settings show `listenerError`
  ([../devices/roles.md](../devices/roles.md)).
- A failure of any other step undoes the steps already done, in reverse order (as in §3.2), ends the activity (as at
  the end of §3.2), sets `state = .stopped` and rethrows.

### 3.2 stop()

`state = .stopping`, then:

| Step | Action                                                                                                               |
|------|----------------------------------------------------------------------------------------------------------------------|
| 1    | `mesh.stopPeerLinks()`, `mesh.stopAdvertising()`, `mesh.stopListener()`; the observers of §3.1 step 11 are cancelled |
| 2    | `events.closeAll()`: closes every served connection, network and loopback                                            |
| 3    | `forge.shutdown()`, `skills.stop()`, `migration.stop()`                                                              |
| 4    | `sessions.stopAll()`; waits for it                                                                                   |
| 5    | `mcp.stop()`, `watcher.stopAll()`, `uploads.stop()`, `search.clearCache()`, `registry.unload()`                      |

Then the activity ends (`ProcessInfo.processInfo.endActivity(_:)` with `activity`, then `activity = nil`),
`state = .stopped` and `listenerError = nil`. `projects.json` is kept, so the next `start()` serves the same projects.
Step 4 lasts at most about 5 s (SIGTERM, then SIGKILL after 5 s, [../claude/cli.md](../claude/cli.md)).

### 3.3 restartListener()

Only while `running`: `mesh.stopAdvertising()`, `mesh.stopListener()`, `mesh.startListener(acceptor:)`,
`mesh.startAdvertising()`; `listenerError` is set from the outcome as in §3.1. Established connections and peer links
stay open.

`MeshService` also replaces the listener when the mesh key changes. When that replacement cannot start, it sets
`listenerError` with `setListenerError(_:)` and keeps trying; a start that succeeds clears it
([../devices/mesh.md](../devices/mesh.md#receiving-a-new-key), key-change reaction step 2).

### 3.4 Settings changes

- The `ForgeConfig` passed to `forge.configure` is built from the `forge` settings
  ([../data/app-storage.md](../data/app-storage.md)), with `repository` = `ForgeConfig.publicRepository`
  ([../protocol/types.md](../protocol/types.md#forgeconfig)), when `forge.enabled` is true, and is `nil` otherwise.
- While `running`, the host iterates `settingsStore.changes()` and compares each value with the previous one: a
  change of any `forge` key → `forge.configure(...)`; a change of `claudePath` → `hostInfo.refresh()`. The Settings
  screen only writes the settings; `listenerPort` changes are applied by `restartListener()`, which the app wiring
  calls ([../ui/shell.md](../ui/shell.md)).

## 4. Connections

### 4.1 Accepting

`accept(_:)` is called by `MeshService` for each accepted network connection and by `makeLoopbackChannel()` for the
loopback. When `state` is not `.running`, the channel is closed at once. Otherwise the host:

1. creates an `RPCPeer` on the channel ([../protocol/envelope.md](../protocol/envelope.md)) and a `connectionID`
   (new UUID);
2. sets the peer's request handler to the handshake and dispatch below;
3. consumes `peer.events`: an event received before the handshake closes the connection; later events are ignored
   (clients send no events);
4. runs `peer.run()` until the connection closes, then performs §4.3.

Requests of one connection are handled concurrently (`RPCPeer` starts one task per request).

### 4.2 Handshake

The first request must be `hello` ([../protocol/methods.md](../protocol/methods.md)). Before it succeeds, a request
other than `hello`, or an event, closes the connection without a reply; responses and malformed frames are ignored.
When no `hello` has arrived 10 s after `accept`, the connection is closed.

| Check, in order                                           | Error response, then close                             |
|-----------------------------------------------------------|--------------------------------------------------------|
| params decode as `HelloParams`                            | `badRequest` "Invalid hello"                           |
| `protocolVersion == WireCoding.protocolVersion`           | `badRequest` "Unsupported protocol version <n>"        |
| `device.isMain` is false, or `device.platform` is `macOS` | `badRequest` "Only a Mac can be a Main"                |
| `device.id` is not revoked (`mesh.isRevoked(_:)`)         | `unauthorized` "This device was removed from the mesh" |

`<n>` is the received `protocolVersion`. The texts are those of [../protocol/methods.md](../protocol/methods.md#hello).

On success, in this order:

1. The connection becomes authenticated with `device`; it is a peer link when `device.isMain` is true.
2. `events.add(connectionID, peer:)`: from now on it receives broadcast events, possibly before the `hello` response.
3. The handler returns `HelloResult {device: await mesh.localDevice(), mesh: await mesh.snapshot()}`, which `RPCPeer`
   sends.
4. Right after, in a new task: `mesh.connectionOpened(device:connectionID:peer:)` (presence and the registry record,
   [mesh.md](../devices/mesh.md#admission-hello)).

- A device id unknown to the registry is accepted: the TLS-PSK handshake already proved mesh membership.
- Several connections from the same device are allowed.
- A second `hello`, on an authenticated connection or while the first one is being handled: `badRequest` "Already
  authenticated"; the connection stays open.

### 4.3 Closing

When the connection closes (either side, keep-alive timeout, `stop()`): `events.remove(connectionID)` (drops its
subscriptions) and `mesh.connectionClosed(connectionID:)`. Requests in progress run to their end; their responses are
dropped by `RPCPeer`.

### 4.4 Dispatch

For each request of an authenticated connection, and for `perform`:

1. `RPCMethod(rawValue: method)`: `nil` → `badRequest` "Unknown method <name>.".
2. Callers ([../protocol/methods.md](../protocol/methods.md#callers)): a `mainPeers` method from a connection whose
   `hello` had `device.isMain == false` → `unauthorized` "Main only"; `mesh.rekey` (callers `servingMain`) →
   `badRequest` "mesh.rekey is not served by a Main". In-process calls count as a Main.
3. The handler of the table is called. Write methods (column W) are refused with `locked` while the project is
   migrating: the handlers do it through `ProjectRegistry.write` or `checkWritable` (§6.8).
4. A thrown error becomes the error response with `ProtocolError.init(_:)`; a `DataError` is mapped as in §6.9 first.
   Errors of code `internal` are logged.

| Methods                                           | Handler                                           |
|---------------------------------------------------|---------------------------------------------------|
| `hello`, `subscribe`, `unsubscribe`               | `HostService` (§4.2, §4.5)                        |
| `mesh.*`, `pairing.*`                             | `mesh`                                            |
| `host.*`                                          | `hostInfo`                                        |
| `projects.*` except `projects.migrate`            | `projects`                                        |
| `projects.migrate`, `migration.*`                 | `migration`                                       |
| `uploads.*`                                       | `uploads`                                         |
| `tasks.*`, `attachments.read`                     | `tasks`                                           |
| `files.*`                                         | `files`                                           |
| `tabs.*`                                          | `tabs`                                            |
| `sessions.*` (`sessions.readAttachment` included) | `sessions`                                        |
| `search.query`                                    | `search`                                          |
| `skills.*`                                        | `skills`                                          |
| `forge.*`                                         | `HostService`, which calls `ForgeService` (below) |

Every handler except `ForgeService` conforms to `HostMethodHandler`. `HostService` decodes the `forge.*` params and
calls: `forge.feedback` → `forge.feedback(screenshot:comment:context:from: context.device.id)`; `forge.status` →
`forge.status()`; `forge.regenerate` → `forge.regenerate()`; `forge.retry` → `forge.retry(itemTaskID:)`.

Every handler resolves the `projectID` param with `registry.hosted(_:)`, which throws `notFound` "Project <id> is not
hosted on this Main." ([../protocol/methods.md](../protocol/methods.md), errors common to all methods).

### 4.5 Subscriptions

`subscribe {topics}` and `unsubscribe {topics}` → `EmptyPayload`. Each topic string is parsed with
`Topic(rawValue:)` ([../protocol/envelope.md](../protocol/envelope.md)); one that does not parse fails the request with
`badRequest` "Invalid topic <topic>" and no topic is applied. Then `events.subscribe(connectionID, topics)` or
`events.unsubscribe(connectionID, topics)`. Topics are not checked for existence; subscribing twice or unsubscribing a
topic not subscribed changes nothing.

## 5. Events

```swift
// EventHub.swift
public actor EventHub {
    init(host: HostService)                                // §1; the hub keeps no reference to it
    func add(_ connectionID: UUID, peer: RPCPeer)          // the connection passed hello
    func remove(_ connectionID: UUID)                      // the connection closed; drops its subscriptions
    func closeAll()                                        // stop(): closes every connection and forgets it
    func subscribe(_ connectionID: UUID, _ topics: [Topic])
    func unsubscribe(_ connectionID: UUID, _ topics: [Topic])
    /// An event whose `topic` is nil: sent to every authenticated connection.
    public func broadcast(_ event: ServerEvent)
    /// An event with a topic: sent to the connections subscribed to `event.topic`.
    public func publish(_ event: ServerEvent)
}
```

- Both encode the event once (`event.encodeFrame()`) and send the frame with `RPCPeer.emit(frame:)` to each target.
  An event that fails to encode is dropped and logged. They return once the frames are queued and never wait for a
  client.
- Broadcast targets are every authenticated connection: remotes, peer links and the loopback
  ([../protocol/envelope.md](../protocol/envelope.md#delivery-rules)). Which event is which:
  [../protocol/events.md](../protocol/events.md). `broadcast` given an event with a topic, or `publish` given one
  without, logs an error and sends nothing.
- `HostService.emit(_:)` calls `publish` when `event.topic` is set and `broadcast` otherwise. Then, for
  `sessionChanged`, it records the session's pending permission count with
  `registry.setPendingPermissions(projectID, sessionID: session.id, count: session.pendingPermissions.count)`, and
  for `sessionRemoved` with `count: 0` (§6.1). For `sessionChanged` it then calls
  `bundles.sessionChanged(projectID:session:)` ([bundles.md](bundles.md#observing-the-task-sessions)). Last, it
  notifies the Forge of the events it follows ([../forge/pipeline.md](../forge/pipeline.md)): `sessionChanged` →
  `forge.sessionChanged(projectID:session:)`, `sessionRemoved` → `forge.sessionRemoved(projectID:sessionID:)` (the
  id's `uuidString`), `taskChanged` → `forge.taskChanged(projectID:task:)`, `taskRemoved` →
  `forge.taskRemoved(projectID:taskID:)`. The services of this doc, of [files.md](files.md), [bundles.md](bundles.md)
  and [search.md](search.md), the host protocol requirements (§12) and the Forge emit through
  `emit`; other services may call `events.broadcast` directly for events the Forge does not follow (`mesh.changed`,
  `migration.progress`).
- Events given in sequence by one caller reach each connection in that order (each channel sends its frames in order).
  Events are not stored.

## 6. ProjectRegistry

The registry holds the hosted projects in memory: the top-level projects of `projects.json` and their sub projects,
found through each parent's `subprojects`, recursively.

```swift
// Projects/ProjectRegistry.swift
struct HostedProject: Sendable {
    let id: String              // project identifier = projectID
    let root: URL               // standardized path, as registered (projects.json form, symlinks not resolved)
    let realRoot: URL           // realpath(3) of root (below): path checks and FSEvents matching
    let parentID: String?       // nil for a top-level project
    var file: ProjectFile       // last valid project.yml (../data/project-yml.md)
    var modified: Date          // modification date of project.yml when `file` was read
    var parseError: String?     // set while project.yml on disk is invalid (§6.6)
    var migrating: Bool
    var pendingPermissions: [UUID: Int]   // pending permission requests per session of the project (§6.1)
}

actor ProjectRegistry {
    func load() async -> Bool                                  // start() step 2; true: projects.json was reset (§6.2)
    func unload()                                              // stop() step 5
    func hosted(_ projectID: String) throws -> HostedProject   // notFound when not hosted
    func all() -> [HostedProject]                              // every project, any level
    func children(of projectID: String) -> [HostedProject]     // registered direct sub projects, subprojects order
    func descendants(of projectID: String) -> [String]         // ids of every nested sub project
    func summaries() -> [ProjectSummary]                       // projects.list (§7.1)
    func project(_ projectID: String) async throws -> Project  // wire Project (§6.1); awaits tasks.highestNumber
    /// Every registered project whose realRoot contains `absolutePath`, deepest first, with the relative path.
    func containing(_ absolutePath: String) -> [(projectID: String, relativePath: String)]

    func register(root: URL, parentID: String?) async throws -> HostedProject
    func unregister(_ projectID: String, forget: Bool) async
    /// Migration recovery: unregisters the top-level project registered at `rootPath` (forget: true); with none,
    /// removes `rootPath` from projects.json and unwatches it (§6.5).
    func forgetRoot(_ rootPath: String) async
    func reloaded(_ projectID: String, file: ProjectFile, modified: Date) async   // file read or written (§6.6)
    func markInvalid(_ projectID: String, error: String) async                    // file found invalid (§6.6)
    func setMigrating(_ projectID: String, _ migrating: Bool) async
    func setPendingPermissions(_ projectID: String, sessionID: UUID, count: Int) async   // §5, §6.1
    func checkWritable(_ projectID: String) throws
    func write<T: Sendable>(_ projectID: String,
                            _ body: @Sendable (HostedProject) async throws -> T) async throws -> T
    func checkIdentifiersAvailable(_ identifiers: [String]) async throws
}
```

`ProjectFile`, `ProjectFile.load/create/update`, `ProjectIdentifier` and the path normalization are defined in
[../data/project-yml.md](../data/project-yml.md); `ProjectsFile` (`projects.json`) in
[../data/app-storage.md](../data/app-storage.md). The registry is the only writer of `projects.json`.

Real paths: wherever this doc and [files.md](files.md) say "realpath(3)" or "symlinks resolved", the path is resolved
with `realpath(3)` (`ClaudePathEncoding.canonicalPath`, [../devices/migration.md](../devices/migration.md#swift-api)),
which gives the `/private/var/…` and `/private/tmp/…` forms that FSEvents reports. `URL.resolvingSymlinksInPath()` and
`URL.standardizedFileURL` are never used for these checks: both turn `/private/var/…` into `/var/…` and `/private/tmp`
into `/tmp`. `realRoot` is the realpath(3) of `root` when the project is registered.

### 6.1 Wire values

Built as [../data/project-yml.md](../data/project-yml.md) ("Mapping to the protocol") says, with the host fields:

| Field                    | Value                                                                                                     |
|--------------------------|-----------------------------------------------------------------------------------------------------------|
| `deviceID`               | this Main's device id                                                                                     |
| `rootPath`               | `root.path`                                                                                               |
| `migrating`              | the project's flag, or its top-level project's flag                                                       |
| `parseError`             | `parseError`                                                                                              |
| `children`               | `ProjectSummary` only: `children(of:)` as summaries, recursively                                          |
| `pendingPermissionCount` | `ProjectSummary` only: the sum of `pendingPermissions` (the project's own sessions, not its sub projects) |
| `taskCounter`            | `Project` only: `max(file.taskCounter, tasks.highestNumber(projectID:feedback: false))`                   |
| `feedbackCounter`        | `Project` only: `max(file.feedbackCounter, tasks.highestNumber(projectID:feedback: true))`                |

`setPendingPermissions(_:sessionID:count:)` stores the count of one session (`0` removes the entry); when the
project's sum changed it emits `projectsChanged`. It does nothing for a project that is not registered. The counts come
from the `SessionInfo.pendingPermissions` of every `session.changed` the host emits (§5), so clients rebuild their
permission indicators from `projects.list` after a reconnect.

### 6.2 load()

1. `ProjectsFile.load(appSupport)` ([../data/app-storage.md](../data/app-storage.md#projectsjson)) returns the file
   and `wasReset`: an unreadable `projects.json` has been renamed to `projects.json.unreadable` (replacing an older one)
   and reads as no projects. When `wasReset` is true it is logged, the registry starts empty and `load()` returns true,
   which sets `HostService.projectsFileWasReset`; the app then shows the banner of
   [../ui/shell.md](../ui/shell.md) ("projects.json was unreadable and has been reset; folders are untouched").
2. For each path: a missing folder, or a missing or invalid `.hephaestus/project.yml`, is logged and skipped; the path
   stays in `projects.json` and the project is registered when its file becomes valid (§11.2).
3. Every other path is registered with §6.4, then its sub projects (§6.3), except that `load()` emits no event and
   does not rewrite `projects.json`.

### 6.3 Sub project paths

Each `subprojects` entry is normalized by `ProjectFile.normalizedRelativePath`; the sub project's root is the parent's
`root` + the entry. Its realpath(3) must be strictly inside the parent's `realRoot`. An entry that breaks this, or whose
folder has no valid project.yml, is logged and not registered; it stays in the YAML.

### 6.4 register(root:parentID:)

Used by `load()`, `ProjectService` (create, import), `MigrationService` (the destination's commit), `FileWatcher` (a
project.yml that appears or becomes valid) and `reloaded` (an entry added to `subprojects`).

1. `ProjectFile.load(projectRoot: root)`: a `DataError` is thrown as it is (§6.9).
2. `conflict` "<path> is already a project of this Main." when `realRoot` equals the `realRoot` of a registered project;
   `conflict` "Identifier <id> is already used by <name> on this Main." when a registered project has the identifier
   (this check is local; the mesh check is §6.7).
3. Stores the `HostedProject`, creates its `ProjectWriteQueue`, calls `tasks.load(projectID:)` and
   `bundles.load(projectID:)`.
4. Registers its sub projects (§6.3); a sub project that fails a check is logged and skipped.
5. Top-level only: `ProjectsFile.add(root.path)` and save; `watcher.watch(root)`.
6. Emits `projectsChanged {deviceID, projects: summaries()}`.

### 6.5 unregister(_:forget:)

Removes the project and its descendants from memory, with their task and bundle caches (`tasks.unload`,
`bundles.unload`) and write queues (operations still queued fail with `notFound`). With `forget == true` (project
removed or moved away) it calls `bundles.removeWorktrees(projectID:)` for each of them
([bundles.md](bundles.md#projects-removed-or-moved)), and for a top-level project it also removes the path from
`projects.json` and calls `watcher.unwatch(root)`. With `forget == false`
(project.yml or folder gone, §11) both stay. Emits `projectsChanged`. Unregistering a project that is not registered
does nothing.

`forgetRoot(_:)` serves the migration recovery
([../devices/migration.md](../devices/migration.md#recovery-after-a-restart)), which knows a project by the root path
its journal recorded: the top-level project whose `root.path` equals `rootPath` is unregistered with `forget: true`;
when none is registered (its folder or project.yml is missing), `rootPath` is removed from `projects.json` and
`watcher.unwatch` is called for it.

### 6.6 Reload and invalid file

`reloaded(_:file:modified:)` is called by every writer right after it wrote project.yml (with the file as written) and
by the watcher after it read a valid file:

1. Replaces `file` and `modified`; clears `parseError`.
2. When the wire `Project` differs from the previous one: emits `projectChanged {project}`.
3. When the project's own `ProjectSummary` fields (`name`, `description`, `parseError`) or its `subprojects` differ:
   emits `projectsChanged`.
4. Entries added to `subprojects` are registered (§6.4); sub projects whose entry was removed are unregistered
   (`forget: false`). No file is written.

`markInvalid(_:error:)` is called by the watcher when project.yml on disk is invalid, including a valid file whose
`id` differs from the registered one (message "project.yml: the project identifier cannot change", the `<file name>:
<problem>` form of [../data/project-yml.md](../data/project-yml.md)): the last valid `file` stays and is served,
`parseError` = the message, and when `parseError` changed, `projectChanged` and `projectsChanged` are emitted.
While `parseError` is set, every write of project.yml fails (`ProjectFile.update` reads the invalid file and throws
`.refused`), and the file is never overwritten ([../data/project-yml.md](../data/project-yml.md#invalid-file)).

### 6.7 checkIdentifiersAvailable(_:)

Used by `projects.create` (one identifier) and `projects.import` (the project's and those of the sub projects its file
lists).

1. Local: a registered project with one of the identifiers → `conflict` "Identifier <id> is already used by <name> on
   this Main.".
2. Mesh: for every Main in `mesh.connectedPeerMains()`, in parallel, `projects.list` through
   `mesh.requestPeer(_:method:params:as:timeout:)` with `EmptyPayload()`, `ProjectsListResult` and a 5 s timeout.
   Every identifier of the returned trees (`children` included) is compared exactly. A match → `conflict` "Identifier
   <id> is already used by <name> on <Main name>.". A Main that fails or does not answer in 5 s is skipped.

### 6.8 Write serialization

Every change to the files of a project goes through `write(_:_:)`:

1. Takes the project's `ProjectWriteQueue` (`notFound` when the project is not hosted).
2. Enqueues an operation. The operations of one project run one at a time, in submission order; one starts after the
   previous one ended, successfully or not. Each project, sub projects included, has its own queue.
3. When the operation starts: re-reads the `HostedProject` (`notFound` when unregistered meanwhile), runs
   `checkWritable`, then `body` with it.

```swift
// Projects/ProjectWriteQueue.swift
actor ProjectWriteQueue {
    func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T
}
```

- `checkWritable(_:)` throws `locked` "<name> is being moved to another Main." when the project or one of its
  ancestors is `migrating`, <name> being the name of that migrating project.
- Writers: `files.write`, `files.create`, `files.rename`, `files.delete`, every task change, `tabs.*`,
  `projects.update`, the parent update of `projects.create` and `projects.remove`, task id allocation, and every
  write of other areas into a project folder, except session storage (`.hephaestus/sessions/`), which
  `SessionService` writes through its `SessionArchive` after `checkWritable` ([../claude/cli.md](../claude/cli.md)).
- Each writer re-reads from disk what it changes (the read-modify-write of
  [../data/project-yml.md](../data/project-yml.md)), so hand edits and unknown keys are kept.
- `setMigrating(_:true)` runs as an operation of the project's queue (it waits for earlier writes), then sets the flag;
  `setMigrating(_:false)` clears it at once. [../devices/migration.md](../devices/migration.md) calls it for the
  top-level project being moved; the flag locks its sub projects too (`checkWritable` looks at the ancestors, and their
  wire `migrating` follows it, §6.1). Each call emits `projectChanged` for the project and each sub project, and
  `projectsChanged`.

### 6.9 Data errors

The data code throws `DataError` ([../data/app-storage.md](../data/app-storage.md)). The host answers with:

| `DataError`   | Protocol error                                                                                                  |
|---------------|-----------------------------------------------------------------------------------------------------------------|
| `.notFound`   | `notFound`                                                                                                      |
| `.invalid`    | `badRequest`                                                                                                    |
| `.refused`    | `conflict` (an invalid project.yml or a broken task, as [../protocol/methods.md](../protocol/methods.md) lists) |
| `.unreadable` | `unavailable`                                                                                                   |
| `.io`         | `internal`                                                                                                      |

The message is the `DataError` message.

## 7. ProjectService

```swift
// Projects/ProjectService.swift
actor ProjectService: HostMethodHandler {
    init(host: HostService)
    func list() async -> [ProjectSummary]
    func snapshot(projectID: String) async throws -> ProjectsSnapshotResult
    func create(_ params: ProjectsCreateParams) async throws -> ProjectSummary
    func importFolder(_ params: ProjectsImportParams) async throws -> ProjectSummary
    func update(projectID: String, patch: ProjectPatch) async throws -> Project
    func remove(projectID: String, moveToTrash: Bool) async throws
}
```

Names are validated with `ProjectFile.validatedName` and identifiers with `ProjectIdentifier.validated`
([../data/project-yml.md](../data/project-yml.md)); their `DataError.invalid` becomes `badRequest`.

### 7.1 projects.list

`{projects: registry.summaries()}`: the top-level projects ordered by name with `localizedStandardCompare`, each with
its sub projects in `children`.

### 7.2 projects.snapshot

`project`: `registry.project(projectID)`; `tasks`: `tasks.list(projectID:)` (by task number); `bundles`:
`bundles.list(projectID:)` (by bundle number); `sessions`:
`sessions.sessions(projectID:)` reordered by `created` ascending. Served while the project is migrating.

### 7.3 projects.create

1. `name` and `identifier` validated.
2. Folder: `folderName`, by default `name` with `/` and `:` replaced by `-`. Normalized with
   `ProjectFile.normalizedRelativePath` ([../data/project-yml.md](../data/project-yml.md#relative-paths)), so `./Atlas/`
   becomes `Atlas`; `nil`, `.` or a first component `.hephaestus` → `badRequest` "Invalid folder name.".
3. Base: without `parentID`, `settings().projectsFolderURL` (created with its intermediate folders when missing); with
   `parentID`, the parent's `root` (`notFound` when not hosted; `registry.checkWritable(parentID)`: `locked` while it
   migrates). While `settings().forge.enabled` is true, a `parentID` that is `forge.sourceProjectID` or one of its sub
   projects (`registry.descendants(of:)`) fails with `badRequest` "The Forge source project is a public repository:
   create this project elsewhere.": its folder is the public repository
   ([../public-repository.md](../public-repository.md)).
4. Target = base + folder, standardized: the root to register. With `realBase` = the realpath(3) of the base,
   `PathResolver(root: realBase).resolve(<folder>)` ([files.md](files.md) §2) must succeed and differ from `realBase`,
   so the target is strictly inside the base with symlinks resolved → else `badRequest` "Invalid folder name.". At the
   target:
   - a folder that holds `.hephaestus/project.yml` → `conflict` "<path> is already a project.";
   - something that is not a folder → `conflict` "<path> already exists.";
   - a folder without `.hephaestus/project.yml` is used as it is; nothing: step 6 creates the folder.
5. `registry.checkIdentifiersAvailable([identifier])`.
6. `ProjectFile.create(ProjectFile(id:name:description:), projectRoot: target)`: writes project.yml (creating the
   folder when missing), `.hephaestus/tasks/` and the docs folder when missing.
7. Top-level: `registry.register(root: target, parentID: nil)`. Sub project: `registry.write(parentID)` with
   `ProjectFile.update(projectRoot: parent root)` appending the normalized folder path to `subprojects` (a `.refused`
   is `conflict`), then `registry.reloaded(parentID, ...)`, which registers the new sub project and emits
   `projectChanged` (parent) and `projectsChanged`.
8. Returns `ProjectSummary` of the new project.

When step 6 or 7 fails, what step 6 created is removed, then the error is returned: the target folder is removed only
when step 6 created it; in a folder that existed before, the `.hephaestus/project.yml` written by step 6 is removed.

### 7.4 projects.import

1. `path`: `~`, or a leading `~/`, is replaced by the home folder (`FileManager.default.homeDirectoryForCurrentUser`);
   any other path must be absolute → else `badRequest` "The path must be absolute.". Standardized; it must be an
   existing folder → else `notFound` "No folder at <path>.".
2. When its realpath(3) is, contains, or is inside the `realRoot` of a registered project → `conflict` "<path>
   overlaps project <name>.".
3. Identifiers to check:
   - with `.hephaestus/project.yml`: `ProjectFile.load` (any failure → `badRequest` with its message); `name` and
     `identifier` are ignored; the file's `id` and the `id` of each listed sub project whose project.yml loads;
   - without it: `name` and `identifier` are required → else `badRequest` "A name and an identifier are required.";
     validated as in §7.3; `identifier`.
4. `registry.checkIdentifiersAvailable(...)`.
5. Without project.yml: `ProjectFile.create(ProjectFile(id:name:description: nil), projectRoot: path)` (project.yml,
   `.hephaestus/tasks/`, and the docs folder when missing, [../data/project-yml.md](../data/project-yml.md#new-file)).
6. `registry.register(root: path, parentID: nil)`, which also registers the listed sub projects.
7. Returns the `ProjectSummary`.

The Forge registers its source project with the same logic, calling `projects.importFolder(_:)` in process
([../forge/pipeline.md](../forge/pipeline.md#registering-the-source-project)).

### 7.5 projects.update

Inside `registry.write(projectID)`: `ProjectFile.update(projectRoot:)` applying each non-nil field of the
`ProjectPatch`, then `registry.reloaded` with the file as written; returns `registry.project(projectID)`.

| Patch field   | Change                                                  |
|---------------|---------------------------------------------------------|
| `name`        | `file.name`                                             |
| `description` | `file.description` (normalization removes an empty one) |
| `skills`      | `file.skills`                                           |
| `claude`      | `file.claude` = the whole block                         |

The rules (names, skill names) are those of `ProjectFile.validate`: a broken rule
is `badRequest` with its message; an invalid file on disk is `conflict`.

### 7.6 projects.remove

1. `registry.checkWritable(projectID)`.
2. For the project and each descendant, concurrently: `sessions.stopAll(projectID:)`; waits for
   all.
3. Top-level project: with `moveToTrash`, `watcher.unwatch(root)` (so the watcher does not unregister the project
   first, §11.2 step 6), then `appSupport.trashItem(realRoot)`; a failure → `watcher.watch(root)` again and
   `unavailable` "Could not move <path> to the Trash: <reason>.", the project stays registered. Then
   `registry.unregister(projectID, forget: true)`.
4. Sub project (instead of step 3): inside `registry.write(parentID)`, one `ProjectFile.update(projectRoot: <parent
   root>)` whose change removes the entry from the parent's `subprojects` and, with `moveToTrash`, moves the sub
   project's folder to the Trash (`appSupport.trashItem(<its realRoot>)`) before the file is written. An invalid
   parent project.yml fails before the change runs (`conflict`, nothing moved); a Trash failure fails the change
   (`unavailable` "Could not move <path> to the Trash: <reason>.", the parent file is not written and the sub project
   stays registered). On success, `registry.reloaded(parentID, ...)`, which unregisters it.

In the Trash messages, <path> is the project's `root` path and <reason> the error's `localizedDescription` without its
final period. After a failure the processes stopped by step 2 stay stopped; nothing else changed.

## 8. TaskService

Task files, `TaskID`, `TaskFile`, broken tasks, id allocation and attachment storage are defined in
[../data/task-yml.md](../data/task-yml.md).

```swift
// Tasks/TaskService.swift
actor TaskService: HostMethodHandler {
    init(host: HostService)
    // cache
    func load(projectID: String) async                    // TaskFile.loadAll for a registered project
    func unload(projectID: String)
    func list(projectID: String) throws -> [TaskItem]     // by task number
    func task(projectID: String, taskID: String) throws -> TaskItem
    func highestNumber(projectID: String, feedback: Bool) -> Int  // largest cached number of the series, 0 when none
    // methods (context.author and the peer-link `author` param decide comment authors)
    /// feedback: true for the Forge's feedback tasks (<projectID>-F<n>); tasks.create passes false.
    func create(projectID: String, name: String, description: String?, status: TaskStatus?,
                feedback: Bool = false) async throws -> TaskItem
    func update(projectID: String, taskID: String, patch: TaskPatch) async throws -> TaskItem
    func delete(projectID: String, taskID: String) async throws
    func addComment(projectID: String, taskID: String, body: String, attachments: [UploadRef],
                    author: String) async throws -> TaskItem
    func updateComment(projectID: String, taskID: String, commentID: UUID, body: String) async throws -> TaskItem
    func deleteComment(projectID: String, taskID: String, commentID: UUID) async throws -> TaskItem
    func readAttachment(projectID: String, taskID: String, fileName: String, offset: Int?,
                        length: Int?) async throws -> AttachmentsReadResult
    // FileWatcher (§11.3)
    func reload(projectID: String, taskID: TaskID) async
    func rescan(projectID: String) async
}
```

- The cache holds the `TaskItem` of every task file of every registered project, valid or broken (mapping of
  [../data/task-yml.md](../data/task-yml.md#mapping-to-taskitem)).
- A `taskID` that `TaskID(_:)` does not parse with the project's identifier, or without a task file: `notFound` "Task
  <id> does not exist.".
- Every change runs inside `registry.write(projectID)` with the `TaskFile` functions listed below, stores the new
  `TaskItem` in the cache, and emits `taskChanged {projectID, task}` when it differs from the cached one (a deletion
  emits `taskRemoved {projectID, taskID}`). The file watcher then finds the file equal to the cache and emits nothing
  for it (§11.3).
- A change of a broken task other than deletion: `TaskFile.update` throws `.refused` → `conflict`.
- The functions throw `ProtocolError` only: `TaskService` maps `DataError` itself (§6.9), so in-process callers (the
  Forge, §12.4) get the errors a client gets. A task file that disappears during a change (`TaskFile`'s
  `.notFound("task <id> not found")`) is `notFound` "Task <id> does not exist." too.

Methods (`TaskFile` calls and rules):

- `tasks.create`: name validated (`badRequest`); `allocateID(projectRoot:feedback:)` with the given `feedback`
  (false for the request), then `create`; `registry.reloaded` with the new project.yml.
- `tasks.update`: `update` with the non-nil `TaskPatch` fields; `name` trimmed, not empty and on one line, with no
  maximum length (`badRequest`).
- `tasks.delete`: `delete` (also for a broken task).
- `tasks.addComment`: below.
- `tasks.updateComment`: `update` whose change finds the comment in the file it read (`.notFound("comment <id> not
  found")` when missing), throws `ProtocolError(.badRequest, "Claude's comments cannot be edited.")` when the
  comment's `author` is `Claude` (nothing is written), and otherwise sets the comment's `body` and `edited` = now. An
  empty trimmed body on a comment without attachments → `badRequest` "The comment is empty.".
- `tasks.deleteComment`: every comment, Claude's included: `update` removing the comment, then `deleteAttachment` for
  each of its files that no other comment names.
- `attachments.read`: `attachmentURL` (`badRequest` for a name that is not one path component, `notFound` when
  missing); `offset` (default 0) below 0 or above the file's size → `badRequest` "Invalid offset <offset> for
  <fileName>."; `length` (default `MethodLimits.maxChunkSize`) below 1 → `badRequest` "Invalid length."; a `length`
  above `maxChunkSize` counts as `maxChunkSize`. The file is opened with `FileHandle`, positioned at `offset`, and
  `min(length, size − offset)` bytes are read. Result: those bytes, the file's `size`, and `mimeType` = the `type` of
  the entry naming the file, else
  `AttachmentNaming.mimeType(forFileName:)`. Any file size is accepted.

`tasks.create` emits `taskChanged` and, through `reloaded`, `projectChanged` (the counter). Allocation fails with
`conflict` while project.yml is invalid.

`tasks.addComment`:

Inside `registry.write(projectID)`:

1. The body trimmed is empty and there is no attachment → `badRequest` "The comment is empty.". The task exists
   (`notFound`) and its cached `TaskItem` is not broken (`conflict`, "The file is invalid: <parse error>").
2. `uploads.claim(attachments, projectID:)` ([files.md](files.md) §7.3): the upload errors of
   [../protocol/methods.md](../protocol/methods.md#using-uploads); nothing is stored.
3. Each claimed upload, in order: `TaskFile.storeAttachment(fileAt: <its url>, originalName: <its fileName>,
   projectRoot:id:)`, which moves the file into `.hephaestus/attachments/<task id>/`.
4. `TaskFile.update` appending the comment: `id` new UUID, `author`, `created` now, `body`, the stored attachments.
5. Success: `uploads.finish(<claimed>)`. When step 3 or 4 fails, the files stored by step 3 are moved back to their
   uploads (`attachmentURL` → `ClaimedUpload.url`, [files.md](files.md) §7.3), `uploads.release(<claimed>)`, and the
   error is returned. The uploads stay usable.

Author of a new comment: the `author` param when the request comes from a peer link (`device.isMain`) and sets it;
else `context.author` when set (in-process calls: `Claude` for MCP tools); else the name of the caller's record in
`mesh.snapshot()`; else `context.device.name`.

Watcher entry points:

- `reload(projectID:taskID:)`: `TaskFile.loadOne`. `nil` (file gone): when cached, removed and `taskRemoved` emitted.
  Otherwise the `TaskItem` is stored and `taskChanged` emitted when it differs from the cache or was not cached.
- `rescan(projectID:)`: `TaskFile.loadAll`, applied like `reload` to every task of the result and every cached task.

## 9. TabService

Web tabs are the `webTabs` of project.yml ([../ui/web.md](../ui/web.md)).

```swift
// Tabs/TabService.swift
actor TabService: HostMethodHandler {
    init(host: HostService)
    func list(projectID: String) async throws -> [WebTab]    // from the cached file, in tab strip order
    func open(projectID: String, url: String, title: String?, locked: Bool?) async throws -> WebTab
    func update(projectID: String, tabID: UUID, patch: WebTabPatch) async throws -> WebTab
    func close(projectID: String, tabID: UUID) async throws
    func move(projectID: String, tabID: UUID, toIndex: Int) async throws
}
```

Every method except `list` runs inside `registry.write(projectID)` as one `ProjectFile.update` (an invalid project.yml
is `conflict`), then `registry.reloaded`, which emits `projectChanged`.

| Method        | Change                                                                 |
|---------------|------------------------------------------------------------------------|
| `tabs.open`   | appends `{id: new UUID, title: <title>, url, locked: locked ?? false}` |
| `tabs.update` | sets the non-nil fields of the patch, its `title` as <title>           |
| `tabs.close`  | a locked tab → `locked` "This tab is locked."; otherwise removes it    |
| `tabs.move`   | moves the tab to `toIndex` clamped to `0…count−1`                      |

- `url` (of `tabs.open`, and of the patch when set) is trimmed; it must be `about:blank` (the New Tab of
  [../ui/web.md](../ui/web.md)) or an absolute `http` or `https` URL with a host (`URL(string:)`, scheme compared
  case-insensitively, `host` not empty) → else `badRequest` "Only http and https addresses can be opened".
- `<title>`: the given `title`; <host> when it is empty, or absent from `tabs.open`.
- `<host>`, the default title of [../protocol/methods.md](../protocol/methods.md#web-tabs): the `host` of the tab's URL
  (`URL(string:)?.host`, after the change for `tabs.update`), or the URL itself when it has none (`about:blank`).
- An unknown `tabID` → `notFound` "Tab <id> does not exist.".

## 10. HostInfoService

```swift
// HostInfo.swift
actor HostInfoService: HostMethodHandler {
    init(host: HostService)
    func refresh() async                  // start() step 4, and when claudePath changes
    var gitAvailable: Bool { get }
    var claudePath: String? { get async } // ClaudeLocator.shared.lastResolvedPath (an actor)
}
```

`refresh()`: `await ClaudeLocator.shared.resolve(configured: settings().claudeURL)`
([../claude/cli.md](../claude/cli.md)), then `gitAvailable` without running git (on a Mac without the Command Line
Tools, running `/usr/bin/git` opens an install dialog): the first executable file named `git` in the directories of
the login environment's `PATH` (`LoginEnvironment.shared.environment()`), in order; none → `false`; another path than
`/usr/bin/git` → `true`; `/usr/bin/git` → `true` when `/usr/bin/xcode-select -p` exits with status 0
(`ChildProcess.capture` with the login environment, in the home folder, timeout 5 s); a timeout, or a failure to run
it (logged), is `false`.

### 10.1 host.info

| Field             | Value                                              |
|-------------------|----------------------------------------------------|
| `device`          | `await mesh.localDevice()`                         |
| `projectsFolder`  | `settings().projectsFolderURL.path`                |
| `claudeAvailable` | `claudePath != nil`                                |
| `claudePath`      | `claudePath ?? ""`                                 |
| `gitAvailable`    | `gitAvailable`                                     |
| `forge`           | `await forge.config()`: set only on the Forge host |

### 10.2 host.listDirectories

1. `path` `""` is the home folder (`FileManager.default.homeDirectoryForCurrentUser`). `~`, or a leading `~/`, is
   replaced by the home folder; any other `path` must be absolute → else `badRequest` "The path must be absolute.".
2. The path is standardized; not an existing folder → `notFound` "No folder at <path>.".
3. Its realpath(3) (§6) must be the realpath(3) of the home folder or inside it → else `badRequest` "Only folders
   inside the home folder can be listed.".
4. A folder that cannot be read (permissions, privacy protection) → `unavailable` with the system's message.
5. Result: `path` = the realpath(3) of the folder; `entries` = its subfolders whose names do not start with `.`, a
   symlink counting when its realpath(3) is a folder inside the home folder, ordered by name with
   `localizedStandardCompare`; each `DirectoryEntry {name, path: <path>/<name>}`.

## 11. FileWatcher

```swift
// Projects/FileWatcher.swift
actor FileWatcher {
    init(host: HostService)
    func start() async               // watch(_:) for every path of projects.json whose folder exists
    func watch(_ root: URL)          // no-op when already watched
    func unwatch(_ root: URL)        // no-op when not watched
    func stopAll()
}
```

### 11.1 Streams

- One FSEvents stream per top-level folder of `projects.json` that exists, registered or not (a project whose
  project.yml is missing or invalid is registered when the file becomes valid). It also covers the sub projects inside.
- `FSEventStreamCreate` with the folder's realpath(3), `kFSEventStreamEventIdSinceNow`, latency 0.3 s, flags
  `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes`,
  delivered on one serial dispatch queue per stream; each callback is one batch, forwarded in order to the actor.
- Changes from every source are reported: the app's own writes, Claude, editors, git.
- FSEvents reports realpath(3) forms (`/private/var/…` for a folder under `/var`, §6). They are matched with
  `realRoot` values by prefix at a `/` boundary, case-insensitively (APFS volumes are case-insensitive by default).

### 11.2 Batch processing

1. Dropped paths ([../protocol/events.md](../protocol/events.md)): a path with a component `.git`, `.build`,
   `DerivedData` or `node_modules`; a file named `.DS_Store`; a path under `.hephaestus/sessions/` of any project
   (`SessionService` emits the session events); a name for which `AtomicFile.isTemporaryName(_:)` is true. The
   components are those of the path relative to the watched folder: a folder above it with one of these names drops
   nothing.
2. A path that no registered project contains, in the stream of an unregistered top-level folder: when it is
   `<folder>/.hephaestus/project.yml` and the file loads, `registry.register(root:parentID: nil)` (errors logged);
   other such paths are ignored.
3. Each remaining path is classified by its owner, the deepest registered project that contains it (§11.3).
4. `filesChanged {projectID, paths}` is emitted once per batch for each project containing at least one path (each
   owner and its ancestors), with the paths it contains, relative to its root, each listed once, sorted. More than
   1,000 paths for one project in one batch → `paths: [""]` (the root: clients refresh everything of that project).
5. Flag `MustScanSubDirs`, `UserDropped` or `KernelDropped` on a path: every registered project whose root is inside
   the path or contains it re-reads project.yml (as in §11.3) and runs `tasks.rescan`; the path goes into the
   `filesChanged` of the projects that contain it, and `""` (the root) into that of every project whose root is inside
   it.
6. Flag `RootChanged` when the folder no longer exists: `registry.unregister(projectID, forget: false)` and
   `unwatch(root)`, logged. The project is served again after the next `start()` once its folder is back.

The events of one batch are emitted in this order: project events (`projectsChanged`, `projectChanged`), task events,
`filesChanged`.

### 11.3 Classification

`rel` is the path relative to the owner's root. Every path also goes into `filesChanged`, whatever its row.

| `rel`                                                                   | Action                                                                            |
|-------------------------------------------------------------------------|-----------------------------------------------------------------------------------|
| `.hephaestus/project.yml`                                               | re-read (below)                                                                   |
| `.hephaestus/tasks/<name>` with `TaskID(fileName: <name>)` of the owner | `tasks.reload(projectID:taskID:)`                                                 |
| `.hephaestus/tasks`                                                     | `tasks.rescan(projectID:)`                                                        |
| `<s>/.hephaestus/project.yml`, `<s>` an entry of `subprojects`          | `registry.register` of `<owner root>/<s>` with the owner as parent; errors logged |
| anything else                                                           | nothing more                                                                      |

Re-reading project.yml (`ProjectFile.load`):

- missing → `registry.unregister(owner, forget: false)`; for a top-level project its stream stays, so §11.2 step 2
  registers it again when the file comes back;
- invalid → `registry.markInvalid(owner, error: <the DataError message>)`; an `id` different from the owner's →
  `registry.markInvalid(owner, error: "project.yml: the project identifier cannot change")` (§6.6);
- valid → `registry.reloaded(owner, file:modified:)`, which emits only what differs.

Because every writer updates the caches before the watcher reads its files, a change made through the app is
announced once, by its writer; a change made outside the app (an editor, Claude, git) is announced by the watcher.

## 12. Host protocols

`HostService` conforms to the host protocols of `SessionService`, `SkillsService` and `MCPServer`; each requirement is
implemented as follows. §12.4 lists the members the Forge uses directly.

### 12.1 SessionHost ([../claude/cli.md](../claude/cli.md))

- `localDevice()`: `mesh.localDevice()`.
- `devices()`: the records of `mesh.snapshot().devices` with `revoked == false`.
- `settings()`: `settings()`.
- `claudeProject(_:)`: from `registry.hosted(_:)`, below.
- `claudeTask(projectID:taskID:)`: from `tasks.task(projectID:taskID:)`, below.
- `claudeBundle(projectID:bundleID:)`: from the cached `BundleItem` and `tasks.task(projectID:taskID:)`, below.
- `bundleWorkFolder(projectID:taskID:)`: `bundles.workFolder(projectID:taskID:)`
  ([bundles.md](bundles.md#working-folder-of-a-task-session)).
- `checkWritable(_:)`: `registry.checkWritable(_:)`.
- `sessionArchive(_:)`: one `SessionArchive(projectRoot: root)` per registered project, created on first use, dropped at
  unregistration.
- `mcp`, `skills`, `uploads`: the properties.
- `sessionChanged`, `sessionRemoved`, `sessionEvent`, `sessionDelta`, `permissionRequested`, `permissionResolved`:
  `emit(_:)` with the matching `ServerEvent` (`emit` also keeps the pending permission counts, §5).

Built values:

- `ClaudeProjectContext`: `id`, `name` (`file.name`), `root`, `codeFolder` = `root` + `file.code` (`.` is `root`),
  `docsFolder` = `codeFolder` + `file.docs`, `parent` = the parent as `ProjectRef {id, name, root}` (sub projects
  only; a parent that is not hosted, which happens only while both are being unregistered, makes `claudeProject(_:)`
  throw the `notFound` of `registry.hosted(_:)` for it, so
  [../claude/cli.md](../claude/cli.md#35-sessions-in-the-public-repository) 3.5 never takes a sub project for a
  top-level project), `subprojects` = `children(of:)` as `ProjectRef` values, `claude` = `file.claudeDefaults`,
  `skills` = `file.skills` ([../claude/prompts.md](../claude/prompts.md)).
- `ClaudeTaskContext`: `id`, `name`, `description`, `parseError` from the cached `TaskItem`; `yaml` = the text of
  the task file read from disk; `attachments` = `TaskFile.attachmentsFolder` + `file` for every attachment of every
  comment, in comment then attachment order.
- `ClaudeBundleContext`: `id`, `name`, `base` (`""` while unset), `tasks` = one `ClaudeBundleTask` per task of the
  bundle, in order (`name` and `status` of its `TaskItem`; `""` and nil for a deleted task), `maxParallel` = the setting
  `bundles.maxParallel`.

### 12.2 SkillsHost ([../claude/skills.md](../claude/skills.md))

| Requirement                     | Implementation                                        |
|---------------------------------|-------------------------------------------------------|
| `appSupport()`                  | `appSupport`                                          |
| `broadcastSkillsChanged(_:)`    | `emit(.skillsChanged(SkillsChangedPayload(skills:)))` |
| `requestPeer(_:method:params:)` | forwarded as `JSONValue` (below)                      |

Forwarding JSON to another Main (also used by §12.3): the params are decoded as `JSONValue`, sent with
`mesh.requestPeer(deviceID, method:, params: <value>, as: JSONValue.self, timeout: RPCPeer.defaultTimeout)`, and the
result is encoded back with `WireCoding.encodeJSON`.

Sync triggers: while `running`, the host iterates `mesh.peerLinkEvents()` ([../devices/mesh.md](../devices/mesh.md)):
`.connected(device)` → `skills.peerLinkOpened(device.id)` and `migration.peerLinkOpened(device.id)` (the pending
migration checks, [../devices/migration.md](../devices/migration.md#outcome-checks)); `.event(mainID:, event)` with
`event.name == "skills.changed"` → `skills.peerSkillsChanged(mainID)`; everything else is ignored.

### 12.3 MCPHost ([../claude/mcp.md](../claude/mcp.md))

- `localMain()`: `MCPMain {id, name}` of `mesh.localDevice()`, `online: true`.
- `otherMains()`: the non-revoked records with `isMain` other than this Main; `online` when in
  `mesh.connectedPeerMains()`.
- `perform(_:params:on:)`: this Main: `perform(_:params:context: .local(device: <local device>, author: "Claude"))`;
  another Main: forwarded as `JSONValue` (§12.2), with `timeout: .seconds(120)` for the methods that use it on devices
  ([../client/workspace.md](../client/workspace.md#conventions)) and `RPCPeer.defaultTimeout` for the others.
- `localProjectRoot(_:)`: `registry.hosted(_:).root`, `nil` when not hosted.
- `forgePushDocs(sessionID:)`: `forge.pushDocs(sessionID: sessionID)`.
- `forgePushRegen(sessionID:)`: `forge.pushRegen(sessionID: sessionID)`.
- `closeSession(projectID:sessionID:)`: `sessions.close(projectID: projectID, sessionID: sessionID)`
  ([../claude/cli.md](../claude/cli.md#511-closing-a-session)).
- `bundleTool(_:projectID:bundleID:arguments:)`: the `BundleService` function of the tool
  ([bundles.md](bundles.md#tools-of-the-coordinator)), its result encoded as the tool's JSON text.

### 12.4 ForgeService ([../forge/pipeline.md](../forge/pipeline.md#swift-api))

There is no host protocol for the Forge. `ForgeService` is created with `init(host: HostService)` and uses these
members directly: `registry.hosted(_:)`, `tasks.create`, `tasks.addComment` and `tasks.update` (§8), `uploads.check`
([files.md](files.md) §7), `sessions.start(_:)` and `sessions.sessions(projectID:)`
([../claude/cli.md](../claude/cli.md)), `emit(_:)` (§5), `mesh.localDevice()` and `mesh.snapshot()` (the device names
and addresses of the private terms too), `registry.all()` and `registry.descendants(of:)` (the projects of the private
terms), `hostInfo.claudePath` and `hostInfo.gitAvailable` (§10), `projects.importFolder(_:)` (§7.4) and `settings()`
(the projects folder) to register its source project, and `appSupport` (`forge.json`, `private-terms.txt`).
The host calls `configure(_:)` (§3.4), `shutdown()` (§3.2), `config()` (§10.1), the `forge.*` functions (§4.4) and the
notifications of §5. The app wiring calls `forge.privateTermsCount()`, `forge.preparePrivateTerms()`,
`forge.privateTermSuggestions()`, `forge.addPrivateTerm(_:)` and `forge.dismissPrivateTerm(_:)` for Settings ▸ Forge &
Updates ([../ui/shell.md](../ui/shell.md)).

### 12.5 hasActiveWork()

`await sessions.isRunningTurn() || await migration.isActive()`
([../devices/migration.md](../devices/migration.md#locked-state)); `false` while `state` is not `.running`. Used by the
self-update ([../forge/update.md](../forge/update.md)), so a self-update never quits the app during a turn or a project
move.

## 13. MeshService and MigrationService

`HostService.init` creates `MeshService(host: self, appSupport:, settings:, credentialStore:, options:)` with its own
init arguments (§2). The host uses these members of `MeshService`
([../devices/mesh.md](../devices/mesh.md#swift-api)): `ensureMesh()`, `startListener(acceptor:)`, `stopListener()`,
`startAdvertising()`, `stopAdvertising()`, `startPeerLinks()`, `stopPeerLinks()`, `boundListenerPort()` (§2, §3);
`localDevice()`, `snapshot()`, `isRevoked(_:)`, `connectionOpened(device:connectionID:peer:)`,
`connectionClosed(connectionID:)` (§4); `connectedPeerMains()` and `requestPeer(_:method:params:as:timeout:)` (§6.7,
§12); `peerLinkEvents()` (§12.2). `MeshService` and `MigrationService` conform to `HostMethodHandler` for the methods
routed to them (§4.4). The host calls `migration.recover()` (§3.1), `migration.stop()` (§3.2),
`migration.peerLinkOpened(_:)` (§12.2) and `migration.isActive()` (§12.5). `MigrationService` uses `registry.hosted`,
`all()`, `descendants(of:)`, `setMigrating`, `register`, `unregister` and `forgetRoot` (§6), `sessions.hasProcess`, and
`appSupport` for the Trash and `migrations.json`
([../devices/migration.md](../devices/migration.md)).

## 14. Events of this doc

| Event              | Emitted by        | When                                                                                                                    |
|--------------------|-------------------|-------------------------------------------------------------------------------------------------------------------------|
| `projects.changed` | `ProjectRegistry` | register, unregister, `setMigrating`; name, description, sub projects, `parseError` or `pendingPermissionCount` changed |
| `project.changed`  | `ProjectRegistry` | the wire `Project` changed: a write, the watcher, `setMigrating`, `markInvalid`                                         |
| `task.changed`     | `TaskService`     | a task method wrote the file; the watcher found a difference                                                            |
| `task.removed`     | `TaskService`     | `tasks.delete`; the watcher found the file gone                                                                         |
| `bundle.changed`   | `BundleService`   | a bundle method or tool wrote the bundle file ([bundles.md](bundles.md))                                                |
| `bundle.removed`   | `BundleService`   | `bundles.delete`                                                                                                        |
| `files.changed`    | `FileWatcher`     | each batch with paths of the project                                                                                    |

`projects.changed` carries `{deviceID: <this Main>, projects: registry.summaries()}`.
