# Task bundles

files:
- HephaestusKit/Sources/HephCore/YAML/BundleFile.swift
- HephaestusKit/Sources/HephHost/Bundles/BundleService.swift
- HephaestusKit/Sources/HephHost/Bundles/BundleGit.swift

---

A bundle is a named, ordered group of tasks of one project that Claude works on in parallel. The user creates it in
the Tasks screen ([../ui/tasks.md](../ui/tasks.md#bundles)) and presses Work on Bundle: the Main starts the bundle's
**coordinator**, a Claude session of kind `bundle`, which starts one task session per task, at most
`bundles.maxParallel` at a time. Each task session works in its own git worktree, on its own branch, so that the
sessions never change each other's files. When every task is in review, the coordinator shows the user the combined
work, and once the user agrees it brings the branches into the project's branch, pushes them (the Forge source
project, [../forge/pipeline.md](../forge/pipeline.md#mcp-tools)) or leaves them for the user to push (other projects),
and finishes the bundle.

`BundleFile.swift` is in `HephCore`; the files of `HephHost/Bundles` are macOS only and wrapped in `#if os(macOS)`.
Logging uses `Log.host` ([../architecture.md](../architecture.md#logging)), in `BundleFile` too; bundle names are never
logged.

## Bundle id

- A bundle id is `<projectID>-B<n>`: the project identifier, `-B`, and the bundle number `n` (1 to `Int.max`; decimal,
  no leading zero). Pattern: `^[A-Z]{2,8}-B[1-9][0-9]*$`. Example: `HEPH-B3`. It never matches the task id pattern,
  so a selection item is either a task id or a bundle id ([../ui/tasks.md](../ui/tasks.md)).
- `BundleID(_:)` trims and maps ASCII `a`–`z` to `A`–`Z` before matching, as `TaskID(_:)` does
  ([../data/task-yml.md](../data/task-yml.md#task-id)); `BundleID(fileName:)` matches `<id>.yml` exactly.
- A new bundle takes the number after the highest number among the entries of `.hephaestus/bundles/` whose name is
  `<projectID>-B<n>.yml` (`1` when there is none); `.invalid("no bundle number is left in <projectID>")` past
  `Int.max`. Deleting the bundle with the highest number lets its number be used again.

## Bundle file

`<project root>/.hephaestus/bundles/<bundle id>.yml`. The YAML coding, unknown-key and read-modify-write rules of
[../data/project-yml.md](../data/project-yml.md#yaml-coding-all-yaml-files) apply. Top level, in this order:

| Key           | YAML type         | Required | Default | Written  | Meaning                                                                 |
|---------------|-------------------|----------|---------|----------|-------------------------------------------------------------------------|
| `id`          | string            | yes      |         | always   | Bundle id; equals the file name without `.yml`.                         |
| `name`        | string            | yes      |         | always   | Name of the bundle.                                                     |
| `status`      | string            | no       | `draft` | always   | `draft`, `running`, `review` or `done` (`BundleStatus`).                |
| `created`     | timestamp         | yes      |         | always   | Creation time.                                                          |
| `updated`     | timestamp         | yes      |         | always   | Time of the last change made by the app.                                |
| `base`        | string            | no       | absent  | when set | The branch the worktrees branch from; set by the first `bundles.start`. |
| `coordinator` | string            | no       | absent  | when set | UUID of the coordinator session; set by the first `bundles.start`.      |
| `tasks`       | sequence of items | no       | `[]`    | always   | The tasks, in the bundle's order.                                       |

Item of `tasks`:

| Key       | YAML type | Required | Default | Written  | Meaning                                                       |
|-----------|-----------|----------|---------|----------|---------------------------------------------------------------|
| `task`    | string    | yes      |         | always   | Task id, of the bundle's project.                             |
| `session` | string    | no       | absent  | when set | UUID of the task session the bundle started for it, the last. |

Validation, applied as in [../data/task-yml.md](../data/task-yml.md#validation-and-normalization):

| Key             | Normalization                                           | Rule                                                  | Message                                                     |
|-----------------|---------------------------------------------------------|-------------------------------------------------------|-------------------------------------------------------------|
| `id`            | none                                                    | a bundle id equal to the file name without `.yml`     | `id <id> does not match the file name <file name>`          |
| `name`          | leading and trailing whitespace and line breaks removed | not empty, no line break                              | `the name must not be empty and must be on one line`        |
| `status`        | none                                                    | a `BundleStatus` value (checked by decoding)          | `status: invalid value`                                     |
| `base`          | whitespace trimmed; empty becomes absent                | no whitespace                                         | `base must be a branch name`                                |
| `tasks[i].task` | `TaskID(_:)` form                                       | a task id of the bundle's project, unique in the file | `tasks[<i>].task must be a task of <projectID> listed once` |

`coordinator` and `tasks[i].session` are decoded as `UUID`s. A file that breaks a rule, cannot be read or is not valid
YAML is skipped and logged when the bundles are loaded; the app never writes it. The tasks need not exist: a task
deleted later stays listed, and the UI shows it as deleted.

`BundleFile.loadAll(projectRoot:projectID:)` lists `.hephaestus/bundles/` like the task files
([../data/task-yml.md](../data/task-yml.md#loading-the-tasks-of-a-project)) and sorts the bundles by number; each file
it skips is logged with `Log.host` (`error`: the file name and the `DataError` message). The file watcher does not
follow the folder: every change goes through `BundleService`.

Errors, as those of `TaskFile` ([../data/task-yml.md](../data/task-yml.md#changes-made-by-the-app)):

- `BundleFile.create` fails with `.invalid("<id> is not a bundle id")` when the file's `id` is not a bundle id, and
  with `.invalid("<id>.yml already exists")` when the bundle file exists.
- `BundleFile.update` and `BundleFile.delete` of a missing file fail with `.notFound("bundle <id> not found")`.
- `BundleFile.update` of a file that does not decode or breaks a rule fails with
  `.refused("The file is invalid: HEPH-B1.yml: <problem>")`.

Example:

```yaml
id: HEPH-B1
name: Sidebar polish
status: running
created: 2026-10-30T08:00:00Z
updated: 2026-10-30T09:12:00Z
base: main
coordinator: 6A1F0C2E-3B4D-4E5F-8A9B-0C1D2E3F4A5B
tasks:
- task: HEPH-12
  session: 0B1E5C6A-2F3D-4E5F-8A9B-0C1D2E3F4A5B
- task: HEPH-14
```

## Mapping to BundleItem

`BundleItem` ([../protocol/types.md](../protocol/types.md#bundleitem)): `id`, `name`, `status`, `created`, `updated`,
`base`, `coordinatorSessionID` = `coordinator`, `tasks` = one `BundleTask {taskID, sessionID}` per item.

## Worktrees

`BundleGit` runs `git -c core.hooksPath=/dev/null -c core.fsmonitor=false <arguments>` with the arguments listed
here, as the Forge's git does ([../forge/pipeline.md](../forge/pipeline.md#git-operations)): no hook or file-system
monitor of the repository runs in the app's process, since the sessions can change them. git is the first executable
regular file named `git` in the `PATH` of the login environment, run with `ChildProcess.capture`, that environment, no
shell and a timeout of 60 s. A failure is `internal` `git <subcommand> failed: <reason>`,
`<reason>` being the last non-empty line of stderr, else `timed out` for a timeout and `exit status <N>` otherwise; a
git that is not found gives `strerror(ENOENT)`, one that cannot be started the `strerror` of the spawn error.
`BundleService` uses `BundleGit` only while `host.info` reports `gitAvailable`; otherwise the method or tool fails with
`unavailable` `git is not available on this Main.`

- **Repository.** `<top>` = `git rev-parse --show-toplevel` in the project's code folder
  ([../data/project-yml.md](../data/project-yml.md)); `<rel>` = the code folder's path relative to `<top>` (empty when
  they are equal). The code folder must be in a repository whose `HEAD` is a branch with a commit
  (`git symbolic-ref --short HEAD` and `git rev-parse --verify HEAD` succeed), else `badRequest` `Bundles need a git
  repository on a branch with a commit: <code folder path> is not in one.`
- **Branch.** The branch of a task is `task/<task id>`, for example `task/HEPH-12`. It exists when
  `git rev-parse --verify --quiet refs/heads/task/<id>`, run in `<top>`, exits with status 0, and does not when it
  exits with status 1; another status is a failure (`BundleGit.branchExists`).
- **Worktree folder.** `<Application Support>/Hephaestus/Worktrees/<projectID>/<task id>/`
  ([../data/app-storage.md](../data/app-storage.md#folder)). The **work folder** of the task is
  `<worktree folder>/<rel>`: the code folder's place in the worktree.
- **Creating.** When the worktree folder does not exist: `git worktree prune`, then, when the branch exists,
  `git worktree add <folder> task/<id>`, else `git worktree add -b task/<id> <folder> <base>`. The parent folders are
  created first. Every command runs in `<top>`.
- **Removing.** `git worktree remove --force <folder>`; when it fails, its error is logged; when the folder is still
  there, it is deleted; then `git worktree prune`.
- **Brought in.** A branch's work is on `<base>` when `git cherry <base> task/<id>` prints no line starting with `+`:
  every commit of the branch has an equal change on `<base>`.
- **Removing the work** (`bundles.delete`, `finish`). For each task of the bundle, in order: its worktree is removed
  when its folder exists; then, when the bundle has a `base` and the task's branch exists, the branch is deleted
  (`git branch -D task/<id>`) when its work is on `base`, else kept. Without a `base` no branch is looked at; a branch
  that does not exist is neither deleted nor kept.

## BundleService

`BundleService` is the `bundles` service of the host ([host.md](host.md#1-objects)): an actor created with
`init(host: HostService)`, conforming to `HostMethodHandler`. It keeps the `BundleItem`s of every registered project in
a cache, loaded with the project and dropped with it, and runs every change inside `registry.write(projectID)`. Each
change emits `bundleChanged {projectID, bundle}` (`bundleRemoved {projectID, bundleID}` for a deletion) when the
bundle differs from the cached one. The event is emitted before the method or tool returns: the device that called a
method receives it before the response.

A `bundleID` that `BundleID(_:)` does not parse with the project's identifier, or without a cached bundle: `notFound`
`Bundle <id> does not exist.`; so is a bundle file that a change finds missing (`.notFound("bundle <id> not found")`).
The other `DataError`s map as in [host.md](host.md#69-data-errors). A task id given to a method must name a task of the
project that is not broken (`notFound` `Task <id> does not exist.`, `conflict` `The file is invalid: <parseError>`).

### Methods

| Method           | Statuses allowed                        | Effect                                                                                                                            |
|------------------|-----------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| `bundles.create` | —                                       | new file: `name`, `status` `draft`, the tasks in the given order, repeats removed (first kept); at least one task                 |
| `bundles.update` | `name`: any; `taskIDs`: `draft`, `done` | `name` replaced; `taskIDs` replaces the tasks, keeping the `session` of a task that stays, and turns a `done` bundle into `draft` |
| `bundles.delete` | `draft`, `done`                         | Removing the work ([Worktrees](#worktrees)); file deleted                                                                         |
| `bundles.start`  | `draft`                                 | Start (below)                                                                                                                     |
| `bundles.stop`   | `running`, `review`                     | `sessions.stop` of the coordinator and of every task session of the bundle; status `draft`; worktrees and branches kept           |

A method in another status fails with `conflict`: `Stop <bundle id> first.` for `running` and `review`, `<bundle id>
is done.` for `bundles.start` of a `done` bundle, `<bundle id> is not running.` for `bundles.stop` of a `draft` or
`done` bundle. `bundles.create` and `bundles.update` without a task: `badRequest` `A bundle needs at least one task.`
A name that is empty or holds a line break: `badRequest` `The name must not be empty and must be on one line.` The
`taskIDs` of `bundles.update` are not deduplicated: a task given twice breaks the file's rule (`badRequest`
`tasks[<i>].task must be a task of <projectID> listed once`). A task is in at most one bundle that is not `done`, since
it has one worktree, which another bundle would remove: a task of `bundles.create`, or of the `taskIDs` of
`bundles.update`, that is in another bundle of the project whose status is not `done` fails with `conflict` `<task id>
is in <bundle id>.`, the first such task and bundle in order.

### Start

1. The repository check of [Worktrees](#worktrees).
2. `base`: kept when set; otherwise `git symbolic-ref --short HEAD` in the code folder, which the cached `BundleItem`
   takes at once, without an event and without writing the file: the coordinator's prompt reads it there in step 3
   ([../claude/prompts.md](../claude/prompts.md#bundle-part)).
3. When `coordinator` names a session of the project: `sessions.send` to it with the text `Resume work on <bundle id>:
   check the state of its tasks with get_bundle.` and this Main's id as `deviceID`. Otherwise
   `sessions.start(SessionStart(projectID:, kind: .bundle, bundleID: <id>, deviceID: <this Main>))`
   ([../claude/cli.md](../claude/cli.md#52-starting-a-session-sessionsstart)), and `coordinator` = its id.
4. The file is written: `base`, `coordinator`, `status` `running`. Result: the `BundleItem`.

When step 3 fails, nothing is written, the cached `base` set by step 2 is removed, and the error is returned.

### Observing the task sessions

The host calls `sessionChanged(projectID:session:)` for every `session.changed` it emits
([host.md](host.md#5-events)). For a `task` session whose `bundleID` names a bundle in `running` or `review`, a change
of status sends one message to the bundle's coordinator with `sessions.send` (this Main's id as `deviceID`; errors
logged):

| New status          | Condition                                                             | Message                                                          |
|---------------------|-----------------------------------------------------------------------|------------------------------------------------------------------|
| `waitingPermission` | —                                                                     | `<task id> is waiting for a permission answer in its session.`   |
| `idle`, `stopped`   | the session had `running` or `waitingPermission`, and its task exists | `<task id> ended its turn. Task status: <TaskStatus raw value>.` |
| `failed`            | —                                                                     | `The session of <task id> failed: <SessionInfo.error>`           |

The previous statuses are kept in memory per session. A message sent while the coordinator runs a turn is queued by the
CLI ([../claude/cli.md](../claude/cli.md#55-statuses)).

### Tools of the coordinator

The MCP tools of [../claude/mcp.md](../claude/mcp.md#625-get_bundle) call these functions with the calling session's
`bundleID`; a session without one gets the tool error `Only the coordinator of a bundle can use this tool.`, once the
tool's arguments are checked.

- `details(projectID:bundleID:)`: for `get_bundle`.
- `startTask(projectID:bundleID:taskID:instructions:)`, for `start_bundle_task`:
  1. The task is in the bundle (`badRequest` `<task id> is not in <bundle id>.`); the bundle is `running` or `review`
     (`conflict` `<bundle id> is not running.`).
  2. When the task's `session` names a session of the project: `instructions` must be given (`badRequest` `<task id>
     already has a session: give instructions for it.`), and they are sent to it with `sessions.send`. Result: that
     `SessionInfo`.
  3. Otherwise the number of task sessions of the bundle whose status is `starting`, `running` or `waitingPermission`
     must be below `bundles.maxParallel` (`conflict` `<n> task sessions of <bundle id> are running, the limit of this
     Main (Settings ▸ Claude ▸ Bundles). Start <task id> when one of them ends its turn.`).
  4. The worktree is created when missing ([Worktrees](#worktrees)), `<base>` being the bundle's `base`, or the
     current branch (`git symbolic-ref --short HEAD` in the code folder) when the bundle has none.
  5. `sessions.start(SessionStart(projectID:, kind: .task, taskID:, mode: .implement, message: instructions,
     deviceID: <this Main>, bundleID:))`; the item's `session` = its id; the task's status becomes `in_progress`
     (`tasks.update`) when it is `todo`, a failure of that update being logged, not returned. Result: the
     `SessionInfo`.
- `setStatus(projectID:bundleID:status:)`, for `update_bundle`: `status` must be `running` or `review` (`badRequest`
  `Invalid arguments: status must be one of running, review.`), and so must the bundle (`conflict` `<bundle id> is not
  running.`).
- `finish(projectID:bundleID:)`, for `finish_bundle`, while the bundle is `running` or `review` (`conflict` `<bundle id>
  is not running.`): Removing the work
  ([Worktrees](#worktrees)); the bundle becomes `done`; outside the Forge source project, every task of the bundle
  whose branch was deleted gets the status `done` with `tasks.update`, a failure being logged, not returned (in the
  Forge source project, Completion sets it, [../forge/pipeline.md](../forge/pipeline.md#completion)). Result:
  `{"bundle":<BundleItem>,"keptBranches":[…]}`, the branches kept because their work is not on `base`.

### Working folder of a task session

A `task` session with a `bundleID` runs in its task's work folder instead of the project root
([../claude/cli.md](../claude/cli.md#3-the-session-process-claudeprocess)): `workFolder(projectID:taskID:)` returns
it. When the worktree folder or the work folder does not exist (the bundle finished or was deleted), it throws
`notFound` `the worktree of <task id> was removed with its bundle.`, and the process does not start: SessionService
adds `Could not start Claude: ` ([../claude/cli.md](../claude/cli.md#53-starting-the-process)), so the session fails
with `Could not start Claude: the worktree of <task id> was removed with its bundle.`

### Projects removed or moved

- When a project is unregistered for good (removed, or moved to another Main, [host.md](host.md#65-unregister_forget)),
  `removeWorktrees(projectID:)` runs `git worktree remove --force` for each folder of `Worktrees/<projectID>/` while the
  repository is still there and `host.info` reports `gitAvailable`, then deletes `Worktrees/<projectID>/`. The
  branches stay in the repository; a later `start_bundle_task` creates the worktree again.
- A sub project removed with `projects.remove` is unregistered by the reload of its parent, with `forget: false`
  ([host.md](host.md#76-projectsremove)): `removeWorktrees` does not run, and its worktrees stay.
- `projects.migrate` is refused while a bundle of the tree is `running` or `review`: `conflict` `Stop the bundles of
  <name> first.`

## Swift API

```swift
public struct BundleID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let projectID: String
    public let number: Int
    public init(projectID: String, number: Int)
    /// Trims, maps ASCII a–z to A–Z, then matches ^[A-Z]{2,8}-B[1-9][0-9]*$.
    public init?(_ text: String)
    /// Matches "<id>.yml" exactly.
    public init?(fileName: String)
    public var description: String        // "HEPH-B3"
    public var fileName: String           // "HEPH-B3.yml"
}

public struct BundleFile: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var task: String
        public var session: UUID?
        public init(task: String, session: UUID?)
    }
    public var id: String
    public var name: String
    public var status: BundleStatus
    public var created: Date
    public var updated: Date
    public var base: String?
    public var coordinator: UUID?
    public var tasks: [Item]

    /// The values as given.
    public init(id: String, name: String, status: BundleStatus, created: Date, updated: Date, base: String?,
                coordinator: UUID?, tasks: [Item])

    public static let shape: YAMLShape    // as TaskFile.shape, "tasks" a list with identity "task"
    public static func folder(projectRoot: URL) -> URL
    public static func url(projectRoot: URL, id: BundleID) -> URL
    public static func decode(_ text: String, fileID: BundleID) throws -> BundleFile
    public func encode(preserving previousText: String?) throws -> String
    /// Valid files only, by number; broken files are logged and skipped.
    public static func loadAll(projectRoot: URL, projectID: String) -> [BundleFile]
    public static func allocateID(projectRoot: URL, projectID: String) throws -> BundleID
    public static func create(_ file: BundleFile, projectRoot: URL) throws
    /// Read-modify-write; sets updated; writes nothing when the change leaves the file equal.
    @discardableResult
    public static func update(projectRoot: URL, id: BundleID, _ change: (inout BundleFile) throws -> Void) throws
        -> BundleFile
    public static func delete(projectRoot: URL, id: BundleID) throws
}

// HephHost/Bundles
actor BundleService: HostMethodHandler {
    init(host: HostService)
    func load(projectID: String) async
    func unload(projectID: String) async
    func removeWorktrees(projectID: String) async          // errors logged
    func list(projectID: String) -> [BundleItem]          // by number
    func hasActiveBundle(projectID: String) -> Bool       // running or review
    func workFolder(projectID: String, taskID: String) async throws -> URL
    func sessionChanged(projectID: String, session: SessionInfo) async
    // methods
    func create(projectID: String, name: String, taskIDs: [String]) async throws -> BundleItem
    func update(projectID: String, bundleID: String, patch: BundlePatch) async throws -> BundleItem
    func delete(projectID: String, bundleID: String) async throws
    func start(projectID: String, bundleID: String) async throws -> BundleItem
    func stop(projectID: String, bundleID: String) async throws -> BundleItem
    // tools
    func details(projectID: String, bundleID: String) async throws -> BundleDetails
    func startTask(projectID: String, bundleID: String, taskID: String, instructions: String?) async throws
        -> SessionInfo
    func setStatus(projectID: String, bundleID: String, status: BundleStatus) async throws -> BundleItem
    func finish(projectID: String, bundleID: String) async throws -> BundleFinishResult
}

struct BundleGit: Sendable {
    init(codeFolder: URL, environment: [String: String])
    func repository() async throws -> (top: URL, relative: String)
    func currentBranch() async throws -> String
    func createWorktree(at folder: URL, branch: String, base: String) async throws
    func removeWorktree(at folder: URL) async throws
    func isBroughtIn(branch: String, base: String) async throws -> Bool
    func deleteBranch(_ branch: String) async throws
    func branchExists(_ branch: String) async throws -> Bool
}
```

`BundleDetails` is the result of `get_bundle`: `bundle` (`BundleItem`), `maxParallel` (`Int`), and `tasks`, one
`BundleDetails.Entry` per task in order: `task` (`TaskItem`, absent for a deleted task), `session` (`SessionInfo`,
absent without one), `branch` (`String`, `task/<id>`), `workFolder` (`String`, the path of the work folder; absent
while the worktree does not exist). `BundleFinishResult`: `bundle`, `keptBranches` (`[String]`). Both are `Codable`
and encoded as the tool results.

## Depends on

| Name                                                                                   | Defined in                                                                                               |
|----------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `BundleItem`, `BundleTask`, `BundleStatus`, `BundlePatch`, `SessionInfo.bundleID`      | [../protocol/types.md](../protocol/types.md)                                                             |
| `bundles.*`, `bundle.changed`, `bundle.removed`                                        | [../protocol/methods.md](../protocol/methods.md#bundles), [../protocol/events.md](../protocol/events.md) |
| `HostService`, `registry.write`, `emit`, `TaskService`                                 | [host.md](host.md)                                                                                       |
| `SessionService` (`start`, `send`, `stop`, `SessionStart.bundleID`), working directory | [../claude/cli.md](../claude/cli.md)                                                                     |
| the coordinator's tools                                                                | [../claude/mcp.md](../claude/mcp.md)                                                                     |
| the prompts of the coordinator and of its task sessions                                | [../claude/prompts.md](../claude/prompts.md)                                                             |
| `forge_push_docs` for bundles of the Forge source project                              | [../forge/pipeline.md](../forge/pipeline.md#mcp-tools)                                                   |
| `bundles.maxParallel`, `Worktrees/`                                                    | [../data/app-storage.md](../data/app-storage.md)                                                         |
| YAML coding, `YAMLShape`, `TaskID`                                                     | [../data/project-yml.md](../data/project-yml.md), [../data/task-yml.md](../data/task-yml.md)             |
| `ChildProcess`, login environment                                                      | [../claude/cli.md](../claude/cli.md)                                                                     |
