# Forge pipeline

files:
- HephaestusKit/Sources/HephHost/Forge/ForgeService.swift
- HephaestusKit/Sources/HephHost/Forge/ForgeFeedback.swift
- HephaestusKit/Sources/HephHost/Forge/ForgeCycles.swift
- HephaestusKit/Sources/HephHost/Forge/ForgePolling.swift
- HephaestusKit/Sources/HephHost/Forge/ForgeStore.swift
- HephaestusKit/Sources/HephHost/Forge/ForgeGit.swift
- HephaestusKit/Sources/HephHost/Forge/ForgeChecks.swift
- HephaestusKit/Sources/HephHost/Forge/ForgePushGate.swift
- HephaestusKit/Sources/HephHost/Forge/PrivateTerms.swift
- HephaestusKit/Sources/HephHost/Forge/GitHubClient.swift

---

The Forge turns feedback into a new build of Hephaestus. A feedback session first rewrites its feedback as a task,
then, when the user asks it to implement the task, updates `docs/` and commits; a regeneration session brings the code
in line with the docs and commits; the Forge checks their commits for personal data and pushes them; GitHub Actions
builds and publishes the release `build-<N>`; every Mac updates itself. One Main runs the pipeline: the **Forge
host**, the Main that hosts the Hephaestus source project. Capture and sheet: [feedback.md](feedback.md). Regeneration
procedure and docs hash: [generation.md](generation.md). Workflow: [ci.md](ci.md). Self-update:
[update.md](update.md). Screen: [../ui/forge.md](../ui/forge.md).

The repository is public and holds no personal data ([../public-repository.md](../public-repository.md)). Claude never
pushes: the two Forge push tools ([MCP tools](#mcp-tools)) are the only way the commits of a Forge session are meant to
reach GitHub. They push only commits that pass the personal data check of the published `scripts/check-public.sh` of
the last head of the branch the Forge trusts, with the user's private terms ([Private terms](#private-terms)). Commits
that reach the branch another way are checked the same way at the next check, and stop the automatic regenerations
while they fail ([Checks and triggers](#checks-and-triggers)).

Every file of this doc is macOS only and wrapped in `#if os(macOS)`. Logging uses `Log.host`
([../architecture.md](../architecture.md#logging)).

## Forge host configuration

The `forge` settings of the Mac (`DeviceSettings.forge` in `settings.json`,
[../data/app-storage.md](../data/app-storage.md)), edited in Settings ▸ Forge & Updates
([../ui/settings.md](../ui/settings.md)):

| Key                     | Default | Meaning                                                               |
|-------------------------|---------|-----------------------------------------------------------------------|
| `forge.enabled`         | `false` | "Set as Forge"                                                        |
| `forge.sourceProjectID` | `HEPH`  | identifier of the source project, whose code folder is the repository |
| `forge.branch`          | `main`  | branch the Forge follows                                              |
| `forge.autoRegenerate`  | `true`  | "Regenerate automatically"                                            |

- The GitHub repository is not a setting: it is `ForgeConfig.publicRepository`, `Azavech/Hephaestus`, a constant of
  the code that the user cannot change ([../protocol/types.md](../protocol/types.md#forgeconfig)). In this doc
  `<repository>` is that constant, the repository's owner its part before the `/` (`Azavech`) and the repository's
  name its part after the `/` (`Hephaestus`).
- `forge.enabled` keeps its default, `false`, until the user turns it on, with one exception: the Mac that creates the
  mesh is its Forge. Onboarding's "Use this Mac as a Main" turns `forge.enabled` on before the Mac becomes a Main
  ([../ui/onboarding.md](../ui/onboarding.md#use-this-mac-as-a-main)). A Mac that joins a mesh, or turns Main on later
  in Settings ▸ General, is not made the Forge, and the host never changes the setting, not even when its
  `ensureMesh()` creates a mesh ([../devices/mesh.md](../devices/mesh.md#credentials)).
- The host calls `configure(_:)` with the `ForgeConfig` built from these settings, its `repository` being
  `ForgeConfig.publicRepository`, while `forge.enabled` is true, and with nil otherwise: at its start and after every
  change of a `forge` setting ([../services/host.md](../services/host.md)); the Settings pane only writes the settings
  ([../ui/settings.md](../ui/settings.md)). The Forge is **enabled** from a `configure` with a configuration until
  `configure(nil)` or `shutdown()`. A new configuration applies at once; an active cycle continues with it.
- `host.info` returns `forge` = `config()`: the `ForgeConfig` while enabled, absent otherwise. Clients find the Forge
  host with it ([../ui/forge.md](../ui/forge.md#forge-host)).
- The **repository root** is the source project's code folder (`<root>/<code>`,
  [../data/project-yml.md](../data/project-yml.md)). Every git command runs with it as working directory; `docs/` and
  `App/DocsHash.txt` are relative to it.
- The source project is the clone of the repository registered as a project on the Forge host (identifier `HEPH` by
  default): by the user, with Add Existing Folder… ([../ui/overview.md](../ui/overview.md#add-existing-folder)), or
  by the Forge itself ([Registering the source project](#registering-the-source-project)). Its `.hephaestus/` folder,
  where the app keeps the project's data, is ignored by git and never committed
  ([../architecture.md](../architecture.md)).

### Configuration checks

Run, in this order, when the Forge is enabled, at the start of every check, at the start of a regeneration step,
before handling `forge.feedback` and at the start of the push tools. Before the first one, when this Main does not host
the source project, the Forge registers it when it can
([Registering the source project](#registering-the-source-project)). The first failure stops the list:

| Check                                                                                                                                                                                              | Message                                                                                                                                                                   |
|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| the source project is hosted on this Main (`registry.hosted(_:)`)                                                                                                                                  | `The Forge source project <ID> is not on this Main.`, a space, then the text of the step of [Registering the source project](#registering-the-source-project) that failed |
| neither it nor one of its ancestors is migrating (`registry.checkWritable(_:)` throws no `locked`)                                                                                                 | `The Forge source project <ID> is being moved.`                                                                                                                           |
| `host.info` reports `gitAvailable`                                                                                                                                                                 | `git is not available on this Main.`                                                                                                                                      |
| `git rev-parse --show-toplevel` prints the repository root (symlinks resolved on both sides)                                                                                                       | `<path> is not the top folder of a git repository.`                                                                                                                       |
| `git remote get-url origin`, without a trailing `.git` and compared case-insensitively, is `https://github.com/<repository>`, `ssh://git@github.com/<repository>` or `git@github.com:<repository>` | `The origin remote of <ID> is <url>, not github.com/<repository>.`                                                                                                        |
| `git remote get-url --push --all origin` prints one URL, which passes the test of the previous row                                                                                                 | `The push URL of origin is <urls>, not github.com/<repository>.` (`<urls>` joined with `, `)                                                                              |
| `git config --get-all remote.origin.pushurl` prints nothing                                                                                                                                        | `origin has a push URL; remove it with git config --unset-all remote.origin.pushurl.`                                                                                     |
| the hooks path is `.githooks` (below)                                                                                                                                                              | the error of `git config`                                                                                                                                                 |
| commits are not signed (below)                                                                                                                                                                     | the error of `git config`                                                                                                                                                 |
| no Claude Code settings in the repository (below)                                                                                                                                                  | `Claude Code settings in <path> would apply to the Forge's sessions: move <files> out of the repository, then retry.` (`<files>` joined with `, `)                        |
| `host.info` reports `claudeAvailable`                                                                                                                                                              | `The Claude CLI is not available on this Main.`                                                                                                                           |

A failure sets `lastError` to the message; `forge.feedback`, `forge.regenerate`, `forge.retry` and the push tools
fail with `unavailable` and the message (`locked` for the migrating case). Checks and polling keep running, so the
error clears once fixed. `<path>` is the repository root. When `git remote get-url origin` or
`git remote get-url --push --all origin` fails (no `origin` remote), the message is the git error
([Git operations](#git-operations)), since the row's message would have no URL.

- Push URL: the Forge pushes only to `origin` on GitHub. A `remote.origin.pushurl` is refused even when it names
  GitHub, because it escapes the push block of the sessions of
  [../claude/cli.md](../claude/cli.md#35-sessions-in-the-public-repository).
- Hooks path: when `git config --local --get core.hooksPath` does not print `.githooks`, the Forge runs
  `git config --local core.hooksPath .githooks`, which activates the hooks of
  [../public-repository.md](../public-repository.md) for the user's own git commands in the source project. No hook
  runs in the Forge's git commands or in its sessions ([Git operations](#git-operations)).
- Signing: when `git config --local --get commit.gpgsign` does not print `false`, the Forge runs
  `git config --local commit.gpgsign false`: a signature names its key, which keyservers resolve to the key's names and
  e-mail addresses, and `commit signature` refuses signed commits ([../public-repository.md](../public-repository.md)).
- Claude Code settings: none of `.claude/settings.json`, `.claude/settings.local.json` and `.mcp.json` exists in the
  repository root. Their rules, hooks, environment and servers would apply to every session started there, the
  Forge's included; git ignores them, and the sessions of 3.5 can neither create nor edit them.

### Registering the source project

The Forge registers its source project itself when it can. Before the first configuration check, when this Main hosts
no project `<ID>` (`registry.hosted(_:)` throws), it looks at `<folder>`, the folder the clone would have in the
projects folder: `DeviceSettings.projectsFolderURL.appendingPathComponent(<name>).path`, that is the `projectsFolder`
setting with a leading `~` expanded to the home folder ([../data/app-storage.md](../data/app-storage.md#settingsjson)),
`/`, and `<name>`, the repository's name: the part of `ForgeConfig.publicRepository` after its `/`, `Hephaestus`
(`~/Developer/Hephaestus` with the default settings).

The steps run in this order. The first that fails ends the registration with nothing imported, and the first
configuration check fails with `The Forge source project <ID> is not on this Main.`, a space, then the step's text:

| Step | Passes when                                                                                                                                         | Text                                                                                                                                                                                                                               |
|------|-----------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1    | `<folder>` is an existing folder                                                                                                                    | `There is no folder <folder>: clone github.com/<repository> there, or add your clone with Add Existing Folder… and choose it as the Source project in Settings ▸ Forge & Updates.`                                                 |
| 2    | `host.info` reports `gitAvailable` and the `PATH` of the environment holds git ([Git operations](#git-operations))                                  | `git is not available on this Main.`                                                                                                                                                                                               |
| 3    | `git rev-parse --show-toplevel`, run in `<folder>`, succeeds and prints `<folder>` (symlinks resolved on both sides)                                | `<folder> is not the top folder of a git repository: clone github.com/<repository> there, or add your clone with Add Existing Folder… and choose it as the Source project in Settings ▸ Forge & Updates.`                          |
| 4    | `git remote get-url origin`, run in `<folder>`, succeeds and passes the test of the origin row of the [configuration checks](#configuration-checks) | `<folder> is not a clone of github.com/<repository>: set its origin remote to https://github.com/<repository>.git, or add your clone with Add Existing Folder… and choose it as the Source project in Settings ▸ Forge & Updates.` |
| 5    | `<folder>/.hephaestus/project.yml` does not exist, or its `id` (`ProjectFile.load(projectRoot:)`) is `<ID>`                                         | `<folder> holds the project <other ID>: choose it as the Source project in Settings ▸ Forge & Updates, after adding it with Add Existing Folder… when it is not on this Mac.` (`<other ID>`: the file's `id`)                      |
| 6    | the import succeeds                                                                                                                                 | `Adding <folder> failed: <message>` (`<message>`: the message of the import's error)                                                                                                                                               |

- Step 4 fails when `origin` is missing (`git remote get-url origin` fails) as when it names another repository. A
  `ProjectFile.load(projectRoot:)` that throws in step 5 fails the registration with the text of step 6, `<message>`
  being its `DataError` message ([../data/project-yml.md](../data/project-yml.md)).
- The import (step 6) is the logic of `projects.import`
  ([../services/host.md](../services/host.md#74-projectsimport)):
  `host.projects.importFolder(ProjectsImportParams(path: <folder>, name: <name>, identifier: <ID>))`. A project.yml
  that exists, which step 5 checked, is used as it is, with the sub projects it lists; without one, a project.yml is
  written with that name and identifier, then `.hephaestus/tasks/` and the docs folder when they are missing. The
  project is registered and added to `projects.json`, and `projects.changed` is sent, as for any import. A successful
  import is logged with `Log.host` at `notice` level, with the identifier; then the configuration checks go on.
- The Forge never clones: it runs no `git clone` and registers only a folder that is already there.
- The registration runs wherever the configuration checks run: when the Forge is enabled, at every check, in a
  regeneration step, before `forge.feedback` and in the push tools. A clone that gets its `origin` later is registered
  at the next check ([Checks and triggers](#checks-and-triggers)).
- Its two git commands are the `top folder` and `origin URL` commands of [Git operations](#git-operations), run as
  that section says, with `<folder>` as working directory and the environment that
  `registerSourceProject(_:environment:)` gets ([Swift API](#swift-api)): the login environment in the configuration
  checks. A command cancelled because the Forge is disabled ([Startup and shutdown](#startup-and-shutdown)) fails no
  step: its `CancellationError` is rethrown, and nothing is imported.

## Private terms

The Forge host keeps `private-terms.txt` in its Application Support folder (`privateTermsURL` = `appSupport.root` +
`private-terms.txt`, `~/Library/Application Support/Hephaestus/private-terms.txt`): the user's own words that the
personal data check refuses in the public repository, in the format of
[../public-repository.md](../public-repository.md#private-terms). It is the check script's default terms file, and the
Forge passes it as `HEPHAESTUS_PRIVATE_TERMS` to every check it runs ([MCP tools](#mcp-tools),
[Checks and triggers](#checks-and-triggers)). It is never inside a repository, and the app never sends it anywhere.

- The Forge writes the file when it is missing: when the Forge is enabled
  ([Startup and shutdown](#startup-and-shutdown)), at the start of a push tool, and for "Edit…" in Settings ▸ Forge &
  Updates (`preparePrivateTerms()`, [../ui/settings.md](../ui/settings.md)). Apart from creating it, the app changes the
  file only when the user adds or dismisses a suggestion (below); it never rewrites it otherwise, even when it holds no
  term.
- Content: the header below, then the suggested terms, one per line, in the order of the sources, each term once
  (compared by their UTF-8 bytes with ASCII letters lowercased, as the check matches terms, so the case forms of a
  letter outside ASCII, and the precomposed and decomposed forms of a term, stay different terms; the first spelling
  is kept). Swift's `==` and `Hashable` of `String` treat canonically equivalent strings as equal, so these
  comparisons use the bytes. UTF-8, written with `AtomicFile.write`.

  ```text
  # Private terms of the Hephaestus personal-data check (docs/public-repository.md).
  # The check refuses every file, file name, commit message, commit author and branch name of the public repository
  # that holds one of these terms as a whole word, ignoring case. One term per line; lines starting with # are
  # comments; terms shorter than 3 characters are ignored; a line "# not private: <term>" dismisses a suggestion.
  # Hephaestus never sends this file anywhere; you copy it to the PRIVATE_TERMS secret and to your other Macs yourself.
  # Hephaestus suggested the terms below from this Mac's account, names and serial number, the mesh's devices, the
  # other projects of this Mac, git, the signing identities and their teams, and the GitHub logins. Remove a term that
  # is not private; add the names of your people and places, and of your other projects.
  ```

- Sources, in this order. Values are trimmed; a source that fails or gives nothing adds no term. The commands run with
  `ChildProcess.capture`, the login environment and the home folder as working directory; `git` and `gh` are those of
  [Git operations](#git-operations).

  | Source                                                                                                    | Terms                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
  |-----------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
  | `NSFullUserName()`                                                                                        | the full name, then each of its words (separated by white space, `-` or `'`) of 3 letters or more                                                                                                                                                                                                                                                                                                                                                                                     |
  | `NSUserName()`                                                                                            | the account name                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
  | `NSHomeDirectory()`                                                                                       | the home folder path                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
  | `SCDynamicStoreCopyComputerName(nil, nil)`                                                                | the computer name                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
  | `SCDynamicStoreCopyLocalHostName(nil)`                                                                    | the local host name, then the same followed by `.local`                                                                                                                                                                                                                                                                                                                                                                                                                               |
  | the `IOPlatformSerialNumber` property of the `IOPlatformExpertDevice` service (IOKit)                     | the Mac's serial number                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
  | `mesh.snapshot().devices` (the registry)                                                                  | each device's name, then each of its addresses that ends with `.local`, followed by the same without `.local`                                                                                                                                                                                                                                                                                                                                                                         |
  | `registry.all()` (the projects of this Main)                                                              | for each project other than the source project and its sub projects (`registry.descendants(of:)`): its name, its identifier, and the last component of its root folder                                                                                                                                                                                                                                                                                                                |
  | `git config --global --get <key>` for `user.name`, `author.name` and `committer.name` (timeout 10 s each) | each name; the e-mails of git's global identity are not read: every commit publishes them, and as terms they would refuse the user's own commits                                                                                                                                                                                                                                                                                                                                      |
  | `/usr/bin/security find-identity -v -p codesigning` (timeout 30 s)                                        | for each quoted identity name of the form `<kind>: <holder> (<id>)`: the holder, the id, then the team ID, that is each `OU=` value of the subject of that identity's certificate: the output of `/usr/bin/security find-certificate -a -c <identity name> -p` is the `input` of `/usr/bin/openssl x509 -noout -subject -nameopt sep_multiline`, which prints it on a line `OU=<team>` (timeout 30 s each). The id in parentheses of an Apple Development identity is not the team ID |
  | `gh auth status --json hosts` (timeout 10 s)                                                              | the `login` of every account of every host of `hosts` (the output holds no token)                                                                                                                                                                                                                                                                                                                                                                                                     |

- Never suggested, compared case-insensitively: a term shorter than 3 characters; the repository's owner, `Azavech`
  (the part of `ForgeConfig.publicRepository` before its `/`); `Hephaestus` and `HEPH`; the placeholders of
  [../general.md](../general.md#placeholders) and their words (`Jane Appleseed`, `Jane`, `Appleseed`, `user`,
  `/Users/user`, `user@example.com`, `Sam's iPad`, `Sam's MacBook Pro`, `Studio`, `Sams-Mac-mini.local`,
  `Sams-Mac-mini`, `ABCDE12345`, `Atlas`, `API`, `Fixture`); the default and model names of devices: `Mac`, `Mac mini`,
  `MacBook`, `MacBook Air`, `MacBook Pro`, `iMac`, `Mac Studio`, `Mac Pro`, `iPad`, `iPad Air`, `iPad Pro`, `iPad mini`
  and `iPhone` ([../devices/roles.md](../devices/roles.md)).
- A suggested term holding the typographic apostrophe `’` (macOS computer names use it) is followed by the same term
  with `'` in its place. A suggested term holding a letter outside ASCII is followed by its precomposed form
  (`precomposedStringWithCanonicalMapping`), its decomposed form (`decomposedStringWithCanonicalMapping`, as macOS file
  names write it), its lowercase and uppercase forms (`lowercased()`, `uppercased()`) and its form without diacritics
  (`folding(options: .diacriticInsensitive, locale: nil)`), each when its UTF-8 bytes differ from the term's: the check
  matches case only for ASCII letters and compares bytes.
- Later suggestions: `privateTermSuggestions()` runs the sources again and returns the **pending** suggestions, in
  source order: those the file holds neither as a term nor in a line `# not private: <term>` (read as below), compared
  as terms are deduplicated (UTF-8 bytes, the case of ASCII letters only ignored), such as a device paired, a device
  renamed or a project registered since the file was written. It returns `[]` when the file is missing or unreadable,
  since writing it adds them all. While one is pending, the push tools refuse to push
  ([MCP tools](#mcp-tools) step 1). Settings ▸ Forge & Updates lists them ([../ui/settings.md](../ui/settings.md)):
  `addPrivateTerm(_:)` adds the term as a line, `dismissPrivateTerm(_:)` adds the line `# not private: <term>`. Each
  writes the whole file with `AtomicFile.write`, the line added at its end (after a line feed when the file's last
  byte is not one). When the file is missing, cannot be read or is not UTF-8 text, they throw (the read error, or
  `DataError.unreadable("private-terms.txt: the file is not UTF-8 text")`) and write nothing.
- The app reads the file as the check reads it: a line ends at a line feed (LF) only, never at a CR, U+2028 or another
  line break; each line loses a leading UTF-8 byte order mark, then the ASCII white space at both ends (space, tab, LF,
  vertical tab, form feed and CR, the `[:space:]` of `LC_ALL=C`), never another white space such as U+00A0. A line
  that is then empty, starts with `#` or has fewer than 3 characters (Unicode scalars) is no term; the `<term>` of a
  line `# not private: <term>` is trimmed the same way.
- `privateTermsCount()`: the number of terms the file holds, so read; 0 when the file is missing, unreadable or not
  UTF-8 text. The push tools refuse to push while it is 0 ([MCP tools](#mcp-tools) step 1): an emptied file would let
  names through.

## Types

Wire types, declared in `HephCore/Protocol/Types/ForgeTypes.swift` ([../protocol/types.md](../protocol/types.md)) with
exactly these fields. JSON coding follows [../protocol/envelope.md](../protocol/envelope.md) (field names = Swift
names, ISO 8601 dates with milliseconds, `UUID` uppercase, nil members omitted). All are `Codable`, `Sendable`,
`Hashable`. `ForgeConfig`, `ForgeRelease`, `FeedbackContext` and `FeedbackSelection` are as in types.md.

### ForgeState

The result of `forge.status` and the payload of `forge.changed`.

| Field           | Type            | Meaning                                                                                                                      |
|-----------------|-----------------|------------------------------------------------------------------------------------------------------------------------------|
| `enabled`       | `Bool`          | true on the Forge host; false in `forge.status` on another Main and in the `forge.changed` sent when its Forge is turned off |
| `hostDeviceID`  | `UUID`          | the Main that sends it                                                                                                       |
| `config`        | `ForgeConfig?`  | nil when not enabled                                                                                                         |
| `appDocsHash`   | `String`        | `DocsHash.embedded` of the host's running app ([generation.md](generation.md#13-docshash-hephcore))                          |
| `head`          | `ForgeHead?`    | result of the last successful check; nil before the first one                                                                |
| `cycle`         | `ForgeCycle?`   | the current cycle, or the last one; nil when none was ever started                                                           |
| `items`         | `[ForgeItem]`   | feedback items, newest `created` first                                                                                       |
| `latestRelease` | `ForgeRelease?` | the newest release known to the Forge                                                                                        |
| `lastError`     | `String?`       | the last error of a check, a poll or a background step; nil once a check fully succeeds                                      |

When not enabled: `config`, `head`, `cycle`, `latestRelease` and `lastError` are nil and `items` is empty.

### ForgeHead

| Field          | Type     | Meaning                                                                          |
|----------------|----------|----------------------------------------------------------------------------------|
| `commit`       | `String` | full SHA of `origin/<branch>` after the last fetch                               |
| `docsHash`     | `String` | docs hash of `commit`                                                            |
| `codeDocsHash` | `String` | `App/DocsHash.txt` at `commit`, trimmed; `""` when the file does not exist there |
| `checkedAt`    | `Date`   | end of the check                                                                 |

Docs and code are **in sync** when `head.docsHash == head.codeDocsHash`.

### ForgeStage

String enum, in pipeline order: `discussing`, `docsPushed`, `regenerating`, `regenPushed`, `building`, `released`,
`done`, `failed`. Items use every value; cycles use `regenerating` to `failed`.

### ForgeTrigger

String enum: `tool` (`forge_push_docs` pushed the commits of a feedback session), `manual` (`forge.regenerate`),
`automatic` (a check found the docs ahead of the code).

### ForgeCycle

A cycle is one pass of regeneration, CI and release; `Identifiable` by `id`. It is **active** while its state is
`regenerating`, `regenPushed`, `building` or `released`.

| Field          | Type            | Meaning                                                                                               |
|----------------|-----------------|-------------------------------------------------------------------------------------------------------|
| `id`           | `UUID`          | new for each cycle                                                                                    |
| `trigger`      | `ForgeTrigger`  | what started it                                                                                       |
| `state`        | `ForgeStage`    | `regenerating`, `regenPushed`, `building`, `released`, `done` or `failed`                             |
| `failedState`  | `ForgeStage?`   | the state it failed in; set with `failed`, nil otherwise                                              |
| `error`        | `String?`       | the failure message; set with `failed`, nil otherwise                                                 |
| `started`      | `Date`          | creation                                                                                              |
| `updated`      | `Date`          | last change                                                                                           |
| `targetCommit` | `String`        | `head.commit` when its last regeneration step ran                                                     |
| `sessionID`    | `UUID?`         | the last regeneration session; nil when no session was needed                                         |
| `attempts`     | `Int`           | regeneration sessions started for this cycle                                                          |
| `regenCommit`  | `String?`       | full SHA CI builds: the commit `forge_push_regen` pushed, or `head.commit` when no session was needed |
| `pushedAt`     | `Date?`         | when `regenCommit` was recorded or polling for its run restarted                                      |
| `run`          | `ForgeRun?`     | the CI run of `regenCommit`                                                                           |
| `release`      | `ForgeRelease?` | the release of `run`                                                                                  |
| `itemTaskIDs`  | `[String]`      | task ids of the items in the cycle                                                                    |

### ForgeItem

One per feedback task, and per task of a bundle of the source project whose coordinator pushed its docs
([../services/bundles.md](../services/bundles.md)); `var id: String { taskID }`.

| Field               | Type         | Meaning                                                           |
|---------------------|--------------|-------------------------------------------------------------------|
| `taskID`            | `String`     | the feedback task                                                 |
| `projectID`         | `String`     | the source project when the item was created                      |
| `title`             | `String`     | the task name, kept current (Items)                               |
| `state`             | `ForgeStage` | see Items                                                         |
| `feedbackSessionID` | `UUID`       | the feedback session, or the coordinator that created the item    |
| `docsCommit`        | `String?`    | full SHA of the last commit `forge_push_docs` pushed for the item |
| `cycleID`           | `UUID?`      | the cycle the item is in                                          |
| `error`             | `String?`    | the cycle's error while the item is `failed`                      |
| `created`           | `Date`       | creation                                                          |
| `updated`           | `Date`       | last change                                                       |

### ForgeRun

A GitHub Actions run; `Identifiable` by `id`.

| Field         | Type      | Meaning                                                               |
|---------------|-----------|-----------------------------------------------------------------------|
| `id`          | `Int`     | GitHub run id                                                         |
| `number`      | `Int`     | `run_number`, the build number of its release                         |
| `url`         | `String`  | `html_url`                                                            |
| `status`      | `String`  | GitHub `status` (`queued`, `in_progress`, `completed`, …)             |
| `conclusion`  | `String?` | GitHub `conclusion` once completed (`success`, `failure`, …)          |
| `headSHA`     | `String`  | `head_sha`                                                            |
| `foundAt`     | `Date`    | when the Forge found the run or restarted polling it                  |
| `completedAt` | `Date?`   | when the Forge first saw it `completed` with `success`; nil otherwise |

## forge.json

The Forge host keeps `forge.json`, the `forgeFile` of the host's `AppSupport`
(`~/Library/Application Support/Hephaestus/forge.json`), written with `JSONFile.write`
([../data/app-storage.md](../data/app-storage.md)) and coded like the wire types (abridged example; every field of the
types above is written):

```json
{
  "version": 1,
  "cycle": {"id": "5D0E…", "trigger": "tool", "state": "building", "started": "2026-10-29T21:20:00.000Z", "…": "…"},
  "items": [{"taskID": "HEPH-14", "projectID": "HEPH", "title": "Feedback: Sidebar breaks on iPad", "state": "building", "…": "…"}],
  "latestRelease": {"tag": "build-41", "build": 41, "url": "https://github.com/Azavech/Hephaestus/releases/tag/build-41", "publishedAt": "2026-10-28T10:02:11.000Z"},
  "trustedHead": "9c1e…"
}
```

- `version` is `1`; `cycle`, `latestRelease` and `trustedHead` are omitted when nil.
- `trustedHead` (`String?`): the full SHA of the last head of the branch that the Forge pushed, or checked and trusts
  ([Checks and triggers](#checks-and-triggers)); its `scripts/check-public.sh` judges the next pushes
  ([MCP tools](#mcp-tools) step 6).
- Loaded when the Forge is first enabled in the app's process. A file that does not decode, or has another `version`,
  is renamed to `forge.json.bad` (replacing an older one) and the Forge starts with no cycle and no items.
- Written after every change of the cycle, the items or `latestRelease`.
- At most 100 items are kept: when a new item would exceed it, the oldest `done` items are dropped.
- `head` and `lastError` are not stored; the first check after loading recomputes them.

## Feedback intake

`forge.feedback {screenshot, comment, context}` (`ForgeFeedbackParams` → `ForgeFeedbackResult {projectID, taskID,
sessionID}`), sent by the feedback sheet ([feedback.md](feedback.md#sending)):

1. Checks: the Forge is enabled (`unavailable`, `This Main is not the Forge.`); the configuration checks pass;
   `comment` trimmed is not empty (`badRequest`, `The comment is empty.`); when `screenshot` is set,
   `host.uploads.check([screenshot], projectID: <source project>)` passes (the upload errors of
   [../protocol/methods.md](../protocol/methods.md#using-uploads): the screenshot is a complete upload of the source
   project, [../services/files.md](../services/files.md#7-uploads)). The screenshot has no size limit.
2. The task is created in the source project with `host.tasks.create(projectID:name:description:status:)`, status
   `todo` ([../services/host.md](../services/host.md), [../data/task-yml.md](../data/task-yml.md)):
   - `name`: `Feedback: ` + the first line of the trimmed comment, cut to its first 60 characters.
   - `description`: the trimmed comment, a blank line, a `---` line, a blank line, then the context block:

     ```text
     Feedback from <deviceName> (<platform>), Hephaestus <appVersion> (<build>), docs <docsHash>

     - Device ID: <deviceID>
     - Main: <name of mainDeviceID in the registry> (<mainDeviceID>)
     - Project: <projectID>
     - Section: <section>
     - Item: <item>
     ```

     The values are those of `context`; the `Main`, `Project`, `Section` and `Item` lines are present only when
     `context.selection` has the value; the Main line is `- Main: <mainDeviceID>` when the registry has no such
     device.
3. When `screenshot` is set: `host.tasks.addComment(projectID:taskID:body:attachments:author:)` on the task, body
   `Screenshot`, attachments `[UploadRef(uploadID: screenshot.uploadID, fileName: "screenshot.png")]`, which moves the
   upload's file into the task's attachments folder; author = the registry name of the requesting device (`from`;
   `context.deviceName` when the registry has none). When it fails, the error is returned (the task stays, without the
   screenshot, and the upload stays usable).
4. The feedback session is started with `host.sessions.start(SessionStart(…))` ([../claude/cli.md](../claude/cli.md)):
   `projectID` = the source project, `kind` `.feedback`, `taskID` = the new task, `permissionMode` `.acceptEdits`,
   `deviceID` = this Main's id, no title, mode, message, attachments or model. The session is titled `Feedback <task
   id>`, starts in `acceptEdits`, which the user can change like its Allow All Tools, its permission rules and
   environment are those of feedback sessions
   ([../claude/cli.md](../claude/cli.md#35-sessions-in-the-public-repository)), its model is the project's default,
   and it starts with the generated feedback message of [../claude/prompts.md](../claude/prompts.md) (the task's
   description and the absolute path of `screenshot.png`).
5. The item is created: `state` `discussing`, `title` = the task name, `feedbackSessionID` = the session's id,
   `created` = `updated` = now; `forge.json` is written; `forge.changed` is sent.
6. Result: `{projectID: <source project>, taskID, sessionID}`.

When step 4 fails, no item is created, the task stays, and the error is returned.

## Items

| From                                         | Event                                             | To                | Effects                                                                       |
|----------------------------------------------|---------------------------------------------------|-------------------|-------------------------------------------------------------------------------|
| (none)                                       | `forge.feedback`                                  | `discussing`      | Feedback intake                                                               |
| (none)                                       | `forge_push_docs` of a coordinator pushed `<sha>` | `docsPushed`      | created for each task of the bundle without an item (MCP tools step 8)        |
| `discussing`, `docsPushed`, `done`, `failed` | `forge_push_docs` of its session pushed `<sha>`   | `docsPushed`      | `docsCommit` = `<sha>`; `cycleID`, `error` cleared; join rule; `tool` trigger |
| `regenPushed`, `building`, `released`        | `forge_push_docs` of its session pushed `<sha>`   | unchanged         | `docsCommit` = `<sha>`                                                        |
| `docsPushed`, `failed`                       | the join rule matches                             | the cycle's state | `cycleID` = the cycle; task id added to `itemTaskIDs`                         |
| in a cycle                                   | the cycle changes state                           | the cycle's state | `error` = the cycle's error when `failed`, else nil                           |
| `released`                                   | Completion writes its comment                     | `done`            | comment, task status `done`                                                   |
| any                                          | its task changes name (`task.changed`)            | unchanged         | `title` = the new name                                                        |
| any                                          | its task is deleted (`task.removed`)              | (removed)         | removed from `items` and from its cycle's `itemTaskIDs`                       |

An item's task is the task of `projectID` whose id is `taskID`. Its feedback session renames it when it rewrites the
feedback as a task ([../claude/prompts.md](../claude/prompts.md#feedback-part)); `task.changed` of a task whose name
equals the item's `title` changes nothing.

**Join rule.** An item in `docsPushed` or `failed` joins the active cycle when its `docsCommit` is an ancestor of the
cycle's reference commit (`git merge-base --is-ancestor <docsCommit> <reference>` exits 0; a commit is its own
ancestor). The reference is `regenCommit` when set, else `targetCommit`. The rule is applied to every such item when
a regeneration step runs and when `regenCommit` is recorded, and to the one item after `forge_push_docs`. An item
that does not join waits for the next cycle.

## Cycles

| From                                    | Event                                                                                                                        | To                |
|-----------------------------------------|------------------------------------------------------------------------------------------------------------------------------|-------------------|
| none, `done`, `failed`                  | a trigger starts a cycle (Checks and triggers)                                                                               | regeneration step |
| (regeneration step)                     | docs and code in sync and no failed run to fix                                                                               | `regenPushed`     |
| (regeneration step)                     | session started                                                                                                              | `regenerating`    |
| (regeneration step)                     | a configuration check or the check failed, working tree not clean, unpushed commits, session start failed                    | `failed`          |
| `regenerating`                          | `forge_push_regen` of the cycle's session pushed `<sha>`                                                                     | `regenPushed`     |
| `regenerating`                          | the cycle's session ends a turn, stops or fails without having pushed with `forge_push_regen`                                | `failed`          |
| `regenerating`                          | the cycle's session is deleted                                                                                               | `failed`          |
| `failed` (`failedState` `regenerating`) | `forge_push_regen` of the cycle's session pushed `<sha>`                                                                     | `regenPushed`     |
| `regenPushed`                           | the CI run of `regenCommit` is found                                                                                         | `building`        |
| `regenPushed`                           | 10 minutes after `pushedAt` without a run                                                                                    | `failed`          |
| `building`                              | the run completed with conclusion `success` and the release `build-<run.number>` is found                                    | `released`        |
| `building`                              | the run completed with another conclusion (Polling: its message depends on the `public-check` and `public-check-terms` jobs) | `failed`          |
| `building`                              | the run is not completed 90 minutes after `run.foundAt`                                                                      | `failed`          |
| `building`                              | the run succeeded and the release is not found 10 minutes after `run.completedAt`                                            | `failed`          |
| `released`                              | Completion is done                                                                                                           | `done`            |
| `failed`                                | Retry                                                                                                                        | see Retry         |

Every transition sets `updated`, writes `forge.json` and sends `forge.changed`. Entering `failed` sets `failedState`
and `error` (the messages of this doc); leaving it clears them.

### Regeneration step

Run when a cycle starts and by Retry from `regenerating`. `fixRun` is the failed run to fix, given only by Retry
from `building`.

1. Configuration checks; a failure → `failed` (`failedState` `regenerating`) with the check's message.
2. A check (Checks and triggers); a failure → `failed` with its message. `targetCommit` = `head.commit`.
3. When `fixRun` is nil and docs and code are in sync, no session is needed: `regenCommit` = `head.commit`,
   `pushedAt` = now, state `regenPushed`; the join rule runs; polling starts.
4. Otherwise `git status --porcelain` must print nothing, else `failed` with `The source project has uncommitted
   changes. Commit or discard them, then retry.`; and `git rev-list refs/remotes/origin/<branch>..HEAD` must print
   nothing, else `failed` with `Unpushed commits on <branch>: push or remove them, then retry.`, since
   `forge_push_regen` pushes only the regeneration's own commits. The project data the app writes under `.hephaestus/`
   (the `taskCounter` of `project.yml` raised by each feedback task, the web tabs) never counts: git ignores that
   folder.
5. The join rule runs. Then `host.sessions.start(SessionStart(…))` with `projectID` = the source project, `kind`
   `.regeneration`, no `taskID`, `title` `Regeneration <yyyy-MM-dd HH:mm>` (local time; ` (attempt <n>)` appended when
   `n` > 1), no message, no attachments, `deviceID` = this Main's id, and `regeneration` = a `RegenerationContext`
   ([../claude/prompts.md](../claude/prompts.md)):

   | Field          | Value                                                                                                                                                                                                                              |
   |----------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
   | `trigger`      | the cycle's `trigger` raw value                                                                                                                                                                                                    |
   | `attempt`      | `attempts` + 1                                                                                                                                                                                                                     |
   | `targetCommit` | `targetCommit`                                                                                                                                                                                                                     |
   | `items`        | one `RegenerationItem {taskID, docsCommit}` per item of the cycle                                                                                                                                                                  |
   | `failedRun`    | with `fixRun`: `FailedCIRun {number, url, conclusion, jobs}`, `jobs` = the failed jobs (at most 3; none when the jobs request fails), each `{name, url, log}`, `log` = the last 300 lines of its log or `Log unavailable: <error>` |

   The session starts in the permission mode `acceptEdits`, its permission rules and environment are those of
   regeneration sessions ([../claude/cli.md](../claude/cli.md#35-sessions-in-the-public-repository)), its model is the
   project's default, and its prompts make Claude follow [generation.md](generation.md#2-procedure). As in every
   session, the user can change its permission mode and allow all its tools.
6. `attempts` += 1, `sessionID` = the new session, state `regenerating`. A start failure → `failed` with
   `The regeneration session could not start: <error>`.

### Session observation

The host calls `sessionChanged(projectID:session:)` for every `session.changed` it emits and
`sessionRemoved(projectID:sessionID:)` for every `session.removed`. For the session `cycle.sessionID` while the cycle
is `regenerating`:

- status `running` or `waitingPermission`: the session has started a turn (remembered in memory per session id);
- status `idle` or `stopped` after a turn started: the cycle fails with `The regeneration session ended its turn
  without pushing with forge_push_regen.`;
- status `failed`: the cycle fails with `The regeneration session failed: <SessionInfo.error>`;
- removed: the cycle fails with `The regeneration session was deleted.`.

A late `forge_push_regen` from that session still moves a cycle failed in `regenerating` to `regenPushed`, so a
session that stopped to ask the user a question can finish after the answer.

### Retry

Retry acts on the current cycle when it is `failed` (`forge.retry` for one of its items, or `forge.regenerate`):

| `failedState`  | Condition                                                       | Action                                                                                                                                                                                                                                                                                       |
|----------------|-----------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `regenerating` | —                                                               | regeneration step, `fixRun` nil                                                                                                                                                                                                                                                              |
| `regenPushed`  | —                                                               | state `regenPushed`, `pushedAt` = now, polling starts                                                                                                                                                                                                                                        |
| `building`     | `run.conclusion` is nil or `success` (timeout, release missing) | state `building`, `run.foundAt` = now, `run.completedAt` = now when it was set, polling starts                                                                                                                                                                                               |
| `building`     | another conclusion                                              | `GET actions/runs/<run.id>` first: when the run is no longer completed (re-run on GitHub) or now concluded `success`, state `building` and polling as above; otherwise regeneration step, with `fixRun` = the run, or nil when its `public-check` or `public-check-terms` job failed (below) |

Retry clears `error` and `failedState`, and moves the cycle's items with it. When a request of the last row fails (the
run or its jobs), nothing changes: the cycle stays `failed` and `lastError` is the request's error, since a fix session
never starts without knowing whether a check job failed.

A run whose `public-check` or `public-check-terms` job concluded `failure` (`actions/runs/<run.id>/jobs?filter=latest`)
is never given to a fix session: no session can take pushed data back. The user first rewrites the branch by hand
([../public-repository.md](../public-repository.md#if-personal-data-was-pushed)); the regeneration step then starts
from origin's new head.

## Checks and triggers

A **check**, one at a time (a check requested while one runs waits for it and uses its result):

1. Configuration checks.
2. `git fetch --quiet origin <branch>`.
3. `head` = {`commit`: `git rev-parse --verify refs/remotes/origin/<branch>`, `docsHash`: the docs hash of that
   commit, `codeDocsHash`: `git show <commit>:App/DocsHash.txt` trimmed, `""` when it fails, `checkedAt`: now}.
4. **Commits pushed elsewhere.** When `trustedHead` is nil, it becomes `head.commit`. When it is set and differs from
   `head.commit`, commits reached the branch without the push tools (by hand, from another clone, or from code a
   session ran): `ForgePushGate.checkPushedElsewhere(from: trustedHead, to: head.commit)` writes
   `git show <trustedHead>:scripts/check-public.sh` to a temporary file and runs it as in [MCP tools](#mcp-tools) step
   6, with `--ref refs/heads/<branch> --commits <head.commit> --not <trustedHead>`: the published check as it was
   before them judges them, with the private terms. They are clean when it exits 0, or when it exits 1 with only
   `ci skip marker` findings: its standard output, untrimmed, each line ending at a line feed, is an optional first
   line starting with `Note: `, then one or more lines `<sha8> message: ci skip marker` (`<sha8>` being 8 lowercase
   hexadecimal digits), then a last line starting with `Personal data check: `. GitHub ran no CI for such commits, and
   this check stands in for the personal data check of that run.
   - Clean: `trustedHead` = `head.commit`.
   - Findings: `lastError` = `Commits pushed to <branch> outside the Forge hold personal data: follow "If personal data
     was pushed" in docs/public-repository.md.`, a blank line and the finding lines; `trustedHead` is kept.
   - Any other failure: `lastError` = `The commits pushed to <branch> outside the Forge could not be checked:
     <reason>.`; `trustedHead` is kept. `<reason>`, written without its final period, is the git error when `git show`
     fails (no script at `trustedHead`: `git show failed: <line>`, [Git operations](#git-operations)), else the
     `<reason>` of [MCP tools](#mcp-tools) step 6 (`timed out` for a timeout).

   `forge.json` is written when `trustedHead` changes. `head` is **trusted** while `trustedHead` equals `head.commit`.
5. `GET releases/latest`: a `tag_name` of the form `build-<N>` with `N` greater than `latestRelease.build` (or no
   `latestRelease`) replaces `latestRelease`; other tags are ignored. Skipped while rate limited, which fails the step
   with the rate-limit message ([GitHub API](#github-api)).
6. The check succeeds when steps 1 to 3 succeed. A failure of steps 1 to 3 sets `lastError` and keeps the previous
   `head`; a failure of step 4 or 5 sets `lastError` and keeps the new `head`, `lastError` being the error of step 4
   when both fail. When every step succeeds, `lastError` is cleared.

Checks run when the Forge is enabled, every 5 minutes while it is, after `forge_push_docs`, in a regeneration step,
after a cycle reaches `done`, and on `forge.status` when `head` is nil or `head.checkedAt` is more than 60 s old (in
the background; the request answers at once). After each check, a cycle still `released` (an error stopped its
Completion) runs Completion again from step 2 ([Completion](#completion)), before the triggers.

Triggers start a cycle (`trigger` set, `started` = now, `attempts` 0, then the regeneration step):

| Trigger     | When                                                                                                                 | Conditions                                                                                                            |
|-------------|----------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| `tool`      | after `forge_push_docs` pushed the commits of an item that did not join a cycle                                      | `forge.autoRegenerate`; no active cycle; `head` is trusted                                                            |
| `automatic` | after a successful check run at enabling, by the 5-minute timer, after a cycle reaches `done`, or for `forge.status` | `forge.autoRegenerate`; no active cycle; the last cycle is not `failed`; docs and code not in sync; `head` is trusted |
| `manual`    | `forge.regenerate`                                                                                                   | no active cycle; when the last cycle is `failed`, `forge.regenerate` retries it instead                               |

A new cycle replaces `cycle`; its items are those the join rule adds.

## MCP tools

The MCP server ([../claude/mcp.md](../claude/mcp.md)) hands the two Forge push tools to the host (`MCPHost`), which
calls `pushDocs(sessionID:)` and `pushRegen(sessionID:)` with the calling session's id. They take no argument. The
returned text is the tool result; a thrown error's message is the result with `isError: true`, and says what Claude
does before calling the tool again. Errors are `ProtocolError` values: `unavailable` (`locked` while migrating) for
the configuration checks, `conflict` for every other step. Forge sessions are denied `git push`, and the git
processes they start fail to push ([../claude/cli.md](../claude/cli.md#35-sessions-in-the-public-repository)); code
they run can still drop that block ([../public-repository.md](../public-repository.md#claude-permissions)). These
tools are the only way their commits are meant to reach GitHub; commits that reach it another way are checked at the
next check ([Checks and triggers](#checks-and-triggers)).

`forge_push_docs` (feedback sessions) and `forge_push_regen` (regeneration sessions) run these steps in order, the
**Forge push gate** ([../public-repository.md](../public-repository.md#forge-push-gate)); the first failure ends the
call with its text. `<tool>` is the tool's name and `<branch>` the configured branch.

1. **Session.**
   - `forge_push_docs`: the session is the `feedbackSessionID` of an item, or the coordinator of a bundle of the source
     project in `running` or `review` (`coordinatorSessionID`, [../services/bundles.md](../services/bundles.md)), else
     `forge_push_docs is only available in Forge feedback sessions and in the bundle sessions of the source project.`;
     the cycle is not `regenerating`, else `A regeneration is working in this repository; call forge_push_docs again
     when it has pushed.` (feedback and regeneration sessions share the working tree and the branch).
   - `forge_push_regen`: the session is `cycle.sessionID` and the cycle is `regenerating`, or `failed` with
     `failedState` `regenerating`, else `forge_push_regen is only available in the current Forge regeneration
     session.`.
   - Then the configuration checks.
   - Then the private terms file is written when it is missing ([Private terms](#private-terms)); a failure to write it
     is logged, and the file, still missing, holds no term for the check that follows. It must hold a term
     (`privateTermsCount()` > 0), else `private-terms.txt holds no terms: add your names in Settings ▸ Forge & Updates
     ▸ Private terms, then call <tool> again.`; and no suggestion may be pending (`privateTermSuggestions()` is empty),
     else `Hephaestus suggests <n> new private terms: add or dismiss them in Settings ▸ Forge & Updates ▸ Private
     terms, then call <tool> again.`.
2. **Branch.** `git fetch --quiet origin <branch>`; `git rev-parse --abbrev-ref HEAD` prints `<branch>`, else `The
   repository is on <name>, not <branch>: switch to <branch>, then call <tool> again.` (`<name>` is what it printed,
   `HEAD` for a detached HEAD). `<sha>` = `git rev-parse --verify HEAD` and `<base>` =
   `git rev-parse --verify refs/remotes/origin/<branch>`, each resolved once: the later steps check and push exactly
   `<sha>` against `<base>`, whatever the session commits or fetches meanwhile.
3. **Commits.** The commits to push are `git rev-list --reverse <base>..<sha>`, oldest first.
   - none: `Nothing to push: commit your change first.`;
   - `git merge-base --is-ancestor <base> <sha>` exits 1: `origin/<branch> moved: run git pull --rebase origin
     <branch>, then call <tool> again.`;
   - `git rev-list --merges <base>..<sha>` prints a commit: `Rebase instead of merging: git pull --rebase origin
     <branch>, then call <tool> again.`.
4. **Paths.** For each commit, oldest first: the paths it changes, `git diff-tree --no-commit-id --name-only -r -z
   <commit>` (added, modified, deleted, and both names of a renamed file), and the paths of its tree,
   `git ls-tree -r -z --name-only <commit>`. Paths are compared after ASCII lowercasing, so that a path written in
   another letter case, which a Mac's disk stores as the same file, counts as that path. The refusals below are looked
   for in their order: the case clashes, then the `docs/` rule of the tool, each over the commits oldest first and,
   within a commit, over its paths in the order of `git diff-tree`.
   - A path the commit adds or changes that equals, ignoring ASCII case, another path of its tree, or one of whose
     folders equals, ignoring ASCII case, another folder of its tree: `<sha8> adds <path>, which differs only in case
     from <other path>.`, `<other path>` being that other path, or that other folder followed by `/` (`…, which
     differs only in case from docs/.`). A path is compared before its folders, outermost first, and `<other path>` is
     the first match in the order of `git ls-tree`.
   - `forge_push_docs`, a path that does not start with `docs/`: `forge_push_docs pushes documentation only: <sha8>
     changes <path>. Keep only docs/ in these commits (git reset --soft origin/<branch>, then commit docs/ alone), then
     call forge_push_docs again.`;
   - `forge_push_regen`, a path that starts with `docs/` once lowercased: `forge_push_regen never pushes documentation:
     <sha8> changes <path>. A regeneration does not edit docs/: take that change out of these commits, then call
     forge_push_regen again.`.
5. **Docs hash** (`forge_push_regen` only). `App/DocsHash.txt` at `<sha>`, trimmed, equals the docs hash of `<sha>`
   ([Git operations](#git-operations)), else `App/DocsHash.txt at <sha8> is <recorded> but the docs hash of that commit
   is <actual>. Run scripts/docs-hash.sh > App/DocsHash.txt, commit, then call forge_push_regen again.` (`<recorded>`
   is `missing` when the file does not exist at `<sha>`).
6. **Personal data.** The check is the published script of `trustedHead` (of `<base>` while `trustedHead` is nil),
   never the working tree's, which a session can change, nor one that reached the branch outside the gate and was not
   trusted ([Checks and triggers](#checks-and-triggers) step 4): `git show <trustedHead>:scripts/check-public.sh` is
   written to a new file in the temporary folder (it fails: `scripts/check-public.sh is missing on origin/<branch>.`).
   Then `/bin/bash <that file> --ref refs/heads/<branch> --commits <base>..<sha>` runs with `ChildProcess.capture`,
   the repository root as working directory and a timeout of 120 s; the file is deleted after. Its environment is that
   of the gate's `ForgeGit` (the login environment in the app) without `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT` and
   every `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>` (`<n>` one or more ASCII digits), with these added:
   `GIT_CONFIG_COUNT` = `2`, `GIT_CONFIG_KEY_0` = `core.hooksPath`, `GIT_CONFIG_VALUE_0` = `/dev/null`,
   `GIT_CONFIG_KEY_1` = `core.fsmonitor`, `GIT_CONFIG_VALUE_1` = `false`, `GIT_NO_REPLACE_OBJECTS` = `1` and
   `HEPHAESTUS_PRIVATE_TERMS` = the terms file. Without the first five, the script's `git update-index`, which writes
   an index, would run the `post-index-change` hook of the working tree.
   - exit status 0: the next step;
   - exit status 1: the script's standard output, trimmed (one line per finding, in the format of
     [../public-repository.md](../public-repository.md#output), never the matched text), a blank line, then
     `Remove the personal data or CI skip markers and rewrite these unpushed commits (git reset --soft origin/<branch>,
     then commit again), then call <tool> again. If a private term is a false positive, the user narrows or removes
     that one term in private-terms.txt.`;
   - another exit status, or the timeout: `The personal data check could not run: <reason>.`, `<reason>` being
     `timed out` for the timeout, else the last non-empty line of its standard error (`check-public.sh: …`), or
     `exit status <N>` when there is none; a script that cannot be written or started: the same text with the error's
     message as `<reason>` (`strerror` of the spawn error when it cannot be started). `<reason>` is written without its
     final period: the script's error lines end with one.
7. **Push.** `git push --no-follow-tags origin <sha>:refs/heads/<branch>`, never forced; no hook runs
   ([Git operations](#git-operations)). When it fails: `git fetch --quiet origin <branch>`, then, when
   `refs/remotes/origin/<branch>` is no longer an ancestor of `<sha>`, `origin/<branch> moved: run git pull --rebase
   origin <branch>, then call <tool> again.`; otherwise the git error (`git push failed: <line>`).
8. **Record**, with `<sha>` as the pushed commit. When `trustedHead` is `<base>`, it becomes `<sha>` and `forge.json`
   is written: the Forge trusts what it checked on a trusted base, and leaves the commits pushed elsewhere to the next
   check ([Checks and triggers](#checks-and-triggers)).
   - `forge_push_docs`: the session's item takes the event of [Items](#items); then, when it is `docsPushed`, the join
     rule; then a check; then the `tool` trigger. For a coordinator, its items are those of the tasks of its bundle:
     a task without an item gets a new one first (`state` `docsPushed`, `title` = the task name, `feedbackSessionID` =
     the coordinator, `created` = `updated` = now), unless the task no longer exists; `<task id>` below is the bundle
     id. Result, the first matching row:

     | Situation                                                                                                            | Text                                                                                                                                                                                  |
     |----------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
     | the item is in the active cycle (it joined now or was in it already); for a coordinator, every item of its bundle is | `Pushed docs commit <sha8> for <task id>. It is part of the regeneration in progress.`                                                                                                |
     | the `tool` trigger started a cycle                                                                                   | `Pushed docs commit <sha8> for <task id>. Regeneration started.`                                                                                                                      |
     | a cycle is active                                                                                                    | `Pushed docs commit <sha8> for <task id>. It will be regenerated after the regeneration in progress.`                                                                                 |
     | `forge.autoRegenerate` is off                                                                                        | `Pushed docs commit <sha8> for <task id>. Regenerate automatically is off: the user starts the regeneration from the Forge screen.`                                                   |
     | `head` is not trusted                                                                                                | `Pushed docs commit <sha8> for <task id>. Commits pushed to <branch> outside the Forge are not trusted yet: the regeneration waits until they are (Forge screen).`                    |

   - `forge_push_regen`: `regenCommit` = `<sha>`, `pushedAt` = now, state `regenPushed`, join rule, polling starts.
     Result: `Pushed regeneration commit <sha8>. The Forge now waits for the CI run and the release.`.

`<sha8>` is the first 8 characters of a full SHA. Steps 2 to 7 are `ForgePushGate.push(_:trustedHead:)`, called with
`trustedHead`, and Checks and triggers step 4 is `ForgePushGate.checkPushedElsewhere(from:to:)`
([Swift API](#swift-api)), which [../testing.md](../testing.md) runs on temporary repositories.

## Git operations

`git` and `gh` are the first executable regular files of those names in the `PATH` of
`LoginEnvironment.shared.environment()`; git is run only while `host.info` reports `gitAvailable` (the host's check
keeps the `/usr/bin/git` stub of a Mac without the Command Line Tools from being run,
[../services/host.md](../services/host.md)). Commands run with `ChildProcess.capture`
([../claude/cli.md](../claude/cli.md)): that environment, the repository root as working directory, arguments passed
as given (no shell). A non-zero exit (unless the table gives it a meaning) or a timeout is an error whose message is
`git <subcommand> failed: <last non-empty stderr line>`, `<subcommand>` being the first argument of the table's command.
When stderr has no non-empty line, the message ends with `timed out` for a timeout and `exit status <N>` otherwise
(`N`: `ChildTermination.exitCode`); a git that cannot be started gives `git <subcommand> failed: <strerror>`.

Every git command runs as `git -c core.hooksPath=/dev/null -c core.fsmonitor=false <arguments>`, with
`GIT_NO_REPLACE_OBJECTS` = `1` added to its environment: no hook and no file-system monitor of the repository runs in
the app's process, which has the user's credentials, and no replace ref (`refs/replace/`, which `git replace` writes)
makes a command read another commit, tree or file than the one a push sends
([../public-repository.md](../public-repository.md#forge-push-gate)). The check of MCP tools step 6, and that of Checks
and triggers step 4, run their own git commands with the same two settings, given through `GIT_CONFIG_COUNT`, and the
same variable. Code that a session starts can change the files of the working tree, the hooks included;
the push needs no hook, since the push tools run the published check themselves (MCP tools step 6).

| Use                 | Command                                                               | Timeout | Result                                                            |
|---------------------|-----------------------------------------------------------------------|---------|-------------------------------------------------------------------|
| fetch               | `git fetch --quiet origin <branch>`                                   | 120 s   | —                                                                 |
| head                | `git rev-parse --verify refs/remotes/origin/<branch>`                 | 30 s    | stdout trimmed                                                    |
| current branch      | `git rev-parse --abbrev-ref HEAD`                                     | 30 s    | stdout trimmed                                                    |
| HEAD                | `git rev-parse --verify HEAD`                                         | 30 s    | stdout trimmed                                                    |
| ancestor            | `git merge-base --is-ancestor <a> <b>`                                | 30 s    | exit 0 = ancestor, 1 = not                                        |
| commits             | `git rev-list --reverse <a>..<b>`                                     | 30 s    | one full SHA per line                                             |
| merge commits       | `git rev-list --merges <a>..<b>`                                      | 30 s    | empty stdout = none                                               |
| changed paths       | `git diff-tree --no-commit-id --name-only -r -z <commit>`             | 30 s    | NUL-terminated paths                                              |
| paths of a tree     | `git ls-tree -r -z --name-only <rev>`                                 | 30 s    | NUL-terminated paths                                              |
| docs files          | `git ls-tree -r -z <rev> -- docs`                                     | 30 s    | entries, below                                                    |
| file at a revision  | `git show <rev>:<path>`                                               | 30 s    | stdout bytes                                                      |
| working tree clean  | `git status --porcelain`                                              | 30 s    | empty stdout = clean                                              |
| top folder          | `git rev-parse --show-toplevel`                                       | 30 s    | stdout trimmed                                                    |
| origin URL          | `git remote get-url origin`                                           | 30 s    | stdout trimmed                                                    |
| push URLs           | `git remote get-url --push --all origin`                              | 30 s    | one URL per line                                                  |
| push URL setting    | `git config --get-all remote.origin.pushurl`                          | 30 s    | stdout; exit 1 = none                                             |
| local setting       | `git config --local --get <key>` (`core.hooksPath`, `commit.gpgsign`) | 30 s    | stdout trimmed; exit 1 = not set                                  |
| set a local setting | `git config --local <key> <value>`                                    | 30 s    | —                                                                 |
| push                | `git push --no-follow-tags origin <sha>:refs/heads/<branch>`          | 120 s   | —                                                                 |
| GitHub token        | `gh auth token`                                                       | 10 s    | stdout trimmed; non-zero exit, empty output or no `gh` = no token |

**Docs hash of a revision.** `git ls-tree -r -z <rev> -- docs` prints NUL-terminated entries
`<mode> <type> <object>\t<path>`. The entries with mode `100644` or `100755` and type `blob` whose last path component
is not `.DS_Store` are kept; for each, `git show <rev>:<path>` gives the content; the docs hash is
`DocsHash.compute(_:)` of these files ([generation.md](generation.md#1-docs-hash)). It equals `scripts/docs-hash.sh`
run on a checkout of `<rev>`.

## GitHub API

`GitHubClient` sends `GET https://api.github.com/repos/<repository>/…` with `URLSession`:

- Headers: `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`,
  `User-Agent: Hephaestus/<CFBundleShortVersionString> (<CFBundleVersion>)`, and `Authorization: Bearer <token>` when a
  token is known. Timeout 30 s.
- Token: `GitHubClient.readToken()` (`gh auth token`) when the Forge is enabled and after a `401`; a `401` is retried
  once with the new token, or without one.
- `403` or `429` with header `x-ratelimit-remaining: 0` or a `retry-after` header: rate limited until
  `x-ratelimit-reset` (epoch seconds) or now + `retry-after` seconds (`GitHubError.rateLimited(until:)`); no request
  is sent before that time, and `lastError` is `GitHub API rate limit reached; next request at <HH:mm>.`.
- Other non-2xx statuses: `GitHubError.http(status:path:)`, message `GitHub API <path>: HTTP <status>.` (`404` is a
  result where the table says so).
- A `2xx` response whose body does not decode throws the decoding error.

| Request                                    | Use                | Fields read                                                                                                           |
|--------------------------------------------|--------------------|-----------------------------------------------------------------------------------------------------------------------|
| `releases/latest`                          | checks             | `tag_name`, `html_url`, `published_at`; `404` = none                                                                  |
| `releases/tags/build-<N>`                  | release wait       | `tag_name`, `html_url`, `published_at`; `404` = not yet                                                               |
| `actions/runs?head_sha=<sha>`              | run lookup         | `workflow_runs[]`: `id`, `run_number`, `status`, `conclusion`, `html_url`, `head_sha`, `head_branch`, `event`, `path` |
| `actions/runs/<run id>`                    | run polling, Retry | `status`, `conclusion`, `html_url`, `run_number`                                                                      |
| `actions/runs/<run id>/jobs?filter=latest` | Polling, Retry     | `jobs[]`: `id`, `name`, `conclusion`, `html_url`                                                                      |
| `actions/jobs/<job id>/logs`               | Retry (`fixRun`)   | the `302` response's `Location`, fetched without the `Authorization` header; body as UTF-8 text                       |

Run lookup keeps the runs whose `head_sha` is the full SHA, `head_branch` is `<branch>`, `event` is `push` and `path`
is `.github/workflows/ci.yml`, and takes the one with the greatest `id`: CI runs for the pushes of every branch and tag
([ci.md](ci.md)). Failed jobs are the jobs whose `conclusion` is
neither `success`, `skipped` nor `neutral`, in response order.

### Polling

While the cycle is `regenPushed` or `building`, one polling step runs at once and then every 20 s (later when rate
limited). A failed request sets `lastError`; the next step runs as planned. The timeouts of the table fail the cycle
only in a step whose request succeeded.

| Cycle                         | Request                     | Outcome                                                                                                                                                                                                                                                                                               |
|-------------------------------|-----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `regenPushed`                 | run lookup of `regenCommit` | found: `run` = {…, `foundAt` = now, `completedAt` = now when it is `completed` with `success`}, `building`; none 10 minutes after `pushedAt`: `failed`, `No CI run for <sha8> after 10 minutes.`                                                                                                      |
| `building`, run not completed | `actions/runs/<id>`         | `status` and `conclusion` updated; `completed` + `success`: `completedAt` = now; `completed` + other: the run's jobs are read (`actions/runs/<id>/jobs?filter=latest`), then `failed` with the message below; 90 minutes after `foundAt`: `failed`, `CI run #<N> did not complete within 90 minutes.` |
| `building`, run succeeded     | `releases/tags/build-<N>`   | found: `release` set, Completion; `404` 10 minutes after `completedAt`: `failed`, `Release build-<N> was not found 10 minutes after CI run #<N> succeeded.`                                                                                                                                           |

A run that completed with a conclusion other than `success` fails the cycle with:

- when its job `public-check` or `public-check-terms` concluded `failure` ([ci.md](ci.md)): `Personal data check failed
  on GitHub for <sha8>: personal data may be public. Follow "If personal data was pushed" in docs/public-repository.md.`
  (`<sha8>`: the run's `headSHA`). Nothing was built or released, but the commits are on GitHub: the user removes the
  data from the branch's history by hand
  ([../public-repository.md](../public-repository.md#if-personal-data-was-pushed)), and Retry never starts a fix session
  for such a run ([Retry](#retry));
- otherwise, or when the jobs request fails: `CI run #<N> concluded <conclusion>.`.

`forge.changed` is sent only when a value of `ForgeState` changed, not for every request.

## Completion

When the release of the cycle's run is found:

1. `release` is set; `latestRelease` = the release when its `build` is greater; the cycle and its items become
   `released`; `forge.json` is written and `forge.changed` sent. Every Mac checks for the update at once
   ([update.md](update.md#schedule)).
2. For each item of the cycle still `released`, in order:
   `host.tasks.addComment(projectID:taskID:body:attachments:author:)` with the body below, no attachment and author =
   this Main's device name, then `host.tasks.update(projectID:taskID:patch:)` with status `done`; the item becomes
   `done`; `forge.json` is written. A task that no longer exists (`notFound`) removes its item. Any other error stops
   Completion: `lastError` is its message and the cycle stays `released`.
   Completion runs again from this step after every check while the cycle is `released`, whatever the check's outcome
   ([Checks and triggers](#checks-and-triggers)), and at the next enabling
   ([Startup and shutdown](#startup-and-shutdown) step 4).

   ```markdown
   Released in build <N>.

   - Docs: [<sha8>](https://github.com/<repository>/commit/<docsCommit>)
   - Built commit: [<sha8>](https://github.com/<repository>/commit/<regenCommit>)
   - CI run: [#<N>](<run url>)
   - Release: [build-<N>](<release url>)
   ```

3. The cycle becomes `done`; `forge.json` is written; `forge.changed` is sent; a check runs (it can start the next
   cycle).

## Broadcasting

After every change of a `ForgeState` value, and when the Forge is enabled, `ForgeService` calls
`host.emit(.forgeChanged(ForgeChangedPayload(state:)))`: every authenticated connection gets it, clients and peer Mains
alike ([../protocol/events.md](../protocol/events.md)). `configure(nil)` while the Forge was enabled sends one
`forge.changed` with `enabled` false (and `config` nil), so clients stop treating this Main as the Forge.

## Methods

The host decodes the `forge.*` params and calls `status()`, `feedback(screenshot:comment:context:from:)` (`from` = the
requesting device), `regenerate()` and `retry(itemTaskID:)` ([../services/host.md](../services/host.md)). Params and
results: [../protocol/methods.md](../protocol/methods.md). Every method except `forge.status` fails with `unavailable`
`This Main is not the Forge.` while the Forge is not enabled.

| Method             | Behavior                                                                                                                                                                                                                                            | Errors                                                                                               |
|--------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|
| `forge.status`     | the current `ForgeState`; may start a background check (Checks and triggers). While the Forge is not enabled: a state with `enabled` false, `hostDeviceID` = this Main, `appDocsHash` = `DocsHash.embedded`, `items` empty and the other fields nil | —                                                                                                    |
| `forge.feedback`   | Feedback intake                                                                                                                                                                                                                                     | `unavailable`, `locked`, `badRequest`, `notFound` and `conflict` (the screenshot upload), `internal` |
| `forge.regenerate` | answers `{}` after the configuration checks and the conflict check, then works in the background: a check of its own (Checks and triggers), then Retry when the cycle is `failed`, else the `manual` trigger                                        | `unavailable`, `conflict` `A regeneration is already in progress (<state>).`                         |
| `forge.retry`      | answers `{}` after the checks (the item must be `failed` and in the current cycle), then works in the background: a check of its own, as for `forge.regenerate`, then Retry                                                                         | `unavailable`, `notFound` `No Forge item for <task id>.`, `conflict` `<task id> has not failed.`     |

Errors of the background work go to the cycle (`failed`) or to `lastError`.

## Startup and shutdown

Enabling (`configure(_:)` with a configuration while not enabled):

1. `forge.json` is loaded (first time in the process); the token is read; `appDocsHash` = `DocsHash.embedded`.
2. `private-terms.txt` is written when it is missing ([Private terms](#private-terms)); a failure is logged and sets
   `lastError`.
3. A cycle in `regenerating` whose session is not `starting`, `running` or `waitingPermission`
   (`host.sessions.sessions(projectID:)`) fails with `Interrupted: the regeneration session is not running.`.
4. A cycle in `regenPushed` or `building` resumes polling (timeouts use the stored dates); a cycle in `released` runs
   Completion from step 2.
5. `forge.changed` is sent; a check runs; the 5-minute timer starts.

Disabling (`configure(nil)`, or `shutdown()` when the host stops) cancels the timer, the polling and every operation of
the queue, waiting or running: the git, gh and check commands they run are killed (`ChildProcess.capture` throws
`CancellationError`, [../claude/cli.md](../claude/cli.md#14-short-commands)), and a method or push tool whose
operation is cancelled fails with `unavailable` `This Main is not the Forge.`. `forge.json` is already written.
`configure(nil)` also sends the `forge.changed` with `enabled` false.

## Concurrency

`ForgeService` is an actor. Every operation that changes state (enabling and disabling, checks, triggers, regeneration
steps, Retry, tool calls, intake, polling steps, Completion, session and task notifications) runs one at a time, in
arrival order, through one internal queue, so no operation interleaves with another across its `await`s.
`config()` and `status()` answer at once from the current state, without waiting for the queue.

The notifications `sessionChanged`, `sessionRemoved`, `taskChanged` and `taskRemoved` add their operation to the
queue and return without waiting for it. `HostService.emit` awaits them, and an operation that starts a session
(Feedback intake, a regeneration step) emits `session.changed` while it holds the queue: waiting there would deadlock.

## Swift API

```swift
// HephHost/Forge — macOS only.

public actor ForgeService {
    /// Created by HostService.init with itself; keeps a strong reference for the app's life, like the other host
    /// services (services/host.md §1).
    public init(host: HostService)
    /// The configuration built from the forge settings, nil when forge.enabled is false. Called by the host at its
    /// start and after every change of a forge setting.
    public func configure(_ config: ForgeConfig?) async
    /// Host stop: disables the Forge.
    public func shutdown() async
    /// host.info `forge`: the configuration while enabled, else nil.
    public func config() -> ForgeConfig?
    // forge.* methods, called by the host. Errors are ProtocolError values.
    /// Never fails: while the Forge is not enabled, the disabled state of Methods.
    public func status() async -> ForgeState
    public func feedback(screenshot: UploadRef?, comment: String, context: FeedbackContext,
                         from deviceID: UUID) async throws -> ForgeFeedbackResult
    public func regenerate() async throws
    public func retry(itemTaskID: String) async throws
    /// MCP tools forge_push_docs and forge_push_regen, through MCPHost: the tool result text, or a thrown ProtocolError
    /// whose message is the error text.
    public func pushDocs(sessionID: UUID) async throws -> String
    public func pushRegen(sessionID: UUID) async throws -> String
    /// Private terms: appSupport.root + "private-terms.txt".
    public nonisolated var privateTermsURL: URL { get }
    /// Private terms: the number of terms the check reads from the file; 0 when it is missing or unreadable.
    public nonisolated func privateTermsCount() -> Int
    /// Private terms: writes the pre-filled file when it is missing, never rewriting it; returns privateTermsURL.
    /// Called at enabling, by the push tools and by Settings "Edit…" (AppModel.editPrivateTerms, ui/shell.md).
    public func preparePrivateTerms() async throws -> URL
    /// Private terms: the pending suggestions, in source order; [] when the file is missing or unreadable.
    public func privateTermSuggestions() async -> [String]
    /// Private terms: adds the term as a line of the file (Settings "Add"). Writes nothing and throws when the file
    /// is missing or cannot be read (the read error) or is not UTF-8 text
    /// (DataError.unreadable("private-terms.txt: the file is not UTF-8 text")).
    public func addPrivateTerm(_ term: String) async throws
    /// Private terms: adds the line "# not private: <term>" to the file (Settings "Dismiss"); throws as addPrivateTerm.
    public func dismissPrivateTerm(_ term: String) async throws
    /// Called by HostService.emit for every session.changed, session.removed, task.changed and task.removed.
    public func sessionChanged(projectID: String, session: SessionInfo) async
    public func sessionRemoved(projectID: String, sessionID: String) async   // the session id's uuidString
    public func taskChanged(projectID: String, task: TaskItem) async
    public func taskRemoved(projectID: String, taskID: String) async
}

/// GitHub REST client of this doc; also used by UpdateService (update.md).
public struct GitHubClient: Sendable {
    public init(repository: String, token: String?)
    public func latestRelease() async throws -> GitHubRelease?          // nil on 404
    public func release(tag: String) async throws -> GitHubRelease?     // nil on 404
    public func runs(headSHA: String) async throws -> [GitHubRun]
    public func run(id: Int) async throws -> GitHubRun
    public func jobs(runID: Int) async throws -> [GitHubJob]
    public func jobLog(jobID: Int) async throws -> String
    /// `gh auth token` (Git operations); nil when unavailable.
    public static func readToken() async -> String?
}

public struct GitHubRelease: Sendable, Decodable {
    public var tagName: String; public var htmlURL: String; public var publishedAt: Date
    public var assets: [GitHubAsset]
}
public struct GitHubAsset: Sendable, Decodable {
    public var name: String; public var browserDownloadURL: String; public var size: Int
}
public struct GitHubRun: Sendable, Decodable {
    public var id: Int; public var runNumber: Int; public var status: String; public var conclusion: String?
    public var htmlURL: String; public var headSHA: String; public var headBranch: String?; public var event: String
    public var path: String
}
public struct GitHubJob: Sendable, Decodable {
    public var id: Int; public var name: String; public var conclusion: String?; public var htmlURL: String
}
public enum GitHubError: Error, Sendable {
    case rateLimited(until: Date)
    case http(status: Int, path: String)
}
/// errorDescription: the messages of GitHub API, "GitHub API rate limit reached; next request at <HH:mm>." (local
/// time) and "GitHub API <path>: HTTP <status>.".
extension GitHubError: LocalizedError {
    public var errorDescription: String? { get }
}

// Internal, used by ForgeService and by the tests (@testable import).

extension ForgeService {
    /// Registering the source project, run by the configuration checks before their first row (ForgeChecks.swift):
    /// returns when `config.sourceProjectID` is hosted on this Main, at once or once <folder> is imported; else throws
    /// ProtocolError(.unavailable, "The Forge source project <ID> is not on this Main. <text of the failed step>").
    /// `environment`: the environment of its git commands, LoginEnvironment.shared.environment() in the configuration
    /// checks; the tests pass the environment of a GitSandbox (testing.md). The Forge need not be enabled.
    func registerSourceProject(_ config: ForgeConfig, environment: [String: String]) async throws
}

/// Runs the git commands of Git operations in a repository root with an environment.
struct ForgeGit: Sendable {
    /// Keeps `environment` with `GIT_NO_REPLACE_OBJECTS` = `1` added.
    init(executable: String, repositoryRoot: URL, environment: [String: String])
    /// `git -c core.hooksPath=/dev/null -c core.fsmonitor=false <arguments>` with `GIT_NO_REPLACE_OBJECTS=1`. A non-zero
    /// exit whose status is not in `allowedExitCodes`, or the timeout, throws
    /// ProtocolError(.internal, "git <subcommand> failed: <line>").
    func run(_ arguments: [String], timeout: Duration, allowedExitCodes: Set<Int32> = [0]) async throws
        -> CapturedOutput
    /// Docs hash of a revision (Git operations).
    func docsHash(of revision: String) async throws -> String
}

/// Steps 2 to 7 of the push tools (MCP tools), on a repository whose origin and branch are given, and step 4 of
/// Checks and triggers.
struct ForgePushGate: Sendable {
    enum Tool: String, Sendable { case pushDocs = "forge_push_docs", pushRegen = "forge_push_regen" }
    /// A refused push: `message` is the tool's error text.
    struct Refusal: Error, Sendable, Equatable { var message: String }
    /// A push: the full SHA pushed and the base of step 2.
    struct Pushed: Sendable, Equatable { var commit: String; var base: String }
    /// `termsFile`: passed as HEPHAESTUS_PRIVATE_TERMS (the caller writes it first when it is missing).
    init(git: ForgeGit, branch: String, termsFile: URL)
    /// Throws Refusal, whose message is also the text of git and bash failures. `trustedHead`: the commit whose
    /// scripts/check-public.sh step 6 runs; `<base>` when nil.
    func push(_ tool: Tool, trustedHead: String? = nil) async throws -> Pushed
    /// Checks and triggers step 4: nil when the commits of `head` that `trusted` does not have are clean (`ci skip
    /// marker` findings alone count as clean), else the finding lines; throws Refusal (its message is the reason) when
    /// the check cannot run.
    func checkPushedElsewhere(from trusted: String, to head: String) async throws -> String?
}

/// Private terms: the pre-filled file, the suggestions and the count.
enum PrivateTerms {
    /// The header and the suggested terms, without the excluded ones (Private terms).
    static func content(suggestions: [String], owner: String) -> String
    /// Runs the sources of Private terms; `devices`: the registry's records; `projects`: the other projects of this
    /// Main, without the source project and its sub projects.
    static func suggestions(devices: [DeviceRecord], projects: [HostedProject], environment: [String: String],
                            git: String?, gh: String?) async -> [String]
    /// The suggestions that `content` holds neither as a term nor in a "# not private: <term>" line, its lines read as
    /// the check reads them, compared by their UTF-8 bytes with the case of ASCII letters only ignored, in their order.
    static func pending(_ suggestions: [String], in content: String) -> [String]
    /// `content` with `line` added at its end, after a line feed when its last byte is not one.
    static func appending(_ line: String, to content: String) -> String
    /// The number of terms the check reads from the file at `url`; 0 when it is missing, unreadable or not UTF-8.
    static func count(at url: URL) -> Int
}
```

`GitHub*` types decode GitHub's snake_case JSON with explicit `CodingKeys` (`tag_name`, `html_url`, `published_at`,
`browser_download_url`, `run_number`, `head_sha`, `head_branch`) and ISO 8601 dates without fractional seconds.

Host members used ([../services/host.md](../services/host.md)): `registry.hosted(_:)` (root, project file),
`registry.checkWritable(_:)` (the source project or one of its ancestors migrating), `tasks` (`create`, `addComment`,
`update`), `sessions` (`SessionService.start(_:)`, `sessions(projectID:)`), `emit(_:)`, `mesh.localDevice()`,
`mesh.snapshot()` (also the devices of Private terms), `registry.all()` and `registry.descendants(of:)` (the projects of
Private terms), `hostInfo.claudePath` (nil: the Claude CLI is not available) and `hostInfo.gitAvailable`,
`projects.importFolder(_:)` and `settings()` (`projectsFolderURL`) for Registering the source project, and the host's
`appSupport`.

The files of this doc:

| File                  | Holds                                                                                                                                                                                                                                       |
|-----------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `ForgeService.swift`  | the actor and its state, Forge host configuration, MCP tools (steps 1 and 8, calling `ForgePushGate`), Broadcasting, Methods, Startup and shutdown, Concurrency                                                                             |
| `ForgeChecks.swift`   | `extension ForgeService`: Configuration checks and Registering the source project (`registerSourceProject(_:environment:)`)                                                                                                                 |
| `ForgeFeedback.swift` | `extension ForgeService`: Feedback intake, Items and the join rule                                                                                                                                                                          |
| `ForgeCycles.swift`   | `extension ForgeService`: Cycles (regeneration step, session observation, Retry) and Completion                                                                                                                                             |
| `ForgePolling.swift`  | `extension ForgeService`: Checks and triggers, Polling                                                                                                                                                                                      |
| `ForgeStore.swift`    | `extension ForgeService`: loading and writing `forge.json`                                                                                                                                                                                  |
| `ForgeGit.swift`      | `ForgeGit`: Git operations and the docs hash of a revision                                                                                                                                                                                  |
| `ForgePushGate.swift` | `ForgePushGate`: steps 2 to 7 of MCP tools, step 4 of Checks and triggers                                                                                                                                                                   |
| `PrivateTerms.swift`  | `PrivateTerms` and the `privateTermsURL`, `privateTermsCount()`, `preparePrivateTerms()`, `privateTermSuggestions()`, `addPrivateTerm(_:)` and `dismissPrivateTerm(_:)` members of `ForgeService` (`extension ForgeService`): Private terms |
| `GitHubClient.swift`  | `GitHubClient` and the `GitHub*` types of the Swift API (GitHub API, except Polling)                                                                                                                                                        |

The actor's stored state is `internal`, so that the extensions in the other files can use it.

## Depends on

| Name                                                                                                                                                                                               | Defined in                                                                                     |
|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| `ForgeConfig` (`publicRepository`), `ForgeRelease`, `FeedbackContext`, `FeedbackSelection`, `ForgeFeedbackParams`, `ForgeFeedbackResult`, `ForgeRetryParams`, `ForgeChangedPayload`, `SessionInfo` | [../protocol/types.md](../protocol/types.md), [../protocol/methods.md](../protocol/methods.md) |
| `ProtocolError`                                                                                                                                                                                    | [../protocol/envelope.md](../protocol/envelope.md)                                             |
| `HostService` (`tasks`, `sessions`, `registry`, `mesh`, `hostInfo`, `emit`, `appSupport`), its calls of `configure`, `shutdown`, `config`, the `forge.*` functions and the notifications           | [../services/host.md](../services/host.md)                                                     |
| `UploadRef` (the feedback screenshot)                                                                                                                                                              | [../protocol/types.md](../protocol/types.md#uploadref)                                         |
| `UploadService.check` (`host.uploads`)                                                                                                                                                             | [../services/files.md](../services/files.md#7-uploads)                                         |
| `SessionService`, `SessionStart`, `ChildProcess`, `CapturedOutput`, `LoginEnvironment`, the permission rules and environment of the sessions of 3.5                                                | [../claude/cli.md](../claude/cli.md#35-sessions-in-the-public-repository)                      |
| `RegenerationContext`, `RegenerationItem`, `FailedCIRun`, `FailedCIJob`, the feedback and regeneration prompts                                                                                     | [../claude/prompts.md](../claude/prompts.md)                                                   |
| `forge_push_docs`, `forge_push_regen`, `MCPHost`                                                                                                                                                   | [../claude/mcp.md](../claude/mcp.md)                                                           |
| `scripts/check-public.sh` (options, output, exit status), the hooks, the private terms format, "If personal data was pushed"                                                                       | [../public-repository.md](../public-repository.md)                                             |
| the placeholders                                                                                                                                                                                   | [../general.md](../general.md#placeholders)                                                    |
| the `public-check` and `public-check-terms` jobs                                                                                                                                                   | [ci.md](ci.md)                                                                                 |
| `DeviceRecord` (names and addresses of Private terms)                                                                                                                                              | [../protocol/types.md](../protocol/types.md)                                                   |
| `HostedProject`, `registry.all()`, `registry.descendants(of:)` (the projects of Private terms)                                                                                                     | [../services/host.md](../services/host.md#6-projectregistry)                                   |
| task creation, comments, attachments, statuses                                                                                                                                                     | [../data/task-yml.md](../data/task-yml.md)                                                     |
| `DeviceSettings.forge`, `DeviceSettings.projectsFolderURL`, `AppSupport`, `JSONFile`, `AtomicFile`, `private-terms.txt` in Application Support                                                     | [../data/app-storage.md](../data/app-storage.md)                                               |
| the Forge pane writing the `forge` settings, its Source project and Private terms rows                                                                                                             | [../ui/settings.md](../ui/settings.md)                                                         |
| `DocsHash`                                                                                                                                                                                         | [generation.md](generation.md)                                                                 |
| `Log.host`                                                                                                                                                                                         | [../architecture.md](../architecture.md#logging)                                               |
| the repository's `.gitignore` (it ignores `.hephaestus/`)                                                                                                                                          | [../architecture.md](../architecture.md)                                                       |
| the default device names                                                                                                                                                                           | [../devices/roles.md](../devices/roles.md)                                                     |
| `host.projects.importFolder(_:)` (`projects.import`) and `host.settings()`, used to register the source project                                                                                    | [../services/host.md](../services/host.md#74-projectsimport)                                   |
| `ProjectsImportParams`                                                                                                                                                                             | [../protocol/methods.md](../protocol/methods.md#projectsimport)                                |
| `ProjectFile.load(projectRoot:)` (the identifier of an existing project.yml)                                                                                                                       | [../data/project-yml.md](../data/project-yml.md)                                               |
| Add Existing Folder…                                                                                                                                                                               | [../ui/overview.md](../ui/overview.md#add-existing-folder)                                     |
| `GitSandbox` (the tests of Registering the source project)                                                                                                                                         | [../testing.md](../testing.md#support-files)                                                   |
