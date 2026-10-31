# Task files

files:
- HephaestusKit/Sources/HephCore/YAML/TaskFile.swift
- HephaestusKit/Sources/HephCore/Model/TaskID.swift

---

Each task is one YAML file, `<project root>/.hephaestus/tasks/<TASK-ID>.yml`. The files attached to its comments are in
`<project root>/.hephaestus/attachments/<TASK-ID>/`. The YAML coding, unknown-key and read-modify-write rules of
[project-yml.md](project-yml.md#yaml-coding-all-yaml-files) apply.

## Task id

- A task id is `<projectID>-<n>`, or `<projectID>-F<n>` for a feedback task, which the Forge creates from feedback
  ([forge/pipeline.md](../forge/pipeline.md#feedback-intake)): the project identifier, `-`, `F` for a feedback task,
  and the task number `n` (1 to `Int.max`, 9,223,372,036,854,775,807; decimal, no leading zero). Pattern:
  `^[A-Z]{2,8}-F?[1-9][0-9]*$`. Examples: `HEPH-12`, `HEPH-F3`. A text that matches the pattern with a larger number is
  not a task id. A bundle id (`HEPH-B3`, [services/bundles.md](../services/bundles.md#bundle-id)) never matches it.
- Tasks and feedback tasks are two series, numbered separately (Id allocation): `HEPH-3` and `HEPH-F3` are two tasks.
  Both are ordinary task files with the same schema, requests and tools. Feedback tasks created before the feedback
  series existed keep their `<projectID>-<n>` id: nothing renames a task.
- The file of a task is named `<task id>.yml`: `HEPH-12.yml`, `HEPH-F3.yml`.
- `TaskID(_:)` parses an id received in a request or a tool call: it removes leading and trailing whitespace and maps
  ASCII `a`–`z` to `A`–`Z` before matching the pattern, so `heph-12` is `HEPH-12` and `heph-f3` is `HEPH-F3`.
  `TaskID(fileName:)` matches a file name exactly, without mapping.
- Ids are compared as `(projectID, feedback, number)`, tasks before feedback tasks: `HEPH-9` comes before `HEPH-10`,
  which comes before `HEPH-F1`. "By task number" in the other docs means this order.

## Schema

Top level, in this order:

| Key           | YAML type            | Required | Default | Written        | Meaning                                                   |
|---------------|----------------------|----------|---------|----------------|-----------------------------------------------------------|
| `id`          | string               | yes      |         | always         | Task id; equals the file name without `.yml`.             |
| `name`        | string               | yes      |         | always         | Name of the task.                                         |
| `description` | string               | no       | empty   | when not empty | Description, Markdown.                                    |
| `status`      | string               | no       | `todo`  | always         | `todo`, `in_progress`, `review` or `done`.                |
| `created`     | timestamp            | yes      |         | always         | Creation time.                                            |
| `updated`     | timestamp            | yes      |         | always         | Time of the last change made by the app.                  |
| `comments`    | sequence of comments | no       | `[]`    | always         | Comments, oldest first.                                   |

Comment (item of `comments`):

| Key           | YAML type               | Required | Default | Written        | Meaning                                                           |
|---------------|-------------------------|----------|---------|----------------|-------------------------------------------------------------------|
| `id`          | string                  | yes      |         | always         | UUID of the comment.                                              |
| `author`      | string                  | yes      |         | always         | Who wrote it (below).                                             |
| `created`     | timestamp               | yes      |         | always         | Creation time.                                                    |
| `edited`      | timestamp               | no       | absent  | when set       | Time of the last edit of the body.                                |
| `body`        | string                  | no       | empty   | always         | Text, Markdown.                                                   |
| `attachments` | sequence of attachments | no       | absent  | when not empty | Files attached to the comment, in the order they were added.      |

Attachment (item of `attachments`):

| Key    | YAML type | Required | Default | Written | Meaning                                                                  |
|--------|-----------|----------|---------|---------|--------------------------------------------------------------------------|
| `file` | string    | yes      |         | always  | File name in `.hephaestus/attachments/<task id>/`.                       |
| `type` | string    | yes      |         | always  | MIME type, for example `image/png`.                                      |
| `size` | integer   | yes      |         | always  | Size in bytes.                                                           |

`status` values are those of `TaskStatus` ([protocol/types.md](../protocol/types.md)). The UI shows them as To Do, In
Progress, Review, Done.

`author` is:

- for a request from a device (`tasks.addComment`): the name of that device in the mesh registry when the comment is
  made;
- for the MCP tools (`comment_task`, [claude/mcp.md](../claude/mcp.md)): `Claude`, a name no device can take
  ([../devices/roles.md](../devices/roles.md#names));
- for comments the Forge host writes: the author given in [forge/pipeline.md](../forge/pipeline.md).

## Validation and normalization

`TaskFile.decode` applies these rules to a file it reads; `TaskFile.create` and `TaskFile.update` apply them to the
struct they are about to write. Normalization runs first. A broken rule makes the file broken (when reading) or fails
the change with `.invalid` (when writing), with the message of the table (`<i>`, `<j>`: item indexes). The rules are
checked in the order of the table, each over every item before the next, so the message is that of the first broken
rule.

| Key                               | Normalization                                           | Rule                                                        | Message                                                        |
|-----------------------------------|---------------------------------------------------------|-------------------------------------------------------------|----------------------------------------------------------------|
| `id`                              | none                                                    | a task id equal to the file name without `.yml`             | `id <id> does not match the file name <file name>`             |
| `name`                            | leading and trailing whitespace and line breaks removed | not empty, no line break                                    | `the name must not be empty and must be on one line`           |
| `description`                     | empty string becomes absent                             | none                                                        |                                                                |
| `status`                          | none                                                    | a `TaskStatus` value (checked by decoding)                  | `status: invalid value`                                        |
| `comments[i].id`                  | none                                                    | unique in the file                                          | `comments[<i>].id must be unique`                              |
| `comments[i].author`              | leading and trailing whitespace removed                 | not empty, no line break                                    | `comments[<i>].author must not be empty`                       |
| `comments[i].body`                | none                                                    | not empty after trimming, or at least one attachment        | `comments[<i>] needs text or an attachment`                    |
| `comments[i].attachments`         | empty sequence becomes absent                           | none                                                        |                                                                |
| `comments[i].attachments[j].file` | none                                                    | a single path component: not empty, no `/`, not `.` or `..` | `comments[<i>].attachments[<j>].file is not a valid file name` |
| `comments[i].attachments[j].type` | none                                                    | not empty                                                   | `comments[<i>].attachments[<j>].type must not be empty`        |
| `comments[i].attachments[j].size` | none                                                    | 0 or more                                                   | `comments[<i>].attachments[<j>].size must not be negative`     |

A task name has no maximum length; line breaks are those of
[project-yml.md](project-yml.md#validation-and-normalization). `comments[i].id` is decoded as a `UUID`, so a value that
is not a UUID is `comments[<i>].id: invalid value`; Yams writes it in canonical uppercase. The rules do not require
`created` to be before `updated`, nor the attachment files to exist.

## Id allocation

`TaskFile.allocateID(projectRoot:feedback:)` reserves the number of a new task with one `ProjectFile.update` of the
project's `project.yml` ([project-yml.md](project-yml.md)). Each series has its counter: `taskCounter` for tasks
(`feedback` false), `feedbackCounter` for feedback tasks (`feedback` true). `<prefix>` below is `<projectID>-` for
tasks and `<projectID>-F` for feedback tasks.

1. `highest` = `TaskFile.highestNumber(projectRoot:projectID:feedback:)`: the largest `n` among the entries of
   `.hephaestus/tasks/` whose name is `<prefix><n>.yml` (valid and broken files alike); `0` when there is none.
2. `n` = `max(<counter>, highest) + 1`.
3. While `.hephaestus/tasks/<prefix><n>.yml` exists, `n` = `n + 1`.
4. `<counter>` = `n`; `project.yml` is written.
5. The function returns `TaskID(projectID:number: n, feedback:)`. The caller then writes the task file with
   `TaskFile.create`.

- When step 2 or 3 would give a number above `Int.max` (a counter or a task file name edited by hand), the allocation
  stops without writing `project.yml` and throws `.invalid("no task number is left in <projectID>")`, or
  `.invalid("no feedback number is left in <projectID>")` for a feedback task: both additions are checked for
  overflow.
- A number is never reused: deleting a task does not lower its counter, and a failure after step 4 leaves the number
  unused.
- When a project is loaded, the host takes `max(<counter>, highest)` of each series as the project's counters (they
  are what `Project` reports); `project.yml` is not rewritten for that.
- While `project.yml` is invalid, allocation fails with `.refused` and no task can be created.
- Every creation path allocates this way: `tasks.create` and the MCP tool `create_task` allocate a task id; the
  Forge's feedback intake allocates a feedback task id.

## Loading the tasks of a project

`TaskFile.loadAll(projectRoot:projectID:)` lists `.hephaestus/tasks/` (one level):

- An entry is a task file when it is a regular file and `TaskID(fileName:)` parses its name with the project's
  identifier. Every other entry is ignored: other names, ids of another project, temporary files of `AtomicFile`,
  folders.
- Each task file is read and decoded. Success gives `.valid(TaskFile)`; any failure gives `.broken(...)` (next
  section).
- Results are sorted by task number. A missing `tasks` folder gives no task.

The host reloads one task file when the file watcher reports it ([services/host.md](../services/host.md)) with
`TaskFile.loadOne(projectRoot:id:)`, which returns the same result for one file, or `nil` when the file no longer
exists.

## Broken files

A task file that cannot be read, is not valid YAML, or breaks a rule of this doc is a broken task:

- It is listed: the host reports it as a `TaskItem` with `id` from the file name, `name` and `description` empty,
  `status` `todo`, `created` and `updated` = the file's modification date, no comments, and `parseError` = the message
  of the `DataError` (for example `HEPH-12.yml: missing key name`).
- The app never writes it: `TaskFile.update` (task update, comment add, edit and delete) fails with
  `.refused("The file is invalid: HEPH-12.yml: <problem>")`, sent as `conflict`.
- It can be deleted (`tasks.delete`): its file and its attachments folder are removed.
- It is fixed by editing the file (code editor, any editor, Claude); the watcher reloads it and it becomes a normal
  task.
- Its number counts for id allocation.

## Changes made by the app

Each change is one read-modify-write of the task file ([project-yml.md](project-yml.md#read-modify-write)). "Now" is
`YAMLCoding.now()`.

| Change         | Requests                                          | Effect on the file                                                                                                          |
|----------------|---------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| Create         | `tasks.create`, MCP `create_task`, Forge feedback | id allocated; new file: `id`, `name`, `description`, `status` (default `todo`), `created` = `updated` = now, `comments: []` |
| Update         | `tasks.update`, MCP `update_task`                 | the given fields replaced; `updated` = now                                                                                  |
| Add comment    | `tasks.addComment`, MCP `comment_task`, Forge     | files stored first (Attachments); comment appended with a new UUID, `author`, `created` = now; `updated` = now              |
| Edit comment   | `tasks.updateComment` (not on Claude's comments)  | `body` replaced; `edited` = now; `updated` = now                                                                            |
| Delete comment | `tasks.deleteComment`                             | comment removed; its files deleted unless another comment of the task names the same file; `updated` = now                  |
| Delete task    | `tasks.delete`, MCP `delete_task`                 | task file deleted, then `.hephaestus/attachments/<task id>/` with its content                                               |

- An update whose fields equal the stored values writes nothing.
- A comment whose `author` is `Claude` is never edited by the app: the change that `tasks.updateComment` passes to
  `TaskFile.update` throws when it finds that author in the file it read, so nothing is written
  ([services/host.md](../services/host.md)). Every comment can be deleted.
- Unknown comment id: `.notFound("comment <id> not found")`. Unknown task id: `.notFound("task <id> not found")`.
- `TaskFile.create` fails with `.invalid("<id> is not a task id")` when the file's `id` is not a task id, and with
  `.invalid("<id>.yml already exists")` when the task file exists.
- Deleting a task does not delete its Claude sessions; they keep their `taskID` ([sessions.md](sessions.md)).
- A new comment's `id` is a new `UUID`.

## Attachments

Files attached to comments are stored in `.hephaestus/attachments/<task id>/`, created when the first file is stored.

### Storing a file

`TaskFile.storeAttachment(fileAt:originalName:projectRoot:id:)` stores a complete upload
([services/files.md](../services/files.md#7-uploads)):

1. `name` = `AttachmentNaming.sanitize(originalName)`.
2. `name` = `AttachmentNaming.unique(name, in: folder)`; the folder is created when missing.
3. The file at `fileAt` is moved to `<folder>/<name>` with `FileManager.moveItem(at:to:)`: a rename when the upload
   and the project are on the same volume, else a copy followed by the removal of the source.
4. It returns `TaskAttachment(file: name, type: AttachmentNaming.mimeType(forFileName: name), size: <size of the moved
   file>)`.

- The original name is `UploadRef.fileName` for `tasks.addComment` and MCP `comment_task` (the last path component of
  each absolute path), and `screenshot.png` for Forge feedback.
- Attachments have no size limit ([protocol/methods.md](../protocol/methods.md#limits)).
- The files of a comment are stored before the task file is written, one after the other. When a later file or the
  task file fails, `TaskService` moves the files stored for that comment back to their uploads, which stay usable
  ([services/host.md](../services/host.md)).

### Naming

`AttachmentNaming.sanitize(_:)`:

1. Keep the part after the last `/`.
2. Replace every control character (U+0000 to U+001F, U+007F), `\` and `:` with `-`.
3. Remove leading and trailing whitespace, then leading `.` characters.
4. Convert to Unicode NFC (`precomposedStringWithCanonicalMapping`).
5. An empty result becomes `file`.
6. When the name is longer than 200 UTF-8 bytes, remove whole characters from the end of its base name until it fits;
   the extension is kept. A name without extension, or whose base name would become empty, is shortened from its end.

The extension is the part after the last `.` when that `.` is not the first character; the base name is the part
before it. `archive.tar.gz` has the base name `archive.tar` and the extension `gz`; `README` has no extension.

`AttachmentNaming.unique(_:in:)`: when the folder has no entry with that name (`FileManager.fileExists`, so a
case-insensitive volume compares without case), the name is kept. Otherwise ` 2`, ` 3`, … is inserted before the
extension, and the first free name is used: `screenshot.png` → `screenshot 2.png`, `archive.tar.gz` →
`archive.tar 2.gz`, `README` → `README 2`.

`AttachmentNaming.mimeType(forFileName:)`: `UTType(filenameExtension: <lowercased extension>)?.preferredMIMEType`, else
`application/octet-stream`.

The same three functions name the files attached to session messages ([sessions.md](sessions.md#attachments)).

### Reading a file

`TaskFile.attachmentURL(projectRoot:id:file:)` returns `<folder>/<file>` for `attachments.read`:

- `file` must be a single path component (not empty, no `/`, not `.` or `..`): else
  `.invalid("invalid attachment name")`.
- The file must exist: else `.notFound("attachment <file> not found")`.

`attachments.read` reads a range of that file, at most 4 MiB from `offset`
([protocol/methods.md](../protocol/methods.md#attachmentsread)), and answers the file's `size` and `mimeType` = the
`type` of the attachment entry that names this file in the task, or `AttachmentNaming.mimeType(forFileName:)` when no
entry names it. Images are those whose type starts with `image/` ([ui/media.md](../ui/media.md)).

## Mapping to TaskItem

The host builds `TaskItem` ([protocol/types.md](../protocol/types.md)) from a valid file:

| File                                    | `TaskItem`                                                                                                     |
|-----------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `id`                                    | `id`                                                                                                           |
| `name`                                  | `name`                                                                                                         |
| `description` (absent: empty string)    | `description`                                                                                                  |
| `status`                                | `status`                                                                                                       |
| `created`, `updated`                    | `created`, `updated`                                                                                           |
| `comments[]`                            | `comments[]`, `TaskComment` values: `id`, `author`, `created`, `edited`, `body`, `attachments` (absent: empty) |
| `comments[].attachments[]`              | `TaskAttachment` values: `file`, `type`, `size`                                                                |
| (none)                                  | `parseError`: absent                                                                                           |

A broken file maps as described in Broken files.

## Logging

`TaskFile` logs with `Log.core` ([architecture.md](../architecture.md#logging)): `error` for each broken task file found
by `loadAll` or `loadOne` (its name and the `DataError` message). Task texts and comment bodies are never logged.

## Swift API

All functions are synchronous, do blocking file I/O and are not isolated to an actor. Host actors call them.

```swift
public struct TaskID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let projectID: String
    public let number: Int
    /// true for a feedback task id, <projectID>-F<n>.
    public let feedback: Bool
    /// projectID must be a valid identifier and number ≥ 1 (precondition).
    public init(projectID: String, number: Int, feedback: Bool = false)
    /// Trims, maps ASCII a–z to A–Z, then matches ^[A-Z]{2,8}-F?[1-9][0-9]*$.
    public init?(_ text: String)
    /// Matches "<id>.yml" exactly.
    public init?(fileName: String)
    /// "HEPH-12", "HEPH-F3"
    public var description: String
    /// "HEPH-12.yml", "HEPH-F3.yml"
    public var fileName: String
    /// Ordered as (projectID, feedback, number), false before true. Coded as one string, "HEPH-12".
}

public struct TaskFile: Codable, Sendable, Equatable {
    public struct Comment: Codable, Sendable, Equatable {
        public var id: UUID
        public var author: String
        public var created: Date
        public var edited: Date?
        public var body: String
        /// nil when the comment has no attachment.
        public var attachments: [TaskAttachment]?
        public init(id: UUID, author: String, created: Date, edited: Date?, body: String,
                    attachments: [TaskAttachment]?)
    }

    public var id: String
    public var name: String
    public var description: String?
    public var status: TaskStatus
    public var created: Date
    public var updated: Date
    public var comments: [Comment]

    public static let shape: YAMLShape
    /// A new task: created = updated = YAMLCoding.now(), no comments.
    public init(id: TaskID, name: String, description: String?, status: TaskStatus)

    /// <projectRoot>/.hephaestus/tasks
    public static func folder(projectRoot: URL) -> URL
    /// <projectRoot>/.hephaestus/tasks/<id>.yml
    public static func url(projectRoot: URL, id: TaskID) -> URL
    /// <projectRoot>/.hephaestus/attachments/<id>
    public static func attachmentsFolder(projectRoot: URL, id: TaskID) -> URL

    /// Decodes, normalizes and validates; `fileID` is the id given by the file name.
    public static func decode(_ text: String, fileID: TaskID) throws -> TaskFile
    public func encode(preserving previousText: String?) throws -> String
    public mutating func normalize()
    public func validate(fileID: TaskID) throws

    public static func loadAll(projectRoot: URL, projectID: String) -> [TaskLoadResult]
    /// nil when the file does not exist.
    public static func loadOne(projectRoot: URL, id: TaskID) -> TaskLoadResult?
    /// The largest number of the series among the task file names (Id allocation step 1).
    public static func highestNumber(projectRoot: URL, projectID: String, feedback: Bool) -> Int
    public static func allocateID(projectRoot: URL, feedback: Bool = false) throws -> TaskID
    /// Fails with .invalid("<id> is not a task id") when `file.id` is not a task id, and with
    /// .invalid("<id>.yml already exists") when the file exists.
    public static func create(_ file: TaskFile, projectRoot: URL) throws
    /// Read-modify-write; returns the file as written. Writes nothing when `change` leaves the file equal.
    @discardableResult
    public static func update(projectRoot: URL, id: TaskID, _ change: (inout TaskFile) throws -> Void) throws -> TaskFile
    /// Deletes the task file, then the attachments folder; works on broken files.
    public static func delete(projectRoot: URL, id: TaskID) throws

    /// Moves the file at `fileAt` (a complete upload) into the task's attachments folder (Storing a file).
    public static func storeAttachment(fileAt: URL, originalName: String, projectRoot: URL, id: TaskID) throws
        -> TaskAttachment
    /// Deletes one stored file; a missing file is ignored.
    public static func deleteAttachment(file: String, projectRoot: URL, id: TaskID) throws
    public static func attachmentURL(projectRoot: URL, id: TaskID, file: String) throws -> URL
}

public enum TaskLoadResult: Sendable {
    case valid(TaskFile)
    /// `message` is the DataError message; `modified` the file's modification date.
    case broken(id: TaskID, message: String, modified: Date)
}

public enum AttachmentNaming {
    public static func sanitize(_ originalName: String) -> String
    public static func unique(_ name: String, in folder: URL) -> String
    public static func mimeType(forFileName name: String) -> String
}
```

`TaskFile.update` sets `updated`; the `change` closure only edits the other fields. The file stores attachments as the
protocol's `TaskAttachment` values; `TaskFile.Comment` maps to `TaskComment` field by field.

`TaskFile.shape`:

```swift
.mapping([
    "id": .value, "name": .value, "description": .value, "status": .value, "created": .value, "updated": .value,
    "comments": .list(identity: "id", item: .mapping([
        "id": .value, "author": .value, "created": .value, "edited": .value, "body": .value,
        "attachments": .list(identity: "file", item: .mapping(["file": .value, "type": .value, "size": .value])),
    ])),
])
```

`TaskStatus`, `TaskItem`, `TaskComment`, `TaskAttachment` and `UploadRef` are defined in
[protocol/types.md](../protocol/types.md); `DataError` and `AtomicFile` in [app-storage.md](app-storage.md);
`YAMLShape`, `YAMLCoding` and `ProjectFile` in [project-yml.md](project-yml.md).

## Example

`.hephaestus/tasks/HEPH-12.yml`, exactly as the app writes it:

```yaml
id: HEPH-12
name: Sidebar breaks on iPad
description: |-
  When the iPad rotates to portrait, the sidebar covers the task list.

  Steps:
  1. Open a project.
  2. Rotate the iPad.
status: in_progress
created: 2026-10-29T21:04:00Z
updated: 2026-10-29T22:10:00Z
comments:
- id: 0B1E5C2A-7F3D-4E9B-8A61-2C4D6E8F0A1B
  author: Sam's iPad
  created: 2026-10-29T21:05:00Z
  edited: 2026-10-29T21:06:00Z
  body: Screenshot of the overlap.
  attachments:
  - file: screenshot.png
    type: image/png
    size: 123456
- id: 5D9A3C7E-1B2F-4A6D-9C8E-7F0A1B2C3D4E
  author: Claude
  created: 2026-10-29T22:10:00Z
  body: |-
    Fixed in `SidebarView.swift`: the split view collapses below 700 pt.
    Status set to review.
```

The screenshot is `.hephaestus/attachments/HEPH-12/screenshot.png`.

A new task:

```yaml
id: HEPH-13
name: Add a Skills shortcut
status: todo
created: 2026-10-30T08:00:00Z
updated: 2026-10-30T08:00:00Z
comments: []
```
