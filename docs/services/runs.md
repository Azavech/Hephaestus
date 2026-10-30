# Runs

files:
- HephaestusKit/Sources/HephHost/Runs/RunService.swift
- HephaestusKit/Sources/HephHost/Runs/RunOutputBuffer.swift

---

A run is one execution of a run configuration (`runs` of project.yml: `name`, `command`, optional `cwd`) on the Main
that hosts the project. `RunService` serves `runs.start`, `runs.stop` and `runs.output`
([../protocol/methods.md](../protocol/methods.md)). The Runs screen and its console are in
[../ui/runs.md](../ui/runs.md); configurations are edited with `projects.update` ([host.md](host.md) §7.5).

## 1. API

```swift
// HephHost/Runs/RunService.swift
actor RunService: HostMethodHandler {
    init(host: HostService)
    func start(projectID: String, name: String) async throws -> RunInfo
    func stop(projectID: String, runID: UUID) async throws
    func output(projectID: String, runID: UUID) async throws -> RunsOutputResult
    func list(projectID: String) -> [RunInfo]          // kept runs, by startedAt ascending
    func activeRunCount(projectID: String?) -> Int     // running runs of a project; of every project when nil
    func stopAll(projectID: String?) async             // stops, waits for the exits, then forgets the runs
}
```

| Caller                                                       | Uses                                                                                  |
|--------------------------------------------------------------|---------------------------------------------------------------------------------------|
| `HostService.stop()`, `hasActiveWork()`                      | `stopAll(projectID: nil)`, `activeRunCount`                                           |
| `ProjectService` (`projects.snapshot`, `projects.remove`)    | `list(projectID:)`, `stopAll(projectID:)`                                             |
| `MigrationService` ([migration.md](../devices/migration.md)) | `activeRunCount(projectID:)` (precondition), `stopAll(projectID:)` (after the commit) |
| MCP tools ([mcp.md](../claude/mcp.md))                       | the `runs.*` methods through `HostService.perform`                                    |

## 2. RunInfo

`RunInfo {id, projectID, name, command, startedAt, endedAt?, exitCode?, state}` and `RunState`
([../protocol/types.md](../protocol/types.md)).

| Field       | Value                                                                                           |
|-------------|-------------------------------------------------------------------------------------------------|
| `id`        | new `UUID`                                                                                      |
| `projectID` | the project identifier                                                                          |
| `name`      | the configuration's name                                                                        |
| `command`   | the configuration's command when the run started                                                |
| `startedAt` | when `runs.start` spawned the process                                                           |
| `endedAt`   | when the run ended; absent while running                                                        |
| `exitCode`  | `ChildTermination.exitCode` (the exit status, or 128 + the signal number); absent while running |
| `state`     | below                                                                                           |

| How the run ended                                                       | `state`     |
|-------------------------------------------------------------------------|-------------|
| still running                                                           | `running`   |
| a stop was requested (`runs.stop`, `stopAll`), whatever the termination | `stopped`   |
| `ChildTermination.exited(0)`                                            | `succeeded` |
| `exited` with another status, or `signaled`                             | `failed`    |

## 3. runs.start {projectID, name} → RunInfo

1. `registry.hosted(projectID)`; `registry.checkWritable(projectID)` (`locked` while the project migrates).
2. The configuration `name` in the project's cached project.yml → else `notFound` "No run configuration named
   <name>.".
3. A run of that configuration in this project is `running` → `conflict` "<name> is already running.".
4. Working folder: the configuration's `cwd` (absent: the project root) resolved like a project path
   ([files.md](files.md) §2) → else `badRequest` "Invalid working folder <cwd>."; it must be an existing folder → else
   `notFound` "No folder at <cwd>.". `<cwd>` is `.` when the configuration has no `cwd`.
5. Spawn (§4). When `ChildProcess.spawn` throws, nothing is recorded and the request fails with `internal` "Could not
   start <name>: <error>".
6. The run is recorded `running`, the history limit applies (§7), `run.changed {projectID, run}` is emitted, and the
   `RunInfo` is returned. Output (§5) and the end of the run (§6) follow in the background.

The environment of §4 (`await LoginEnvironment.shared.environment()`) is read before step 3, so steps 3 to 6 run
without suspension on the actor: two concurrent `runs.start` of one configuration cannot both pass step 3.

## 4. Process

```swift
ChildProcessConfiguration(
    executable: "/bin/zsh",
    arguments: ["-lc", <command>],
    workingDirectory: <working folder of §3 step 4>,
    environment: await LoginEnvironment.shared.environment(),
    standardInput: .null,
    mergeStandardError: true)
```

`ChildProcess.spawn` ([../claude/cli.md](../claude/cli.md)) starts it in its own process group; stdout and stderr share
one pipe, so their output is merged in the order it is written. `RunService` reads `standardOutput` until it finishes
and gets the termination with `waitForExit()`.

## 5. Output

```swift
// HephHost/Runs/RunOutputBuffer.swift
struct UTF8StreamDecoder {
    /// Decodes a chunk; an incomplete UTF-8 sequence at its end waits for the next chunk.
    /// Invalid bytes become U+FFFD.
    mutating func decode(_ data: Data) -> String
    /// What is left, incomplete bytes as U+FFFD.
    mutating func finish() -> String
}

struct RunOutputBuffer {
    static let maxLines = 5_000
    static let maxLineLength = 16_384               // characters
    /// Appends text; returns it as stored (with the line breaks forced into over-long lines).
    mutating func append(_ text: String) -> String
    /// The kept lines, each followed by "\n", then the unterminated last line.
    var text: String { get }
}
```

- Each chunk of `standardOutput` is decoded with `UTF8StreamDecoder` and added to the run's pending text. The text is
  kept as the process wrote it: escape sequences and carriage returns are handled by the console
  ([../ui/runs.md](../ui/runs.md)).
- Flush: the pending text goes through `RunOutputBuffer.append`; the returned text is emitted as
  `run.output {projectID, runID, text, seq}` with `seq` = the run's previous `seq` + 1 (the first batch is 1). The event
  goes to the subscribers of `run:<runID>` ([host.md](host.md) §5).
- A flush happens 100 ms after pending text first arrives, at once when the pending text reaches 64 KiB of UTF-8, when
  `runs.output` is called, and when the output ends.
- Lines end at `\n`. Beyond 5,000 complete lines the oldest are dropped. An unterminated line that reaches 16,384
  characters gets a `\n` inserted by the buffer, so the stored and the streamed text are the same.
- Characters are Swift `Character` values. A `\r\n` pair is one `Character` in Swift: it ends a line like `\n`, and
  the line keeps its `\r`.
- Output lives in memory only.

## 6. Stop and end

- `runs.stop {projectID, runID} → {}`: a run that is not among the project's kept runs → `notFound` "Run <id> does not
  exist."; a run that is not `running` → nothing; otherwise the stop is marked as requested, `terminate()` is started
  in a task (SIGTERM to the group, SIGKILL after 5 s), and the method returns without waiting.
- End: when `standardOutput` has finished and `waitForExit()` returned, `RunService` flushes the rest
  (`UTF8StreamDecoder.finish()` included), sets `endedAt`, `exitCode` and `state` (§2) and emits
  `run.changed {projectID, run}`. The last `run.output` of a run is always emitted before its final `run.changed`.
- `stopAll(projectID:)` requests the stop of every running run of the project (of every project when `nil`), waits
  until each has ended, then forgets the runs of that project (of every project when `nil`). Used by
  `HostService.stop()` and `projects.remove`; the ends emit `run.changed` (`stopped`).

## 7. History

- The Main keeps at most 20 runs per project in memory, running and ended, with their output.
- When a run is recorded and the project already has 20, the oldest ended runs are dropped until 19 remain; running
  runs are never dropped. Dropping emits nothing.
- `list(projectID:)` returns the kept runs by `startedAt` ascending; `projects.snapshot` lists them newest first
  ([host.md](host.md) §7.2).

## 8. runs.output {projectID, runID} → {text, seq}

A run that is not among the project's kept runs → `notFound` "Run <id> does not exist.". Flushes the run's pending
text (§5), then returns `text` = `RunOutputBuffer.text` and `seq` = the `seq` of the last batch emitted (`0` before
any output). A client subscribes to `run:<runID>` first, then applies the events whose `seq` is greater
([../protocol/events.md](../protocol/events.md)).

## 9. Events

| Event         | Delivery                     | When                          |
|---------------|------------------------------|-------------------------------|
| `run.changed` | broadcast                    | a run is recorded; a run ends |
| `run.output`  | subscribers of `run:<runID>` | each flush (§5)               |

`RunService` queues the events of every run and emits them through `HostService.emit` one at a time, in the order it
produced them, so every connection gets the `run.output` of a run in `seq` order and its last `run.output` before its
final `run.changed`. A method does not wait for its events to be sent: the `run.changed` of a new run can reach a
client after the `runs.start` response.
