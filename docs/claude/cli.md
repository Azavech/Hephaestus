# Claude CLI integration

files:
- HephaestusKit/Sources/HephHost/Process/ChildProcess.swift
- HephaestusKit/Sources/HephHost/Process/LineReader.swift
- HephaestusKit/Sources/HephHost/Process/LoginEnvironment.swift
- HephaestusKit/Sources/HephHost/Claude/ClaudeLocator.swift
- HephaestusKit/Sources/HephHost/Claude/ClaudeProcess.swift
- HephaestusKit/Sources/HephHost/Claude/StreamJSONParser.swift
- HephaestusKit/Sources/HephHost/Claude/SessionService.swift
- HephaestusKit/Sources/HephHost/Claude/SessionTitler.swift
- HephaestusKit/Sources/HephHost/Claude/PermissionBroker.swift
- HephaestusKit/Sources/HephHost/Claude/ForgeSessionRules.swift

---

A Main runs every Claude session as a `claude` CLI process driven in stream-json mode. This doc defines the child
process layer shared with git, how the CLI is found, the session process and its JSON lines, permissions,
`SessionService`, which serves the `sessions.*` methods, and `SessionTitler`, the one-shot call that titles a session
from its first message. The Hephaestus tools are in [mcp.md](mcp.md), the prompt texts
in [prompts.md](prompts.md), the plugin folder in [skills.md](skills.md), the session files in
[../data/sessions.md](../data/sessions.md).

Every file of this doc is macOS only and wrapped in `#if os(macOS)`. Every JSON shape below was recorded from Claude
CLI 2.1.309 on this Mac; the recordings are the parser's test fixtures ([../testing.md](../testing.md)). Logging uses
`Log.host` with the levels and privacy rules of [../architecture.md](../architecture.md#logging): message texts, tool
inputs and results, prompts and bearer tokens are never logged.

## 1. Child processes (`HephHost/Process`)

Claude sessions, git and gh ([../forge/pipeline.md](../forge/pipeline.md)), the updater
([../forge/update.md](../forge/update.md)) and the shell lookups below start processes through `ChildProcess`.

### 1.1 Login environment

Child processes get the user's login environment, captured once when the app launches on macOS (Main or not).

- Command: `/bin/zsh -lic 'echo __HEPHAESTUS_ENV__; /usr/bin/env -0'` through `ChildProcess.capture` (1.4): stdin
  `/dev/null`, environment = the app's own environment, working directory = the home folder, timeout 5 s.
- Parsing: only the stdout after the first line equal to `__HEPHAESTUS_ENV__` is used (text printed by shell startup
  files before it is ignored). It is split on NUL bytes; each non-empty item is split at its first `=` into name and
  value. An item without `=`, or with nothing before it, is skipped.
- Failure (timeout, non-zero exit, no marker line): the environment is the app's own environment with `PATH` replaced
  by the fallback PATH.
- Success without a `PATH` variable, or with an empty one: `PATH` is set to the fallback PATH.
- Fallback PATH: `<home>/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, `<home>` being
  the user's home folder path.

```swift
public actor LoginEnvironment {
    public static let shared: LoginEnvironment
    /// Starts the capture in a task. Called once at app launch on macOS; later calls do nothing.
    public func capture()
    /// The captured environment. Waits for a capture in progress; starts one when none was started.
    public func environment() async -> [String: String]
}
```

### 1.2 ChildProcess

```swift
public struct ChildProcessConfiguration: Sendable {
    public enum StandardInput: Sendable { case pipe, null }
    public var executable: String              // absolute path; also argv[0]
    public var arguments: [String]             // argv[1...]
    public var workingDirectory: String
    public var environment: [String: String]
    public var standardInput: StandardInput    // .pipe: written with write(_:); .null: /dev/null
    public var mergeStandardError: Bool        // true: fd 2 is the stdout pipe
    public init(executable: String, arguments: [String], workingDirectory: String,
                environment: [String: String], standardInput: StandardInput = .null,
                mergeStandardError: Bool = false)
}

public enum ChildTermination: Sendable, Equatable {
    case exited(Int32)      // exit status
    case signaled(Int32)    // terminating signal number
    /// The exit status, or 128 + the signal number.
    public var exitCode: Int32 { get }
}

public enum ChildProcessError: Error, Sendable {
    case spawnFailed(errno: Int32)
    case standardInputClosed
    case writeFailed(errno: Int32)
}

public struct CapturedOutput: Sendable {
    public let termination: ChildTermination
    public let standardOutput: Data
    public let standardError: Data
    public let timedOut: Bool
}

public final class ChildProcess: Sendable {
    public static func spawn(_ configuration: ChildProcessConfiguration) throws -> ChildProcess
    public let pid: Int32                          // also the process group id
    public let standardOutput: AsyncStream<Data>   // chunks in order; finishes at end of file
    public let standardError: AsyncStream<Data>    // finishes at once when merged
    /// Writes all bytes to stdin (blocking, serialized by a lock).
    public func write(_ data: Data) throws
    public func closeStandardInput()
    /// Sends `signal` to the whole process group.
    public func signalGroup(_ signal: Int32)
    /// The stop sequence below; returns when the process has exited.
    public func terminate() async
    /// Waits for the exit; every caller gets the same value.
    public func waitForExit() async -> ChildTermination
    /// Runs a short command to completion and collects its output (1.4).
    public static func capture(_ configuration: ChildProcessConfiguration, input: Data? = nil,
                               timeout: Duration) async throws -> CapturedOutput
}
```

`ChildProcess` is `Sendable` because its mutable state (stdin handle, termination, waiters) is guarded by an
`OSAllocatedUnfairLock`.

Spawning:

1. One `pipe()` per used stream: stdin when `.pipe`, stdout always, stderr when not merged. Every pipe end gets
   `FD_CLOEXEC`. The parent's stdin write end gets `F_SETNOSIGPIPE`: a write after the child is gone fails with `EPIPE`
   instead of raising SIGPIPE.
2. File actions: `posix_spawn_file_actions_adddup2` of the child ends onto 0, 1 and 2 (fd 2 = the stdout pipe when
   merged); for `.null`, `posix_spawn_file_actions_addopen(0, "/dev/null", O_RDONLY, 0)`;
   `posix_spawn_file_actions_addchdir_np(workingDirectory)`.
3. Attributes: flags `POSIX_SPAWN_SETPGROUP` (process group 0: the child leads a new group whose id is its pid),
   `POSIX_SPAWN_SETSIGDEF` with every signal (`sigfillset`), `POSIX_SPAWN_SETSIGMASK` with an empty mask,
   `POSIX_SPAWN_CLOEXEC_DEFAULT` (the child inherits only fds 0, 1 and 2).
4. `posix_spawn(&pid, executable, &actions, &attributes, argv, envp)`; argv = `[executable] + arguments`; envp = one
   `NAME=value` string per environment entry. On failure every pipe is closed and `spawnFailed(errno)` is thrown.
5. The parent closes the child's pipe ends.

Running:

- Reading: each output pipe's read end is wrapped in a `FileHandle` whose `readabilityHandler` reads `availableData`
  and yields it to the stream ([../architecture.md](../architecture.md)); empty data (end of file) sets the handler to
  nil, finishes the stream and closes the handle.
- Waiting: one `Thread` calls `waitpid(pid, &status, 0)` (retrying `EINTR`) and records the `ChildTermination`
  (`WIFEXITED` → `exited(WEXITSTATUS)`, `WIFSIGNALED` → `signaled(WTERMSIG)`). A `waitpid` that fails otherwise records
  `exited(-1)` and is logged as a fault.
- Writing: `write(_:)` loops on `write(2)` until every byte is written, retrying `EINTR`. Any other error throws
  `writeFailed(errno)`; after `closeStandardInput()` it throws `standardInputClosed`.

Stop sequence (`terminate()`), used for every stop of sessions:

1. Close stdin when it is a pipe. Send `SIGTERM` to the group (`kill(-pid, SIGTERM)`).
2. Every 100 ms, test the group with `kill(-pid, 0)`. When it fails with `ESRCH` (no process of the group is left) and
   the child has been reaped, return.
3. After 5 s, send `SIGKILL` to the group, wait for the exit, return.

When the process has already exited and its group is empty, `terminate()` returns at once.

### 1.3 LineReader

```swift
public struct LineReader: Sendable {
    public init()
    /// Appends a chunk; returns the lines it completes, in order.
    public mutating func append(_ data: Data) -> [String]
    /// Returns the unterminated rest, or nil when it is empty.
    public mutating func finish() -> String?
}
```

- A line ends at byte `0x0A`. The `0x0A` and one `0x0D` before it are removed.
- Each complete line is decoded as UTF-8, invalid sequences replaced by U+FFFD (`String(decoding:as:)`). Decoding
  happens per line, so a character split across chunks decodes correctly.
- A line longer than 64 MiB is delivered in pieces of 64 MiB. (CLI lines reach tens of KiB: the initialize response
  is about 46 KiB.)

### 1.4 Short commands

`ChildProcess.capture` spawns the configuration (stdin `.pipe` when `input` is given, which a `Thread` of its own
writes then closes while the output is collected; otherwise `.null`), collects stdout and stderr fully, and waits for
the exit. When `timeout` passes first, it sends `SIGKILL` to the group, waits for the exit and returns with
`timedOut = true`. When the calling task is cancelled first, it sends `SIGKILL` to the group, waits for the exit and
throws `CancellationError`. Spawn errors are thrown.

## 2. Locating the CLI (`ClaudeLocator`)

Resolution, in order:

1. Setting `claudePath` not empty ([../data/app-storage.md](../data/app-storage.md), `DeviceSettings.claudeURL`, `~`
   expanded): that file, which must be an executable regular file; otherwise the CLI is not found (no fallback).
2. `/bin/zsh -lic 'command -v claude'` through `ChildProcess.capture` (app environment, stdin `/dev/null`, timeout 5 s):
   the last stdout line that starts with `/` and names an executable regular file.
3. The first executable regular file among `<home>/.local/bin/claude`, `/opt/homebrew/bin/claude`,
   `/usr/local/bin/claude`.

`HostInfoService.refresh()` resolves at Main start and when `claudePath` changes; `SessionService` calls `current`
before each process start, which resolves again when the stored path is nil or no longer executable. `host.info`
reports `claudeAvailable` and `claudePath` from the stored result ([../services/host.md](../services/host.md)).

The CLI transcript of a session is the file `<session id>.jsonl` in the folder
`ClaudePathEncoding.transcriptsFolder(projectRoot: projectRoot.path, configDirectory:
ClaudePathEncoding.configDirectory(environment: <login environment>, home:
FileManager.default.homeDirectoryForCurrentUser))`: `CLAUDE_CONFIG_DIR` or `~/.claude`, then `projects/` and the CLI's
folder name of the session's working directory (section 3), passed as `projectRoot`, computed on its `realpath(3)` and
cut with a hash past 200 characters ([../devices/migration.md](../devices/migration.md#claude-folder-names)). `<session
id>` is the lowercase form (`SessionFile.fileStem(_:)`, [../data/sessions.md](../data/sessions.md)).

```swift
public actor ClaudeLocator {
    public static let shared: ClaudeLocator
    /// Runs the resolution and stores its result (nil: not found). `configured`: DeviceSettings.claudeURL.
    @discardableResult public func resolve(configured: URL?) async -> String?
    /// The stored path when it is still an executable file; otherwise runs the resolution.
    public func current(configured: URL?) async -> String?
    /// The stored result of the last resolution.
    public var lastResolvedPath: String? { get }
    /// ClaudePathEncoding.transcriptsFolder(projectRoot: projectRoot.path, configDirectory:
    /// ClaudePathEncoding.configDirectory(environment: environment, home:
    /// FileManager.default.homeDirectoryForCurrentUser)) + SessionFile.fileStem(sessionID) + ".jsonl"
    public static func transcriptURL(projectRoot: URL, sessionID: UUID, environment: [String: String]) -> URL
}
```

## 3. The session process (`ClaudeProcess`)

One `ClaudeProcess` is one running `claude` for one session. It is spawned with `ChildProcess` (stdin, stdout and
stderr as separate pipes), working directory = the session's project root (a sub project's own root), or, for a
`task` session with a `bundleID`, its task's work folder (`SessionHost.bundleWorkFolder`,
[../services/bundles.md](../services/bundles.md#working-folder-of-a-task-session)); environment = the login
environment, with the changes of 3.5 for the sessions of 3.5.

### 3.1 Arguments

argv[1...] in this order. `-p`, `--verbose`, `--include-partial-messages` and `--name=<title>` are one argument each;
`--allowedTools` and `--disallowedTools` are each the flag followed by one argument per rule; every other row is two
arguments (flag, value). `<session id>` is the lowercase form.

| Arguments                            | Value and condition                                                                                                                      |
|--------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| `-p`                                 | always                                                                                                                                   |
| `--input-format stream-json`         | always                                                                                                                                   |
| `--output-format stream-json`        | always                                                                                                                                   |
| `--verbose`                          | always                                                                                                                                   |
| `--include-partial-messages`         | always                                                                                                                                   |
| `--permission-prompt-tool stdio`     | always                                                                                                                                   |
| `--session-id <session id>`          | when the session's CLI transcript (section 2) does not exist                                                                             |
| `--resume <session id>`              | when it exists                                                                                                                           |
| `--permission-mode <mode>`           | always: `manual`, `acceptEdits`, `auto`, `plan` or `bypassPermissions` (the CLI's accepted values)                                       |
| `--model <model>`                    | only when the session has a model: an alias (`opus`, `sonnet`, `haiku`, `fable`) or a full model name, as stored                         |
| `--mcp-config <JSON>`                | always: the session's MCP config ([mcp.md](mcp.md#5-sessions-tokens-and---mcp-config))                                                   |
| `--allowedTools <rules>`             | always: the allowed rules of 3.5, in their order, for the sessions of 3.5 that have them (3.5); `mcp__hephaestus` for the others         |
| `--disallowedTools <rules>`          | always: the denied rules of 3.5, in their order, for the sessions of 3.5; `Edit(**/.hephaestus/**)` for the others                       |
| `--plugin-dir <folder>`              | always: `SessionPlugins/<session id>/hephaestus` in Application Support ([skills.md](skills.md#6-session-plugin-folder))                 |
| `--append-system-prompt-file <file>` | always: `SessionPlugins/<session id>/system-prompt.md` in Application Support, holding the text of [prompts.md](prompts.md) (5.3 step 4) |
| `--name=<title>`                     | always: the session title; the `=` form keeps a title that starts with `-` a value (verified)                                            |

`--mcp-config`, `--allowedTools` and `--disallowedTools` take several values; each is followed by another flag, which
ends its list. The app never passes `--bare` (it ignores the subscription login). The system prompt goes through a
file because it holds the whole task file and argv plus the environment are limited to `ARG_MAX` (1,048,576 bytes on
macOS); verified with CLI 2.1.309: the flag is read, and a missing file exits with code 1 and `Append system prompt
file not found: <path>`.
Example of a first start:

```
claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
  --permission-prompt-tool stdio --session-id 3f1c2a9e-5b7d-4c11-9e2a-6d0f8b1c2e3d --permission-mode acceptEdits
  --model opus --mcp-config '{"mcpServers":{"hephaestus":{"type":"http","url":"http://127.0.0.1:53124/mcp","headers":{"Authorization":"Bearer 9f…"}}}}'
  --allowedTools mcp__hephaestus --disallowedTools 'Edit(**/.hephaestus/**)'
  --plugin-dir '/Users/user/Library/Application Support/Hephaestus/SessionPlugins/3f1c2a9e-5b7d-4c11-9e2a-6d0f8b1c2e3d/hephaestus'
  --append-system-prompt-file '/Users/user/Library/Application Support/Hephaestus/SessionPlugins/3f1c2a9e-5b7d-4c11-9e2a-6d0f8b1c2e3d/system-prompt.md'
  '--name=Implement HEPH-12'
```

### 3.2 stdin messages

Each message is compact JSON followed by `\n`, written with `ChildProcess.write`.

| Message                                | Line                                                                                                           |
|----------------------------------------|----------------------------------------------------------------------------------------------------------------|
| initialize (first line of every start) | `{"type":"control_request","request_id":"init","request":{"subtype":"initialize","hooks":null}}`               |
| user message                           | `{"type":"user","message":{"role":"user","content":"<text>"},"parent_tool_use_id":null,"session_id":""}`       |
| interrupt                              | `{"type":"control_request","request_id":"<new lowercase UUID>","request":{"subtype":"interrupt"}}`             |
| permission answer                      | section 4.2                                                                                                    |
| refusal of another control request     | `{"type":"control_response","response":{"subtype":"error","request_id":"<id>","error":"Unsupported request"}}` |

`content` is always a JSON string; attachments are referenced by path in the text (5.4). Several user messages can be
written over the life of one process, also during a turn (the CLI queues them).

Recorded answers, to the initialize request and then to an interrupt:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{"commands":[…],"agents":[…],"models":[…],"account":{…},"claude_code_version":"2.1.309",…},"pending_permission_requests":[],"pending_user_dialog_requests":[]}}
{"type":"control_response","response":{"subtype":"success","request_id":"int1","response":{"still_queued":[]}}}
```

The CLI then writes a `user` line whose content is `[{"type":"text","text":"[Request interrupted by user]"}]` and ends
the turn with a `result` whose `subtype` is `error_during_execution`, `is_error` true, `stop_reason` null,
`terminal_reason` `aborted_streaming` and `errors` `["[ede_diagnostic] result_type=user last_content_type=n/a
stop_reason=null"]`; the process stays usable (5.6).

### 3.3 stdout messages

`ClaudeProcess` reads stdout with `LineReader` and gives each line to `StreamJSONParser`, which decodes it with
`JSONSerialization` and returns zero or more `CLIMessage` values. A line that is not a JSON object with a string
`type` is logged and ignored. Lines of type `stream_event`, `assistant` or `user` whose `parent_tool_use_id` is a
string (sub-agent traffic) are ignored.

```swift
public enum AssistantBlock: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: String)        // input: JSON text
}

public struct InitInfo: Sendable, Equatable {
    public var version: String?          // claude_code_version
    public var model: String?            // model
    public var permissionMode: String?   // permissionMode
    public var toolCount: Int            // number of tools
    public var hephaestusStatus: String? // status of the mcp_servers item named "hephaestus"
    public init(...)                     // memberwise: one labeled parameter per property, in order, no default
}

public struct ResultInfo: Sendable, Equatable {
    public var isError: Bool             // is_error, false when absent
    public var subtype: String?          // subtype
    public var durationMS: Int           // duration_ms, 0 when absent
    public var costUSD: Double           // total_cost_usd, 0 when absent
    public var stopReason: String?       // stop_reason (null → nil)
    public var errorText: String?        // see Field rules
    public init(...)                     // memberwise: one labeled parameter per property, in order, no default
}

public enum CLIMessage: Sendable, Equatable {
    case controlResponse(requestID: String, error: String?)     // error nil: success
    case permissionRequest(PermissionRequest)
    case unsupportedControlRequest(requestID: String)
    case controlCancel(requestID: String)
    case initialized(InitInfo)
    case statusLine(String)                                      // live status line text
    case turnActivity                                            // system status, message_start
    case delta(messageID: String, index: Int, kind: SessionDeltaKind, text: String)
    case block(messageID: String, index: Int, block: AssistantBlock)
    case toolResult(toolUseID: String, text: String, isError: Bool)
    case result(ResultInfo)
}

public struct StreamJSONParser: Sendable {
    public init()
    public mutating func parse(_ line: String) -> [CLIMessage]
}
```

Every line type, what the parser returns, and what `SessionService` does with it (5.5 for statuses, 5.8 for events):

| `type`                   | Condition                                                                         | Parser returns                                                     | `SessionService`                                                                                          | Appended to the log                                                                                                            | Wire events                                                |
|--------------------------|-----------------------------------------------------------------------------------|--------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------|
| `control_response`       | `response.request_id` = `init`, `response.subtype` = `success`                    | `controlResponse(init, nil)`                                       | the process is ready: `starting` → `running` (a user message was written) or `idle`                       | —                                                                                                                              | `session.changed`                                          |
| `control_response`       | `request_id` = `init`, another or no `subtype`                                    | `controlResponse(init, <error text>)` (Field rules)                | terminates the process; `failed` (5.7)                                                                    | `error`                                                                                                                        | `session.event`, `session.changed`                         |
| `control_response`       | other request ids (interrupts)                                                    | `controlResponse(id, error?)`                                      | nothing; an error is logged                                                                               | —                                                                                                                              | —                                                          |
| `control_request`        | `request.subtype` = `can_use_tool`, `tool_name` not empty, `allowsAllTools` false | `permissionRequest` (4.1)                                          | adds it to `PermissionBroker`; `waitingPermission`                                                        | `permission`                                                                                                                   | `permission.requested`, `session.event`, `session.changed` |
| `control_request`        | `request.subtype` = `can_use_tool`, `tool_name` not empty, `allowsAllTools` true  | `permissionRequest` (4.1)                                          | answers it at once with allow (4.4); the status stays `running`                                           | `permission`, `permissionDecision` (`allowAll`)                                                                                | `session.event`, `permission.resolved`                     |
| `control_request`        | any other subtype, or `tool_name` empty or not a string                           | `unsupportedControlRequest(request_id)`                            | writes the refusal of 3.2                                                                                 | —                                                                                                                              | —                                                          |
| `control_cancel_request` | —                                                                                 | `controlCancel(request_id)`                                        | cancels that pending request (4.3)                                                                        | `permissionDecision`                                                                                                           | `permission.resolved`, `session.event`, `session.changed`  |
| `system`                 | `subtype` = `init`                                                                | `initialized` (fields of `InitInfo`)                               | first `init` of the process, or `hephaestusStatus` changed since the last one: a `system` event           | `system` (5.8)                                                                                                                 | `session.event`                                            |
| `system`                 | `status`, `status` a non-empty string                                             | `turnActivity`, `statusLine("<status, first letter uppercased>…")` | sets `statusLine`                                                                                         | —                                                                                                                              | `session.changed` (throttled)                              |
| `system`                 | `status`, `status` null, absent, empty or not a string                            | `turnActivity`                                                     | —                                                                                                         | —                                                                                                                              | —                                                          |
| `system`                 | `thinking_tokens`                                                                 | `statusLine("Thinking… (~<estimated_tokens> tokens)")`             | sets `statusLine`                                                                                         | —                                                                                                                              | `session.changed` (throttled)                              |
| `system`                 | `task_summary`, `detail` not empty                                                | `statusLine(detail)`                                               | sets `statusLine`                                                                                         | —                                                                                                                              | `session.changed` (throttled)                              |
| `system`                 | `post_turn_summary`, `status_detail` not empty                                    | `statusLine(status_detail)`                                        | sets `statusLine`                                                                                         | —                                                                                                                              | `session.changed` (throttled)                              |
| `system`                 | other subtypes (`session_title_changed`, …)                                       | nothing                                                            | —                                                                                                         | —                                                                                                                              | —                                                          |
| `stream_event`           | `event.type` = `message_start`                                                    | `turnActivity` (the parser keeps `event.message.id`)               | —                                                                                                         | —                                                                                                                              | —                                                          |
| `stream_event`           | `content_block_delta`, `delta.type` = `text_delta`                                | `delta(…, .text, delta.text)`                                      | forwards                                                                                                  | —                                                                                                                              | `session.delta`                                            |
| `stream_event`           | `content_block_delta`, `delta.type` = `thinking_delta`                            | `delta(…, .thinking, delta.thinking)`                              | forwards                                                                                                  | —                                                                                                                              | `session.delta`                                            |
| `stream_event`           | `content_block_delta`, `delta.type` = `input_json_delta`                          | `delta(…, .toolInput, delta.partial_json)`                         | forwards                                                                                                  | —                                                                                                                              | `session.delta`                                            |
| `stream_event`           | other event and delta types                                                       | nothing                                                            | —                                                                                                         | —                                                                                                                              | —                                                          |
| `assistant`              | content block `text`                                                              | `block(…, .text(text))`                                            | appends unless the text is empty                                                                          | `assistant`                                                                                                                    | `session.event`                                            |
| `assistant`              | content block `thinking`                                                          | `block(…, .thinking(thinking))`                                    | appends unless the text is empty                                                                          | `thinking`                                                                                                                     | `session.event`                                            |
| `assistant`              | content block `tool_use`                                                          | `block(…, .toolUse(id, name, input))`                              | appends                                                                                                   | `toolUse`                                                                                                                      | `session.event`                                            |
| `assistant`              | other content block types                                                         | nothing (the block still takes an index)                           | —                                                                                                         | —                                                                                                                              | —                                                          |
| `user`                   | content block `tool_result`                                                       | `toolResult(tool_use_id, text, is_error)`                          | appends                                                                                                   | `toolResult`                                                                                                                   | `session.event`                                            |
| `user`                   | other content blocks (`[Request interrupted by user]`, …)                         | nothing                                                            | —                                                                                                         | —                                                                                                                              | —                                                          |
| `result`                 | —                                                                                 | `result(ResultInfo)`                                               | cancels pending permission requests (4.3), then appends; `idle`; restarts when a restart is pending (5.6) | an interrupted turn (5.6): `system` `Interrupted`, then `result`; otherwise `error` when `errorText` is not nil, then `result` | `session.event`, `session.changed`                         |
| `rate_limit_event`       | —                                                                                 | nothing                                                            | —                                                                                                         | —                                                                                                                              | —                                                          |
| any other `type`         | —                                                                                 | nothing                                                            | —                                                                                                         | —                                                                                                                              | —                                                          |

Turn messages are `initialized`, `turnActivity`, `permissionRequest`, `delta`, `block` and `toolResult`. A turn message
received in status `idle` first sets `running`: a message queued during the previous turn has started its own turn.

Field rules:

- A `control_response` whose `response.subtype` is not `success`, or is missing, is an error: its text is
  `response.error` when it is a string, else `response.subtype` when it is a string, else `""`.
- Delta `messageID`: the line's `api_message_id` when it is a string, else the `id` of the last `message_start`.
  `index`: `event.index`. Deltas whose text is empty are dropped (the first `input_json_delta` is always empty).
- Assistant blocks: `messageID` = `message.id`. The CLI writes one `assistant` line per finished content block, with
  the same `message.id` for all blocks of one API message (recorded: a `thinking` line then a `text` line). A block's
  `index` = the number of blocks already parsed for that `message.id`, so it equals the `index` of the block's
  deltas. The counters are cleared after each `result`.
- `tool_use` input: `block.input` re-serialized as compact JSON (`JSONSerialization`, options `.sortedKeys`,
  `.withoutEscapingSlashes`).
- `tool_result` text: `content` when it is a string; when it is an array, the `text` of its items of type `text`,
  joined with `\n` (other items, such as images, are skipped). `is_error` absent → false.
- `errorText` of a result: the `errors` array (strings) joined with `\n` when it is not empty; else, when `is_error` is
  true, `result` when it is a non-empty string; else, when `is_error` is true, `Claude ended the turn with an error
  (<subtype>).`; else nil. It is not used for the `result` of an interrupted turn (5.6). Recorded for a `--resume` of
  an unknown id (exit code 1, same text on stderr):

  ```json
  {"type":"result","subtype":"error_during_execution","duration_ms":0,"is_error":true,"num_turns":0,"stop_reason":null,"total_cost_usd":0,…,"errors":["No conversation found with session ID: 0c5d3c1e-1111-4222-8333-944455556666"]}
  ```

Recorded lines, with the identifiers of the sanitized fixtures ([../testing.md](../testing.md#fixtures)) and
`mcp_servers` reduced to the Hephaestus server (other fields omitted):

```json
{"type":"system","subtype":"init","cwd":"/…/cli3","session_id":"00000000-0000-4000-8000-000000000311","tools":["Bash","Read","mcp__…"],"mcp_servers":[{"name":"hephaestus","status":"connected"}],"model":"claude-haiku-5-5","permissionMode":"default","claude_code_version":"2.1.309"}
{"type":"system","subtype":"status","status":"requesting","session_id":"00000000-0000-4000-8000-000000000311","uuid":"…"}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_fixture_01","role":"assistant","content":[]}},"parent_tool_use_id":null,"api_message_id":"msg_fixture_01"}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"touch probe-file"}},"parent_tool_use_id":null,"api_message_id":"msg_fixture_01"}
{"type":"assistant","message":{"id":"msg_fixture_01","role":"assistant","content":[{"type":"tool_use","id":"toolu_fixture_01","name":"Bash","input":{"command":"touch probe-file.txt && ls","description":"Create probe-file.txt and list directory contents"}}]},"parent_tool_use_id":null}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_fixture_01","type":"tool_result","content":"probe-file.txt\nstream.log","is_error":false}]},"parent_tool_use_id":null}
{"type":"system","subtype":"thinking_tokens","estimated_tokens":300,"estimated_tokens_delta":250}
{"type":"system","subtype":"task_summary","detail":"Creating probe-file.txt and listing directory contents"}
{"type":"system","subtype":"post_turn_summary","status_category":"completed","status_detail":"touch + ls ran; listing shows probe-file.txt and stream.log","needs_action":""}
{"type":"result","subtype":"success","is_error":false,"duration_ms":2797,"num_turns":2,"stop_reason":"end_turn","total_cost_usd":0.00121975,"result":"The command ran …","terminal_reason":"completed"}
```

The CLI sends `system`/`init` at the start of every turn, not when the process starts: a process that receives only
the initialize request answers it and writes nothing else. With CLI 2.1.309 the `thinking` blocks arrive with empty
text, so they are not logged.

### 3.4 API

```swift
public final class ClaudeProcess: Sendable {
    public struct Options: Sendable {
        public var executable: String
        public var sessionID: UUID
        public var resume: Bool                 // --resume instead of --session-id
        public var permissionMode: PermissionMode
        public var model: String?
        public var mcpConfig: String            // MCPServer.configJSON(token:)
        public var allowedTools: [String]       // ["mcp__hephaestus", …] (3.1, 3.5)
        public var disallowedTools: [String]    // 3.1, 3.5
        public var pluginFolder: URL
        public var systemPromptFile: URL        // --append-system-prompt-file (5.3 step 4)
        public var title: String
        public var workingDirectory: URL
        public var environment: [String: String] // the login environment; changed as in 3.5 for its sessions
        public init(...)                         // memberwise: one labeled parameter per property, in order, no default
    }

    public enum StdinMessage: Sendable {
        case initialize
        case user(text: String)
        case interrupt(requestID: String)
        case permission(answer: Data)           // PermissionBroker.answer(…)
        case refuse(requestID: String)
        /// The line of 3.2 without its trailing newline.
        public var json: Data { get }
    }

    /// argv[1...] of 3.1.
    public static func arguments(_ options: Options) -> [String]
    /// Spawns the process and writes the initialize request.
    public static func launch(_ options: Options) throws -> ClaudeProcess
    public let sessionID: UUID
    /// Parsed stdout, in order; finishes at stdout's end of file.
    public let messages: AsyncStream<CLIMessage>
    public func send(_ message: StdinMessage) throws
    /// The last 4 KiB of stderr decoded as UTF-8 (lossy), whitespace-trimmed.
    public var standardErrorTail: String { get }
    public func terminate() async
    public func waitForExit() async -> ChildTermination
}
```

A task drains stderr into a 4,096-byte buffer that keeps the last bytes received.

### 3.5 Sessions in the public repository

The Hephaestus repository is public ([../public-repository.md](../public-repository.md)). The **sessions of 3.5** are
the sessions that work in it:

- the Forge's `feedback` and `regeneration` sessions;
- while the setting `forge.enabled` is true on this Main, every `project`, `task` and `bundle` session whose project
  is `forge.sourceProjectID` or one of its sub projects (the project, or an ancestor found through
  `ClaudeProjectContext.parent`, has that identifier, or an ancestor cannot be read), as read at each process start
  (5.3).

They get the denied rules and the environment below, no permission suggestion (4.1), and the
[Forge common part](prompts.md#forge-common-part) of the system prompt instead of the Common part, which names the
mesh's devices. Feedback, regeneration and bundle sessions also get the allowed rules below and start in the
permission mode `acceptEdits` (5.2); so do the `task` sessions of a bundle, which work without waiting for the user
([../services/bundles.md](../services/bundles.md)). Other `project` and `task` sessions keep `mcp__hephaestus` as their
allowed rule and start in their own permission mode. The user can change the permission mode of every session of 3.5
and allow all its tools (4.4, 5.6); the denied rules and the environment below stay.

Their commits are meant to reach GitHub only through the Forge push tools, which check them for personal data first
([../forge/pipeline.md](../forge/pipeline.md#mcp-tools)). A `task` session that is not of a bundle pushes its
documentation commits with `forge_push_docs`, and a `bundle` session those of its tasks; a `project` session has no
push tool, and the user pushes its commits by hand, outside the session. A `feedback` session changes no file
([prompts.md](prompts.md#feedback-part)). The rules and the environment below stop the direct ways of pushing
that were tried. In a session, the environment makes a push fail even when the user approves its permission card
(`git -C <folder> push …`), but not a push that overrides its git settings:
`git -C <folder> -c url.<url>.pushInsteadOf=<url> push …` pushed despite it, since git uses the longest matching
`pushInsteadOf` (verified with git 2.54). With all tools allowed (4.4) the Main approves such a command itself. Code a
session runs (its scripts, tests and builds) can still push, and so can every session of 3.5
([../public-repository.md](../public-repository.md#limits)): in the mode `bypassPermissions`, where the CLI asks for
no approval, and with all tools allowed.

`ForgeSessionRules.swift` holds the lists and the environment of this section, and nothing else:

```swift
/// The rules and the environment of the sessions of cli.md 3.5.
enum ForgeSessionRules {
    enum AllowedSet { case feedback, bundle, regeneration }
    /// --allowedTools: .feedback for feedback sessions and the task sessions of a bundle, .bundle for bundle
    /// sessions, .regeneration for regeneration sessions; branch: the setting forge.branch.
    static func allowedTools(_ set: AllowedSet, branch: String) -> [String]
    /// --disallowedTools.
    static let disallowedTools: [String]
    /// The login environment with the changes below.
    static func environment(_ login: [String: String]) -> [String: String]
}
```

`--allowedTools` of `feedback` sessions and of the `task` sessions of a bundle, one argument per line, in this order,
`<branch>` being the setting `forge.branch`:

```text
mcp__hephaestus
Bash(git status *)
Bash(git diff *)
Bash(git log *)
Bash(git show *)
Bash(git add *)
Bash(git rm *)
Bash(git commit *)
Bash(git reset --soft origin/<branch>)
Bash(git stash *)
Bash(git fetch origin <branch>)
Bash(git fetch --quiet origin <branch>)
Bash(git pull --rebase origin <branch>)
Bash(git pull --ff-only origin <branch>)
Bash(git rev-parse *)
Bash(git ls-files *)
Bash(git branch *)
Bash(scripts/check-public.sh --staged)
```

`--allowedTools` of `bundle` sessions: the same rules, followed by these, with which the coordinator brings the task
branches in ([prompts.md](prompts.md#bundle-part)):

```text
Bash(git cherry-pick *)
Bash(git cherry *)
```

`--allowedTools` of `regeneration` sessions: the rules of `feedback` sessions, followed by:

```text
Bash(xcodebuild *)
Bash(swift *)
Bash(scripts/*)
Bash(./scripts/*)
```

`--disallowedTools` of the sessions of 3.5, one argument per line, in this order:

```text
Bash(git push *)
Bash(git config *)
Bash(git -c *)
Bash(git remote *)
Bash(git update-ref *)
Bash(git filter-branch *)
Bash(git replace *)
Bash(git notes *)
Bash(git fetch *--upl*)
Bash(git pull *--upl*)
Bash(git diff *--output*)
Bash(git log *--output*)
Bash(git show *--output*)
Bash(git stash *--output*)
Edit(.claude/**)
Edit(.mcp.json)
Edit(**/.hephaestus/**)
```

Every other session gets the last rule alone (3.1): the app's project data under `.hephaestus/` changes only through
the app.

How the CLI applies them, as verified with CLI 2.1.309 in sessions driven like the app's:

- A denied rule wins over the allowed rules: with `Bash(git *)` allowed as well, every command a denied rule matches
  is still refused. Allowed rules of the user's settings files add to the allowed rules above: a command that no
  denied rule matches can then run without a request, and the environment below does not stop all its pushes: a push
  run as the `--upload-pack` command of `git -C <folder> fetch` passes both.
- `Bash(git push *)` also matches a bare `git push`. Denied rules match a command after an environment assignment
  (`GIT_TERMINAL_PROMPT=0 git push …`), after `env`, with an absolute path (`/usr/bin/git push …`) and in each part
  of a compound command (`cd . && git push …`).
- They do not match `bash -c "…"`, `sh -c "…"` or `git -C <folder> push …`. These, like every command no rule
  allows, are not run without the user's approval in the modes `manual`, `acceptEdits` and `plan`: the CLI sends a
  permission request ([section 4](#4-permissions-permissionbroker)), which the Main allows at once when the session
  allows all tools (4.4). In the mode `bypassPermissions`, which every session may be given (5.6), the CLI sends none;
  the mode `auto` was not tried.
- An allowed rule without `*` allows that exact command only: `git fetch origin <branch>` and
  `git pull --rebase origin <branch>` ran without a request, while `git fetch <another repository> <ref>`,
  `git pull <another repository> <ref>` and `git mv …` asked. An allowed command with an environment assignment before
  it asked too (`GIT_EDITOR=true git commit …`): a session cannot change the environment of a command without the
  user.
- `*--upl*`: `git fetch` and `git pull` run the command given to `--upload-pack` (also abbreviated, `--upl=`).
  `*--output*`: `git diff`, `git log`, `git show` and `git stash` (`git stash list` takes the options of `git log`,
  `git stash show` those of `git diff`) write a file given to `--output`, a hook for example; an existing file keeps
  its mode, so `git stash list --format='tformat:<text>' --output=.githooks/pre-push` turned the hook into `<text>`,
  still executable (verified with git 2.54).
- `scripts/check-public.sh` is allowed with `--staged` alone, the form the prompts give: its `--commits` passes the
  arguments after it to `git rev-list`, whose `--output=<file>` empties that file, a hook for example (verified with
  git 2.54). Regeneration sessions run every script of `scripts/` anyway.
- An `Edit(<path>)` rule takes a path relative to the session's working directory, the project root, and matches no
  path outside it. `.claude/**`, `.mcp.json` and `**/.hephaestus/**` are relative to the project root, where Claude
  Code reads its project settings; in the project root, they refused the Write tool and shell redirections for
  `.claude/settings.json`, `.mcp.json`, `.hephaestus/project.yml` and `sub/.hephaestus/project.yml`. The Edit tool
  itself and the other paths were not tried.

Environment: the login environment (1.1) with these changes.

- Removed: `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` and `EMAIL`, so the
  session's commits have the identity of git's configuration, the user's own
  ([../public-repository.md](../public-repository.md#commit-identity)); `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`
  and every `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>`, `<n>` being one or more ASCII digits; `GH_TOKEN` and
  `GITHUB_TOKEN`.
- Added:

  | Variable             | Value                                             |
  |----------------------|---------------------------------------------------|
  | `GIT_CONFIG_COUNT`   | `2`                                               |
  | `GIT_CONFIG_KEY_0`   | `url.hephaestus-no-push://blocked/.pushInsteadOf` |
  | `GIT_CONFIG_VALUE_0` | the empty string                                  |
  | `GIT_CONFIG_KEY_1`   | `core.hooksPath`                                  |
  | `GIT_CONFIG_VALUE_1` | `/dev/null`                                       |
  | `TZ`                 | `UTC`                                             |

  Every git process started with this environment, the hooks, scripts, tests and builds included, rewrites every push
  URL to the scheme `hephaestus-no-push`, which has no remote helper: a push to a relative or absolute path, a
  `file://`, `https://` or `ssh://` URL or a `git@host:` address fails with `fatal: remote helper 'hephaestus-no-push'
  aborted session`, while fetch and `ls-remote` work (verified with git 2.54, and in a session for a hook and a
  script). No git hook runs, since `core.hooksPath` is `/dev/null` (verified in a session: a pre-commit hook of
  `.githooks/` did not run on `git commit`); the session runs `scripts/check-public.sh --staged` itself before
  committing ([prompts.md](prompts.md#forge-common-part)), and the Forge checks the commits again before pushing them.
  Commit dates carry the UTC offset.
- The block does not hold against a process that drops or overrides these variables: `GIT_CONFIG_COUNT=0 git push …`,
  `env -u GIT_CONFIG_COUNT git push …` and `git -c url.<url>.pushInsteadOf=<url> push …` (the longest matching prefix
  wins) pushed (verified with git 2.54). Nor does it hold against a push run as the `--upload-pack` command of a fetch,
  for which git clears them (verified in a session). `gh` still finds the user's login in its keyring without
  `GH_TOKEN` and `GITHUB_TOKEN`. A `remote.origin.pushurl` setting would escape it: the Forge works only while there is
  none ([../forge/pipeline.md](../forge/pipeline.md#configuration-checks)). The Forge's own git commands run in the
  app's environment, without these changes.

## 4. Permissions (`PermissionBroker`)

### 4.1 Request

The CLI asks before a tool call that the permission mode and settings do not allow (recorded; identifiers as in the
fixtures):

```json
{"type":"control_request","request_id":"00000000-0000-4000-8000-000000000301","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"touch probe-file.txt && ls","description":"Create probe-file.txt and list directory contents"},"description":"Create probe-file.txt and list directory contents","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch probe-file.txt && ls"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/private/tmp/…/cli3"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}],"blocked_path":"/private/tmp/…/cli3/probe-file.txt","tool_use_id":"toolu_fixture_01"}}
```

It becomes a `PermissionRequest` ([../protocol/types.md](../protocol/types.md)):

| Field         | Source                                                                                                                           |
|---------------|----------------------------------------------------------------------------------------------------------------------------------|
| `requestID`   | `request_id`                                                                                                                     |
| `toolName`    | `request.tool_name`                                                                                                              |
| `input`       | `request.input` re-serialized as compact JSON text (same options as `tool_use` input)                                            |
| `description` | `request.description` (nil when absent)                                                                                          |
| `suggestions` | `request.permission_suggestions` re-serialized as compact JSON text; `[]` when absent, and for every request of a session of 3.5 |
| `blockedPath` | `request.blocked_path` (nil when absent)                                                                                         |

### 4.2 The three answers

Answers are built with `JSONSerialization` from the stored request; `input` and `suggestions` are parsed back from
their JSON text, so the original input object is sent back unchanged.

allow and allowAll (recorded, accepted by the CLI):

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<requestID>","response":{"behavior":"allow","updatedInput":<input>}}}
```

allowAlways:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<requestID>","response":{"behavior":"allow","updatedInput":<input>,"updatedPermissions":<kept suggestions>}}}
```

deny:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<requestID>","response":{"behavior":"deny","message":"<message>"}}}
```

- allowAlways: `<kept suggestions>` is the array of the objects of `suggestions` whose `type` is `addRules` or
  `addDirectories`, in their order. Other objects, `setMode` included, are never sent. When no object is kept, the
  allow answer is sent; the decision is still recorded as `allowAlways`. The CLI applies the kept suggestions itself:
  `addRules` with destination `localSettings` writes the rule to the project's `.claude/settings.local.json`; `session`
  destinations last as long as the process. A session of 3.5 has no suggestion (4.1), so its "Always allow" keeps
  nothing and no rule of it outlives the process.
- `<message>`: the `message` of `sessions.respond` when it is not empty after trimming, else
  `Denied from <device name>` (the answering device's `DeviceInfo.name`).

### 4.3 Resolution

- The first answer for a pending request wins: a `sessions.respond`, or the automatic answer of 4.4. `PermissionBroker`
  keeps the ids of the requests received from the session's current process (the last one when it has ended), until the
  next process of the session starts. An answer for a request that is not pending fails: with `notFound`,
  `No permission request <id>.`, when that process never sent the id; with `conflict`, `This request is not pending.`,
  when it was answered (by another device or by 4.4) or cancelled.
- An answer writes its JSON to the process, appends `permissionDecision {requestID, decision, deviceID}`, emits
  `permission.resolved {projectID, sessionID, requestID, decision, deviceID}` and, when no other request of the
  session is pending, sets the status back to `running`.
- A pending request is cancelled when the CLI sends `{"type":"control_cancel_request","request_id":"<id>"}` for it,
  when a `result` arrives, and when the process ends. Nothing is written to the CLI. A cancellation is recorded and
  announced like an answer, with decision `deny` and this Main's device id as `deviceID`.
- Every request added, answered or cancelled changes `SessionInfo.pendingPermissions` (5.1) and emits
  `session.changed`, one event with the status change it causes.
- `sessions.respond` with decision `allowAll` fails with `badRequest` `Use sessions.update to allow all tools.`: only
  the Main records that decision (4.4).

### 4.4 Allow All Tools

While the session's `allowsAllTools` is true (`SessionInfo`, stored in the session file,
[../data/sessions.md](../data/sessions.md)), the Main answers every permission request itself, without waiting for a
client:

- A `can_use_tool` request that arrives is answered at once with the allow answer of 4.2. It is never pending: it is
  not added to `PermissionBroker`, the status stays `running`, and no `permission.requested` is emitted. The
  `permission` event is appended, then `permissionDecision {requestID, decision: allowAll, deviceID}` with this Main's
  device id; `permission.resolved` is emitted with the same values.
- When `sessions.update` turns it on (5.6), every pending request of the session, oldest first, is taken from
  `PermissionBroker` and answered the same way: allow answer, `permissionDecision` with `allowAll` and this Main's
  device id, `permission.resolved`; the status becomes `running` and `session.changed` is emitted once, with the
  empty `pendingPermissions`.
- Turning it off answers nothing: the next requests wait for a client again.
- It is read at each request from the session's current `SessionInfo`; being stored, it holds across process restarts
  and app relaunches. Changing it does not restart the process.
- The CLI refuses the commands of the denied rules (`--disallowedTools`, 3.5) itself, before it asks: they are never
  allowed this way. Commands the denied rules miss (`git -C <folder> …`, `bash -c "…"`) are allowed; the environment
  of 3.5 still makes a plain push fail, but not one that overrides its git settings.

```swift
public struct PermissionBroker: Sendable {
    public init()
    /// A process of the session starts, or the session is deleted: forgets the request ids it received.
    public mutating func reset(sessionID: UUID)
    public mutating func add(sessionID: UUID, request: PermissionRequest)
    /// The pending requests of the session, oldest first.
    public func pending(sessionID: UUID) -> [PermissionRequest]
    /// Removes and returns a pending request. Throws ProtocolError notFound "No permission request <id>." when the id
    /// was not received since the last reset, conflict "This request is not pending." when it was answered or cancelled.
    public mutating func take(sessionID: UUID, requestID: String) throws -> PermissionRequest
    /// Removes and returns every pending request of the session, oldest first (cancellation, Allow All Tools 4.4).
    public mutating func takeAll(sessionID: UUID) -> [PermissionRequest]
    /// The answer line of 4.2, without the trailing newline; allowAll gives the allow answer.
    public static func answer(to request: PermissionRequest, decision: PermissionDecision, message: String?,
                              deviceName: String) -> Data
}
```

`SessionService` owns one `PermissionBroker`.

## 5. Sessions (`SessionService`)

### 5.1 API

`SessionService` is the `sessions` service of the host ([../services/host.md](../services/host.md)): an actor created
by `HostService.init`, conforming to `HostMethodHandler`. Its `handle(method:params:context:)` decodes the params types
of [../protocol/methods.md](../protocol/methods.md), calls the function of the method with the caller's
`context.device`, and encodes the result. The Forge calls `start(_:)` and `sessions(projectID:)` in process
([../forge/pipeline.md](../forge/pipeline.md)); the MCP tools reach the methods through the host
([mcp.md](mcp.md#7-locating-a-project-and-forwarding)).

```swift
/// Implemented by HostService.
public protocol SessionHost: Sendable {
    func localDevice() async -> DeviceInfo
    /// Non-revoked devices of the registry.
    func devices() async -> [DeviceRecord]
    func settings() async -> DeviceSettings
    /// Throws ProtocolError notFound when the project is not hosted on this Main.
    func claudeProject(_ projectID: String) async throws -> ClaudeProjectContext
    /// Throws ProtocolError notFound when the task does not exist.
    func claudeTask(projectID: String, taskID: String) async throws -> ClaudeTaskContext
    /// Throws ProtocolError notFound when the bundle does not exist (services/bundles.md).
    func claudeBundle(projectID: String, bundleID: String) async throws -> ClaudeBundleContext
    /// BundleService.workFolder: the working directory of a task session of a bundle.
    func bundleWorkFolder(projectID: String, taskID: String) async throws -> URL
    /// ProjectRegistry.checkWritable: throws locked when the project or an ancestor is migrating.
    func checkWritable(_ projectID: String) async throws
    /// The project's SessionArchive (data/sessions.md).
    func sessionArchive(_ projectID: String) async throws -> SessionArchive
    var mcp: MCPServer { get }
    var skills: SkillsService { get }
    /// The upload store: claims the uploads that sessions.start and sessions.send attach (services/files.md §7).
    var uploads: UploadService { get }
    // Events: sent with EventHub; sessionChanged and sessionRemoved also notify ForgeService.
    func sessionChanged(projectID: String, session: SessionInfo) async               // session.changed
    func sessionRemoved(projectID: String, sessionID: UUID) async                   // session.removed
    func sessionEvent(projectID: String, sessionID: UUID, event: SessionEvent) async // session.event, topic session:<id>
    func sessionDelta(projectID: String, sessionID: UUID, messageID: String, index: Int,
                      kind: SessionDeltaKind, text: String) async                   // session.delta, topic session:<id>
    func permissionRequested(projectID: String, sessionID: UUID, request: PermissionRequest) async
    func permissionResolved(projectID: String, sessionID: UUID, requestID: String,
                            decision: PermissionDecision, deviceID: UUID) async
}

public struct SessionStart: Sendable {
    public var projectID: String
    public var kind: SessionKind
    public var taskID: String?
    public var mode: SessionMode?
    public var title: String?
    public var message: String?
    public var attachments: [UploadRef] = []         // project sessions: files of the first message; [] otherwise
    public var permissionMode: PermissionMode?
    public var model: String?
    public var deviceID: UUID                        // requesting device; this Main's id for the Forge
    public var bundleID: String?                     // bundle sessions, and the task sessions a bundle starts
    public var regeneration: RegenerationContext?    // regeneration sessions (prompts.md)
    /// Memberwise: one labeled parameter per property, in order; the optional parameters default to nil and
    /// `attachments` to [].
    public init(...)
}

public actor SessionService {
    public init(host: any SessionHost)

    // host lifecycle (services/host.md §3)
    public func start()                              // start() step 6: marks the service running
    public func stopAll() async                      // stop() step 4: terminates every process, waits
    public func stopAll(projectID: String) async     // project removed or moved away (called per sub project too)

    // sessions.* methods
    public func start(_ request: SessionStart) async throws -> SessionInfo
    public func history(projectID: String, sessionID: UUID, before: Int?, limit: Int?) async throws
        -> SessionsHistoryResult
    public func send(projectID: String, sessionID: UUID, text: String, attachments: [UploadRef],
                     deviceID: UUID) async throws
    /// sessions.readAttachment: a range of a file of SessionArchive.attachmentURL (5.4).
    public func readAttachment(projectID: String, sessionID: UUID, fileName: String, offset: Int?,
                               length: Int?) async throws -> AttachmentsReadResult
    public func interrupt(projectID: String, sessionID: UUID) async throws
    public func stop(projectID: String, sessionID: UUID) async throws
    public func respond(projectID: String, sessionID: UUID, requestID: String, decision: PermissionDecision,
                        message: String?, device: DeviceInfo) async throws
    public func update(projectID: String, sessionID: UUID, patch: SessionPatch) async throws -> SessionInfo
    public func delete(projectID: String, sessionID: UUID) async throws
    /// MCP tool close_session (5.11).
    public func close(projectID: String, sessionID: UUID) async throws

    // other areas
    /// projects.snapshot, Forge: the project's sessions, newest `updated` first.
    public func sessions(projectID: String) async throws -> [SessionInfo]
    /// Migration precondition: a session of the project has a process.
    public func hasProcess(projectID: String) -> Bool
    /// Self-update: a session is starting, running or waitingPermission.
    public func isRunningTurn() -> Bool
}
```

`SessionKind`, `SessionMode`, `SessionStatus`, `PermissionMode`, `PermissionDecision`, `SessionInfo`, `SessionPatch`,
`SessionEvent`, `PermissionRequest`, `SessionDeltaKind`, `UploadRef`, `DeviceInfo` and `DeviceRecord` are the wire
types of [../protocol/types.md](../protocol/types.md); `SessionsHistoryResult` is the result of `sessions.history` and
`AttachmentsReadResult` the result of `sessions.readAttachment`
([../protocol/methods.md](../protocol/methods.md#sessionshistory)); `UploadService` and `ClaimedUpload` are in
[../services/files.md](../services/files.md#7-uploads); `DeviceSettings` and `AtomicFile` are in
[../data/app-storage.md](../data/app-storage.md); `SessionArchive` and `SessionFile` in
[../data/sessions.md](../data/sessions.md); `ClaudeProjectContext`, `ClaudeTaskContext` and `RegenerationContext` in
[prompts.md](prompts.md). Errors are `ProtocolError` values with the codes of
[../protocol/envelope.md](../protocol/envelope.md). A method naming a session the project does not have fails with
`notFound` `session <id> not found` (`<id>`: the `uuidString`, the text of
[../data/sessions.md](../data/sessions.md#reading-events)).

Storage: `SessionService` reads and writes session files only through the project's `SessionArchive`: `create` at
creation, `update` at every `user` and `result` event, at `sessions.update`, when a generated title arrives (5.10),
when the session is closed (5.11), when a process ends (status `stopped` or
`failed`) and when it cannot start (status `failed`, 5.3), `append` for every event (5.8), `saveAttachment`,
`history`, `delete`. Live statuses exist only in memory; a session without a process has the file's status.

`history` returns `SessionArchive.history` for its `before` and its `limit`, nil replaced by 1000 and clamped to
1…5000 (paging and the 16 MiB cut of [../protocol/methods.md](../protocol/methods.md#sessionshistory),
[../data/sessions.md](../data/sessions.md#reading-events)).

`SessionInfo` fields: the thirteen keys of the session file (`allowsAllTools` false and `closed` nil when the file has
none); `status`
(live while a process exists); `statusLine` (the last status line text of the current process; nil when there is no
process and when a user message is written); `error` (the reason of the last failure, nil unless the status is
`failed`); `pendingPermissions` (`PermissionBroker.pending` of the session, oldest first; empty when there is no
process). A client that reconnects rebuilds its permission indicator and cards from them (`projects.snapshot`) and from
`ProjectSummary.pendingPermissionCount` (`projects.list`), which the host counts from the `pendingPermissions` of the
`session.changed` events it emits ([../services/host.md](../services/host.md#61-wire-values)).

Settings used (`DeviceSettings`): `claudePath` (`claudeURL`), `defaultModel`, `defaultPermissionMode`,
`sessionIdleMinutes`, `forge.branch` (`{branch}` of [prompts.md](prompts.md), the allowed rules of 3.5), `forge.enabled`
and `forge.sourceProjectID` (the sessions of 3.5).

### 5.2 Starting a session (`sessions.start`)

Checks, in order (all `badRequest` unless noted):

1. The project is hosted on this Main (`notFound`) and writable (`checkWritable`: `locked`).
2. Over the wire, `kind` is `project` or `task` (`Only the Forge starts feedback and regeneration sessions.`, and
   `Bundle sessions are started with bundles.start.` for `bundle`); `feedback` and `regeneration` sessions are
   started in process by the Forge, `bundle` sessions and the task sessions of a bundle by `BundleService`
   ([../services/bundles.md](../services/bundles.md)).
3. `project`: no `taskID`, no `mode` (`A project session has no task and no mode.`).
4. `task`: `taskID` and `mode` are present (`A task session needs a task and a mode.`); `taskID` names an existing task
   of the project (`notFound`) that is not broken (`conflict`, `The file is invalid: <parseError>`); mode `custom`
   needs a `message` that is not empty after trimming (`Mode custom needs instructions.`).
5. `feedback`: `taskID` is present (`A feedback session needs a task.`) and names an existing task (`notFound`) that is
   not broken (`conflict`, as in 4). `regeneration`: no `taskID` (`A regeneration session has no task.`). `bundle`:
   `bundleID` names a bundle of the project (`notFound`), no `taskID` and no `mode` (`A bundle session has no task
   and no mode.`). `bundleID` is given only to `bundle` sessions and to `task` sessions
   (`Only bundle and task sessions belong to a bundle.`).
6. `title`, when given, is not empty after trimming and holds no line break (no maximum length; the message of the
   `title` rule of [../data/sessions.md](../data/sessions.md)); `model`, when given, is not empty after trimming
   (`The model must not be empty.`).
7. `attachments` is empty unless `kind` is `project` (`Only the first message of a project session has
   attachments.`).
8. When a process will start (a first message exists, see below): steps 1 and 2 of 5.3 succeed (`unavailable` with
   their message).
9. Last, with attachments: `uploads.claim(attachments, projectID:)`
   ([../services/files.md](../services/files.md#7-uploads)), with the upload errors of
   [../protocol/methods.md](../protocol/methods.md#using-uploads). Attachments have no size limit.

Creation:

- `id` = a new `UUID`.
- `title`: the given title, trimmed; otherwise by kind: `project` → `Chat <n>`, n = 1 + the number of `project`
  sessions of the project; `task` → `<mode displayName> <task id>` (`Implement HEPH-12`); `feedback` → `Feedback <task
  id>`; `regeneration` → `Regeneration`; `bundle` → `Bundle <bundle id>`. The first message of a `project`,
  `feedback` or `bundle` session then gets a generated title (5.10), given or default title alike.
- `permissionMode`: `feedback` and `regeneration`, and `bundle` sessions and the `task` sessions of a bundle that are
  sessions of 3.5 → `acceptEdits`; otherwise the given value, else the project's
  `claude.permissionMode`, else the setting `defaultPermissionMode`. Every session can change it later (5.6).
- `allowsAllTools`: false.
- `model`: the given value, else the project's `claude.model`, else the setting `defaultModel` when not empty, else
  none.
- Attachments (project sessions): before the session file is created, the claimed files are moved into the session's
  attachment folder as in 5.4 step 2. When a move fails, or when creating the session file fails, the moved files go
  back to their uploads, the folder `<id>/` is removed, `uploads.release` is called and the request fails: nothing is
  created. After the session file is created, `uploads.finish` is called.
- The session file is created with `status: stopped`; `session.changed` is emitted.
- First message: `project` → `message` (empty when nil) and the stored attachments, when either is given; `task`,
  `feedback`, `regeneration`, `bundle` → the generated first message of [prompts.md](prompts.md#first-messages), without
  attachments. When there is one, it is delivered as by `sessions.send` (steps 3 to 5 of 5.4) with `deviceID` = the
  request's: the process starts.
- Result: the `SessionInfo` (status `starting` when a process started, else `stopped`).

### 5.3 Starting the process

Used whenever a message must be delivered and the session has no process, and for restarts (5.6):

1. Path: `ClaudeLocator.shared.current(configured: settings.claudeURL)`; nil gives the message `Claude CLI not found.
   Set its path in Settings → Claude.`
2. MCP: the MCP server runs (`MCPServer.start()` when it does not; a failure gives the message `Hephaestus tools are
   not available.`); `MCPServer.register(_:)` returns a new token for this process
   ([mcp.md](mcp.md#5-sessions-tokens-and---mcp-config)).
3. Plugin folder: `SkillsService.buildPluginFolder(sessionID:enabled:)` with the project's `skills`
   ([skills.md](skills.md#6-session-plugin-folder)). It empties `SessionPlugins/<session id>/` first.
4. Prompt: `Prompts.systemPrompt(_:)` ([prompts.md](prompts.md)) from `claudeProject`, `claudeTask` (task and feedback
   sessions), `claudeBundle` (bundle sessions and the task sessions of a bundle), `bundleWorkFolder` (the task sessions
   of a bundle), the setting `bundles.maxParallel`, `localDevice`, `devices`, the settings `forge.branch`,
   `forge.enabled` and `forge.sourceProjectID`, the session's kind, mode and bundle, read now. The session is a session
   of 3.5 when its kind is `feedback` or `regeneration`, or when `forge.enabled` is true and its project, or an ancestor
   reached through `claudeProject(_:)` of each `parent`, is `forge.sourceProjectID`, or one of these ancestors cannot be
   read (`claudeProject(_:)` throws, which ends the walk); `PromptContext.publicRepository` is then true. `instructions`
   (task sessions): at the first start the `message` of `sessions.start`; at later starts the text after the first blank
   line of the session's first `user` event, nil when there is none. `regeneration`: the `RegenerationContext` given at
   the first start; nil later. The prompt is written as UTF-8 with `AtomicFile.write` to `system-prompt.md` in the
   folder that holds the plugin folder of step 3 (`SessionPlugins/<session id>/`).
5. `resume` = the CLI transcript of the session exists (section 2).
6. `ClaudeProcess.launch` with the arguments of 3.1, the working directory and the environment of section 3 (3.5 for the
   sessions of 3.5, as found in step 4); a spawn error gives the message `Could not start Claude: <strerror>`.
7. `PermissionBroker.reset(sessionID:)`. Status `starting`, `error` and `statusLine` nil, `session.changed`. The
   message (if any) is written right after the initialize request.
8. One task handles `messages` in order on the actor; when the stream ends it awaits `waitForExit()` and handles the
   exit (5.7), so every line is handled before the exit.

A failure in step 3 or 4, reading `claudeProject` or `claudeTask` included, gives the message `Could not start Claude:
<the error's message>`. A failure of step 1, 2, 3, 4 or 6 unregisters the token (when registered), sets the status
`failed` with `error` = the message, appends an `error` event with it and writes `status: failed` to the session file,
so the failure outlives the app. `sessions.send` then fails with `unavailable` and the message; `sessions.start` returns
the session with status `failed`; a restart (5.6) ends there. `sessions.start` and `sessions.send` run steps 1 and 2
first, before writing anything (5.2, 5.4), and the start continues at step 3 later; a failure of step 1 or 2 there only
fails the request and leaves the session unchanged.

### 5.4 Sending (`sessions.send`)

1. Checks: the session exists (`notFound`); it is not closed (`conflict`, `This conversation is over.`, 5.11); the
   project is writable (`locked`); `text` (not trimmed) is not empty or
   there is at least one attachment (`badRequest`, `The message is empty.`); when the session has no process, steps 1
   and 2 of 5.3 succeed (`unavailable` with their message); last, `uploads.claim(attachments, projectID:)`
   ([../services/files.md](../services/files.md#7-uploads)), with the upload errors of
   [../protocol/methods.md](../protocol/methods.md#using-uploads). Attachments have no size limit.
2. Each claimed upload, in order, is moved into the session's attachment folder with
   `SessionArchive.saveAttachment(fileAt: <its url>, originalName: <its fileName>, to:)`, which returns its
   `TaskAttachment`. When a move fails, or when appending the `user` event of step 4 fails, the files already moved go
   back to their uploads, `uploads.release` is called and the request fails; once the event is appended,
   `uploads.finish` is called.
3. CLI text: `text`, then, when there are attachments, a blank line (omitted when `text` is empty) and:

   ```
   Attached files:
   - /Users/user/Developer/Hephaestus/.hephaestus/sessions/3f1c2a9e-…/screenshot.png
   ```

   one `- <absolute path>` line per file (`SessionArchive.attachmentURL`), so Claude reads them (images included) with
   its tools.
4. The `user` event `{text, attachments, deviceID}` is appended (`text` as typed, `attachments` = the saved
   `TaskAttachment` values, omitted when empty). When it is the session's first `user` event, the title call of 5.10
   starts.
5. Delivery: with a process, the user message is written; `idle` becomes `running`. Without a process, the process
   starts (5.3) and receives the message. When the write fails, the process is terminated and a new one is started
   with the message.

`sessions.readAttachment {projectID, sessionID, fileName, offset?, length?}` (`readAttachment`): `fileName` must be a
single path component (not empty, no `/`, not `.` or `..`; else `badRequest` "invalid attachment name", as for task
attachments); the file is `SessionArchive.attachmentURL(sessionID, file: fileName)` (missing → `notFound` "No
attachment <fileName> in this session."). `offset` (default 0) below 0 or above the file's size → `badRequest`
"Invalid offset <offset> for <fileName>."; `length` (default `MethodLimits.maxChunkSize`) below 1 → `badRequest`
"Invalid length."; a `length` above `maxChunkSize` counts as `maxChunkSize`. The file is opened with `FileHandle`,
positioned at `offset`, and `min(length, size − offset)` bytes are read. Result: those bytes, the file's
`size`, and `mimeType` = `AttachmentNaming.mimeType(forFileName: fileName)`. It is a read: served while the project is
migrating, and for a session whose metadata file is gone as long as the file exists.

### 5.5 Statuses

| Status              | Meaning                                                                                                    |
|---------------------|------------------------------------------------------------------------------------------------------------|
| `stopped`           | no process: a new session, a stopped or idle-stopped one, one whose process ended with exit code 0         |
| `starting`          | the process is spawned; the initialize response has not arrived                                            |
| `running`           | a turn is in progress                                                                                      |
| `waitingPermission` | a turn waits for at least one permission answer                                                            |
| `idle`              | the process is alive between turns                                                                         |
| `failed`            | the last process failed or could not start; `SessionInfo.error` holds the reason with the stderr tail      |

A session has a process exactly when its status is `starting`, `running`, `waitingPermission` or `idle`.

Transitions (every change emits `session.changed`):

| From                                               | Event                                                                                     | To                  | Effects                                                                          |
|----------------------------------------------------|-------------------------------------------------------------------------------------------|---------------------|----------------------------------------------------------------------------------|
| (none)                                             | session created                                                                           | `stopped`           | session file created                                                             |
| `stopped`, `failed`                                | a message to deliver (first message of `sessions.start`, `sessions.send`)                 | `starting`          | 5.3; the message is written after the initialize request                         |
| `idle`                                             | restart for an option change (5.6)                                                        | `starting`          | the old process is terminated (`stopped`, 5.7); the new one gets no message      |
| `starting`                                         | initialize answered with success, a user message was written                              | `running`           | —                                                                                |
| `starting`                                         | initialize answered with success, no user message                                         | `idle`              | idle timer starts                                                                |
| `starting`                                         | initialize answered with an error                                                         | `failed`            | process terminated; `error` event                                                |
| `idle`                                             | `sessions.send`                                                                           | `running`           | message written                                                                  |
| `idle`                                             | a turn message (3.3): a queued message's turn started                                     | `running`           | —                                                                                |
| `running`                                          | `can_use_tool`, `allowsAllTools` false                                                    | `waitingPermission` | `permission` event                                                               |
| `running`                                          | `can_use_tool`, `allowsAllTools` true                                                     | `running`           | answered at once (4.4)                                                           |
| `waitingPermission`                                | the last pending request is answered or cancelled, or `allowsAllTools` becomes true (4.4) | `running`           | —                                                                                |
| `running`, `waitingPermission`                     | `result` in an open session                                                               | `idle`              | pending requests cancelled; restart when one is pending (5.6); idle timer starts |
| `idle`                                             | no activity for `sessionIdleMinutes`                                                      | `stopped`           | process terminated                                                               |
| `starting`, `running`, `waitingPermission`, `idle` | `sessions.stop`                                                                           | `stopped`           | process terminated; `system` event `Stopped` when a turn was in progress (5.6)   |
| `starting`, `running`, `waitingPermission`, `idle` | the process exits by itself with exit code 0                                              | `stopped`           | 5.7                                                                              |
| `starting`, `running`, `waitingPermission`, `idle` | the process exits by itself otherwise                                                     | `failed`            | 5.7                                                                              |
| `starting`, `running`, `waitingPermission`, `idle` | `stopAll`                                                                                 | `stopped`           | process terminated                                                               |
| `idle`                                             | the session is closed (5.11)                                                              | `stopped`           | process terminated                                                               |
| `running`, `waitingPermission`                     | `result` in a closed session (5.11)                                                       | `stopped`           | pending requests cancelled; process terminated, no idle timer                    |
| any                                                | `sessions.delete`                                                                         | (removed)           | 5.9                                                                              |

A status set by a stop (`stopped`) is applied when the process has exited. While a stop is in progress, new messages
wait for it and then start a new process.

### 5.6 Interrupt, stop, idle stop, option changes

- `sessions.interrupt`: when the status is `starting`, `running` or `waitingPermission`, writes an interrupt request
  and marks the process interrupted; in other statuses it does nothing. It succeeds in both cases (`notFound` for an
  unknown session). The CLI ends the turn with a `result` whose `is_error` is true (3.2). A `result` with `is_error`
  true received while the process is marked ends an interrupted turn: after the cancellation of pending requests, a
  `system` event with text `Interrupted` is appended, then the `result` event with `isError` false; no `error` event is
  appended. Every `result` clears the mark; the status becomes `idle` as for any result, and the process stays usable
  (verified with CLI 2.1.309).
- `sessions.stop`: terminates the process (SIGTERM to its group, SIGKILL after 5 s). When the status was `starting`,
  `running` or `waitingPermission`, a `system` event with text `Stopped` is appended once the process has exited,
  before the status becomes `stopped`. Without a process it does nothing.
- Idle stop: in status `idle`, the process is terminated after `sessionIdleMinutes` minutes without activity.
  Activity = a line written to stdin or read from stdout. No event is appended.
- `sessions.update {patch}`, checks in this order: the session exists (`notFound`); the project is writable
  (`locked`); `title` trimmed, not empty and on one line (`badRequest`). `permissionMode` and `allowsAllTools` are
  accepted for every kind, the sessions of 3.5 included.
  `model` `""` removes the model. The session file is updated. A title change shows at once (`session.changed`) and
  reaches the CLI at the next process start (`--name`); the running process is not restarted for it. Claude renames
  its own session with the tool `rename_session` ([mcp.md](mcp.md#625-rename_session)), which calls this method.
  `allowsAllTools` applies at once and never restarts the process: when it becomes true, the pending requests are
  answered after the file is saved, before the response (4.4). A change of `permissionMode` or `model`
  applies at the next process start: in status `idle` the process is restarted at once (terminated, then started
  without a message: `starting` → `idle`); in `starting`, `running` or `waitingPermission` a restart is marked pending
  and runs when the status next becomes `idle`. The restart is an operation of its own, after the response:
  `sessions.update` answers before it ends, and clients then get `session.changed` with `stopped` (the old process
  ended, 5.7), `starting`, then `idle`. A closed session (5.11) accepts every field but is never restarted: a pending
  restart is dropped when it is closed.

### 5.7 Errors and the end of a process

When a process ends, `SessionService` cancels its pending permission requests (4.3), unregisters its MCP token, clears
`statusLine` and the interrupt mark, appends the `system` event `Stopped` when the end comes from a `sessions.stop`
during a turn (5.6), and sets the status from the first matching row:

| Situation                                                          | Status    | Appended `error` event and `SessionInfo.error`                               |
|--------------------------------------------------------------------|-----------|------------------------------------------------------------------------------|
| initialize was answered with an error E (the app terminated it)    | `failed`  | `Claude could not start: E`                                                  |
| the app terminated it (stop, idle stop, restart, stopAll, delete)  | `stopped` | none                                                                         |
| exited by itself with exit code 0                                  | `stopped` | none                                                                         |
| exited by itself with exit code N ≠ 0                              | `failed`  | `Claude exited with code N.` + `\n\n` + stderr tail (when not empty)         |
| killed by signal S, not by the app                                 | `failed`  | `Claude was terminated by signal S.` + `\n\n` + stderr tail (when not empty) |

The session file's `status` is written. A process that could not be started is handled by 5.3. Other errors:

- A `result` with `is_error` true appends an `error` event with its `errorText` before the `result` event, except
  the `result` of an interrupted turn (5.6); the status becomes `idle` as for any result.
- A line that is not valid JSON, and a failing write to stdin, are logged; the write failure is handled by 5.4.
- The stderr tail is the last 4 KiB of stderr (3.4).

### 5.8 What is logged and what is only broadcast

Every `SessionEvent` gets a new `UUID` as `id` and the current time as `at`, is appended with `SessionArchive.append`,
and the returned event is sent as `session.event` to the subscribers of `session:<id>`. Field names and the size limit
are those of [../data/sessions.md](../data/sessions.md). When `append` throws (the archive logs it as a fault), the
event as built is sent as `session.event` and the session goes on; that event is missing from `sessions.history`.

| `type`               | Produced by                                                                                                                                    | Fields                                                                        |
|----------------------|------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------|
| `user`               | `sessions.send`, first messages                                                                                                                | `text`, `attachments`, `deviceID`                                             |
| `assistant`          | `assistant` block `text`                                                                                                                       | `text`, `messageID`, `index`                                                  |
| `thinking`           | `assistant` block `thinking`                                                                                                                   | `text`, `messageID`, `index`                                                  |
| `toolUse`            | `assistant` block `tool_use`                                                                                                                   | `toolUseID`, `name`, `input` (JSON text), `messageID`, `index`                |
| `toolResult`         | `user` block `tool_result`                                                                                                                     | `toolUseID`, `text`, `isError`                                                |
| `permission`         | `can_use_tool`                                                                                                                                 | `requestID`, `toolName`, `input`, `description`, `suggestions`, `blockedPath` |
| `permissionDecision` | an answer or a cancellation (4.3), an automatic answer (4.4)                                                                                   | `requestID`, `decision`, `deviceID`                                           |
| `result`             | `result` (`isError` false for an interrupted turn, 5.6)                                                                                        | `isError`, `durationMS`, `costUSD`, `stopReason`                              |
| `system`             | the first `system` `init` of a process (and later ones, below); an interrupted turn (`Interrupted`); `sessions.stop` during a turn (`Stopped`) | `text`                                                                        |
| `error`              | 5.3, 5.7, results with `errorText` other than an interrupted turn's                                                                            | `text`                                                                        |

- The `system` text for `init`: `Claude Code <version> · <model> · <permissionMode> mode · <toolCount> tools ·
  Hephaestus tools <hephaestusStatus>` (`missing` when the `hephaestus` server is absent). Another `system` event is
  appended at a later `init` of the same process only when `hephaestusStatus` changed.
- `messageID` and `index` of a block equal those of its `session.delta` events, so a client replaces the streamed text
  of that block with the event ([../ui/sessions.md](../ui/sessions.md)).

Only broadcast, never logged:

- `session.delta {projectID, sessionID, messageID, index, kind, text}` (topic `session:<id>`): one per non-empty delta,
  `text` being the fragment to append (not the accumulated text).
- `statusLine` changes, through `session.changed`, at most one per second per session (the latest value is sent at the
  end of the second).
- Status and `pendingPermissions` changes (`session.changed`), `permission.requested` and `permission.resolved` (every
  connection).

### 5.9 Delete, project removal, startup

- `sessions.delete`: terminates the process, cancels pending requests, `PermissionBroker.reset(sessionID:)`,
  `SessionArchive.delete`, removes the plugin folder and the prompt file
  (`SkillsService.removePluginFolder(sessionID:)`), emits `session.removed`. The CLI transcript under
  `~/.claude/projects/` is left in place.
- `stopAll(projectID:)`: terminates every process of that project, in parallel, and forgets its cached sessions. The
  host calls it for a project and for each of its sub projects when they are removed or moved away.
- Startup: sessions are loaded per project on first use (`SessionArchive.list`). No process exists, so every session
  has its file's status (`stopped` or `failed`).
- `stopAll()`: terminates every process in parallel (each writes `stopped`) and returns when all have exited.
  `stopAll()` and `stopAll(projectID:)` also cancel the title calls (5.10) of the sessions they cover.

### 5.10 Generated titles (`SessionTitler`)

A `project`, `feedback` or `bundle` session is titled from its first message by one short call to the Claude CLI with
the model `haiku`. The call is not a session: it has no session file, no events and no CLI transcript, and no list
shows it. `task` and `regeneration` sessions keep their titles.

1. Trigger: `SessionService` appends the first `user` event of a session of one of these kinds (5.4 step 4, for the
   first message of `sessions.start` and for the first `sessions.send` of a project session started without one).
   First: `SessionArchive.history(_:before: nil, limit: 1)` gave `total` 0 just before the append. A first message
   whose `text` is empty after trimming (attachments only) gives no call, and the session keeps its title.
2. The call runs in a `Task` of its own, kept per session id. `sessions.start` and `sessions.send` neither wait for it
   nor fail with it: the session's process starts and answers as usual, and the title changes whenever the call ends,
   during a turn too.
3. Command: `ChildProcess.capture` (1.4) of the path of `ClaudeLocator.shared.current(configured:
   settings.claudeURL)` (nil: no call), arguments `SessionTitler.arguments`, `input` = `Prompts.titleRequest(text)`
   ([prompts.md](prompts.md#title-call)) as UTF-8, working directory `FileManager.default.temporaryDirectory`,
   environment = the login environment (1.1), timeout 60 s. Arguments, one each, in this order: `-p`, `--model`,
   `haiku`, `--output-format`, `text`, `--no-session-persistence`, `--tools`, an empty argument (no tool),
   `--strict-mcp-config`, `--disable-slash-commands`, `--system-prompt`, `Prompts.titleSystemPrompt`. Verified with
   CLI 2.1.309: the title alone on stdout, exit code 0, in about 4 s, and no transcript written.
4. Output: with exit code 0 and no timeout, stdout decoded as UTF-8 (lossy) goes through `SessionTitler.cleanTitle`:
   its first line that is not empty after trimming, trimmed; one pair of surrounding quotes removed (`"…"`, `'…'`,
   `“…”`, `‘…’`, `` `…` ``), then a final `.`, then whitespace again; cut to its first 80 `Character`s and trimmed. An
   empty result, a spawn error, another exit code and a timeout give no title: the session keeps its title, and the
   failure is logged at `error` with the exit code or the error, never the message or the output.
5. Title: `SessionTitler.sessionTitle`: `project` → the cleaned title; `feedback` → `<task id> · <title>`; `bundle` →
   `<bundle id> · <title>` (a space, U+00B7, a space), for example `HEPH-F1 · Sidebar breaks on rotation`.
6. Applied on the actor: when the session still exists and its project is writable, the title is written with
   `SessionArchive.update`, whatever the title is then (one the user or `rename_session` set meanwhile is replaced),
   and `session.changed` is emitted. Otherwise it is dropped and nothing is written. The process is not restarted:
   the CLI gets the title at its next start (`--name`, 3.1).

```swift
/// The title call of 5.10.
public enum SessionTitler {
    /// argv[1...] of step 3.
    public static let arguments: [String]
    /// Runs the call of step 3 with the cleanup of step 4; nil when it fails or leaves nothing. Throws only
    /// CancellationError.
    public static func generate(executable: String, text: String, environment: [String: String]) async throws
        -> String?
    /// Step 4; nil when nothing is left.
    public static func cleanTitle(_ output: String) -> String?
    /// Step 5; `id` is the task id of a feedback session, the bundle id of a bundle session, ignored for the others.
    public static func sessionTitle(_ title: String, kind: SessionKind, id: String?) -> String
}
```

### 5.11 Closing a session

Claude closes its own session with the MCP tool `close_session` ([mcp.md](mcp.md#626-close_session)), which calls
`close(projectID:sessionID:)` with the session of its token. Only Claude closes a session: no protocol method does,
and the app offers no way to reopen one. The prompts say when ([prompts.md](prompts.md)): a `feedback` session as soon
as no question is open; a `project`, `task` or `bundle` session only when the user says the conversation is done or
asks to close it. A `regeneration` session has no `close_session` tool.

1. Checks: the session exists (`notFound`); its kind is not `regeneration` (`badRequest`, `A regeneration session
   cannot be closed.`); the project is writable (`locked`). A session that is already closed is left as it is, and
   the call succeeds.
2. `closed` = now is written to the session file (`SessionArchive.update`); a pending restart (5.6) is dropped;
   `session.changed` is emitted.
3. The process: in `starting`, `running` or `waitingPermission` (the turn that called the tool), it is terminated when
   that turn's `result` has been handled, its pending requests cancelled; in `idle`, it is terminated at once; without
   a process, nothing. It ends as a process the app terminated (5.7): status `stopped`, no `error` event. The tool's
   result reaches Claude before the process stops.

A closed session keeps its transcript, its attachments and its file; `sessions.history`, `sessions.readAttachment`,
`sessions.update`, `sessions.stop` and `sessions.delete` work as for any session. It never starts a process again:
`sessions.send` fails with `conflict` `This conversation is over.` (5.4), and so do the instructions that
`start_bundle_task` sends to it ([../services/bundles.md](../services/bundles.md)). The UI replaces its composer with
the text "This conversation is over" ([../ui/sessions.md](../ui/sessions.md#composer)).

## Depends on

| Name                                                                                                                                                                                                                                                                                                                                                                                                          | Defined in                                                                                       |
|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `SessionInfo` (`allowsAllTools`, `statusLine`, `error`, `pendingPermissions`), `SessionPatch`, `SessionEvent` (with `messageID`, `index`, `description`, `blockedPath`), `SessionKind`, `SessionMode`, `SessionStatus`, `PermissionMode`, `PermissionDecision`, `PermissionRequest`, `SessionDeltaKind`, `UploadRef`, `TaskAttachment`, `DeviceInfo`, `DeviceRecord`, `ProjectSummary.pendingPermissionCount` | [../protocol/types.md](../protocol/types.md)                                                     |
| `ProtocolError` and its codes                                                                                                                                                                                                                                                                                                                                                                                 | [../protocol/envelope.md](../protocol/envelope.md)                                               |
| `sessions.*` params and results (`SessionsHistoryResult`, paging, `AttachmentsReadResult`), uploads, `session.*` and `permission.*` events                                                                                                                                                                                                                                                                    | [../protocol/methods.md](../protocol/methods.md), [../protocol/events.md](../protocol/events.md) |
| `SessionArchive`, `SessionFile.fileStem(_:)`, session file and event formats                                                                                                                                                                                                                                                                                                                                  | [../data/sessions.md](../data/sessions.md)                                                       |
| `DeviceSettings` (`claudePath`, `claudeURL`, `defaultModel`, `defaultPermissionMode`, `sessionIdleMinutes`, `forge.branch`, `forge.enabled`, `forge.sourceProjectID`), `AtomicFile`                                                                                                                                                                                                                           | [../data/app-storage.md](../data/app-storage.md)                                                 |
| `ClaudePathEncoding` (transcript folder)                                                                                                                                                                                                                                                                                                                                                                      | [../devices/migration.md](../devices/migration.md)                                               |
| `HostService` (conformance to `SessionHost`), `HostMethodHandler`, `HostInfoService.refresh()`, `checkWritable`                                                                                                                                                                                                                                                                                               | [../services/host.md](../services/host.md)                                                       |
| `UploadService` (`claim`, `finish`, `release`), `ClaimedUpload`                                                                                                                                                                                                                                                                                                                                               | [../services/files.md](../services/files.md#7-uploads)                                           |
| `ForgeService` notifications, the Forge push tools, the configuration checks (push URL, Claude Code settings)                                                                                                                                                                                                                                                                                                 | [../forge/pipeline.md](../forge/pipeline.md)                                                     |
| the public repository rule, the commit identity, the limits of these rules                                                                                                                                                                                                                                                                                                                                    | [../public-repository.md](../public-repository.md)                                               |
| `Log.host`, logging rules                                                                                                                                                                                                                                                                                                                                                                                     | [../architecture.md](../architecture.md)                                                         |
| `MCPServer`                                                                                                                                                                                                                                                                                                                                                                                                   | [mcp.md](mcp.md)                                                                                 |
| `Prompts` (`titleRequest`, `titleSystemPrompt`), `ClaudeProjectContext`, `ClaudeTaskContext`, `RegenerationContext`                                                                                                                                                                                                                                                                                           | [prompts.md](prompts.md)                                                                         |
| `SkillsService`                                                                                                                                                                                                                                                                                                                                                                                               | [skills.md](skills.md)                                                                           |
