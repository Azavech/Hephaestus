# Files

files:
- HephaestusKit/Sources/HephHost/Files/FileService.swift
- HephaestusKit/Sources/HephHost/Files/PathResolver.swift
- HephaestusKit/Sources/HephHost/Files/UploadService.swift
- HephaestusKit/Sources/HephCore/Util/IgnoreRules.swift
- HephaestusKit/Sources/HephCore/Util/Revision.swift

---

How a Main serves the `files.*` methods of [../protocol/methods.md](../protocol/methods.md) on the files of its
projects, the `uploads.*` methods and the upload store (§7), and the helpers other areas share: path safety, revisions
and the ignore rules. The file browser and editor that call these methods are in [../ui/code.md](../ui/code.md) and
[../ui/docs.md](../ui/docs.md); the host that routes the requests is in [host.md](host.md). Atomic writes are
`AtomicFile.write` of [../data/app-storage.md](../data/app-storage.md). Ticket attachments (naming, collisions, MIME
types, storage) are defined in [../data/ticket-yml.md](../data/ticket-yml.md#attachments) and served by `TicketService`
([host.md](host.md) §8).

## 1. FileService

```swift
// HephHost/Files/FileService.swift
actor FileService: HostMethodHandler {
    init(host: HostService)
    func list(projectID: String, path: String) async throws -> [FileEntry]
    func read(projectID: String, path: String, offset: Int?, length: Int?) async throws -> FilesReadResult
    func write(projectID: String, path: String, data: Data, baseRevision: String?) async throws -> FilesWriteResult
    func create(projectID: String, path: String, isDirectory: Bool) async throws -> FileEntry
    func rename(projectID: String, from: String, to: String) async throws
    func delete(projectID: String, path: String) async throws
}
```

- Every path is relative to the project root (not to the code folder) and is resolved by a `PathResolver` on the
  project's `realRoot` ([host.md](host.md) §6).
- `write`, `create`, `rename` and `delete` run inside `registry.write(<owner>)` ([host.md](host.md) §6.8). The owner is
  the first project of `registry.containing(<resolved absolute path>)`: the deepest registered project that contains
  the path (for `rename`, the owner of `from`). A sub project's files are thus serialized with that sub project's other
  writers (tickets, tabs, project.yml), and the request is refused with `locked` while the owner or one of its ancestors
  migrates (`checkWritable`). `list` and `read` are not serialized and are served while the project migrates.
- `FileService` emits no event: the file watcher reports every change with `files.changed`, plus `project.changed`,
  `ticket.changed` or `ticket.removed` when the file is a project or ticket file ([host.md](host.md) §11). The caller
  receives the `files.changed` of its own writes too.
- Every path inside the project root can be read and written, `.hephaestus/` included (a hand edit of project.yml or a
  ticket file is picked up by the watcher). Clients read ticket and session attachments with `attachments.read` and
  `sessions.readAttachment` ([../data/sessions.md](../data/sessions.md#attachments)).
- Protected paths: `.hephaestus` and `.hephaestus/project.yml` (of the request's project) cannot be renamed or deleted
  (§5.5, §5.6). They are protected for `files.rename` and `files.delete` only.
- Errors are thrown as `ProtocolError` values; their messages are the ones below. Any other failure of the file
  system is `internal` with the system's message (the error's `localizedDescription`, or `strerror(errno)` for a
  failed `stat`).

## 2. Paths

```swift
// HephHost/Files/PathResolver.swift
struct PathResolver {
    let root: URL                             // the project's realRoot: realpath(3) of the project root
    /// Checks a project path (rules below) and returns its components; [] for the root "". Throws badRequest.
    static func components(_ path: String) throws -> [String]
    /// The absolute URL of `path`. With `followLast`, a symlink in the last component is followed; without it, the
    /// last component is not resolved (rename and delete act on a link itself). Throws badRequest.
    func resolve(_ path: String, followLast: Bool = true) throws -> URL
    /// The project path of an absolute URL inside root, "" for root itself; nil when outside.
    func projectPath(of url: URL) -> String?
}
```

`components` refuses with `badRequest` "Invalid path <path>.":

1. a path containing a NUL character;
2. a path starting with `/` (absolute);
3. a path whose split on `/` has an empty component (`a//b`, a trailing `/`), a `.` component or a `..` component.

`""` is the project root and has no components. No other normalization happens: a valid path is its own canonical
form.

`resolve`:

1. URL = `root` + the components.
2. The part to resolve is the whole URL with `followLast`, and the URL without its last component otherwise. Its
   deepest existing component is resolved with realpath(3) (`ClaudePathEncoding.canonicalPath`,
   [host.md](host.md) §6); the components after it, which do not exist yet (a file being created), are appended as
   written. Without `followLast`, the last component is then appended as written. `URL.resolvingSymlinksInPath()` and
   `standardizedFileURL` are not used: they turn `/private/var/…` into `/var/…`, which `root` never matches.
3. The result must be `root` or start with `root` + `/` → else `badRequest` "<path> is outside the project.".

The same containment check, applied to sub project roots and the folder of `projects.create`, is required by
[host.md](host.md) §6.3 and §7.3.

## 3. Revision

```swift
// HephCore/Util/Revision.swift
public enum Revision {
    /// The first 16 characters of the lowercase hexadecimal SHA-256 (CryptoKit) of `data`.
    public static func of(_ data: Data) -> String
}
```

`files.read` returns it, `files.write` compares it with `baseRevision` and returns the new one. Clients treat it as an
opaque string and compare it for equality only ([../ui/code.md](../ui/code.md)).

## 4. Writes

File contents are written with `AtomicFile.write(_:to:)`
([../data/app-storage.md](../data/app-storage.md#atomic-writes)):
a temporary file in the same folder, the permissions of the replaced file kept (a script keeps its executable bit),
then `rename(2)`. `AtomicFile.write` creates missing parent folders, so `FileService` checks the parent folder before
calling it (§5.3, §5.4). The watcher ignores the temporary files (`AtomicFile.isTemporaryName`).

## 5. Methods

"Exists" is tested with `lstat` (a dangling symlink exists). Sizes are compared with `MethodLimits`
([../protocol/methods.md](../protocol/methods.md#limits)). In "No folder at <parent>.", `<parent>` is the project path
of the folder that holds the request's path (`""` for an item of the root).

### 5.1 files.list {projectID, path} → {entries}

1. `resolve(path)`; nothing there → `notFound` "No folder at <path>."; a file → `badRequest` "<path> is a file.".
2. `entries`: every item directly inside, hidden names included (clients hide them, §6).
3. Order: folders first, then files, each group by `name` with `localizedStandardCompare`.

| Field         | Value                                                                   |
|---------------|-------------------------------------------------------------------------|
| `name`        | the item's name                                                         |
| `path`        | `<path>/<name>`, or `<name>` when `path` is `""`                        |
| `isDirectory` | `true` for a folder or a symlink to a folder                            |
| `size`        | size in bytes of a file (of its target for a symlink); `0` for a folder |
| `modified`    | content modification date (the link's own date for a dangling symlink)  |

A symlink is listed even when it points outside the project; reading through it fails with `badRequest`.

### 5.2 files.read {projectID, path, offset?, length?} → {data, revision, size}

`resolve(path)`; nothing there → `notFound` "No file at <path>."; a folder → `badRequest` "<path> is a folder.". Then:

- Without `offset` and `length` (a whole read): larger than `MethodLimits.maxFileSize` → `tooLarge` "<path> is larger
  than 10 MiB.". Returns the content, `Revision.of(content)` and the size in bytes.
- With `offset` or `length` (a ranged read): `offset` (default 0) below 0 or above the file's size → `badRequest`
  "Invalid offset <offset> for <path>."; `length` (default `MethodLimits.maxChunkSize`) below 1 → `badRequest` "Invalid
  length."; a `length` above `maxChunkSize` counts as `maxChunkSize`. The file is opened with `FileHandle`, positioned
  at `offset`, and `min(length, size − offset)` bytes are read. Returns those bytes, `revision` `""` and the size of
  the whole file. Any file size is accepted.

### 5.3 files.write {projectID, path, data, baseRevision?} → {revision}

1. `data` larger than `MethodLimits.maxFileSize` → `tooLarge` "The content is larger than 10 MiB.".
2. `resolve(path)` gives the owner (§1). Inside `registry.write(<owner>)`: a folder → `badRequest` "<path> is a
   folder."; parent folder missing → `notFound` "No folder at <parent>.".
3. With `baseRevision`: the file must exist → else `conflict` "<path> was deleted on the Main."; its content must be
   at most `maxFileSize` and `Revision.of(content) == baseRevision` → else `conflict` "<path> was changed on the
   Main.".
4. Without `baseRevision`: no check; a missing file is created.
5. `AtomicFile.write(data, to:)`; returns `{revision: Revision.of(data)}`.

### 5.4 files.create {projectID, path, isDirectory} → FileEntry

1. `path` `""` → `badRequest` "Invalid path.".
2. `resolve(path, followLast: false)` gives the owner (§1). Inside `registry.write(<owner>)`: something exists there →
   `conflict` "<path> already exists."; the parent is missing or not a folder → `notFound` "No folder at <parent>.".
3. Folder: `FileManager.createDirectory(at:withIntermediateDirectories: false)`. File: `AtomicFile.write(Data(), to:)`.
4. Returns the new item's `FileEntry`.

### 5.5 files.rename {projectID, from, to} → {}

1. `from` or `to` `""` → `badRequest` "Invalid path."; `from` or `to` equal to `.hephaestus` or
   `.hephaestus/project.yml` → `badRequest` "<path> cannot be renamed or deleted."; `to` equal to `from` or inside it
   (`to` starts with `from` + `/`) → `badRequest` "A folder cannot be moved into itself.".
2. Both resolved with `followLast: false`; the owner is that of `from` (§1). Inside `registry.write(<owner>)`: nothing
   at `from` → `notFound` "No file at <from>."; the parent of `to` missing → `notFound` "No folder at <parent>.".
3. Something exists at `to` → `conflict` "<to> already exists.", except when it is the item at `from` itself (a change
   of letter case on a case-insensitive volume: same `fileResourceIdentifier`).
4. `FileManager.moveItem(at:to:)`. `to` may be in another folder of the project.

### 5.6 files.delete {projectID, path} → {}

1. `path` `""` → `badRequest` "Invalid path."; `path` equal to `.hephaestus` or `.hephaestus/project.yml` →
   `badRequest` "<path> cannot be renamed or deleted.".
2. `resolve(path, followLast: false)` gives the owner (§1). Inside `registry.write(<owner>)`: nothing there →
   `notFound` "No file at <path>.".
3. `host.appSupport.trashItem(<url>)` ([../data/app-storage.md](../data/app-storage.md#trash)): the item goes to the
   Trash of the Main's user. A failure → `unavailable` "Could not move <path> to the Trash: <reason>.", <reason> being
   the error's `localizedDescription` without its final period. `files.delete` never deletes permanently.

## 6. Ignore rules

```swift
// HephCore/Util/IgnoreRules.swift
public enum IgnoreRules {
    /// .git, .hephaestus, .build, DerivedData, node_modules, .DS_Store
    public static let hiddenNames: Set<String>
    /// True when `name`, one path component, is in hiddenNames (exact, case-sensitive).
    public static func isHidden(name: String) -> Bool
    /// True when a component of the project path `path` is hidden.
    public static func isHidden(path: String) -> Bool
}
```

- These are the hidden names: the file browser hides them unless "Show hidden files" is on and the docs
  browser always hides them ([../ui/code.md](../ui/code.md), whose `FileTreeModel.hiddenNames` holds the same six
  names); search never enters or searches them ([search.md](search.md) §4.3).
- There are no other ignore rules: `.gitignore` files are not read.
- They are not the `files.changed` filter, which is defined by [../protocol/events.md](../protocol/events.md) and
  applied by the watcher ([host.md](host.md) §11.2).

## 7. Uploads

Files attached to comments, messages and feedback reach the Main in chunks before the request that attaches them
([../protocol/methods.md](../protocol/methods.md#uploads)). `UploadService` serves `uploads.begin`, `uploads.chunk` and
`uploads.cancel`, keeps the upload store, and hands complete uploads to the requests that use them.

```swift
// HephHost/Files/UploadService.swift. Public because the public SessionHost protocol names it (../claude/cli.md).
public actor UploadService: HostMethodHandler {
    init(host: HostService)
    /// HostService.start(): empties Uploads/ and starts the expiry sweep (§7.4).
    func start()
    /// HostService.stop(): ends the sweep, forgets every upload and deletes its file.
    func stop()
    /// uploads.begin, uploads.chunk, uploads.cancel (§7.2).
    public func handle(method: String, params: Data, context: RequestContext) async throws -> Data
    /// The checks of §7.3 on the UploadRefs of one request, without reserving them. Throws ProtocolError.
    func check(_ refs: [UploadRef], projectID: String) throws
    /// The checks of §7.3; then reserves the uploads for the request. Throws ProtocolError.
    func claim(_ refs: [UploadRef], projectID: String) throws -> [ClaimedUpload]
    /// The request succeeded: the uploads, whose files were moved away, are forgotten.
    func finish(_ claimed: [ClaimedUpload])
    /// The request failed: each upload whose file is back at its URL is usable again; the others are forgotten.
    func release(_ claimed: [ClaimedUpload])
    /// Deletes the uploads that no request holds and whose last chunk is more than an hour before `now` (§7.4).
    func sweep(now: Date)
}

/// An upload reserved by one request.
struct ClaimedUpload: Sendable {
    let uploadID: UUID
    let fileName: String   // the UploadRef's fileName: the original name of the attachment
    let url: URL           // Uploads/<uploadID>
    let size: Int
}
```

### 7.1 Store

- Folder: `appSupport.uploadsFolder`, `Application Support/Hephaestus/Uploads/`
  ([../data/app-storage.md](../data/app-storage.md)). Each upload is one file, `Uploads/<uploadID>`, the id in canonical
  uppercase form. `UploadService` is the only writer of the folder.
- In memory, per upload: `uploadID`, `projectID`, `fileName` (of `uploads.begin`), `size`, `received` (bytes written),
  `lastChunk` (time of the last chunk, else of `uploads.begin`) and `inUse` (reserved by a request in progress).
- Uploads last for one run of the host: `start()` deletes every item of `Uploads/` (left by an earlier run) and creates
  the folder; `stop()` cancels the sweep, forgets every upload and deletes the folder's content. A request that names a
  lost upload fails with `notFound`; the message composer uploads its attachments again after its Main reconnects
  ([../ui/sessions.md](../ui/sessions.md#message-composer)).

### 7.2 Methods

`uploads.begin {projectID, fileName, size}`:

1. `registry.hosted(projectID)` (`notFound`). A migrating project is accepted.
2. `size` below 0 → `badRequest` "Invalid size."; `fileName` empty after trimming white space and line breaks →
   `badRequest` "The file name is empty.".
3. A new `uploadID`; the empty file is created with `FileManager.createFile(atPath:contents: nil)`; a failure →
   `internal` "Cannot create the upload: <reason>.", <reason> being `strerror(errno)`.
4. The upload is recorded with `received` 0, `lastChunk` now and `inUse` false; the result is `{uploadID}`. An upload of
   size 0 is complete.

`uploads.chunk {uploadID, offset, data}`, checked in this order (messages of
[../protocol/methods.md](../protocol/methods.md#uploadschunk)):

| Check                                      | Error        |
|--------------------------------------------|--------------|
| the upload exists                          | `notFound`   |
| it is not `inUse`                          | `conflict`   |
| `data.count` ≤ `MethodLimits.maxChunkSize` | `tooLarge`   |
| `data` is not empty                        | `badRequest` |
| `offset` equals `received`                 | `badRequest` |
| `offset + data.count` ≤ `size`             | `badRequest` |

Then `FileHandle(forWritingTo:)`, `seekToEnd()`, `write(contentsOf: data)`, `close()`; `received += data.count`;
`lastChunk` = now. A write failure deletes the upload (file and record) and answers `internal` "Cannot write the
upload: <reason>.", <reason> being the error's `localizedDescription` without its final period.

`uploads.cancel {uploadID}`: an upload that exists and is not `inUse` is forgotten and its file deleted; for any other
id nothing changes. The result is `{}`.

### 7.3 Using uploads

`claim(_:projectID:)` applies the checks of [../protocol/methods.md](../protocol/methods.md#using-uploads) to the refs,
in order, and throws the first failure without reserving anything. When every check passes, each upload gets `inUse`
true and the result lists them in the order of the refs, each with its ref's `fileName`. `check(_:projectID:)` runs the
same checks and reserves nothing: the Forge calls it before it creates the feedback ticket
([../forge/pipeline.md](../forge/pipeline.md#feedback-intake)).

A request that attaches uploads (`TicketService` for `tickets.addComment` and the Forge's screenshot comment,
[host.md](host.md) §8; `SessionService` for `sessions.start` and `sessions.send`, [../claude/cli.md](../claude/cli.md)):

1. runs its own checks, then `claim`, the last check before it changes anything;
2. moves each claimed file into place, in order: `TicketFile.storeAttachment(fileAt:originalName:projectRoot:id:)`
   ([../data/ticket-yml.md](../data/ticket-yml.md#storing-a-file)) or
   `SessionArchive.saveAttachment(fileAt:originalName:to:)` ([../data/sessions.md](../data/sessions.md#attachments)),
   with the claimed `fileName` as the original name;
3. on success, calls `finish`;
4. when a step after the claim fails: each file already moved goes back to its `ClaimedUpload.url`
   (`FileManager.moveItem(at:to:)`; a file that cannot be moved back is deleted and the failure logged), then `release`,
   then the request's error is returned.

`finish` forgets the uploads. `release` sets `inUse` false on each upload whose file exists at its URL and forgets the
others; `lastChunk` keeps its value.

Moving a file to a project on another volume than the Application Support folder copies it, so such a request can take
as long as the copy; clients send the requests that attach uploads with the longer timeout of
[../client/workspace.md](../client/workspace.md#conventions).

### 7.4 Expiry

A task created by `start()` calls `sweep(now: Date())` every 5 minutes until `stop()`. `sweep(now:)` deletes each upload
whose `inUse` is false and whose `lastChunk` is more than 3,600 s before `now`: its file and its record. An upload that
no request uses is thus deleted between 60 and 65 minutes after its last chunk.

### 7.5 Logging

`Log.host` ([../architecture.md](../architecture.md#logging)): `debug` when an upload is begun, completed, used,
cancelled or expired (its id, project and size); `error` for a failed write and for a file that could not be moved
back. File contents and file names are never logged.
