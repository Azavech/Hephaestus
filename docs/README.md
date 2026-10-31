# Hephaestus documentation

**Public repository.** The repository `Azavech/Hephaestus` is public: nothing personal ever enters it, in files, file
names, commit messages, commit author and committer names, branch or tag names, release notes or CI output, except the
e-mail of the user's own git identity, which each of their commits carries. The rule, what counts as personal data and
the placeholders: [general.md](general.md#public-repository-no-personal-data). How it is enforced:
[public-repository.md](public-repository.md).

This folder is the specification of Hephaestus. The code of the repository is generated from it, and nothing goes into
the code that is not written here ([general.md](general.md)). [prompt.md](prompt.md) is the original request, verbatim;
the other files refine it.

## Reading order

1. [general.md](general.md), then [public-repository.md](public-repository.md), then [prompt.md](prompt.md).
2. [app.md](app.md): what the app is, platforms, glossary.
3. [architecture.md](architecture.md): repository, modules, Xcode project, process and concurrency model, data flow.
4. [devices/roles.md](devices/roles.md), [devices/mesh.md](devices/mesh.md), [devices/migration.md](devices/migration.md).
5. [protocol/envelope.md](protocol/envelope.md), [protocol/types.md](protocol/types.md),
   [protocol/methods.md](protocol/methods.md), [protocol/events.md](protocol/events.md).
6. [data/project-yml.md](data/project-yml.md), [data/task-yml.md](data/task-yml.md), [data/sessions.md](data/sessions.md),
   [data/app-storage.md](data/app-storage.md).
7. [services/host.md](services/host.md), then [services/files.md](services/files.md), [services/runs.md](services/runs.md),
   [services/search.md](services/search.md), [services/bundles.md](services/bundles.md).
8. [claude/cli.md](claude/cli.md), [claude/mcp.md](claude/mcp.md), [claude/prompts.md](claude/prompts.md),
   [claude/skills.md](claude/skills.md).
9. [client/workspace.md](client/workspace.md).
10. [ui/shell.md](ui/shell.md), then the other `ui/` files in the order of the index.
11. [forge/feedback.md](forge/feedback.md), [forge/pipeline.md](forge/pipeline.md), [forge/generation.md](forge/generation.md),
    [forge/ci.md](forge/ci.md), [forge/update.md](forge/update.md).
12. [testing.md](testing.md).

## Index

| File                                         | Subject                                                                                                                |
|----------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| [README.md](README.md)                       | This index, the reading order, how the docs drive the build                                                            |
| [general.md](general.md)                     | The public repository rule first, then the rules: docs are the source of truth, `files:` headers, aligned tables       |
| [public-repository.md](public-repository.md) | Enforcement of the public repository rule: check script, git hooks, Forge push gate, private terms, CI check           |
| [prompt.md](prompt.md)                       | The original request, verbatim                                                                                         |
| [app.md](app.md)                             | What Hephaestus is, platforms, device roles, project contents, UI adaptation, glossary                                 |
| [architecture.md](architecture.md)           | Repository layout, modules, Package.swift, Xcode project, Info.plist, assets, process, concurrency, logging            |
| [client/workspace.md](client/workspace.md)   | HephClient: connections to Mains, mirrored state, presence merge, selection, request API, transfers, events            |
| [testing.md](testing.md)                     | Test targets, test cases, fixtures, how tests run locally and in CI                                                    |
| [devices/roles.md](devices/roles.md)         | Device identity, Main and remote roles, the Main toggle                                                                |
| [devices/mesh.md](devices/mesh.md)           | Mesh credentials, TLS-PSK WebSocket transport, Bonjour, pairing, registry, revoke and rekey, presence, Main↔Main links |
| [devices/migration.md](devices/migration.md) | Moving a project from one Main to another, its journal and the recovery after a restart                                |
| [protocol/envelope.md](protocol/envelope.md) | Framing, envelope, handshake, errors, dates and binary data, subscriptions, delivery, timeouts                         |
| [protocol/types.md](protocol/types.md)       | Every shared wire type with its fields, Swift names and JSON names                                                     |
| [protocol/methods.md](protocol/methods.md)   | Every method: params, result, errors, side effects, events emitted                                                     |
| [protocol/events.md](protocol/events.md)     | Every event: params, who emits it, who receives it                                                                     |
| [data/project-yml.md](data/project-yml.md)   | `.hephaestus/project.yml`                                                                                              |
| [data/task-yml.md](data/task-yml.md)         | `.hephaestus/tasks/<TASK-ID>.yml` and task attachments                                                                 |
| [data/sessions.md](data/sessions.md)         | Session metadata and event files under `.hephaestus/sessions/`                                                         |
| [data/app-storage.md](data/app-storage.md)   | Application Support files, `settings.json` keys, Keychain items, per-window UI state                                   |
| [claude/cli.md](claude/cli.md)               | Locating and running the Claude CLI, the stream-json session process, permissions, child processes                     |
| [claude/mcp.md](claude/mcp.md)               | The Hephaestus MCP server and its tools                                                                                |
| [claude/prompts.md](claude/prompts.md)       | The full texts of every system prompt and generated first message                                                      |
| [claude/skills.md](claude/skills.md)         | The skills library, session plugin folders, skills sync between Mains                                                  |
| [services/host.md](services/host.md)         | HostService: startup and shutdown, request routing, project registry, file watching, peer links                        |
| [services/files.md](services/files.md)       | File operations, path safety, revisions, ignore rules, atomic writes, attachments, uploads                             |
| [services/runs.md](services/runs.md)         | Run configurations and their execution on the Main                                                                     |
| [services/search.md](services/search.md)     | Search matcher, Main search service, client fan-out                                                                    |
| [services/bundles.md](services/bundles.md)   | Task bundles: bundle files, worktrees, the coordinator and its parallel task sessions                                  |
| [ui/shell.md](ui/shell.md)                   | Scenes, windows, toolbar, path bar, sidebar, layouts per device, shortcuts, banners, app wiring                        |
| [ui/onboarding.md](ui/onboarding.md)         | First launch: become a Main or join a mesh                                                                             |
| [ui/settings.md](ui/settings.md)             | Settings screens                                                                                                       |
| [ui/devices.md](ui/devices.md)               | Devices screen: presence, rename, revoke, pairing                                                                      |
| [ui/search.md](ui/search.md)                 | Search UI                                                                                                              |
| [ui/overview.md](ui/overview.md)             | Project Overview, sub projects, Move to…                                                                               |
| [ui/tasks.md](ui/tasks.md)                   | Task list and task detail, comments, attachments, bundles                                                              |
| [ui/sessions.md](ui/sessions.md)             | Session chat UI, permission cards, the task Claude section                                                             |
| [ui/runs.md](ui/runs.md)                     | Runs screen and run output                                                                                             |
| [ui/skills.md](ui/skills.md)                 | Skills screen                                                                                                          |
| [ui/code.md](ui/code.md)                     | Code screen: file browser and editor tabs                                                                              |
| [ui/editor.md](ui/editor.md)                 | HephEditor: text views, gutter, syntax highlighting grammars                                                           |
| [ui/docs.md](ui/docs.md)                     | Docs browser, viewer and editor                                                                                        |
| [ui/markdown.md](ui/markdown.md)             | HephMarkdown renderer                                                                                                  |
| [ui/web.md](ui/web.md)                       | Web tabs                                                                                                               |
| [ui/media.md](ui/media.md)                   | Image viewer, attachment chips, Quick Look, large files, attachment picking                                            |
| [ui/forge.md](ui/forge.md)                   | Forge screen                                                                                                           |
| [forge/feedback.md](forge/feedback.md)       | Feedback capture and sheet                                                                                             |
| [forge/pipeline.md](forge/pipeline.md)       | Forge host, pipeline state machine, git and GitHub operations                                                          |
| [forge/generation.md](forge/generation.md)   | The regeneration procedure, the docs hash, the repository's CLAUDE.md                                                  |
| [forge/ci.md](forge/ci.md)                   | The GitHub Actions workflow and the scripts                                                                            |
| [forge/update.md](forge/update.md)           | macOS self-update                                                                                                      |

## How the docs drive the build

- **Mapping.** A doc that governs code starts with a `files:` list of source files (paths from the repository root),
  followed by a `---` line. Every source file of the repository is listed by exactly one doc; the test files are listed
  by [testing.md](testing.md). Docs without a `files:` list (this file, [app.md](app.md), [prompt.md](prompt.md),
  [general.md](general.md)) govern no code. [public-repository.md](public-repository.md) governs
  `scripts/check-public.sh` and the hooks of `.githooks/`.
- **Docs first.** A change to the app is a change to the docs, committed first. The files listed by the changed docs
  are then regenerated by the procedure of [forge/generation.md](forge/generation.md), either by the Forge's
  regeneration session ([forge/pipeline.md](forge/pipeline.md)) or by Claude following the same procedure by hand.
- **Docs hash.** `scripts/docs-hash.sh` prints the hash of `docs/`
  ([forge/generation.md](forge/generation.md#12-scriptsdocs-hashsh)). A regeneration commit writes that hash to
  `App/DocsHash.txt` together with the regenerated code, so `App/DocsHash.txt` names the documentation the code was
  generated from. The app bundles the file and shows it in About and in the Forge screen.
- **CI builds only in-sync code.** The `docs-sync` job of [forge/ci.md](forge/ci.md) compares the hash of `docs/` with
  `App/DocsHash.txt`. When they differ, the docs are ahead of the code: tests, builds and releases are skipped until a
  regeneration commit brings the code in sync. Only in-sync code is tested, built and released.
- **Feedback loop.** Feedback from any device becomes a task and a Claude discussion that edits the docs
  ([forge/feedback.md](forge/feedback.md)). The Forge checks the docs commits for personal data and pushes them
  ([public-repository.md](public-repository.md#forge-push-gate)); the pushed docs are regenerated into code, which is
  checked and pushed the same way; CI checks again, builds and releases it, and every Mac updates and restarts itself
  ([forge/update.md](forge/update.md)).
