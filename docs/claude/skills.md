# Skills

files:
- HephaestusKit/Sources/HephCore/Model/SkillName.swift
- HephaestusKit/Sources/HephCore/YAML/SkillFrontMatter.swift
- HephaestusKit/Sources/HephHost/Skills/SkillsService.swift
- HephaestusKit/Sources/HephHost/Skills/SkillsIndex.swift
- HephaestusKit/Sources/HephHost/Skills/SkillPluginFolder.swift
- HephaestusKit/Sources/HephHost/Skills/SkillsSync.swift

---

Each Main keeps a library of Claude skills, separate from `~/.claude`. The user creates, views and edits them from any
device ([../ui/skills.md](../ui/skills.md)), projects choose which ones their sessions get, and Mains keep their
libraries in sync. The files of `HephHost/Skills` are macOS only and wrapped in `#if os(macOS)`. `SkillName` and
`SkillFrontMatter` are in HephCore and compile on every platform, without `#if`, because the Skills screen uses them on
iOS and iPadOS; `SkillFrontMatter` uses Yams, a dependency of HephCore ([../architecture.md](../architecture.md)).
Logging uses `Log.host` ([../architecture.md](../architecture.md#logging)); file contents are never logged.

## 1. Library

- Folder: `AppSupport.skillsFolder` (`~/Library/Application Support/Hephaestus/Skills/`,
  [../data/app-storage.md](../data/app-storage.md)), created by `start()`. Nothing is read from or written to
  `~/.claude`.
- One folder per skill, `Skills/<name>/`, holding `SKILL.md` (the standard Claude skill format) and any other files and
  folders.
- `Skills/.index.json` is the sync index (section 7); `Skills/.incoming/` is a temporary folder of the sync. Entries of
  `Skills/` whose name is not a valid skill name are not skills.
- Settings → Skills shows the folder path, read-only ([../ui/settings.md](../ui/settings.md)).

## 2. Skill names

- A name matches `^[a-z0-9-]{1,64}$`: lowercase letters `a`–`z`, digits and hyphens, 1 to 64 characters. The folder
  name is the skill name.
- An invalid name in a request fails with `badRequest`, `Skill names use lowercase letters, digits and hyphens (1 to
  64 characters).`

## 3. Wire values

The types are declared in [../protocol/types.md](../protocol/types.md); this doc fills them:

| Type            | Fields as filled here                                                                                                                                                                 |
|-----------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `SkillSummary`  | `name`; `description` (from the front matter, `""` when SKILL.md is invalid); `modified` (the index entry's date); `problem` (the validation problem of section 4, absent when valid) |
| `SkillManifest` | `name`, `modified`, `deleted` (the index entry)                                                                                                                                       |
| `SkillFile`     | `path` (relative to the skill folder, `/`-separated), `size` (bytes), `modified` (the file's modification date)                                                                       |

## 4. SKILL.md

```markdown
---
name: release-notes
description: Write release notes for a Hephaestus project. Use when asked for release notes.
---

# release-notes

Instructions for Claude, in Markdown.
```

The front matter is the text between a first line that is exactly `---` (after an optional UTF-8 byte order mark) and
the next line that is exactly `---`. A line ends at a line feed, a carriage return before it not counted, so a `---`
line ending with CR LF is a fence too. It is parsed with Yams. Keys other than `name` and `description` are allowed
and kept.

Validation, in this order; the first failing check gives the skill's `problem`:

| Check                                                                   | `problem`                                                    |
|-------------------------------------------------------------------------|--------------------------------------------------------------|
| `SKILL.md` exists in the skill folder                                   | `SKILL.md is missing.`                                       |
| it is valid UTF-8                                                       | `SKILL.md is not UTF-8 text.`                                |
| it starts with a `---` line and has a closing `---` line                | `SKILL.md has no front matter between --- lines.`            |
| the front matter is a YAML mapping                                      | `The front matter is not a valid YAML mapping: <error>.`     |
| `name` is a string equal to the skill name                              | `name in the front matter must be "<skill name>".`           |
| `description` is a string, not empty after trimming                     | `description is missing in the front matter.`                |
| `description` has at most 1,024 characters                              | `description is longer than 1024 characters.`                |

- `<error>`: the Yams parser message, on one line ([../data/project-yml.md](../data/project-yml.md)), or `it is empty`,
  `it is a sequence` or `it is a scalar` when the front matter parses to something other than a mapping.
- A string is a scalar whose resolved YAML tag is `str`: `name: 123` is not a string, `name: "123"` is.
- Trimming removes white space and line breaks.

A skill with a `problem` is listed (so it can be fixed) but never linked into a session (section 6). Writes are not
validated: the editor saves partial content while the user types. `save_skill` validates before writing
([mcp.md](mcp.md#622-save_skill)).

Template written by `skills.create {name, description}`:

```markdown
---
name: <name>
description: <description>
---

# <name>

Write here the instructions Claude follows when it uses this skill.
```

- `description`: line breaks replaced by spaces, trimmed; it must then have 1 to 1,024 characters (`badRequest`,
  `The description must have 1 to 1024 characters.`).
- The front matter is emitted by Yams from an ordered mapping (`name`, then `description`), so the description is
  quoted when YAML needs it.

Rename rewrites `name`: the front matter is parsed as a Yams node, its `name` value replaced (added at the end of the
mapping when it has none), and the mapping emitted again with its other keys in their order; the body is unchanged. A
SKILL.md without a parseable front matter is left unchanged.

## 5. `skills.*` methods

Served by every Main from its own library: the host routes `skills.*` to `SkillsService`
([../services/host.md](../services/host.md)), which conforms to `HostMethodHandler`. Params and results are those of
[../protocol/methods.md](../protocol/methods.md).

- A `path` is relative and `/`-separated, with no empty, `.` or `..` component and no leading `/`, and must resolve
  inside the skill folder; otherwise `badRequest`. Both are compared in their realpath(3) form
  (`ClaudePathEncoding.canonicalPath`), a path that does not exist yet through its deepest existing folder, as
  `PathResolver.resolve` does for project paths ([../services/files.md](../services/files.md) §2).
- File contents are at most `maxFileSize` (`tooLarge`).
- After every change the index is updated (section 7) and `skills.changed {skills}` (the full list of `skills.list`)
  is broadcast through the host.

| Method                                | Behavior                                                                                                                                                    | Errors                                                                                             |
|---------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| `skills.list {}`                      | scans (7.2); returns `{skills}`: every skill not deleted, sorted by name                                                                                    | —                                                                                                  |
| `skills.create {name, description}`   | writes `Skills/<name>/SKILL.md` from the template; returns its `SkillSummary`                                                                               | `badRequest` (name, description), `conflict` (folder exists)                                       |
| `skills.files {name}`                 | `{files}`: every regular file under the skill folder, recursively, except `.DS_Store`, sorted by path                                                       | `notFound`                                                                                         |
| `skills.readFile {name, path}`        | `{data}`: the file's bytes                                                                                                                                  | `notFound` (skill or file), `badRequest`, `tooLarge`                                               |
| `skills.writeFile {name, path, data}` | writes the file atomically (temporary file, rename), creating missing folders; returns `{}`                                                                 | `notFound` (skill), `badRequest`, `tooLarge`                                                       |
| `skills.deleteFile {name, path}`      | moves the file to the Main's Trash (`appSupport.trashItem`); returns `{}`                                                                                   | `notFound` (skill or file), `badRequest` (`SKILL.md cannot be deleted. Delete the skill instead.`) |
| `skills.rename {name, newName}`       | moves `Skills/<name>` to `Skills/<newName>`, rewrites `name` in SKILL.md; `name` becomes a tombstone, `newName` a new entry; returns the new `SkillSummary` | `notFound`, `badRequest`, `conflict` (`newName` exists)                                            |
| `skills.delete {name}`                | moves `Skills/<name>` to the Main's Trash (`appSupport.trashItem`); `name` becomes a tombstone; returns `{}`                                                | `notFound`                                                                                         |
| `skills.manifest {}`                  | scans (7.2); returns `{skills}`: one `SkillManifest` per index entry, tombstones included, sorted by name (Main↔Main)                                       | —                                                                                                  |

`notFound` for a skill means no folder `Skills/<name>/` (a tombstoned name is not found).

Messages:

- Skills: `notFound` `Skill <name> does not exist.`; `conflict` `Skill <name> already exists.` when something is at
  `Skills/<name>` (a dangling symbolic link included) for `skills.create`, or at `Skills/<newName>` for `skills.rename`.
- Paths, worded as [../services/files.md](../services/files.md) words project paths: `badRequest` `Invalid path
  <path>.` (empty, holding a NUL character, starting with `/`, or with an empty, `.` or `..` component) and `<path> is
  outside the skill folder.`; `notFound` `No file at <path>.` when no regular file is there (`skills.readFile`), and
  when nothing or a folder is there (`skills.deleteFile`, which moves a symbolic link itself to the Trash);
  `badRequest` `<path> is a folder.` (`skills.writeFile`); `tooLarge` `<path> is larger than 10 MiB.`
  (`skills.readFile`) and `The content is larger than 10 MiB.` (`skills.writeFile`).
- `skills.deleteFile` keeps the skill's `SKILL.md`: `badRequest` `SKILL.md cannot be deleted. Delete the skill
  instead.` when `path` is `SKILL.md` (even when the file is missing), and when the file `path` names, its last
  component not followed, is `Skills/<name>/SKILL.md` itself: same device and inode (`lstat`). This refuses `skill.md`
  on a case-insensitive disk, a path through a folder link back to the skill folder and a hard link to `SKILL.md`; a
  symbolic link to `SKILL.md` and a `SKILL.md` in a subfolder are deleted as other files are.
- File system failures: `internal` `<path>: <the error's message>` when reading or trashing a file, `<name>: <the
  error's message>` when moving or trashing a skill folder; a failed write gives the error of `AtomicFile.write`.
- Before `start()`: `unavailable` `The skills library is not started.`.

## 6. Session plugin folder

Per-project enablement: `project.yml` `skills` lists the names of the library skills enabled for the project; absent or
empty means every skill ([../data/project-yml.md](../data/project-yml.md)). The skills of a session are the project's
enabled skills that exist in the library and have no `problem`.

Before each session process starts, `SessionService` calls `buildPluginFolder(sessionID:enabled:)`
([cli.md](cli.md#53-starting-the-process)), which builds, `<session id>` being the lowercase form
(`SessionFile.fileStem(_:)`, [../data/sessions.md](../data/sessions.md)):

```
<AppSupport.sessionPluginsFolder>/<session id>/
  hephaestus/
    .claude-plugin/plugin.json
    skills/<name>  →  <AppSupport.skillsFolder>/<name>
```

1. `SessionPlugins/<session id>/` is removed when it exists, then the folders are created.
2. `plugin.json` is written with exactly these bytes (no trailing newline):
   `{"name":"hephaestus","version":"1.0.0","description":"Skills managed by Hephaestus"}`
3. One symbolic link per session skill, named after the skill, whose absolute target is the skill's library folder.
   No skill: `skills/` is empty.
4. It returns the `hephaestus` folder, passed to the CLI with `--plugin-dir`.

Claude Code loads the folder as the plugin `hephaestus` and offers each skill as `hephaestus:<name>` (verified with CLI
2.1.309, symlinked skill folders included). Because the links point into the library, a session sees library edits
made while it runs. Changes to the enabled list apply at the next process start.

`SessionService` then writes the session's system prompt to `SessionPlugins/<session id>/system-prompt.md`, beside the
`hephaestus` folder ([cli.md](cli.md#53-starting-the-process)).

Cleanup: `sessions.delete` calls `removePluginFolder(sessionID:)`, which removes `SessionPlugins/<session id>/` with
everything in it; `start()` deletes everything inside `SessionPlugins/` (no session process exists yet).

## 7. Sync between Mains

### 7.1 Index

`Skills/.index.json` holds one entry per skill name known to this Main:

```json
{
  "old-skill": {"deleted": true, "modified": "2026-10-01T09:00:00.000Z"},
  "release-notes": {"deleted": false, "modified": "2026-10-29T21:04:00.123Z"}
}
```

- `modified`: when the skill last changed, on any Main (a deletion is a change); `deleted`: true for a tombstone.
  Dates are written as on the wire and compared at millisecond precision.
- The file is written atomically, pretty-printed with sorted keys. When it is missing or unreadable, the scan rebuilds
  it from the folders.
- After a change made through `skills.*` (create, writeFile, deleteFile, rename, delete), the entry's `modified` is
  the later of the current time and the skill's file date `L` (below), taken after the change.

### 7.2 Scan

Run by `start()`, `skills.list`, `skills.manifest` and `buildPluginFolder`, and at the start of a sync. `L` of a skill
= the latest modification date among the regular files of its folder (recursively), or the distant past when it has
none.

1. A skill folder without an entry: entry `{modified: L, deleted: false}`.
2. A skill folder whose entry is a tombstone (the folder came back from the Trash or was made by hand): entry
   `{modified: <now>, deleted: false}`.
3. A skill folder whose entry has `modified` earlier than `L` (edited outside Hephaestus): `modified = L`.
4. An entry not deleted whose folder is missing (deleted outside Hephaestus): `{modified: <now>, deleted: true}`.
5. Tombstones whose `modified` is more than 30 days old are removed.
6. When the index changed, it is written and `skills.changed` is broadcast.

### 7.3 When Mains sync

Each Main only pulls, over its own outgoing peer link ([../devices/mesh.md](../devices/mesh.md)). The host calls:

- `peerLinkOpened(_:)` when this Main's peer link to another Main becomes connected;
- `peerSkillsChanged(_:)` when a `skills.changed` event arrives from that Main over that link.

Both queue a pull from that Main (7.4) and return at once, so the host's peer link handling does not wait for it. The
other Main pulls from this one through its own link. Pulls of one library run one at a time, in the order requested; a
pull requested while another runs waits for it.

### 7.4 Pull

1. Scan (7.2). Request `skills.manifest {}` from the other Main.
2. For each of its items, by name, when there is no local entry or the item's `modified` is later than the local
   entry's (equal dates: nothing, the local copy stays):
   - Deleted item: when `Skills/<name>/` exists, it is moved to the Trash (`appSupport.trashItem`,
     [../data/app-storage.md](../data/app-storage.md#trash)). The local entry becomes `{modified: <item
     modified>, deleted: true}`.
   - Other item: `Skills/.incoming/<name>/` is emptied; `skills.files {name}` lists the files and each is downloaded
     with `skills.readFile {name, path}` into it; every downloaded file's modification date is set to the item's
     `modified`; the local `Skills/<name>/` is removed when it exists, and the incoming folder is moved to
     `Skills/<name>/`. The local entry becomes `{modified: <item modified>, deleted: false}`.
   - Right before a local `Skills/<name>/` is moved to the Trash or replaced, the pull scans again (7.2). When the local
     entry's `modified` is now later than the item's (a `skills.*` change or an edit made while the pull awaited the
     other Main), the incoming folder is removed and the local skill and entry stay.
   - A failure (request error, file error) is logged; the incoming folder is removed, the local skill and entry stay
     as they were, and the pull goes on with the next item.
3. Local entries the other Main does not list are left alone.
4. When anything changed, the index is written and `skills.changed` is broadcast; it makes the other Main pull from
   this one, which finds nothing newer and stops.

The file dates set in step 2 equal the entry's `modified`, so the next scan does not take the pulled skill for a local
edit.

## 8. Swift API

```swift
// HephCore/Model/SkillName.swift (every platform)
public enum SkillName {
    /// ^[a-z0-9-]{1,64}$
    public static func isValid(_ name: String) -> Bool
}

// HephCore/YAML/SkillFrontMatter.swift (every platform)
public enum SkillFrontMatter {
    /// The problem text of section 4 for a SKILL.md content, nil when valid.
    public static func problem(in content: Data, skillName: String) -> String?
    /// The description of a valid SKILL.md, nil otherwise.
    public static func description(in content: Data) -> String?
    /// The SKILL.md of skills.create; replaces the line breaks of `description` with spaces and trims it.
    public static func template(name: String, description: String) -> String
    /// The content with `name` set to `newName`; nil when the front matter cannot be parsed.
    public static func renamed(_ content: String, to newName: String) -> String?
}

// HephHost/Skills (macOS)
public struct SkillsIndexEntry: Sendable, Equatable, Codable {
    public var modified: Date
    public var deleted: Bool
    public init(modified: Date, deleted: Bool)
}

/// Implemented by HostService (services/host.md).
public protocol SkillsHost: Sendable {
    func appSupport() async -> AppSupport
    /// Sends skills.changed {skills} to every authenticated connection (EventHub.broadcast).
    func broadcastSkillsChanged(_ skills: [SkillSummary]) async
    /// A request over this Main's outgoing peer link to another Main (MeshService.requestPeer); JSON params and
    /// result. Failures throw ProtocolError.
    func requestPeer(_ deviceID: UUID, method: String, params: Data) async throws -> Data
}

public actor SkillsService {
    public init(host: any SkillsHost)

    // host lifecycle (services/host.md §3)
    /// Creates Skills/ when missing, empties SessionPlugins/, scans.
    public func start() async
    /// Cancels pulls in progress.
    public func stop() async

    // skills.* methods (also reached through HostMethodHandler.handle)
    public func list() throws -> [SkillSummary]
    public func create(name: String, description: String) throws -> SkillSummary
    public func files(name: String) throws -> [SkillFile]
    public func readFile(name: String, path: String) throws -> Data
    public func writeFile(name: String, path: String, data: Data) throws
    public func deleteFile(name: String, path: String) throws
    public func rename(name: String, newName: String) throws -> SkillSummary
    public func delete(name: String) throws
    public func manifest() throws -> [SkillManifest]

    // sessions (section 6)
    /// `enabled` = project.yml skills ([] = every skill). Returns the `hephaestus` folder.
    public func buildPluginFolder(sessionID: UUID, enabled: [String]) throws -> URL
    public func removePluginFolder(sessionID: UUID)

    // sync (section 7)
    public func peerLinkOpened(_ deviceID: UUID) async
    public func peerSkillsChanged(_ deviceID: UUID) async
}
```

Errors thrown by `SkillsService` are `ProtocolError` values with the codes of section 5. `SkillsIndex.swift` holds the
index load, save, scan and prune; `SkillsSync.swift` the pull; `SkillPluginFolder.swift` section 6.

## Depends on

| Name                                                                                  | Defined in                                                                                       |
|---------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `SkillSummary` (with `problem`), `SkillManifest`, `SkillFile`, `ProtocolError`        | [../protocol/types.md](../protocol/types.md)                                                     |
| `skills.*` methods, `maxFileSize`, `skills.changed`                                   | [../protocol/methods.md](../protocol/methods.md), [../protocol/events.md](../protocol/events.md) |
| `HostService` (conformance to `SkillsHost`), `HostMethodHandler`, sync triggers       | [../services/host.md](../services/host.md)                                                       |
| outgoing peer links, `MeshService.requestPeer`                                        | [../devices/mesh.md](../devices/mesh.md)                                                         |
| `project.yml` `skills`                                                                | [../data/project-yml.md](../data/project-yml.md)                                                 |
| `AppSupport` (`skillsFolder`, `sessionPluginsFolder`)                                 | [../data/app-storage.md](../data/app-storage.md)                                                 |
| `SessionFile.fileStem(_:)`                                                            | [../data/sessions.md](../data/sessions.md)                                                       |
| `Log.host`, logging rules, modules (HephCore with Yams, HephHost)                     | [../architecture.md](../architecture.md)                                                         |
| plugin folder use, `system-prompt.md` and `sessions.delete`                           | [cli.md](cli.md)                                                                                 |
