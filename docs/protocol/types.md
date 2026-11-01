# Wire protocol: shared types

files:
- HephaestusKit/Sources/HephCore/Protocol/Types/DeviceTypes.swift
- HephaestusKit/Sources/HephCore/Protocol/Types/ProjectTypes.swift
- HephaestusKit/Sources/HephCore/Protocol/Types/TicketTypes.swift
- HephaestusKit/Sources/HephCore/Protocol/Types/BundleTypes.swift
- HephaestusKit/Sources/HephCore/Protocol/Types/FileTypes.swift
- HephaestusKit/Sources/HephCore/Protocol/Types/SessionTypes.swift
- HephaestusKit/Sources/HephCore/Protocol/Types/SearchTypes.swift
- HephaestusKit/Sources/HephCore/Protocol/Types/SkillTypes.swift
- HephaestusKit/Sources/HephCore/Protocol/Types/MigrationTypes.swift
- HephaestusKit/Sources/HephCore/Protocol/Types/ForgeTypes.swift

---

The types that travel in method params, results and event payloads. The params and result structs of each method are
in [methods.md](methods.md), the event payloads in [events.md](events.md), the JSON encoding rules in
[envelope.md](envelope.md#encoding).

## Conventions

- Every type below is public and lives in module `HephCore`, in the file named in its section heading.
- Structs: `public struct <Name>: Codable, Sendable, Hashable`, with one `public var` per field, in table order. Each
  struct declares a public memberwise `init` with the fields as parameters in table order; optional parameters default
  to `nil`, no other parameter has a default.
- Enums: `public enum <Name>: String, Codable, Sendable, Hashable, CaseIterable`, one case per raw value listed, the
  case name equal to the raw value unless the table gives another case name.
- A type with an `id` field, or with "Identifiable" in its description, conforms to `Identifiable`.
- JSON field names are the field names. A type ending in `?` is optional: the member is omitted when `nil`.
- No custom `CodingKeys` and no custom coding, except where a section says so.
- Identifiers: `projectID` is the project identifier (2–8 letters A–Z, [data/project-yml.md](../data/project-yml.md));
  `ticketID` is `<projectID>-<n>`, or `<projectID>-F<n>` for a feedback ticket
  ([data/ticket-yml.md](../data/ticket-yml.md#ticket-id)); `bundleID` is `<projectID>-B<n>`
  ([services/bundles.md](../services/bundles.md#bundle-id)); device, mesh, session, comment, web tab,
  migration, upload and Forge cycle ids are `UUID`s; session event ids are strings (`SessionEvent`).
- Names (project, sub project, ticket, session title) are trimmed of surrounding white space and line
  breaks, must not be empty and must be on one line; they have no maximum length
  ([methods.md](methods.md#paths)).
- Project-relative paths are `/`-separated, without a leading `/`; `""` is the project root.

## Devices (DeviceTypes.swift)

### DevicePlatform

| Raw value | Meaning   |
|-----------|-----------|
| `macOS`   | A Mac     |
| `iOS`     | An iPhone |
| `iPadOS`  | An iPad   |

### DeviceInfo

What a device says about itself in `hello` ([methods.md](methods.md#hello)) and in pairing
([devices/mesh.md](../devices/mesh.md)).

| Field        | Type             | Meaning                                                                              |
|--------------|------------------|--------------------------------------------------------------------------------------|
| `id`         | `UUID`           | Device id, generated once per installation ([devices/roles.md](../devices/roles.md)) |
| `name`       | `String`         | Device name                                                                          |
| `platform`   | `DevicePlatform` | Platform                                                                             |
| `isMain`     | `Bool`           | The device is a Main                                                                 |
| `appVersion` | `String`         | Marketing version (`1.0`)                                                            |
| `build`      | `Int`            | Build number (`CURRENT_PROJECT_VERSION`; `0` for local builds)                       |

### DeviceRecord

A device of the mesh registry ([devices/mesh.md](../devices/mesh.md)).

| Field        | Type             | Meaning                                                                                                                                                            |
|--------------|------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`         | `UUID`           | Device id                                                                                                                                                          |
| `name`       | `String`         | Device name                                                                                                                                                        |
| `platform`   | `DevicePlatform` | Platform                                                                                                                                                           |
| `isMain`     | `Bool`           | The device is a Main                                                                                                                                               |
| `addresses`  | `[String]`       | Mains: host names and IP addresses to reach the listener (`.local` name, non-loopback IPv4 addresses, additional addresses from Settings); empty for other devices |
| `port`       | `Int`            | Mains: listener port (default `47100`); `0` for other devices                                                                                                      |
| `appVersion` | `String`         | Marketing version                                                                                                                                                  |
| `build`      | `Int`            | Build number                                                                                                                                                       |
| `pairedAt`   | `Date`           | When the device joined the mesh                                                                                                                                    |
| `updatedAt`  | `Date`           | Last change of the record; registry merges keep the record with the latest `updatedAt`                                                                             |
| `revoked`    | `Bool`           | The device was revoked; revoked records stay in the registry                                                                                                       |

### Presence

One device's online state in a Main's presence report ([devices/mesh.md](../devices/mesh.md)). Identifiable by
`deviceID` (`var id: UUID { deviceID }`).

| Field      | Type     | Meaning                                                                                                                                                                                         |
|------------|----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `deviceID` | `UUID`   | The device                                                                                                                                                                                      |
| `online`   | `Bool`   | The device is connected                                                                                                                                                                         |
| `lastSeen` | `Date`   | Online: when the report was built. Offline: when the last connection with the device ended                                                                                                      |
| `via`      | `[UUID]` | Ids of the Mains whose direct observation gave this entry; a Main's entry for itself and for its direct connections lists the Main itself, a relayed entry lists the peer Main that reported it |

### MeshSnapshot

| Field      | Type             | Meaning                                                                             |
|------------|------------------|-------------------------------------------------------------------------------------|
| `meshID`   | `UUID`           | Mesh id                                                                             |
| `devices`  | `[DeviceRecord]` | Every record of the registry, revoked ones included                                 |
| `presence` | `[Presence]`     | The Main's presence report: one entry per device, direct and relayed entries merged |

## Projects (ProjectTypes.swift)

### ProjectSummary

A project in a Main's project tree. Identifiable.

| Field                    | Type               | Meaning                                                                                                                                          |
|--------------------------|--------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| `id`                     | `String`           | Project identifier                                                                                                                               |
| `name`                   | `String`           | Project name                                                                                                                                     |
| `description`            | `String?`          | Project description                                                                                                                              |
| `deviceID`               | `UUID`             | The Main hosting the project                                                                                                                     |
| `rootPath`               | `String`           | Absolute path of the project root on that Main                                                                                                   |
| `children`               | `[ProjectSummary]` | Sub projects, in the order of `subprojects` in project.yml, each with its own children                                                           |
| `migrating`              | `Bool`             | The project, or the top-level project containing it, is being moved to another Main                                                              |
| `parseError`             | `String?`          | Set when `.hephaestus/project.yml` cannot be parsed; the other fields then hold the last valid content ([services/host.md](../services/host.md)) |
| `pendingPermissionCount` | `Int`              | Permission requests waiting for an answer in the sessions of this project; those of a sub project count in its own summary                       |

### Project

The content of `.hephaestus/project.yml` ([data/project-yml.md](../data/project-yml.md)) plus where it lives.
Identifiable.

| Field             | Type             | Meaning                                                      |
|-------------------|------------------|--------------------------------------------------------------|
| `id`              | `String`         | Project identifier                                           |
| `name`            | `String`         | Project name                                                 |
| `description`     | `String?`        | Project description                                          |
| `created`         | `Date`           | Creation date                                                |
| `code`            | `String`         | Code folder, relative to the project root (`.` is the root)  |
| `docs`            | `String`         | Docs folder, relative to the code folder                     |
| `ticketCounter`   | `Int`            | Last ticket number used                                      |
| `feedbackCounter` | `Int`            | Last feedback ticket number used                             |
| `subprojects`     | `[String]`       | Relative paths of the sub project roots                      |
| `webTabs`         | `[WebTab]`       | Web tabs, in tab strip order                                 |
| `skills`          | `[String]`       | Names of the enabled library skills; empty means all skills  |
| `claude`          | `ClaudeDefaults` | Defaults for new sessions                                    |
| `deviceID`        | `UUID`           | The Main hosting the project                                 |
| `rootPath`        | `String`         | Absolute path of the project root on that Main               |
| `migrating`       | `Bool`           | The project is being moved to another Main                   |
| `parseError`      | `String?`        | Set when project.yml cannot be parsed (see `ProjectSummary`) |

### ClaudeDefaults

The `claude` block of project.yml. An absent block is a `ClaudeDefaults` with both fields `nil`.

| Field            | Type              | Meaning                                                                                    |
|------------------|-------------------|--------------------------------------------------------------------------------------------|
| `model`          | `String?`         | Model alias for new sessions (for example `opus`); `nil`: the Main's default model setting |
| `permissionMode` | `PermissionMode?` | Permission mode for new sessions; `nil`: the Main's default permission mode setting        |

The Main's settings are in [data/app-storage.md](../data/app-storage.md).

### ProjectPatch

Changes for `projects.update`. A `nil` field leaves the value unchanged.

| Field         | Type              | Meaning                                                                                         |
|---------------|-------------------|-------------------------------------------------------------------------------------------------|
| `name`        | `String?`         | New name, trimmed: not empty, on one line                                                       |
| `description` | `String?`         | New description; an empty string removes it                                                     |
| `skills`      | `[String]?`       | Replaces the enabled skills; empty means all skills                                             |
| `claude`      | `ClaudeDefaults?` | Replaces the whole `claude` block: a `nil` field removes that key, and so does an empty `model` |

### WebTab

A web tab of a project ([ui/web.md](../ui/web.md)). Identifiable.

| Field    | Type     | Meaning                       |
|----------|----------|-------------------------------|
| `id`     | `UUID`   | Tab id                        |
| `title`  | `String` | Title                         |
| `url`    | `String` | Absolute URL                  |
| `locked` | `Bool`   | A locked tab cannot be closed |

### WebTabPatch

Changes for `tabs.update`. A `nil` field leaves the value unchanged.

| Field    | Type      | Meaning             |
|----------|-----------|---------------------|
| `url`    | `String?` | New URL (not empty) |
| `title`  | `String?` | New title           |
| `locked` | `Bool?`   | Lock or unlock      |

## Tickets (TicketTypes.swift)

### TicketStatus

| Case         | Raw value     | `displayName` |
|--------------|---------------|---------------|
| `todo`       | `todo`        | To Do         |
| `inProgress` | `in_progress` | In Progress   |
| `review`     | `review`      | Review        |
| `done`       | `done`        | Done          |

`public var displayName: String` returns the text of the last column. `allCases` is in the order of the table (the
order of the ticket list sections).

### TicketItem

A ticket ([data/ticket-yml.md](../data/ticket-yml.md)). Identifiable.

| Field         | Type              | Meaning                                                              |
|---------------|-------------------|----------------------------------------------------------------------|
| `id`          | `String`          | Ticket id, `<projectID>-<n>` or `<projectID>-F<n>` (feedback ticket) |
| `name`        | `String`          | Name                                                                 |
| `description` | `String`          | Markdown; empty when there is none                                   |
| `status`      | `TicketStatus`    | Status                                                               |
| `created`     | `Date`            | Creation date                                                        |
| `updated`     | `Date`            | Last change of the ticket (a field or a comment)                     |
| `comments`    | `[TicketComment]` | Comments, oldest first                                               |
| `parseError`  | `String?`         | Set when the ticket file cannot be parsed (a broken ticket)          |

A broken ticket has `id` from its file name, `name` and `description` empty, `status` `todo`, `created` and `updated`
equal to the file's modification date, no comments, and `parseError` set to the parser's message. The Main never
rewrites a broken ticket file.

### TicketComment

Identifiable.

| Field         | Type                 | Meaning                                                                               |
|---------------|----------------------|---------------------------------------------------------------------------------------|
| `id`          | `UUID`               | Comment id                                                                            |
| `author`      | `String`             | Name of the device that wrote it, or `Claude` for comments made through the MCP tools |
| `created`     | `Date`               | Creation date                                                                         |
| `edited`      | `Date?`              | Date of the last edit                                                                 |
| `body`        | `String`             | Markdown                                                                              |
| `attachments` | `[TicketAttachment]` | Attached files                                                                        |

A comment whose `author` is `Claude` can be deleted but not edited
([methods.md](methods.md#ticketsupdatecomment)); the comments of devices can be edited and deleted.

### TicketAttachment

A file stored in `.hephaestus/attachments/<ticket id>/`. Identifiable by `file` (`var id: String { file }`).

| Field  | Type     | Meaning                                      |
|--------|----------|----------------------------------------------|
| `file` | `String` | File name in the ticket's attachments folder |
| `type` | `String` | MIME type (for example `image/png`)          |
| `size` | `Int`    | Size in bytes                                |

### TicketPatch

Changes for `tickets.update`. A `nil` field leaves the value unchanged.

| Field         | Type            | Meaning                                   |
|---------------|-----------------|-------------------------------------------|
| `name`        | `String?`       | New name, trimmed: not empty, on one line |
| `description` | `String?`       | New description (Markdown)                |
| `status`      | `TicketStatus?` | New status                                |

## Bundles (BundleTypes.swift)

Ticket bundles: [services/bundles.md](../services/bundles.md).

### BundleStatus

| Raw value | `displayName` | Meaning                                                           |
|-----------|---------------|-------------------------------------------------------------------|
| `draft`   | Draft         | Not being worked on                                               |
| `running` | Running       | Its coordinator and ticket sessions work on it                    |
| `review`  | Review        | Every ticket is finished; the coordinator waits for the user's OK |
| `done`    | Done          | Its work was brought in and its worktrees removed                 |

### BundleTicket

Identifiable by `ticketID` (`var id: String { ticketID }`).

| Field       | Type     | Meaning                                                                                                          |
|-------------|----------|------------------------------------------------------------------------------------------------------------------|
| `ticketID`  | `String` | Ticket id                                                                                                        |
| `sessionID` | `UUID?`  | The last ticket session the bundle started for this ticket                                                       |
| `finished`  | `Bool?`  | `true` once its session reported the ticket's work finished, until the coordinator gives it new work; else `nil` |

### BundleItem

A bundle. Identifiable.

| Field                  | Type             | Meaning                                                       |
|------------------------|------------------|---------------------------------------------------------------|
| `id`                   | `String`         | Bundle id, `<projectID>-B<n>`                                 |
| `name`                 | `String`         | Name                                                          |
| `status`               | `BundleStatus`   | Status                                                        |
| `created`              | `Date`           | Creation date                                                 |
| `updated`              | `Date`           | Last change                                                   |
| `base`                 | `String?`        | Branch the ticket branches start from; set when first started |
| `coordinatorSessionID` | `UUID?`          | The coordinator session; set when first started               |
| `tickets`              | `[BundleTicket]` | Its tickets, in order                                         |

### BundlePatch

Changes for `bundles.update`. A `nil` field leaves the value unchanged.

| Field       | Type        | Meaning                                       |
|-------------|-------------|-----------------------------------------------|
| `name`      | `String?`   | New name, trimmed: not empty, on one line     |
| `ticketIDs` | `[String]?` | Replaces the tickets, in order (`draft` only) |

## Files (FileTypes.swift)

### FileEntry

A file or folder of a project. Identifiable by `path` (`var id: String { path }`).

| Field         | Type     | Meaning                                                                |
|---------------|----------|------------------------------------------------------------------------|
| `name`        | `String` | Last path component                                                    |
| `path`        | `String` | Project-relative path                                                  |
| `isDirectory` | `Bool`   | The entry is a folder (a symbolic link to a folder counts as a folder) |
| `size`        | `Int`    | Size in bytes; `0` for folders                                         |
| `modified`    | `Date`   | Modification date                                                      |

### UploadRef

A file attached to a request (`tickets.addComment`, `sessions.start`, `sessions.send`, `forge.feedback`): a complete
upload of the request's project, sent before with `uploads.begin` and `uploads.chunk`
([methods.md](methods.md#uploads)). Files have no size limit.

| Field      | Type     | Meaning                                                                                                          |
|------------|----------|------------------------------------------------------------------------------------------------------------------|
| `uploadID` | `UUID`   | The upload, as `uploads.begin` returned it                                                                       |
| `fileName` | `String` | Original file name of the attachment; the Main sanitizes it ([data/ticket-yml.md](../data/ticket-yml.md#naming)) |

## Sessions (SessionTypes.swift)

### SessionKind

| Raw value      | Meaning                                                                        |
|----------------|--------------------------------------------------------------------------------|
| `project`      | Project chat                                                                   |
| `ticket`       | Session bound to a ticket                                                      |
| `feedback`     | Forge feedback discussion ([forge/pipeline.md](../forge/pipeline.md))          |
| `regeneration` | Forge regeneration ([forge/pipeline.md](../forge/pipeline.md))                 |
| `bundle`       | Coordinator of a ticket bundle ([services/bundles.md](../services/bundles.md)) |

### SessionMode

Mode of a ticket session. `public var displayName: String` returns the last column.

| Raw value   | `displayName` |
|-------------|---------------|
| `implement` | Implement     |
| `debug`     | Debug         |
| `review`    | Review        |
| `plan`      | Plan          |
| `custom`    | Custom        |

### SessionStatus

| Raw value           | Meaning                                                                                         |
|---------------------|-------------------------------------------------------------------------------------------------|
| `stopped`           | No process: a new session, or the process was stopped, stopped when idle, or exited with code 0 |
| `starting`          | The process was started and has not answered the initialize request yet                         |
| `running`           | A turn is in progress                                                                           |
| `waitingPermission` | The turn waits for at least one permission answer                                               |
| `idle`              | The process is alive between turns                                                              |
| `failed`            | The last process failed; `error` gives the reason                                               |

Transitions and the next process start: [claude/cli.md](../claude/cli.md). The session file stores only `stopped` and
`failed` ([data/sessions.md](../data/sessions.md)). A closed session (`SessionInfo.closed` set) has no process once its
last turn ends, and never starts one again.

### PermissionMode

| Raw value           | Meaning                                                     |
|---------------------|-------------------------------------------------------------|
| `manual`            | Asks for everything the user's Claude settings do not allow |
| `acceptEdits`       | The CLI permission mode of the same name                    |
| `auto`              | The CLI permission mode of the same name                    |
| `plan`              | The CLI permission mode of the same name                    |
| `bypassPermissions` | The CLI permission mode of the same name                    |

How each value is passed to the CLI: [claude/cli.md](../claude/cli.md).

### SessionInfo

A Claude session ([data/sessions.md](../data/sessions.md)). Identifiable.

| Field                | Type                  | Meaning                                                                                                          |
|----------------------|-----------------------|------------------------------------------------------------------------------------------------------------------|
| `id`                 | `UUID`                | Session id, also the Claude CLI session id ([claude/cli.md](../claude/cli.md))                                   |
| `kind`               | `SessionKind`         | Kind                                                                                                             |
| `ticketID`           | `String?`             | Ticket and feedback sessions: the ticket                                                                         |
| `mode`               | `SessionMode?`        | Ticket sessions: the mode                                                                                        |
| `bundleID`           | `String?`             | Bundle sessions, and ticket sessions started by a bundle: the bundle                                             |
| `title`              | `String`              | Title                                                                                                            |
| `created`            | `Date`                | Creation date                                                                                                    |
| `updated`            | `Date`                | Last change of a stored field                                                                                    |
| `permissionMode`     | `PermissionMode`      | Permission mode                                                                                                  |
| `allowsAllTools`     | `Bool`                | Allow All Tools: the Main answers every permission request itself ([claude/cli.md](../claude/cli.md))            |
| `model`              | `String?`             | Model alias; `nil`: the CLI's default                                                                            |
| `status`             | `SessionStatus`       | Status                                                                                                           |
| `closed`             | `Date?`               | When Claude closed the session; `nil` while it is open ([claude/cli.md](../claude/cli.md#511-closing-a-session)) |
| `statusLine`         | `String?`             | Live status line during a turn ([claude/cli.md](../claude/cli.md))                                               |
| `error`              | `String?`             | When `status` is `failed`: the reason (tail of the CLI's standard error, or the start error)                     |
| `pendingPermissions` | `[PermissionRequest]` | Permission requests of the current process waiting for an answer, oldest first; empty when there is none         |

`statusLine`, `error` and `pendingPermissions` are kept in memory by the Main and are not stored in the session file.
A client that connects later rebuilds its permission cards from `pendingPermissions`
([events.md](events.md#permissionrequested)).

### SessionPatch

Changes for `sessions.update`. A `nil` field leaves the value unchanged.

| Field            | Type              | Meaning                                    |
|------------------|-------------------|--------------------------------------------|
| `title`          | `String?`         | New title (trimmed, not empty, one line)   |
| `permissionMode` | `PermissionMode?` | New permission mode                        |
| `allowsAllTools` | `Bool?`           | Turns Allow All Tools on or off            |
| `model`          | `String?`         | New model alias; an empty string clears it |

### SessionEventType

`user`, `assistant`, `thinking`, `toolUse`, `toolResult`, `permission`, `permissionDecision`, `result`, `system`,
`error`.

### SessionEvent

One entry of a session transcript, stored as one JSON line of `.hephaestus/sessions/<id>.jsonl`
([data/sessions.md](../data/sessions.md)). A flat struct: the fields a type does not use are `nil`. Identifiable.

| Field         | Type                  | Used by                                              | Meaning                                                                                       |
|---------------|-----------------------|------------------------------------------------------|-----------------------------------------------------------------------------------------------|
| `id`          | `String`              | all                                                  | Event id, unique within the session, chosen by the Main ([claude/cli.md](../claude/cli.md))   |
| `at`          | `Date`                | all                                                  | When the Main recorded the event                                                              |
| `type`        | `SessionEventType`    | all                                                  | Type                                                                                          |
| `text`        | `String?`             | user, assistant, thinking, toolResult, system, error | Text ([data/sessions.md](../data/sessions.md))                                                |
| `attachments` | `[TicketAttachment]?` | user                                                 | Files attached to the message, stored in the session's attachment folder                      |
| `deviceID`    | `UUID?`               | user, permissionDecision                             | Device that sent the message, or whose answer was applied                                     |
| `messageID`   | `String?`             | assistant, thinking, toolUse                         | Id of the Claude message the block belongs to: the `messageID` of the block's `session.delta` |
| `index`       | `Int?`                | assistant, thinking, toolUse                         | Index of the block in its message, from 0: the `index` of the block's `session.delta`         |
| `toolUseID`   | `String?`             | toolUse, toolResult                                  | The CLI's tool use id                                                                         |
| `name`        | `String?`             | toolUse                                              | Tool name                                                                                     |
| `input`       | `String?`             | toolUse, permission                                  | Tool input, as JSON text                                                                      |
| `isError`     | `Bool?`               | toolResult, result                                   | The tool or the turn failed                                                                   |
| `requestID`   | `String?`             | permission, permissionDecision                       | The CLI's permission request id                                                               |
| `toolName`    | `String?`             | permission                                           | Tool asking for permission                                                                    |
| `description` | `String?`             | permission                                           | The CLI's description of the call                                                             |
| `suggestions` | `String?`             | permission                                           | The CLI's permission suggestions, as JSON text; `[]` when it gives none                       |
| `blockedPath` | `String?`             | permission                                           | The path that caused the request                                                              |
| `decision`    | `PermissionDecision?` | permissionDecision                                   | The answer                                                                                    |
| `durationMS`  | `Int?`                | result                                               | Duration of the turn in milliseconds                                                          |
| `costUSD`     | `Double?`             | result                                               | Cost of the turn in US dollars                                                                |
| `stopReason`  | `String?`             | result                                               | The CLI's stop reason; `nil` when it gives none                                               |

- The attachment folder of a session is `.hephaestus/sessions/<session id>/`, the id written in lowercase
  ([data/sessions.md](../data/sessions.md)). A client reads an attachment with `sessions.readAttachment`
  ([methods.md](methods.md#sessionsreadattachment)), in ranges of at most 4 MiB.
- Which CLI output produces which event: [claude/cli.md](../claude/cli.md).

### PermissionRequest

A permission request of the CLI waiting for an answer. Identifiable by `requestID` (`var id: String { requestID }`).

| Field         | Type      | Meaning                                                                                         |
|---------------|-----------|-------------------------------------------------------------------------------------------------|
| `requestID`   | `String`  | The CLI's request id                                                                            |
| `toolName`    | `String`  | Tool asking for permission                                                                      |
| `input`       | `String`  | Tool input, as JSON text                                                                        |
| `description` | `String?` | The CLI's description of the action                                                             |
| `suggestions` | `String`  | The CLI's permission suggestions, as JSON text; `[]` when it gives none (used by `allowAlways`) |
| `blockedPath` | `String?` | The path that caused the request                                                                |

### PermissionDecision

| Raw value     | Meaning                                                                          |
|---------------|----------------------------------------------------------------------------------|
| `allow`       | Allow this use                                                                   |
| `allowAlways` | Allow, and apply the request's suggestions                                       |
| `allowAll`    | Allowed by the Main because the session allows all tools; never sent by a client |
| `deny`        | Deny                                                                             |

### SessionDeltaKind

Kind of a streamed fragment (`session.delta`, [events.md](events.md#sessiondelta)).

| Raw value   | Meaning                      |
|-------------|------------------------------|
| `text`      | Assistant text               |
| `thinking`  | Thinking text                |
| `toolInput` | Partial JSON of a tool input |

## Search (SearchTypes.swift)

### SearchScope

| Raw value  | Searched fields                                                 |
|------------|-----------------------------------------------------------------|
| `projects` | Project identifier, name, description                           |
| `tickets`  | Ticket id, name, description                                    |
| `comments` | Comment bodies                                                  |
| `docs`     | File names and content of the Markdown files of the docs folder |
| `code`     | File names and text content of the code folder                  |
| `skills`   | Skill name, description, file contents                          |
| `webTabs`  | Web tab title and URL                                           |
| `sessions` | Session title, text of the user and assistant messages          |
| `devices`  | Device names                                                    |

Matching and ranking: [services/search.md](../services/search.md).

### SearchResult

One search hit, as produced by a Main ([services/search.md](../services/search.md#3-searchresult)).

| Field       | Type          | Meaning                                                                                                                                                                                        |
|-------------|---------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `kind`      | `SearchScope` | Kind of item                                                                                                                                                                                   |
| `deviceID`  | `UUID`        | The Main that produced the result, for `devices` too (the matched device is `itemID`)                                                                                                          |
| `projectID` | `String?`     | The item's project; `nil` for `skills` and `devices`                                                                                                                                           |
| `itemID`    | `String`      | Identifier of the item within its kind: project identifier, ticket id, comment id, project-relative path (`docs`, `code`), skill name, tab id, session id or device id (UUIDs as `uuidString`) |
| `ticketID`  | `String?`     | The ticket of a ticket or comment, or of a session bound to a ticket                                                                                                                           |
| `path`      | `String?`     | `docs`, `code`: project-relative path; `skills`: path inside the skill folder                                                                                                                  |
| `line`      | `Int?`        | `docs`, `code`, `skills`: 1-based line of the snippet when it comes from the content                                                                                                           |
| `title`     | `String`      | Text shown as the result's title                                                                                                                                                               |
| `snippet`   | `String`      | Text shown under the title; may be empty                                                                                                                                                       |
| `rank`      | `Int`         | `0`: exact id match, `1`: title match, `2`: content match                                                                                                                                      |
| `date`      | `Date?`       | Recency of the item, used for ordering                                                                                                                                                         |

The client highlights the query words in `title` and `snippet` itself
([services/search.md](../services/search.md#24-highlights)).

## Skills (SkillTypes.swift)

### SkillSummary

A skill of a Main's library ([claude/skills.md](../claude/skills.md)). Identifiable by `name`
(`var id: String { name }`).

| Field         | Type      | Meaning                                                                             |
|---------------|-----------|-------------------------------------------------------------------------------------|
| `name`        | `String`  | Skill name (folder name)                                                            |
| `description` | `String`  | Description from the SKILL.md front matter; empty when SKILL.md is invalid          |
| `modified`    | `Date`    | Last change of the skill (its `.index.json` entry)                                  |
| `problem`     | `String?` | Why SKILL.md is invalid ([claude/skills.md](../claude/skills.md)); `nil` when valid |

### SkillFile

A file of a skill folder. Identifiable by `path` (`var id: String { path }`).

| Field      | Type     | Meaning                                          |
|------------|----------|--------------------------------------------------|
| `path`     | `String` | Path relative to the skill folder, `/`-separated |
| `size`     | `Int`    | Size in bytes                                    |
| `modified` | `Date`   | Modification date                                |

### SkillManifest

One entry of a Main's skills index, for synchronization between Mains ([claude/skills.md](../claude/skills.md)).

| Field      | Type     | Meaning                                       |
|------------|----------|-----------------------------------------------|
| `name`     | `String` | Skill name                                    |
| `modified` | `Date`   | Last change, or deletion date for a tombstone |
| `deleted`  | `Bool`   | The skill was deleted (tombstone)             |

## Migration (MigrationTypes.swift)

### ManifestEntry

One item to transfer when a project moves to another Main ([devices/migration.md](../devices/migration.md)).
Identifiable by `path` (`var id: String { path }`).

| Field           | Type      | Meaning                                                                                                                                                                                              |
|-----------------|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `path`          | `String`  | Relative path, `/`-separated: project-relative for project files; for Claude CLI transcripts, relative to the source Main's `~/.claude/projects/`, its first component being the encoded folder name |
| `isDirectory`   | `Bool`    | The item is a folder                                                                                                                                                                                 |
| `size`          | `Int`     | Size in bytes; `0` for folders and symbolic links                                                                                                                                                    |
| `sha256`        | `String?` | Lowercase hex SHA-256 of the content; `nil` for folders and symbolic links                                                                                                                           |
| `mode`          | `Int`     | POSIX permission bits                                                                                                                                                                                |
| `modified`      | `Date`    | Modification date                                                                                                                                                                                    |
| `symlinkTarget` | `String?` | Target of a symbolic link (the link is transferred, not followed)                                                                                                                                    |

### MigrationState

| Raw value      | Meaning                                                    |
|----------------|------------------------------------------------------------|
| `preparing`    | The source builds the manifest                             |
| `transferring` | Files are being sent                                       |
| `committing`   | The destination verifies and installs the files            |
| `completed`    | The project is on the destination and gone from the source |
| `failed`       | The migration stopped; the project stays on the source     |

### MigrationOutcome

What the destination knows of a migration (`migration.status`, [methods.md](methods.md#migrationstatus)).

| Raw value   | Meaning                                                                                                                                                 |
|-------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| `committed` | The destination committed the move: its migration journal has a `received` entry with that id ([devices/migration.md](../devices/migration.md#journal)) |
| `unknown`   | The destination has no record of a committed move with that id                                                                                          |

## Forge (ForgeTypes.swift)

### FeedbackContext

Where a feedback was sent from ([forge/feedback.md](../forge/feedback.md)).

| Field        | Type                | Meaning                                  |
|--------------|---------------------|------------------------------------------|
| `deviceID`   | `UUID`              | Sending device                           |
| `deviceName` | `String`            | Its name                                 |
| `platform`   | `DevicePlatform`    | Its platform                             |
| `appVersion` | `String`            | Its marketing version                    |
| `build`      | `Int`               | Its build number                         |
| `docsHash`   | `String`            | Docs hash the running app was built from |
| `selection`  | `FeedbackSelection` | What the window showed                   |

### FeedbackSelection

| Field          | Type      | Meaning                                                                     |
|----------------|-----------|-----------------------------------------------------------------------------|
| `mainDeviceID` | `UUID?`   | Selected Main                                                               |
| `projectID`    | `String?` | Selected project or sub project                                             |
| `section`      | `String?` | Raw value of the selected sidebar section ([ui/shell.md](../ui/shell.md))   |
| `item`         | `String?` | Selected item of that section (ticket id, file path, tab id, session id, …) |

### ForgeConfig

The Forge settings of the Forge host, with the GitHub repository. This type and the next ones follow
[forge/pipeline.md](../forge/pipeline.md), which defines when each value changes.

| Field             | Type     | Meaning                                                                         |
|-------------------|----------|---------------------------------------------------------------------------------|
| `sourceProjectID` | `String` | The Hephaestus source project (default `HEPH`)                                  |
| `repository`      | `String` | GitHub repository, `owner/name`; the Forge host sets `publicRepository` (below) |
| `branch`          | `String` | Branch the Forge follows (`main`)                                               |
| `autoRegenerate`  | `Bool`   | "Regenerate automatically" (default on)                                         |

`ForgeConfig` also declares `public static let publicRepository = "Azavech/Hephaestus"`: the GitHub repository of
Hephaestus, `owner/name`, a constant of the code that no setting changes. Every `ForgeConfig` the Forge host builds
has it as `repository` ([forge/pipeline.md](../forge/pipeline.md#forge-host-configuration)); the Forge and the
self-update read the constant itself ([forge/update.md](../forge/update.md#check)).

### ForgeStage

The state of a feedback item or of a cycle, in pipeline order: `discussing`, `docsPushed`, `regenerating`,
`regenPushed`, `building`, `released`, `done`, `failed`. Items use every value; cycles use `regenerating` to `failed`.

### ForgeTrigger

What started a cycle: `tool` (`forge_push_docs` pushed the commits of a ticket or bundle session), `manual`
(`forge.regenerate`), `automatic` (a check found the docs ahead of the code).

### ForgeHead

The result of the Forge's last successful check of the repository.

| Field          | Type     | Meaning                                                                    |
|----------------|----------|----------------------------------------------------------------------------|
| `commit`       | `String` | Full SHA of `origin/<branch>` after the last fetch                         |
| `docsHash`     | `String` | Docs hash of `commit`                                                      |
| `codeDocsHash` | `String` | `App/DocsHash.txt` at `commit`, trimmed; `""` when the file does not exist |
| `checkedAt`    | `Date`   | End of the check                                                           |

### ForgeRun

A GitHub Actions run watched by the Forge. Identifiable.

| Field         | Type      | Meaning                                                               |
|---------------|-----------|-----------------------------------------------------------------------|
| `id`          | `Int`     | GitHub run id                                                         |
| `number`      | `Int`     | `run_number`, the build number of its release                         |
| `url`         | `String`  | `html_url`                                                            |
| `status`      | `String`  | GitHub `status` (`queued`, `in_progress`, `completed`, …)             |
| `conclusion`  | `String?` | GitHub `conclusion` once completed (`success`, `failure`, …)          |
| `headSHA`     | `String`  | `head_sha`                                                            |
| `foundAt`     | `Date`    | When the Forge found the run or restarted polling it                  |
| `completedAt` | `Date?`   | When the Forge first saw it `completed` with `success`; nil otherwise |

### ForgeRelease

| Field         | Type     | Meaning                  |
|---------------|----------|--------------------------|
| `tag`         | `String` | Release tag, `build-<N>` |
| `build`       | `Int`    | `N`                      |
| `url`         | `String` | The release's `html_url` |
| `publishedAt` | `Date`   | `published_at`           |

### ForgeCycle

One pass of regeneration, CI and release. Identifiable.

| Field           | Type            | Meaning                                                                                               |
|-----------------|-----------------|-------------------------------------------------------------------------------------------------------|
| `id`            | `UUID`          | Cycle id                                                                                              |
| `trigger`       | `ForgeTrigger`  | What started it                                                                                       |
| `state`         | `ForgeStage`    | `regenerating`, `regenPushed`, `building`, `released`, `done` or `failed`                             |
| `failedState`   | `ForgeStage?`   | The state it failed in; set with `failed`                                                             |
| `error`         | `String?`       | The failure message; set with `failed`                                                                |
| `started`       | `Date`          | Creation                                                                                              |
| `updated`       | `Date`          | Last change                                                                                           |
| `targetCommit`  | `String`        | `head.commit` when its last regeneration step ran                                                     |
| `sessionID`     | `UUID?`         | The last regeneration session; `nil` when no session was needed                                       |
| `attempts`      | `Int`           | Regeneration sessions started for this cycle                                                          |
| `regenCommit`   | `String?`       | Full SHA CI builds: the commit `forge_push_regen` pushed, or `head.commit` when no session was needed |
| `pushedAt`      | `Date?`         | When `regenCommit` was recorded or polling for it restarted                                           |
| `run`           | `ForgeRun?`     | The CI run of `regenCommit`                                                                           |
| `release`       | `ForgeRelease?` | The release of `run`                                                                                  |
| `itemTicketIDs` | `[String]`      | Ticket ids of the items in the cycle                                                                  |

### ForgeItem

The pipeline state of one feedback ticket. Identifiable by `ticketID` (`var id: String { ticketID }`).

| Field               | Type         | Meaning                                                            |
|---------------------|--------------|--------------------------------------------------------------------|
| `ticketID`          | `String`     | The feedback ticket                                                |
| `projectID`         | `String`     | The source project when the item was created                       |
| `title`             | `String`     | The ticket name, kept current                                      |
| `state`             | `ForgeStage` | State                                                              |
| `feedbackSessionID` | `UUID`       | The session that created the item: feedback, ticket or coordinator |
| `docsCommit`        | `String?`    | Full SHA of the last commit `forge_push_docs` pushed for the item  |
| `cycleID`           | `UUID?`      | The cycle the item is in                                           |
| `error`             | `String?`    | The cycle's error while the item is `failed`                       |
| `created`           | `Date`       | Creation                                                           |
| `updated`           | `Date`       | Last change                                                        |

### ForgeState

The result of `forge.status` and the payload of `forge.changed`; everything the Forge screen shows about the pipeline
([ui/forge.md](../ui/forge.md)).

| Field           | Type            | Meaning                                                              |
|-----------------|-----------------|----------------------------------------------------------------------|
| `enabled`       | `Bool`          | The Main that sends it is the Forge                                  |
| `hostDeviceID`  | `UUID`          | The Main that sends it                                               |
| `config`        | `ForgeConfig?`  | `nil` when not enabled                                               |
| `appDocsHash`   | `String`        | Docs hash of the running app of that Main                            |
| `head`          | `ForgeHead?`    | Result of the last successful check; `nil` before the first one      |
| `cycle`         | `ForgeCycle?`   | The current cycle, or the last one; `nil` when none was ever started |
| `items`         | `[ForgeItem]`   | Feedback items, newest `created` first                               |
| `latestRelease` | `ForgeRelease?` | The newest release known to the Forge                                |
| `lastError`     | `String?`       | Last error of a check, a poll or a background step                   |

When not enabled: `config`, `head`, `cycle`, `latestRelease` and `lastError` are `nil` and `items` is empty.

## Files on disk

The files on disk are read and written through their own file types, defined by the docs in the last column; they map
to these wire types. Files written before tasks were renamed tickets are migrated to the new names
([data/ticket-yml.md](../data/ticket-yml.md#data-from-before-tickets),
[forge/pipeline.md](../forge/pipeline.md#forgejson)).

| File                              | Wire type                                                           | Spec                                          |
|-----------------------------------|---------------------------------------------------------------------|-----------------------------------------------|
| `.hephaestus/project.yml`         | `Project` without `deviceID`, `rootPath`, `migrating`, `parseError` | [data/project-yml.md](../data/project-yml.md) |
| `.hephaestus/tickets/<id>.yml`    | `TicketItem` without `parseError`                                   | [data/ticket-yml.md](../data/ticket-yml.md)   |
| `.hephaestus/sessions/<id>.yml`   | `SessionInfo` without `statusLine`, `error`, `pendingPermissions`   | [data/sessions.md](../data/sessions.md)       |
| `.hephaestus/sessions/<id>.jsonl` | One `SessionEvent` per line                                         | [data/sessions.md](../data/sessions.md)       |
| `registry.json`                   | `MeshSnapshot`                                                      | [data/app-storage.md](../data/app-storage.md) |
| `Skills/.index.json`              | `SkillManifest` entries                                             | [claude/skills.md](../claude/skills.md)       |
| `forge.json`                      | `ForgeCycle`, `ForgeItem` and `ForgeRelease` values                 | [forge/pipeline.md](../forge/pipeline.md)     |
