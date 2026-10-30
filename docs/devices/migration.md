# Moving projects between Mains

files:
- HephaestusKit/Sources/HephHost/Migration/MigrationService.swift
- HephaestusKit/Sources/HephHost/Migration/ManifestBuilder.swift
- HephaestusKit/Sources/HephHost/Migration/MigrationSender.swift
- HephaestusKit/Sources/HephHost/Migration/MigrationReceiver.swift
- HephaestusKit/Sources/HephCore/Util/ClaudePathEncoding.swift

---

A top-level project moves from the Main that hosts it (the source, S) to another Main (the destination, D) with
everything in its folder, sub projects included, and the Claude CLI transcripts of its sessions, so the sessions
resume on D. The user starts it with "Move to…" in the project Overview ([../ui/overview.md](../ui/overview.md)).
The transfer runs over S's outgoing peer link to D ([mesh.md](mesh.md#peer-links)). Method contracts:
[../protocol/methods.md](../protocol/methods.md#projectsmigrate) and
[../protocol/methods.md](../protocol/methods.md#migration); wire types `ManifestEntry` and `MigrationState`:
[../protocol/types.md](../protocol/types.md#migration-migrationtypesswift).

## Overview

```
client               source Main S                                destination Main D
  | projects.migrate --> |                                                |
  |                      | checks, project locked (migrating)             |
  | <-- {migrationID} -- | progress preparing                             |
  |                      | walks the folder and the transcripts, hashes   |
  |                      | journal: transferring                          |
  |                      | migration.begin -----------------------------> | creates <projectsFolder>/<folder>
  |                      | <-------------------------- {destinationPath}  |
  |                      | progress transferring                          |
  |                      | migration.chunk (256 KiB, in order) ---------> | writes at offset, hashes
  |                      | <------------------------------------------ {} |
  |                      |   … every file, one request at a time …        |
  |                      | progress committing, journal: committing       |
  |                      | migration.commit ----------------------------> | verifies, folders, links, modes,
  |                      |                                                | dates, transcripts, registers,
  |                      |                                                | journal: received
  |                      | <------------------------------------------ {} | projects.changed
  |                      | journal: committed                             |
  |                      | unregisters, folder and transcripts to Trash   |
  |                      | journal entry removed                          |
  |                      | projects.changed, progress completed           |
```

| Value                              | Setting                                                                                |
|------------------------------------|----------------------------------------------------------------------------------------|
| chunk size                         | 262,144 bytes (`MethodLimits.migrationChunkSize`); the last chunk of a file is shorter |
| requests from S to D               | `mesh.requestPeer`, timeout 30 s (`migration.status` included); `migration.abort` 10 s |
| progress events                    | each state change; while `transferring`, at most one per 500 ms                        |
| outcome check (`migration.status`) | every 10 s while S has a peer link to D, until D answers; no time limit                |

Several migrations may run at the same time, on one Main or on several, each identified by its `migrationID`.

In the messages "Cannot read <path>: <error>", "Cannot create <path>: <error>" and "Cannot write <path>: <error>" of
this doc, <error> is the error's `localizedDescription`, or `strerror(errno)` when a system call fails (`lstat`,
`open(2)`, `realpath(3)`; `ENOENT` when `errno` is 0); a path that has no file system representation gives `invalid
path`, and a folder for which `FileManager` returns no enumerator `the folder cannot be listed`.

## Starting a move

`projects.migrate {projectID, targetDeviceID}` on S. Checks, in order:

| Check                                                                                  | Error                                                                    |
|----------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| `projectID` is hosted here (`host.registry.hosted`)                                    | `notFound` "Project <id> is not hosted on this Main."                    |
| it is a top-level project                                                              | `badRequest` "Sub projects move with their parent project."              |
| it is not migrating                                                                    | `locked` "<name> is already being moved."                                |
| `targetDeviceID` is not this Main                                                      | `badRequest` "<name> is already on this Main."                           |
| the target is a non-revoked record of the registry                                     | `notFound` "No device <targetDeviceID>."                                 |
| the target record has `isMain`                                                         | `badRequest` "<target name> is not a Main."                              |
| S has an established outgoing peer link to the target (`mesh.connectedPeerMains()`)    | `unavailable` "<target name> is not connected."                          |
| no project of the tree has live work                                                   | `conflict` "Stop the Claude sessions and runs of <name> first."          |

- The tree is the project and every sub project at any depth (`host.registry.descendants(of:)`).
- Live work: a session with a CLI process (`host.sessions.hasProcess(projectID:)`, [../claude/cli.md](../claude/cli.md))
  or a running run (`host.runs.activeRunCount(projectID:)` > 0, [../services/runs.md](../services/runs.md)). The Move
  sheet stops them before it sends the request ([../ui/overview.md](../ui/overview.md#move-sheet)).

Then:

1. `host.registry.setMigrating(projectID, true)`: queued behind the project's pending writes, then the project and its
   sub projects are locked and `projects.changed` is broadcast
   ([../services/host.md](../services/host.md#68-write-serialization)).
2. The live-work check runs again; when it fails now, `setMigrating(projectID, false)` and the `conflict` above.
3. A new `migrationID` (`UUID()`) is answered: `{migrationID}`.
4. The source run starts in a new task ([Transfer](#transfer)).

## Locked state

While a project is migrating:

- Every write method on it or on its sub projects is refused with `locked` "<name> is being moved to another Main."
  (`ProjectRegistry.checkWritable`, [../services/host.md](../services/host.md#68-write-serialization)); no session
  starts ([../claude/cli.md](../claude/cli.md)). Reads (`projects.snapshot`, `files.read`, `files.list`,
  `sessions.history`, `sessions.readAttachment`, `attachments.read`, `runs.output`, `search.query`) keep working, and
  so does `uploads.begin` (the request that uses the upload is refused).
- `ProjectSummary.migrating` and `Project.migrating` are true for the project and its sub projects
  ([../protocol/types.md](../protocol/types.md)).
- Files changed in the folder by other programs during the move are not prevented; a file whose content changed after
  it was hashed fails the move at the commit (checksum).
- The lock ends when the project leaves S (success) or with `setMigrating(projectID, false)` (failure). A move whose
  outcome S does not know keeps the lock until an outcome check answers ([Outcome checks](#outcome-checks)), across
  restarts of S ([Recovery after a restart](#recovery-after-a-restart)).
- While any migration runs on a Main (as source or destination), `isActive()` is true: Main cannot be turned off, the
  Mac cannot leave the mesh ([roles.md](roles.md#turning-main-off-macos)), and the host reports active work, so the
  self-update waits ([../forge/update.md](../forge/update.md)). A move that only waits for an outcome check does not
  count: its journal entry carries it across a restart.

## Manifest

### Walk

`ManifestBuilder.entries(of:prefix:)` lists a folder tree:

- `FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
  options: [], errorHandler:)`: depth-first, each folder before its content, hidden files included, symbolic links not
  followed. An enumeration error fails the walk with "Cannot read <path>: <error>", <path> being the `path` (below) of
  the item it names, `prefix` for `root` itself, or the item's last path component when it is not inside `root`. A
  folder for which `FileManager` returns no enumerator fails it the same way, <path> being `prefix`, or the last path
  component of `root` when `prefix` is empty.
- Each item is examined with `lstat`:

| `st_mode` type | Entry                                                                                          |
|----------------|------------------------------------------------------------------------------------------------|
| `S_IFREG`      | file: `size` = `st_size`, `sha256` = SHA-256 of the content read in 1 MiB blocks               |
| `S_IFDIR`      | folder                                                                                         |
| `S_IFLNK`      | symbolic link: `symlinkTarget` = `FileManager.destinationOfSymbolicLink(atPath:)`, unchanged   |
| anything else  | skipped (sockets, FIFOs, devices), logged                                                      |

- `path`: the item's path relative to `root`, components joined with `/`, prefixed with `prefix` and `/` when `prefix`
  is not empty. The root itself has no entry.
- `mode` = `st_mode & 0o7777`; `modified` = `st_mtimespec` as a `Date` (the wire keeps milliseconds).
- An item that cannot be read fails the walk: "Cannot read <path>: <error>".

### Exclusions

An item named exactly `.build`, `DerivedData`, `node_modules` or `.DS_Store` (case-sensitive, at any depth) is left
out with everything inside it: `enumerator.skipDescendants()` for a folder only, since on macOS a call right after a
file (a `.DS_Store`) skips the content of the next folder instead. `.git` and `.hephaestus` are included.

Not transferred: extended attributes, ACLs, file flags, creation dates, owners (D's user owns the copies), hard links
(each link is copied as a separate file), the mode and date of symbolic links.

### ManifestEntry

`ManifestEntry` is defined in [../protocol/types.md](../protocol/types.md); its fields per kind of item:

| Field           | File                         | Folder            | Symbolic link               |
|-----------------|------------------------------|-------------------|-----------------------------|
| `path`          | relative path                | relative path     | relative path               |
| `isDirectory`   | `false`                      | `true`            | `false`                     |
| `size`          | size in bytes                | `0`               | `0`                         |
| `sha256`        | lowercase hex of the content | `nil`             | `nil`                       |
| `mode`          | permission bits              | permission bits   | permission bits (ignored)   |
| `modified`      | modification date            | modification date | modification date (ignored) |
| `symlinkTarget` | `nil`                        | `nil`             | the link's target           |

`manifest` is `ManifestBuilder.entries(of: <project root>, prefix: "")`.

### Claude transcripts

The Claude CLI keeps the transcripts of its sessions in one folder per working directory, under `<config>/projects/`
and named after that directory ([Claude folder names](#claude-folder-names)). Sessions run in their project's root
([../claude/cli.md](../claude/cli.md)), so each project of the tree has its own folder.

- `<config>`: `ClaudePathEncoding.configDirectory(environment: await LoginEnvironment.shared.environment(), home:)`:
  `CLAUDE_CONFIG_DIR` of the login environment when set and not empty, else `<home>/.claude`
  ([../claude/cli.md](../claude/cli.md#11-login-environment)).
- For each project of the tree, top-level first, then the sub projects depth-first in `subprojects` order: the folder
  `<config>/projects/<ClaudePathEncoding.folderName(for: <canonical root>)>`, `<canonical root>` being
  `ClaudePathEncoding.canonicalPath` of the project root. A folder that does not exist is skipped; a folder already
  included (two roots giving the same name) is not included again.
- `claudeFiles` lists, for each included folder, an entry for the folder itself (`path` = its name, a folder entry)
  and `ManifestBuilder.entries(of: <folder>, prefix: <its name>)`. So every path's first component is the source's
  encoded folder name ([../protocol/types.md](../protocol/types.md)).
- `migration.begin` carries the `project` summary with every `rootPath` (of the project and of each nested child)
  replaced by its canonical path, so that D finds which project each folder belongs to
  ([migration.begin](#migrationbegin)).

### Claude folder names

`ClaudePathEncoding.folderName(for:)` reproduces the Claude CLI's folder name for a working directory (verified in the
CLI 2.1.309 bundle installed on this Mac):

1. Every UTF-16 code unit of the path that is not `A`–`Z`, `a`–`z` or `0`–`9` becomes `-`; the others are kept.
2. When the result has at most 200 characters, it is the name.
3. Otherwise the name is its first 200 characters, `-`, then the hash below in base 36 (`String(_, radix: 36)`,
   lowercase): `h` is an `Int32` starting at 0; for each UTF-16 code unit `u` of the original path,
   `h = (h &<< 5) &- h &+ Int32(u)`; the value written is `|h|` as an `Int64` (2147483648 for `Int32.min`).

The CLI encodes its working directory as the operating system reports it (symbolic links resolved). Hephaestus
therefore encodes `canonicalPath(_:)` = `realpath(3)`, never `URL.resolvingSymlinksInPath()`, which turns
`/private/tmp/x` into `/tmp/x` and would give another folder name.

| Path                                                                                                                                                                                                                            | Folder name                                                                                                                                                                                                       |
|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `/Users/user/Developer/Atlas/sample-service`                                                                                                                                                                                    | `-Users-user-Developer-Atlas-sample-service`                                                                                                                                                                      |
| `/private/tmp/claude-501/-Users-user-Developer/x/cli1`                                                                                                                                                                          | `-private-tmp-claude-501--Users-user-Developer-x-cli1`                                                                                                                                                            |
| `/Users/user/Developer/Café Projet` (`é` precomposed, U+00E9)                                                                                                                                                                   | `-Users-user-Developer-Caf--Projet`                                                                                                                                                                               |
| `/Users/user/Developer/🚀 Rocket` (the emoji is two UTF-16 units)                                                                                                                                                                | `-Users-user-Developer----Rocket`                                                                                                                                                                                 |
| `/Users/user/Developer/clients/acme-corporation/platform-modernization-initiative/backend-services/payment-processing-gateway/integration-tests/fixtures/sandbox-environment/regional-deployments/europe-west` (204 characters) | `-Users-user-Developer-clients-acme-corporation-platform-modernization-initiative-backend-services-payment-processing-gateway-integration-tests-fixtures-sandbox-environment-regional-deployments-europe--q52z38` |

The last vector was computed with the CLI's own JavaScript functions run in JavaScriptCore.

## Transfer

The source run (`MigrationSender`) sends every request with `host.mesh.requestPeer(<D>, method:, params:, as:,
timeout:)` ([mesh.md](mesh.md#requests-to-other-mains)). D handles them in `MigrationReceiver`; the host accepts them
only from peer Mains (callers `mainPeers`).

### Source run

1. Progress `preparing`.
2. `manifest` and `claudeFiles` are built ([Manifest](#manifest)); `bytesTotal` = the sum of the `size` of their file
   entries.
3. The journal entry is added, state `transferring` ([Journal](#journal)). Then
   `migration.begin {migrationID, project, folderName, manifest, claudeFiles}`: `project` is S's `ProjectSummary` of
   the project with canonical root paths; `folderName` is the last component of the project root. When the request
   does not fit in one frame (`requestPeer` throws `tooLarge`; nothing is sent), the move fails with
   `ProtocolError(.tooLarge, "This project has too many files to move (<count>).")`, `<count>` being the number of
   entries of `manifest` plus those of `claudeFiles`.
4. Progress `transferring` (`bytesDone` 0).
5. For each file entry of `manifest` with `size` > 0, in order, then each of `claudeFiles` (`transcript: true`): the
   file is read from offset 0 in chunks of 262,144 bytes and each chunk is sent with
   `migration.chunk {migrationID, path, offset, data, transcript}`, waiting for its answer before the next one.
   `bytesDone` grows with each answer. A read that returns fewer bytes than expected before `size` fails the move with
   `internal` "<path> changed during the move."; a file that cannot be opened or read, with `internal` "Cannot read
   <path>: <error>". <path> is the entry's `path`. Bytes past `size` are not sent.
6. Progress `committing`; the journal entry becomes `committing`; `migration.commit {migrationID}`.
7. Success (`{}`): the journal entry becomes `committed`, then [After the commit](#after-the-commit). The commit failed
   with `unavailable` (no answer in time, or the link closed): [Lost commit answer](#lost-commit-answer). Any other
   failure of steps 2–6: [Failures](#failures).

### migration.begin

D, in order:

1. Checks (`badRequest` unless noted):

| Check                                                                                                                                                                                                                                  | Message                                                    |
|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------|
| `migrationID` is not known on D                                                                                                                                                                                                        | "Migration <id> already exists."                           |
| `folderName` is not empty, not `.` or `..`, has no `/` and no NUL                                                                                                                                                                      | "Invalid folder name."                                     |
| no identifier of `project` and its `children` (any depth) is hosted on D (`conflict`)                                                                                                                                                  | "Identifier <id> is already used by <name> on this Main."  |
| every path: not empty, no leading `/`, no NUL, no empty, `.` or `..` component                                                                                                                                                         | "Invalid manifest entry <path>: <reason>."                 |
| no path appears twice in a list                                                                                                                                                                                                        | "Invalid manifest entry <path>: <reason>."                 |
| the parent path of every entry is a folder entry of the same list, or the root for `manifest`; a `claudeFiles` entry of one component (a transcript folder) is a folder                                                                | "Invalid manifest entry <path>: <reason>."                 |
| file: `sha256` is 64 lowercase hex digits, `size` ≥ 0, no `symlinkTarget`; folder: `size` 0, no `sha256`, no `symlinkTarget`; link: not a folder, `size` 0, no `sha256`, `symlinkTarget` not empty and without NUL; `mode` in 0…0o7777 | "Invalid manifest entry <path>: <reason>."                 |
| the first component of every `claudeFiles` path is the folder name of a project of `project`                                                                                                                                           | "Unknown transcript folder <name>."                        |

   Folder name of a project: `ClaudePathEncoding.folderName(for: <its rootPath>)` computed on the received
   `rootPath`s; it maps to that project's root relative to `project.rootPath` (`""` for the top-level project).

   The checks run row by row, each list in turn (`manifest`, then `claudeFiles`). The <reason> of "Invalid manifest
   entry <path>: <reason>.":

| Check         | <reason>                                                                                                                                      |
|---------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| path          | "the path is empty", "the path starts with /", "the path contains a NUL character", "the path has an empty, . or .. component"                |
| duplicate     | "it appears twice"                                                                                                                            |
| parent        | "its parent is not a folder of the list"; a `claudeFiles` entry of one component that is not a folder: "a transcript folder must be a folder" |
| file          | "sha256 is not 64 lowercase hex digits", "the size is negative"                                                                               |
| folder        | "a folder has size 0 and no sha256"                                                                                                           |
| symbolic link | "a symbolic link is not a folder and has size 0, no sha256 and a target"                                                                      |
| every entry   | "the mode is not in 0…0o7777"                                                                                                                 |

2. Creates the destination folder `<projectsFolder>/<folderName>`, or the first of `<folderName> 2`,
   `<folderName> 3`, … for which no item exists (checked with `lstat`). `projectsFolder` is the device setting
   (`DeviceSettings.projectsFolderURL`, [../data/app-storage.md](../data/app-storage.md)), created when missing. A
   failure answers `internal` "Cannot create <path>: <error>".
3. Creates a staging folder for the transcripts:
   `FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: <D's config>/projects,
   create: true)` (`<D's config>/projects` is created first when missing). A failure removes the destination folder of
   step 2 and answers `internal` "Cannot create <D's config>/projects: <error>".
4. Records the migration (source device id, the `connectionID` of the request, destination folder, both lists, per
   file: bytes received and an incremental `SHA256` hasher) and answers `{destinationPath}`: the destination folder's
   absolute path.

### migration.chunk

| Check                                                                                                   | Error                                                   |
|---------------------------------------------------------------------------------------------------------|---------------------------------------------------------|
| the migration exists, is not finished or being committed, and was begun by the calling device           | `notFound` "No migration <id>."                         |
| `path` is a file entry of `manifest` (`transcript` false) or of `claudeFiles` (`transcript` true)       | `notFound` "<path> is not in the manifest."             |
| `offset` equals the bytes received so far for that file                                                 | `badRequest` "Unexpected offset <offset> for <path>."   |
| `data` is not empty, has 262,144 bytes unless `offset + data.count == size`, and ends at most at `size` | `badRequest` "Invalid chunk for <path>."                |

- The first chunk of a file creates it, empty, with mode `0o644`, after creating its missing parent folders with mode
  `0o755`. A project file goes to `<destination folder>/<path>`; a transcript file goes to `<staging>/<index>`, the
  index of its entry in `claudeFiles`.
- The data is appended and fed to the file's hasher; when the file has `size` bytes its digest is finalized and the
  file is closed. At most one file is open.
- A write failure answers `internal` "Cannot write <path>: <error>".

### migration.commit

D answers within the request timeout: digests were computed while the chunks arrived. In order:

1. The migration exists, is not being committed, and was begun by the caller (`notFound` "No migration <id>.").
2. Verification, for every file entry of both lists: a file of size 0 must have the SHA-256 of empty data; other
   files must have received `size` bytes (`badRequest` "Missing data for <path>.") with a digest equal to `sha256`
   (`badRequest` "Checksum mismatch for <path>.").
3. Project folder, in `manifest` order: missing folders are created (`0o755`), empty files are created, symbolic links
   are created with `FileManager.createSymbolicLink(atPath:withDestinationPath: symlinkTarget)`.
4. Modes and dates: each file gets `setAttributes([.posixPermissions: mode, .modificationDate: modified])`; then each
   folder the same, in reverse `manifest` order (deepest first, after their content was written). Symbolic links and
   the destination folder itself are left as created.
5. Transcripts: the destination folder of a transcript folder is
   `<D's config>/projects/<ClaudePathEncoding.folderName(for: canonicalPath(<destination folder>[/<relative root>]))>`
   (the path itself when its realpath(3) fails).
   For each `claudeFiles` entry, in order, at that folder joined with the rest of its path: a folder is created when
   missing; for a file or a link an existing item at that place is removed, then the staged file is moved there (an
   empty file is created for size 0) or the link is created. Modes and dates are applied as in step 4. Every installed
   path is recorded.

   In steps 3 and 5, each path is resolved inside the realpath(3) of its folder (the destination folder, whose path
   itself is used when its realpath(3) fails, or the transcript folder for the rest of a `claudeFiles` path) with
   `PathResolver.resolve(_:followLast: false)` ([../services/files.md](../services/files.md) §2): a path that a symbolic
   link created earlier would lead outside it (on a case-insensitive volume, also a link whose name differs in letter
   case) fails with `badRequest` "<path> is outside the project.", <path> as given to `resolve`. A file system failure
   in steps 3–5 is `internal` "Cannot write <path>: <error>", <path> being the entry's `path`; a realpath(3) of a
   transcript folder that fails is such a failure.
6. Registration: `host.registry.register(root: <destination folder>, parentID: nil)`
   ([../services/host.md](../services/host.md#64-registerrootparentid)): it reads project.yml, refuses an identifier
   taken meanwhile (`conflict`), adds the folder to `projects.json`, watches it and broadcasts `projects.changed`.
7. The journal entry `received` is added ([Journal](#journal)); a failure to write it is logged and the commit goes on.
8. The staging folder is removed, the migration is finished, D answers `{}`.

A failure in steps 2–6 rolls back: the recorded transcript paths, the destination folder and the staging folder are
removed (`FileManager.removeItem`), the migration is finished, and the error is answered (`badRequest`, `conflict`, or
`internal` for a file system error).

### After the commit

S, after `{}` (or an outcome check that answered `committed`), the journal entry being `committed`:

1. `host.registry.unregister(projectID, forget: true)`: the project and its sub projects leave the registry and
   `projects.json`, the folder is no longer watched, `projects.changed` is broadcast
   ([../services/host.md](../services/host.md#65-unregister_forget)).
2. `host.sessions.stopAll(projectID:)` and `host.runs.stopAll(projectID:)` for every project id of the tree (no
   process runs; the cached sessions and the runs are forgotten).
3. `host.appSupport.trashItem` ([../data/app-storage.md](../data/app-storage.md#trash)) on the project folder, then on
   each transcript folder that was included in `claudeFiles`. A failure is logged and the next item is processed.
4. The journal entry is removed when the project folder is in the Trash or no longer exists; when its Trash failed, the
   entry stays `committed` and the next start of the host tries again
   ([Recovery after a restart](#recovery-after-a-restart)).
5. Progress `completed`.

Windows showing the project follow it to D ([UI expectations](#ui-expectations)).

## Failures

### Source

Any failure of the source run before the commit answer, and an outcome check that answered `unknown`: when
`migration.begin` had succeeded, or failed with `unavailable` (no answer in time, or the link closed: D may have begun
the migration), `migration.abort {migrationID}` is sent (10 s, its error ignored); then
`host.registry.setMigrating(projectID, false)`, the journal entry is removed, and progress `failed` with `error` = the
failure's message (the `ProtocolError` message, or the error's `localizedDescription`; after an outcome check, the
message of the failed commit). The project stays on S, unchanged. Without the abort after a lost `migration.begin`
answer, D would keep that migration, its folders and `isActive()` true until the connection that carried it closes
([Destination](#destination)), which can take as long as the peer link lasts. `unavailable` also covers
"<D name> is not connected." thrown before anything was sent, when S had no established link to D: the abort is sent
then too, since `requestPeer` throws the same error when the link closes after the request was sent
([mesh.md](mesh.md#requests-to-other-mains)).

### Destination

- `migration.abort`: an unknown or finished migration changes nothing. Otherwise D closes the open file and removes
  the destination folder and the staging folder; the migration is finished. Answer `{}`. An abort that arrives during
  a commit waits for the commit to end; a committed migration is not undone.
- When the connection that carried `migration.begin` closes (`MeshService.connectionClosed` calls
  `connectionClosed(connectionID:)`), D aborts every unfinished migration begun on it, with the same rules.

### Lost commit answer

When `migration.commit` fails with `unavailable` (no answer in time, or the link closed), S does not know whether D
registered the project. The project stays locked, the progress and the journal entry stay `committing`, and S starts
an outcome check ([Outcome checks](#outcome-checks)): `committed` → [After the commit](#after-the-commit);
`unknown` → [Source](#source). There is no time limit; a restart of S resumes the check from the journal.

### Interrupted Mains

- D quits or crashes during a move: S's next request fails. Before the commit S takes the failure path; during the
  commit S has a lost commit answer and its outcome check waits until D is back (D's journal tells whether D
  registered the project). A partial destination folder left by a crash stays in D's projects folder, unregistered;
  the user deletes it. The staging folder is a system temporary folder.
- S quits or crashes: its link closes and D aborts the unfinished migration (a commit in progress ends first and is
  kept). The lock lived in memory, but the journal did not: at its next start S resolves the move
  ([Recovery after a restart](#recovery-after-a-restart)). A move that had not reached the commit leaves the project on
  S; a committed move ends with the project on D only.
- D crashes after registering the project and before writing its `received` entry: an outcome check answers `unknown`,
  so both Mains host the project; the user removes one copy (Overview ▸ Remove Project).

## Journal

Each Main records its moves in its migration journal, `migrations.json` in its Application Support folder (format:
[../data/app-storage.md](../data/app-storage.md#migrationsjson)), so that a source that quits or crashes finishes its
part of a move at its next start. `MigrationService` loads the journal in `recover()`, keeps the entries in memory, and
writes the whole file with `MigrationJournal.save` after each change. `updatedAt` is set at each change.

Source entries, on S: `{migrationID, projectID, rootPath, targetDeviceID, state, updatedAt}`, `rootPath` being the
root the project is registered with (`HostedProject.root.path`, the `projects.json` form).

| Moment                                                                                             | Entry                   |
|----------------------------------------------------------------------------------------------------|-------------------------|
| before `migration.begin` is sent ([Source run](#source-run) step 3)                                | added as `transferring` |
| before `migration.commit` is sent (step 6)                                                         | becomes `committing`    |
| the commit answer `{}` arrives, or an outcome check answers `committed`                            | becomes `committed`     |
| the project is unregistered and its folder is in the Trash ([After the commit](#after-the-commit)) | removed                 |
| the move fails ([Source](#source))                                                                 | removed                 |

A write of the entry that fails before `migration.commit` is sent fails the move with `internal` "Cannot write
migrations.json: <reason>.", <reason> being the message of the `DataError` (else the error's `localizedDescription`)
without its `migrations.json: ` prefix and without the periods at its end; a write that fails afterwards is logged and
the move goes on.

Destination entries, on D: `{migrationID, projectID, rootPath: <destination folder>, sourceDeviceID: <S's id>, state:
received, updatedAt}`, added by `migration.commit` once the project is registered (step 7). `MigrationJournal` drops
them 30 days after `updatedAt`. They answer `migration.status`.

## Recovery after a restart

`HostService.start()` calls `migration.recover()` right after `registry.load()`, before the file watcher, the
listener and the peer links start ([../services/host.md](../services/host.md#31-start)). It loads the journal, keeps the
`received` entries, and handles each source entry by its state:

| State          | Action                                                                                                                                                                                                                                                                                                                      |
|----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `committed`    | D has the project; S finishes its cleanup: the project folder is moved to the Trash when it still exists (`appSupport.trashItem` of `ClaudePathEncoding.canonicalPath(rootPath)`; nothing when it is nil), the project is unregistered (`registry.forgetRoot(rootPath)`), and the entry is removed                          |
| `committing`   | S does not know whether D committed: the project stays `migrating` (`registry.setMigrating(projectID, true)` when the top-level project registered at `rootPath` has that identifier) and an outcome check is started ([Outcome checks](#outcome-checks))                                                                   |
| `transferring` | The move had not reached the commit: the project is served as before (no `migrating` flag is set), the entry is removed, and `migration.abort {migrationID}` is queued for the target: sent once, best effort (10 s, the result ignored), as soon as S's peer link to the target is established during this run of the host |

- `committed`: when the Trash fails, it is logged, the project is unregistered anyway and the entry stays `committed`,
  so the next start tries again. The Claude CLI transcript folders of the project are not moved to the Trash by the
  recovery (the journal does not record them); they stay under `<config>/projects/`.
- Nothing is emitted for these steps: no device is connected yet. The tree that devices then load shows the result.

### Outcome checks

An outcome check asks D whether it committed a move whose commit answer S does not have: after a lost commit answer,
and for each `committing` entry found at start. While it is pending, the journal entry stays `committing` and the
project stays `migrating` (writes refused with `locked`).

- The check sends `migration.status {migrationID}` with `host.mesh.requestPeer(<D>, method: "migration.status",
  params: MigrationStatusParams(migrationID:), as: MigrationStatusResult.self, timeout: .seconds(30))` as soon as S
  has an established peer link to D (`mesh.connectedPeerMains()` lists D, or the host calls `peerLinkOpened(D)` when the
  link opens), then every 10 s while the link stays established, until it gets an answer. A failed request (timeout,
  link closed, error response) is tried again; there is no time limit.
- `committed`: a check of a running move goes on with [After the commit](#after-the-commit). A check started at start
  sets the entry to `committed`, moves the project folder to the Trash when it still exists, unregisters the project
  (`registry.forgetRoot(rootPath)`), removes the entry (kept `committed` when the Trash fails, as at start), and
  broadcasts progress `completed`.
- `unknown`: a check of a running move takes the failure path of [Source](#source). A check started at start clears
  the flag (`setMigrating(projectID, false)` when the project is registered), removes the entry, and broadcasts
  progress `failed` with the error "The move to <D name> did not complete.".
- The progress of a check started at start carries `fromDeviceID` = S, `toDeviceID` = the entry's `targetDeviceID`,
  `projectID`, and `bytesDone` and `bytesTotal` 0 ([Progress](#progress)).
- `stop()` cancels the pending checks, whose entries stay `committing` in the journal for the next start, and drops
  the queued aborts, whose entries `recover()` already removed: an abort not sent during that run of the host is never
  sent.

### migration.status

D answers `{state}`: `committed` when its journal has a `received` entry with that `migrationID`, else `unknown`. When
a commit of that migration is in progress on D, the answer waits for it to end (as `migration.abort` does).

## Progress

S broadcasts `migration.progress {migrationID, projectID, fromDeviceID, toDeviceID, state, bytesDone, bytesTotal,
error?}` ([../protocol/events.md](../protocol/events.md)) with `host.events.broadcast`:

| `state`        | When                                                                                                    | `bytesDone`            | `bytesTotal`              |
|----------------|---------------------------------------------------------------------------------------------------------|------------------------|---------------------------|
| `preparing`    | the move started                                                                                        | 0                      | 0                         |
| `transferring` | `migration.begin` answered; then at most every 500 ms while chunks are answered, and after the last one | bytes answered         | the sum of the file sizes |
| `committing`   | `migration.commit` is sent                                                                              | `bytesTotal`           | same                      |
| `completed`    | the cleanup after the commit ended                                                                      | `bytesTotal`           | same                      |
| `failed`       | the move failed; `error` set                                                                            | last value             | same                      |

An outcome check started after a restart of S broadcasts `completed` or `failed` with `bytesDone` and `bytesTotal` 0
([Outcome checks](#outcome-checks)).

### UI expectations

- Every window of every device connected to S that shows the project, or a project containing it, presents the
  progress sheet of [../ui/overview.md](../ui/overview.md#progress-sheet), driven by these events: progress
  `bytesDone` of `bytesTotal` (indeterminate while `bytesTotal` is 0) and one line per state:

| `state`        | Line                                                                   |
|----------------|------------------------------------------------------------------------|
| `preparing`    | "Preparing…"                                                           |
| `transferring` | "Copying files…"                                                       |
| `committing`   | "Installing on <to Main>…"                                             |
| `completed`    | "Moved to <to Main>."                                                  |
| `failed`       | "Move failed: <error>", then "The project stays on <from Main>."       |

- On `completed`, every window whose selection is the project or one of its sub projects selects it on D: the path bar
  switches to D (rule 2 "Project moved" of the Workspace's
  [selection rules](../client/workspace.md#selection-rules)).
- While the project is locked, controls that would write show the `locked` error banner when used.

## Swift API

```swift
// HephHost/Migration/MigrationService.swift
public actor MigrationService: HostMethodHandler {
    public init(host: HostService)
    /// True while a migration runs here, as source or destination (Main toggle, Leave mesh, host active work); a move
    /// that only waits for an outcome check does not count.
    public func isActive() -> Bool
    /// HostService.start() step 2: loads migrations.json and handles its source entries (Recovery after a restart).
    func recover() async
    /// HostService.stop() step 3: cancels the outcome checks and the queued aborts; the journal stays.
    func stop()
    /// The host's peer-link observer: a link to `deviceID` was established; runs its pending checks and aborts.
    func peerLinkOpened(_ deviceID: UUID) async
    /// Called by MeshService when a connection served by this Main closes.
    func connectionClosed(connectionID: UUID) async
    // HostMethodHandler: projects.migrate, migration.begin, migration.chunk, migration.commit, migration.abort,
    // migration.status. Public: a public actor conforming to the public protocol.
    public func handle(method: String, params: Data, context: RequestContext) async throws -> Data
}

// HephHost/Migration/ManifestBuilder.swift
enum ManifestBuilder {
    static let excludedNames: Set<String>          // [".build", "DerivedData", "node_modules", ".DS_Store"]
    static func entries(of root: URL, prefix: String) throws -> [ManifestEntry]
}

// HephHost/Migration/MigrationSender.swift: the source run of one migration, a task owned by MigrationService.
// HephHost/Migration/MigrationReceiver.swift: the destination state of one migration (lists, files, hashers,
// staging folder) and its begin, chunk, commit and abort steps, used by MigrationService.

// HephCore/Util/ClaudePathEncoding.swift
public enum ClaudePathEncoding {
    /// The folder name the Claude CLI uses under <config>/projects/ for the working directory `path`.
    public static func folderName(for path: String) -> String
    /// realpath(3) of an existing path; nil when it does not exist.
    public static func canonicalPath(_ path: String) -> String?
    /// CLAUDE_CONFIG_DIR of `environment` when set and not empty, else <home>/.claude.
    public static func configDirectory(environment: [String: String], home: URL) -> URL
    /// <configDirectory>/projects/<folderName(for: canonicalPath(projectRoot) ?? projectRoot)>
    public static func transcriptsFolder(projectRoot: String, configDirectory: URL) -> URL
}
```

- `MigrationService` is created by `HostService.init` with the other services
  ([../services/host.md](../services/host.md#1-objects)) and reaches them through `host`: `registry`, `sessions`,
  `runs`, `mesh`, `events`, and `appSupport` for the Trash and the journal (`MigrationJournal`,
  [../data/app-storage.md](../data/app-storage.md#migrationsjson)).
- `ClaudePathEncoding` is also the encoding of the transcript path of [../claude/cli.md](../claude/cli.md)
  (`ClaudeLocator`).
- Params and results are the structs of [../protocol/methods.md](../protocol/methods.md#migration)
  (`ProjectsMigrateParams`, `ProjectsMigrateResult`, `MigrationBeginParams`, `MigrationBeginResult`,
  `MigrationChunkParams`, `MigrationCommitParams`, `MigrationAbortParams`, `MigrationStatusParams`,
  `MigrationStatusResult`, with `MigrationOutcome` of [../protocol/types.md](../protocol/types.md)); the event
  payload is `MigrationProgressPayload` ([../protocol/events.md](../protocol/events.md)).
