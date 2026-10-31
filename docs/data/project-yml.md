# project.yml

files:
- HephaestusKit/Sources/HephCore/YAML/YAMLCoding.swift
- HephaestusKit/Sources/HephCore/YAML/ProjectFile.swift
- HephaestusKit/Sources/HephCore/Model/ProjectIdentifier.swift

---

Every project, top-level or sub project, has the file `<project root>/.hephaestus/project.yml`. It holds the identity
of the project and the state every device shares: sub projects, web tabs, enabled skills and Claude
defaults.

The first section defines the YAML coding used by every YAML file of Hephaestus: this file, the task files
([task-yml.md](task-yml.md)) and the session metadata files ([sessions.md](sessions.md)).

## YAML coding (all YAML files)

`YAMLCoding` reads and writes every YAML file with Yams (`jpsim/Yams`). No other code parses or emits YAML, except
`SkillFrontMatter` for the front matter of SKILL.md ([claude/skills.md](../claude/skills.md)). The output described
here was verified with Yams 5.4.0.

### Encoder options

| Option               | Value      | Effect                                               |
|----------------------|------------|------------------------------------------------------|
| `indent`             | `2`        | Two spaces per nesting level.                        |
| `width`              | `-1`       | Long strings are never folded onto several lines.    |
| `allowUnicode`       | `true`     | Non-ASCII characters are written as they are.        |
| `newLineScalarStyle` | `.literal` | A string containing a line break is a literal block. |
| `sortKeys`           | `false`    | Keys keep the order of the schema.                   |

The other options keep their Yams defaults: no `---` document marker, LF line breaks. `YAMLCoding.makeEncoder()`
returns a `YAMLEncoder` set up this way; `Yams.serialize(node:)` is called with the same values.

### What is written

- Keys appear in the order of the file's schema table. Each Swift struct declares its stored properties in that order
  and keeps the synthesized `encode(to:)`, which encodes them in declaration order.
- An unset optional key is not written: its property is `nil`. The "Written" column of each schema says when a key is
  written; "always" keys are written even when their value is the default or an empty sequence.
- A string is a plain scalar when YAML reads it back as the same string. A string YAML would read as another type is
  single-quoted: `'NO'`, `'12'`, `'null'`, `'2026-10-29T21:00:00Z'`, `'a: b'`, `'#tag'`, `''`.
- A string containing a line break is a literal block: `|-` when it does not end with a line break, `|` when it does,
  with an indentation indicator (`|2-`) when its first line starts with spaces. A string that cannot be a literal block
  (a line ending with a space) is double-quoted with `\n` escapes.
- Sequences are in block style, their `- ` items at the indentation of their key. An empty sequence is `[]`.
- Dates are UTC with whole seconds: `2026-10-29T21:00:00Z`. Yams writes the fractional seconds of a date that has
  some (`2026-10-29T21:00:00.123000026Z`), so every date stored in a YAML file is made with `YAMLCoding.now()` or
  passed through `YAMLCoding.wholeSeconds(_:)` before it is stored.
- The text is UTF-8 with LF line breaks and ends with a line break. Files are written with `AtomicFile.write`
  ([app-storage.md](app-storage.md#atomic-writes)).

Strings as written:

```yaml
plain: Hephaestus Café
looksLikeBool: 'NO'
looksLikeNumber: '12'
multiLine: |-
  line1
  line2
endsWithLineBreak: |
  line1
  line2
startsWithSpaces: |2-
    indented
  x
lineEndsWithSpace: "a \nb"
empty: ''
```

### Reading

- `YAMLCoding.decode` decodes with Yams' `YAMLDecoder`. A `String` property receives the scalar's text whatever it
  looks like: `id: NO` gives `"NO"`, `name: 12` gives `"12"`.
- Accepted on read: every YAML timestamp form (`2026-10-29` is midnight UTC; offsets such as `+02:00`; fractional
  seconds; quoted or not), booleans `true` `false` `yes` `no` `on` `off`, decimal integers.
- A key absent from the file takes its default: each struct implements `init(from:)` with `decodeIfPresent` for every
  key that has a default. A required key that is absent, or a value that cannot be decoded, makes the file invalid.
- Keys that are not in the schema are ignored by decoding and kept when the file is rewritten (next section).
- After decoding, the struct is normalized and validated by the rules of its file.
- Errors are `DataError` values ([app-storage.md](app-storage.md#errors)) whose message is `<file name>: <problem>`:

| Problem                       | Error         | `<problem>`                                            |
|-------------------------------|---------------|--------------------------------------------------------|
| File not UTF-8 text           | `.unreadable` | `the file is not UTF-8 text`                           |
| Empty file (only whitespace)  | `.unreadable` | `the file is empty`                                    |
| YAML syntax error             | `.unreadable` | the Yams parser message, on one line (below)           |
| Root is not a mapping         | `.unreadable` | `the file is not a YAML mapping`                       |
| Required key absent           | `.invalid`    | `missing key <path>`                                   |
| Value that cannot be decoded  | `.invalid`    | `<path>: invalid value`                                |
| Validation rule broken        | `.invalid`    | the message of the rule in the file's validation table |

`<path>` names a key with its parents: `webTabs[1].url`, `comments[0].attachments[2].size` (sequence indexes from 0).

The Yams parser message is built from the parts of the Yams error, without the excerpt of the file that Yams appends to
its description, so that the message is one line and holds no line of the file:

| Yams error                      | Message                                                                                                                                                                     |
|---------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `scanner`, `parser`, `composer` | `<line>:<column>: error: <kind>: <problem>`, `<kind>` being the error's name; a context, when Yams gives one, adds `<context> in line <l>, column <c>; ` before `<problem>` |
| `reader`                        | `error: reader: <problem>`, then ` at offset <n>` when Yams gives the offset                                                                                                |
| `duplicatedKeysInMapping`       | `error: parser: duplicated keys: <key> (<line>:<column>, …), …`: each repeated key in sorted order, with the position of each of its occurrences                            |
| another error                   | the first line of Yams' description                                                                                                                                         |

### Keys that are not in the schema

Hand edits and other tools may add keys. The app keeps them when it rewrites a file:

1. The new value is encoded with the encoder of this section, and the text is composed into a Yams `Node`
   (`Yams.compose(yaml:)`).
2. The text the file had just before the write is composed into a `Node`; its retired top-level keys (below) are
   removed from it.
3. The two nodes are merged with the file's `YAMLShape`; the merged node is serialized.

`YAMLShape` lists the known keys of a file. `merge(new, old, shape)`:

- `.value`: the result is `new`.
- `.mapping(known)`: every key of `new` in `new`'s order, its value merged with `old`'s value for the same key when
  `old` has it (with `known[key]` as shape); then every key of `old` that is not in `known`, in `old`'s order, with its
  old value. A key of `known` that `new` does not have is not written: the app removed it.
- `.list(identity:item:)`: the items of `new` in `new`'s order. An item whose `identity` key has the same string value
  as the `identity` key of an item of `old` is merged with the first such `old` item (with `item` as shape). Items of
  `old` without a match are dropped.
- When `new` and `old` are not both of the kind the shape expects (both mappings, or both sequences), the result is
  `new`. Keys are compared by their string value.

Consequences:

- Unknown keys come after the known keys of their mapping.
- An unknown key inside a list item stays while the item keeps its identity value. An unknown key inside a known
  mapping stays while that mapping is still written.
- YAML comments (`# …`), flow style, anchors and aliases of the old text are not kept: the whole file is rewritten from
  the merged node.
- When the old text has no unknown key, the merged text is exactly the encoder's output.
- Unknown keys are never sent over the protocol and cannot be edited in the app.

A retired key is a key that earlier versions of the app wrote and this version no longer knows. Decoding ignores it,
whatever its value, like any unknown key; step 2 removes it, so the next write of the file drops it. project.yml has
one retired key, `runs` (the run configurations of earlier versions). The task and session files have none.

### Read-modify-write

The app never writes a YAML file from a copy held in memory. Every change made by the app:

1. reads the current text of the file (absent file: `.notFound` with the message of the file's doc,
   `project.yml: the file does not exist` for this file, except when the operation creates the file; another read
   failure: `.io("<file name>: <reason>")`);
2. decodes, normalizes and validates it; when that fails, nothing is written and the change fails with
   `.refused("The file is invalid: <message>")`, `<message>` being the error message of the Reading table
   (`<file name>: <problem>`);
3. applies the change to the decoded struct, then normalizes and validates the result; a broken rule fails the change
   with `.invalid(<message>)`, `<message>` being the rule's message of the file's validation table without the file
   name, and nothing is written;
4. encodes the result, merging it with the text read in step 1, and writes it with `AtomicFile.write`; a value that
   cannot be encoded fails the change with `.io("<file name>: cannot encode the file: <error>")`.

The functions of this doc do no locking. The host serializes the writes of one project
([services/host.md](../services/host.md)).

## Schema

Top level, in this order:

| Key               | YAML type            | Required | Default | Written             | Meaning                                                                    |
|-------------------|----------------------|----------|---------|---------------------|----------------------------------------------------------------------------|
| `id`              | string               | yes      |         | always              | Project identifier: the `projectID` of the protocol. Never changes.        |
| `name`            | string               | yes      |         | always              | Display name.                                                              |
| `description`     | string               | no       | empty   | when not empty      | Description; may span several lines.                                       |
| `created`         | timestamp            | yes      |         | always              | Creation time.                                                             |
| `code`            | string               | no       | `.`     | always              | Code folder, relative to the project root.                                 |
| `docs`            | string               | no       | `docs`  | always              | Docs folder, relative to the code folder.                                  |
| `taskCounter`     | integer              | no       | `0`     | always              | Last task number used ([task-yml.md](task-yml.md#id-allocation)).          |
| `feedbackCounter` | integer              | no       | `0`     | always              | Last feedback task number used ([task-yml.md](task-yml.md#id-allocation)). |
| `subprojects`     | sequence of strings  | no       | `[]`    | always              | Roots of the sub projects, relative to this project's root.                |
| `webTabs`         | sequence of web tabs | no       | `[]`    | always              | Web tabs, in tab strip order.                                              |
| `skills`          | sequence of strings  | no       | `[]`    | always              | Names of the enabled library skills. Empty: every skill of the library.    |
| `claude`          | mapping              | no       | absent  | when one key is set | Defaults of new Claude sessions.                                           |

Web tab (item of `webTabs`):

| Key      | YAML type | Required | Default | Written | Meaning                                                    |
|----------|-----------|----------|---------|---------|------------------------------------------------------------|
| `id`     | string    | yes      |         | always  | UUID of the tab.                                           |
| `title`  | string    | no       | empty   | always  | Title shown in the tab strip.                              |
| `url`    | string    | yes      |         | always  | URL of the tab ([ui/web.md](../ui/web.md) updates it).     |
| `locked` | boolean   | no       | `false` | always  | A locked tab cannot be closed.                             |

`claude`:

| Key              | YAML type | Required | Default | Written  | Meaning                                                                                  |
|------------------|-----------|----------|---------|----------|------------------------------------------------------------------------------------------|
| `model`          | string    | no       | absent  | when set | Model alias or id for new sessions, for example `opus`. Absent: the Main's default.      |
| `permissionMode` | string    | no       | absent  | when set | Permission mode for new sessions. Absent: the Main's default.                            |

`permissionMode` is one of `manual`, `acceptEdits`, `auto`, `plan`, `bypassPermissions` (`PermissionMode`,
[protocol/types.md](../protocol/types.md)). The Main's defaults are its settings `defaultModel` and
`defaultPermissionMode` ([app-storage.md](app-storage.md#settingsjson)); the full resolution order for a new session is
in [claude/cli.md](../claude/cli.md).

## Validation and normalization

`ProjectFile.decode` applies these rules to a file it reads; `ProjectFile.create` and `ProjectFile.update` apply them
to the struct they are about to write. Normalization runs first. A value that still breaks a rule makes the file
invalid (when reading) or fails the change with `.invalid` (when writing). The message is the one in the table, with
`<i>` the index of the item. The rules are checked in the order of the table, each over every item before the next,
so the message is that of the first broken rule.

| Key                     | Normalization                                                       | Rule                                           | Message                                                       |
|-------------------------|---------------------------------------------------------------------|------------------------------------------------|---------------------------------------------------------------|
| `id`                    | `ProjectIdentifier.normalize`                                       | `^[A-Z]{2,8}$`                                 | `the identifier must be 2 to 8 letters A to Z`                |
| `name`                  | leading and trailing whitespace and line breaks removed             | not empty, no line break                       | `the name must not be empty and must be on one line`          |
| `description`           | empty string becomes absent                                         | none                                           |                                                               |
| `code`                  | relative path normalization                                         | valid relative path                            | `code must be a relative path inside the project`             |
| `docs`                  | relative path normalization                                         | valid relative path                            | `docs must be a relative path inside the code folder`         |
| `taskCounter`           | none                                                                | 0 or more                                      | `taskCounter must not be negative`                            |
| `feedbackCounter`       | none                                                                | 0 or more                                      | `feedbackCounter must not be negative`                        |
| `subprojects[i]`        | relative path normalization; repeated paths removed, the first kept | valid relative path, not `.`                   | `subprojects[<i>] must be a relative path inside the project` |
| `webTabs[i].id`         | none                                                                | unique in the file                             | `webTabs[<i>].id must be unique`                              |
| `webTabs[i].url`        | leading and trailing whitespace removed                             | not empty                                      | `webTabs[<i>].url must not be empty`                          |
| `skills[i]`             | leading and trailing whitespace removed; repeated names removed     | `^[a-z0-9-]{1,64}$`                            | `skills[<i>] is not a valid skill name`                       |
| `claude.model`          | whitespace trimmed; empty becomes absent                            | no line break                                  | `claude.model must be on one line`                            |
| `claude.permissionMode` | none                                                                | a `PermissionMode` value (checked by decoding) | `claude.permissionMode: invalid value`                        |
| `claude`                | absent when both of its keys are absent                             | none                                           |                                                               |

Names have no maximum length. A line break is a `Character` whose `isNewline` is true (LF, CR, CR LF, vertical tab,
form feed, U+0085, U+2028, U+2029). Every trim of the data docs removes `.whitespacesAndNewlines`, line breaks
included, whether its rule says whitespace or white space and line breaks: the tables of this doc,
[task-yml.md](task-yml.md), [sessions.md](sessions.md) and [app-storage.md](app-storage.md#rules),
`ProjectIdentifier.normalize` and `TaskID(_:)`. The same name rule applies to task names ([task-yml.md](task-yml.md))
and session titles ([sessions.md](sessions.md)).

`webTabs[i].id` is decoded as a `UUID`, so a value that is not a UUID is `webTabs[<i>].id: invalid value`; Yams writes
it in canonical uppercase. The skill name rule is the one of [claude/skills.md](../claude/skills.md).
Names in `skills` that are not in the Main's library are kept and ignored when sessions start.

### Identifier

- `ProjectIdentifier.normalize` removes leading and trailing whitespace and maps the ASCII letters `a`–`z` to `A`–`Z`.
  No other character is mapped: `ß` stays `ß` and fails the rule.
- The identifier is set at creation and never changes. `ProjectFile.update` fails with
  `.invalid("the project identifier cannot change")` when a change alters `id`.
- Uniqueness across the mesh is checked by the host at creation and registration
  ([services/host.md](../services/host.md), [protocol/methods.md](../protocol/methods.md)).

### Relative paths

`code`, `docs` and `subprojects[i]` are relative paths with `/` separators. Normalization
(`ProjectFile.normalizedRelativePath`):

1. Remove leading and trailing whitespace.
2. A path starting with `/` or `~` is invalid.
3. Split on `/`; drop empty components and `.` components.
4. A `..` component makes the path invalid.
5. Join the components with `/`; no component left gives `.`.

Examples: `./services/api/` becomes `services/api`; an empty string becomes `.`; `a/../b` is invalid.

These rules are lexical. With symlinks resolved, the host also requires every sub project root to be strictly inside
this project's root, and serves files only inside the project root ([services/host.md](../services/host.md),
[services/files.md](../services/files.md)).

## Invalid file

A `project.yml` is invalid when it is unreadable or breaks a rule of this doc. The host applies:

- Startup or registration: a project whose `project.yml` is missing or invalid is not listed (a sub project is not
  listed under its parent). The error is logged. A top-level path stays in `projects.json`, and the file is loaded again
  when it changes.
- A loaded project whose file becomes invalid keeps its last valid state: reads go on serving it, `Project` and
  `ProjectSummary` carry the `DataError` message in `parseError`, every change that writes `project.yml` fails with
  `.refused`, and the file is not overwritten. When the file is valid again, it is reloaded with `parseError` cleared.
  Each of these changes sends `project.changed` and `projects.changed`.
- A reload whose `id` differs from the loaded project's `id` is invalid, with the parse error
  `project.yml: the project identifier cannot change`.
- `projects.import` of a folder whose `project.yml` is invalid fails with `badRequest` and the message.

`DataError` values map to protocol error codes as listed in [app-storage.md](app-storage.md#errors): `.refused` is
`conflict`, `.invalid` from a request is `badRequest`.

## New file

`ProjectFile.create` writes a new `project.yml` for `projects.create` and for `projects.import` of a folder without
one. The new file has:

| Key               | Value                                       |
|-------------------|---------------------------------------------|
| `id`              | the normalized identifier                   |
| `name`            | the normalized name                         |
| `description`     | the description when not empty, else absent |
| `created`         | `YAMLCoding.now()`                          |
| `code`            | `.`                                         |
| `docs`            | `docs`                                      |
| `taskCounter`     | `0`                                         |
| `feedbackCounter` | `0`                                         |
| `subprojects`     | `[]`                                        |
| `webTabs`         | `[]`                                        |
| `skills`          | `[]`                                        |
| `claude`          | absent                                      |

`create` also creates `.hephaestus/tasks/` and the docs folder `<code>/<docs>` when they are missing. It fails with
`.invalid("<project root> already has a .hephaestus/project.yml")` when the file exists. Adding a sub project to its
parent's `subprojects` is a separate `ProjectFile.update` of the parent made by the host.

## Mapping to the protocol

The host builds the types of [protocol/types.md](../protocol/types.md) from `ProjectFile`:

- `Project` carries every key of the schema under the same name and nesting: `webTabs` items become `WebTab` values
  (`id`, `title`, `url`, `locked`), and `claude` the
  `ClaudeDefaults` value (both fields `nil` when the file has no `claude`).
- `Project.taskCounter` is the number the host uses: the larger of the file's `taskCounter` and the highest task file
  number ([task-yml.md](task-yml.md#id-allocation)); `Project.feedbackCounter` the same for `feedbackCounter` and the
  highest feedback task file number.
- `ProjectSummary` takes `id`, `name` and `description` from the file; its `children` follow the order of
  `subprojects`.
- `deviceID`, `rootPath`, `migrating` and `parseError` of `Project` and `ProjectSummary`, and the `children` of
  `ProjectSummary`, do not come from this file: the host fills them ([services/host.md](../services/host.md)).
- Requests that change the project (`projects.update`, `tabs.open`, `tabs.update`, `tabs.close`, `tabs.move`, sub
  project creation, task id allocation) are each one `ProjectFile.update`.

## Logging

`YAMLCoding` and `ProjectFile` log with `Log.core` ([architecture.md](../architecture.md#logging)): `error` when a
`project.yml` is found invalid, with the project's root and the `DataError` message. File contents are never logged.

## Swift API

All functions are synchronous, do blocking file I/O and are not isolated to an actor. Host actors call them; the
MainActor never does.

```swift
import Yams

/// The known keys of a YAML file, used to keep unknown keys on rewrite.
public indirect enum YAMLShape: Sendable {
    case value
    case mapping([String: YAMLShape])
    case list(identity: String, item: YAMLShape)
}

public enum YAMLCoding {
    /// indent 2, width -1, allowUnicode true, newLineScalarStyle .literal.
    public static func makeEncoder() -> YAMLEncoder
    /// Encodes `value`; when `previousText` is a YAML mapping, removes its top-level `retiredKeys`, then merges its
    /// unknown keys with `shape`.
    public static func encode<T: Encodable>(_ value: T, shape: YAMLShape, preserving previousText: String?,
                                            retiredKeys: Set<String> = []) throws -> String
    /// Decodes `text`; errors are DataError with messages prefixed by `fileName`.
    public static func decode<T: Decodable>(_ type: T.Type, from text: String, fileName: String) throws -> T
    public static func merge(new: Node, old: Node, shape: YAMLShape) -> Node
    /// The date with its fractional seconds removed.
    public static func wholeSeconds(_ date: Date) -> Date
    /// wholeSeconds(Date()).
    public static func now() -> Date
}

public enum ProjectIdentifier {
    /// Trims whitespace, maps ASCII a–z to A–Z.
    public static func normalize(_ raw: String) -> String
    /// True when `value` matches ^[A-Z]{2,8}$.
    public static func isValid(_ value: String) -> Bool
    /// normalize, then check; throws DataError.invalid("the identifier must be 2 to 8 letters A to Z").
    public static func validated(_ raw: String) throws -> String
}

public struct ProjectFile: Codable, Sendable, Equatable {
    public struct WebTabEntry: Codable, Sendable, Equatable {
        public var id: UUID
        public var title: String
        public var url: String
        public var locked: Bool
        public init(id: UUID, title: String, url: String, locked: Bool)
    }

    public var id: String
    public var name: String
    public var description: String?
    public var created: Date
    public var code: String
    public var docs: String
    public var taskCounter: Int
    public var feedbackCounter: Int
    public var subprojects: [String]
    public var webTabs: [WebTabEntry]
    public var skills: [String]
    public var claude: ClaudeDefaults?

    /// ".hephaestus/project.yml"
    public static let relativePath: String
    public static let shape: YAMLShape
    /// ["runs"]: dropped by `encode(preserving:)`.
    public static let retiredKeys: Set<String>
    /// A new file with the values of "New file"; `created` = YAMLCoding.now().
    public init(id: String, name: String, description: String?)
    /// <projectRoot>/.hephaestus/project.yml
    public static func url(projectRoot: URL) -> URL
    /// Decodes, normalizes and validates.
    public static func decode(_ text: String) throws -> ProjectFile
    public func encode(preserving previousText: String?) throws -> String
    /// Normalizes in place.
    public mutating func normalize()
    public func validate() throws
    /// .notFound("project.yml: the file does not exist") when the file is missing.
    public static func load(projectRoot: URL) throws -> ProjectFile
    public static func create(_ file: ProjectFile, projectRoot: URL) throws
    /// Read-modify-write; returns the file as written.
    @discardableResult
    public static func update(projectRoot: URL, _ change: (inout ProjectFile) throws -> Void) throws -> ProjectFile
    /// WebTab and ClaudeDefaults values for Project.
    public var webTabValues: [WebTab] { get }
    public var claudeDefaults: ClaudeDefaults { get }
    /// The relative path normalization; nil when invalid.
    public static func normalizedRelativePath(_ raw: String) -> String?
    /// Trims white space and line breaks; throws DataError.invalid with the name rule's message when the result is
    /// empty or holds a line break. No maximum length.
    public static func validatedName(_ raw: String) throws -> String
}
```

`ProjectFile.shape`:

```swift
.mapping([
    "id": .value, "name": .value, "description": .value, "created": .value, "code": .value, "docs": .value,
    "taskCounter": .value, "feedbackCounter": .value, "subprojects": .value, "skills": .value,
    "webTabs": .list(identity: "id", item: .mapping(["id": .value, "title": .value, "url": .value, "locked": .value])),
    "claude": .mapping(["model": .value, "permissionMode": .value]),
])
```

`WebTabEntry` decodes `title` and `locked` with their defaults when absent; `ClaudeDefaults`
(the protocol type) has two optional fields. `DataError` and `AtomicFile` are defined in
[app-storage.md](app-storage.md). `PermissionMode`, `ClaudeDefaults`, `Project`, `ProjectSummary` and `WebTab` are
defined in [protocol/types.md](../protocol/types.md).

## Example

An example project file, exactly as the app writes it:

```yaml
id: HEPH
name: Hephaestus
description: Multi-device project workbench
created: 2026-10-29T21:00:00Z
code: .
docs: docs
taskCounter: 12
feedbackCounter: 3
subprojects:
- services/api
webTabs:
- id: 7C3A0E1B-5D2F-4C8A-9E61-0B4D2F7A9C13
  title: GitHub
  url: https://github.com/Azavech/Hephaestus
  locked: true
- id: E4F1A2B3-C4D5-4E6F-8A9B-0C1D2E3F4A5B
  title: Actions
  url: https://github.com/Azavech/Hephaestus/actions
  locked: false
skills: []
claude:
  model: opus
  permissionMode: acceptEdits
```

A new sub project created with identifier `API` and name `API`:

```yaml
id: API
name: API
created: 2026-10-30T09:12:45Z
code: .
docs: docs
taskCounter: 0
feedbackCounter: 0
subprojects: []
webTabs: []
skills: []
```
