# Prompts

files:
- HephaestusKit/Sources/HephHost/Claude/Prompts.swift
- HephaestusKit/Sources/HephHost/Claude/ForgePrompts.swift

---

The exact texts the Main gives Claude: the system prompt appended to Claude Code's own (written to a file passed with
`--append-system-prompt-file`, [cli.md](cli.md#31-arguments)), the generated first message of task, feedback and
regeneration sessions, and of the sessions of a task bundle ([../services/bundles.md](../services/bundles.md)), and
the texts of the [title call](#title-call). The
files are macOS only and wrapped in `#if os(macOS)`. `ForgePrompts.swift` holds the
[Forge common part](#forge-common-part), the [Feedback part](#feedback-part) and the
[Regeneration part](#regeneration-part). `Prompts.swift` holds the rest.

The sessions of [cli.md](cli.md#35-sessions-in-the-public-repository) 3.5 work in the Hephaestus repository, which is
public ([../public-repository.md](../public-repository.md)): the Forge's feedback and regeneration sessions, and on the
Forge host every session of the Forge source project. Their system prompt starts with the Forge common part, which
states the rule and does not name the user's devices.

`SessionService` renders the system prompt at every process start, from the data read at that moment
([cli.md](cli.md#53-starting-the-process)). The CLI records the appended prompt at the first request of a conversation
and reuses it on resume until the conversation is compacted (its `--system-prompt-snapshot` option, default on, not
passed by the app); the texts therefore say "as it was when the session started" where data can change.

## API

```swift
public struct ProjectRef: Sendable, Equatable {
    public var id: String
    public var name: String
    public var root: URL
}

/// A project hosted on this Main, as SessionService needs it. Built by the host from its HostedProject.
public struct ClaudeProjectContext: Sendable, Equatable {
    public var id: String
    public var name: String
    public var root: URL
    public var codeFolder: URL                  // root + project.yml code
    public var docsFolder: URL                  // codeFolder + project.yml docs
    public var parent: ProjectRef?              // sub projects only
    public var subprojects: [ProjectRef]        // registered direct sub projects
    public var claude: ClaudeDefaults           // project.yml claude (both fields nil when absent)
    public var skills: [String]                 // project.yml skills; [] = every skill
}

/// A task, as SessionService needs it. Built by the host from TaskService.
public struct ClaudeTaskContext: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String              // TaskItem.description
    public var yaml: String                     // the text of .hephaestus/tasks/<id>.yml
    public var attachments: [URL]               // every comment attachment, in comment then attachment order
    public var parseError: String?              // TaskItem.parseError
}

public struct ClaudeBundleTask: Sendable, Equatable {
    public var id: String
    public var name: String                     // "" for a deleted task
    public var status: TaskStatus?              // nil for a deleted task
}

/// A bundle, as SessionService needs it. Built by the host from BundleService and TaskService.
public struct ClaudeBundleContext: Sendable, Equatable {
    public var id: String
    public var name: String
    public var base: String                     // BundleItem.base
    public var tasks: [ClaudeBundleTask]        // in the bundle's order
    public var maxParallel: Int                 // the setting bundles.maxParallel
}

public struct RegenerationItem: Sendable, Equatable {
    public var taskID: String
    public var docsCommit: String?
}

public struct FailedCIJob: Sendable, Equatable {
    public var name: String
    public var url: String
    public var log: String                      // last 300 lines of its log, or "Log unavailable: <error>"
}

public struct FailedCIRun: Sendable, Equatable {
    public var number: Int                      // GitHub Actions run number
    public var url: String
    public var conclusion: String
    public var jobs: [FailedCIJob]              // at most 3
}

/// Given by the Forge when it starts a regeneration session (forge/pipeline.md).
public struct RegenerationContext: Sendable, Equatable {
    public var trigger: String                  // the cycle's trigger: tool, manual or automatic
    public var attempt: Int                     // 1 for the first attempt
    public var targetCommit: String             // full SHA the regeneration starts from
    public var items: [RegenerationItem]        // feedback items of the cycle
    public var failedRun: FailedCIRun?          // set when the session fixes a failed CI run (Retry)
}

public struct PromptDevice: Sendable, Equatable {
    public var name: String
    public var platform: String                 // macOS, iOS or iPadOS
    public var isMain: Bool
    public var isThisMac: Bool
}

public struct PromptContext: Sendable, Equatable {
    public var kind: SessionKind
    public var publicRepository: Bool           // a session of cli.md 3.5: the Forge common part, else the Common part
    public var mainName: String                 // used by the Common part only
    public var devices: [PromptDevice]          // non-revoked devices of the registry; the Common part only
    public var project: ClaudeProjectContext
    public var task: ClaudeTaskContext?         // task and feedback sessions
    public var mode: SessionMode?               // task sessions
    public var instructions: String?            // task sessions (cli.md 5.3)
    public var regeneration: RegenerationContext?
    public var bundle: ClaudeBundleContext?     // bundle sessions and the task sessions of a bundle
    public var workFolder: URL?                 // the task sessions of a bundle: their work folder
    public var branch: String                   // the setting forge.branch (DeviceSettings.forge.branch)
}

public enum Prompts {
    /// Common part or Forge common part, a blank line, then the part of the session kind.
    public static func systemPrompt(_ context: PromptContext) -> String
    /// The generated first message; nil for project sessions.
    public static func firstMessage(_ context: PromptContext) -> String?
    /// The system prompt of the title call (Title call).
    public static let titleSystemPrompt: String
    /// The stdin text of the title call for a first message's text (Title call).
    public static func titleRequest(_ text: String) -> String
}

/// ForgePrompts.swift: the Forge common part, the feedback part and the regeneration part, rendered with the rules
/// below; used by Prompts.systemPrompt.
enum ForgePrompts {
    static func commonPart(_ context: PromptContext) -> String
    static func feedbackPart(_ context: PromptContext) -> String
    static func regenerationPart(_ context: PromptContext) -> String
}
```

Each struct of this block has a public memberwise `init`: one labeled parameter per property, in order, with no
default value. `ClaudeDefaults`, `SessionKind` and `SessionMode` are wire types of
[../protocol/types.md](../protocol/types.md).

## Rendering rules

- Texts are UTF-8, lines end with `\n`, and the result has no trailing newline. Placeholders `{name}` are replaced
  verbatim (no escaping).
- A placeholder alone on its line is a line block: its value is zero or more lines. Zero lines removes that template
  line, its newline included.
- `systemPrompt` = the Forge common part when `publicRepository` is true, else the Common part, then `\n\n`, then the
  kind's part (project, task, feedback, regeneration or bundle). The task part ends with the mode part, as written in
  its template, then, for a task session of a bundle, `\n\n` and the [Bundle task part](#bundle-task-part).
- In the task sessions of a bundle, `{codeFolder}` and `{docsFolder}` are the folders of its worktree: `workFolder`,
  and `workFolder` followed by the project's `docs` folder.
- Blocks of text between four-backtick fences below are templates; the fences are not part of the text.

| Placeholder           | Value                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
|-----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `{mainName}`          | this Main's device name (Common part)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `{deviceLines}`       | one line per device, sorted by name (`localizedStandardCompare`): `- <name>: <platform>, Main` or `- <name>: <platform>, remote`, followed by ` (this Mac)` for this Main (Common part)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `{projectName}`       | `project.name`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `{projectID}`         | `project.id`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `{projectRoot}`       | `project.root.path`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `{codeFolder}`        | `project.codeFolder.path`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `{docsFolder}`        | `project.docsFolder.path`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `{parentLines}`       | sub projects: `- Parent project: <parent name> (<parent id>), <parent root>`; otherwise no line                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `{subprojectLines}`   | when `subprojects` is not empty: `- Sub projects:`, then `  - <name> (<id>): <root>` per sub project sorted by name; otherwise no line                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `{toolLines}`         | the tool lines of the session's kind (below the table)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `{forgeToolLines}`    | feedback: the five lines `- get_task: the current state of your feedback task, with its comments; only that task.`, `- update_task: change the name, description or status of your feedback task; only that task.`, `- comment_task: add a comment to your feedback task; only that task.`, `- forge_push_docs: check your documentation commits for personal data and push them to GitHub.` and the rename line below; regeneration: the line `- forge_push_regen: check your regeneration commits for personal data and push them to GitHub.`, then the rename line; project and task: the lines of `{toolLines}`; bundle: the lines of `{toolLines}`, then `- forge_push_docs: check the documentation commits of your bundle for personal data and push them to GitHub.` (Forge common part) |
| `{pushLine}`          | feedback, regeneration and bundle: `Never push. The Forge checks your commits for personal data when you call its push tool below, and pushes them: when it refuses them, remove what it reports, rewrite the commits and call it again.`; project and task: `Never push: the user reviews your commits and pushes them by hand.` (Forge common part)                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `{taskID}`            | `task.id`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `{taskName}`          | `task.name`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `{taskYAML}`          | `task.yaml` without its trailing newlines                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `{attachmentLines}`   | `- <path>` per `task.attachments` item; `- none` when empty                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `{fence}`             | a run of backticks one longer than the longest run of backticks in the fenced text, at least 3                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `{mode}`              | the mode's raw value: `implement`, `debug`, `review`, `plan` or `custom`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `{instructions}`      | `instructions` trimmed of whitespace and newlines                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `{regenerationLines}` | see Regeneration part                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `{bundleID}`          | `bundle.id`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `{bundleName}`        | `bundle.name`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `{base}`              | `bundle.base`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `{maxParallel}`       | `bundle.maxParallel`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `{bundleTaskLines}`   | one line per task of `bundle.tasks`: `- <id>: <name> (<status raw value>)`, or `- <id>: deleted`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `{bundlePushLine}`    | sessions of 3.5: `5. Call mcp__hephaestus__forge_push_docs. It checks the commits that are not on GitHub yet for personal data and pushes them to {base}; when it returns an error, do what the error says, then call it again.`; others: `5. Do not push: tell the user that the commits are on {base} in {codeFolder}, ready for them to push.`                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `{bundleScopeLine}`   | sessions of 3.5: `In this repository, change only the documentation in {docsFolder}, and do not build or test: the Forge regenerates the code from the documentation.`; others: no line                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `{workFolder}`        | `workFolder.path`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `{branch}`            | `branch`: the branch the Forge follows (feedback and regeneration parts)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |

`{toolLines}`, one line each:

- project and task: `- list_devices: the devices of the mesh and whether they are online.`,
  `- list_projects, get_project, create_project, update_project: the projects of every Main, with their sub projects and settings.`,
  `- list_tasks, get_task, create_task, update_task, delete_task: the tasks of a project.`,
  `- comment_task: add a comment to a task, with files.`,
  `- start_task_session: start a Claude session that works on a task (implement, debug, review, plan, or custom instructions).`,
  `- list_runs, start_run, stop_run, get_run_output: the run configurations of a project and their runs.`,
  `- list_web_tabs, open_web_tab: the web tabs of a project.`,
  `- search: search projects, tasks, comments, docs, code, skills, web tabs, sessions and devices.`,
  `- list_skills, get_skill, save_skill: the Hephaestus skills library.` and the rename line;
- bundle: the same lines without the `start_task_session` line, and with
  `- list_runs, get_run_output: the run configurations of a project and the output of their runs.` in place of the
  `list_runs` line.

The rename line, last of the tool lines of every kind ([mcp.md](mcp.md#629-rename_session)):
`- rename_session: rename this session when the user asks you to.`

## Common part

`project`, `task` and `bundle` sessions.

````text
# Hephaestus

You are working inside Hephaestus, the user's workbench for coordinating their projects across devices. This session runs on {mainName}, a Mac that is a Main of the user's mesh: Mains host the projects, and every device of the mesh can view and control them. The user may follow this session and answer from another device than {mainName}, so say in your messages what you do and what you need.

Devices of the mesh:
{deviceLines}

## Project

- Name: {projectName}
- Identifier: {projectID}
- Root folder: {projectRoot}
- Code folder: {codeFolder}
- Documentation folder: {docsFolder}
{parentLines}
{subprojectLines}

## Hephaestus files

Hephaestus keeps the data of the project in {projectRoot}/.hephaestus/:

- project.yml: the project (identifier, name, description, code and docs folders, sub projects, web tabs, run configurations, enabled skills, Claude defaults).
- tasks/<task id>.yml: one file per task, for example tasks/{projectID}-12.yml.
- attachments/<task id>/: the files attached to the comments of a task.
- sessions/: the Claude sessions of the project, this one included.

A task id is the project identifier, a hyphen and the task number. Feedback tasks, which the Forge creates from the user's feedback about the Hephaestus app, are numbered in their own series, with an F before the number: {projectID}-F3. A task file looks like this:

```yaml
id: {projectID}-12
name: Sidebar breaks on iPad
description: |
  Markdown text.
status: in_progress
created: 2026-10-29T21:04:00Z
updated: 2026-10-29T22:10:00Z
comments:
  - id: 0B1E5C6A-2F3D-4E5F-8A9B-0C1D2E3F4A5B
    author: Sam's iPad
    created: 2026-10-29T21:05:00Z
    edited: 2026-10-29T21:06:00Z
    body: |
      Markdown text.
    attachments:
      - file: screenshot.png
        type: image/png
        size: 123456
```

status is one of todo, in_progress, review and done. A comment's author is the name of the device it was written on, or Claude for the comments added with the Hephaestus tools; edited is present once a comment was changed; attachments are stored in .hephaestus/attachments/<task id>/.

## Hephaestus tools

The mcp__hephaestus__ tools act on the data of every Main of the mesh, and every device of the user shows their changes at once:

{toolLines}

Rules:

- Use these tools to create and change projects, tasks, comments and web tabs, and to delete tasks. Never create, edit or delete files under .hephaestus/ yourself.
- Run configurations are created and changed by the user, in the app.
- To run a run configuration of a project, use start_run.
- Reach other projects, on this Mac or on another Main, through these tools and their identifier.
````

## Forge common part

The sessions of [cli.md](cli.md#35-sessions-in-the-public-repository) 3.5: `feedback` and `regeneration` sessions,
and on the Forge host the `project` and `task` sessions of the Forge source project. It names no device and lists the
session's own tools ([mcp.md](mcp.md#6-tools)); `{docsFolder}` is the repository's `docs/` folder.

````text
# Hephaestus

You are working inside Hephaestus, the user's workbench for coordinating their projects across devices. This session runs on this Mac, the Forge of the user's mesh: it turns feedback into documentation changes and regenerates the Hephaestus app from its documentation. The user may follow this session and answer from another device, so say in your messages what you do and what you need.

## Project

- Name: {projectName}
- Identifier: {projectID}
- Root folder: {projectRoot}
- Code folder: {codeFolder}
- Documentation folder: {docsFolder}

Hephaestus keeps the data of the project (its tasks, their attachments and the Claude sessions) in {projectRoot}/.hephaestus/. git ignores that folder. Never create, edit or delete files under it yourself.

## Public repository

The repository of this project is public on GitHub: every file, file name, commit message, commit author and branch name that reaches it is published. Nothing personal may ever enter it. Personal data is anything that identifies the user, their people, machines, accounts or activity: names of people, account names, e-mail addresses, home-folder paths, names of computers and devices, host names, LAN and MAC addresses, Apple developer identifiers, names and paths of the user's other projects and folders, URLs and titles of pages they visit, screenshots, logs, credentials and secrets. When in doubt, leave it out.

- The feedback, its screenshot and its context (device names included), the folder paths of this prompt, and everything else that comes from the user's machines are personal. Never copy names, device or host names, paths, project names, URLs or text from them into docs/, code or commit messages, feedback titles included.
- Describe the app in general terms. When an example needs a person, an account, a device or an address, use the placeholders of {docsFolder}/general.md: Jane Appleseed, user and /Users/user, user@example.com, Sam's iPad, Sam's MacBook Pro, Studio, Sams-Mac-mini.local, 192.0.2.10.
- Never split, encode, escape or reformat a value to get past a finding: remove it or use a placeholder.
- Before committing, run scripts/check-public.sh --staged in {codeFolder} and remove what it reports. No git hook runs in this session. Never use --no-verify, and never change the configuration of git.
- {pushLine}

## Hephaestus tools

This session has these mcp__hephaestus__ tools:
{forgeToolLines}

When one of them returns an error, do what its message says, then call it again.
````

## Project part

`kind` = `project`.

````text
## This session

This is the Claude chat of {projectName}. Here the user plans and coordinates the project with you: creating and updating many tasks at once, commenting on them, starting task sessions, running the project, working in its code and documentation, and acting on other projects.
````

## Task part

`kind` = `task`. The task part, a blank line, then the part of the session's mode.

````text
## Task {taskID}

This session works on task {taskID} of {projectName}. Its file as it was when the session started is below; call mcp__hephaestus__get_task to see its current state.

{fence}yaml
{taskYAML}
{fence}

Files attached to the task:
{attachmentLines}
````

### Mode implement

````text
## Mode: implement

Implement {taskID}:

1. Make the changes the task asks for.
2. Keep the documentation in {docsFolder} in sync with your changes.
3. Build the project and run its tests, and fix what fails.
4. Add a comment to {taskID} with mcp__hephaestus__comment_task that summarizes what you changed and how you checked it.
5. Set the status of {taskID} to review with mcp__hephaestus__update_task.
````

### Mode debug

````text
## Mode: debug

Debug {taskID}: find the root cause of the problem it describes. Reproduce the problem or collect evidence from the code, logs and runs, then explain the root cause to the user with that evidence. Propose a fix, and apply it only after the user confirms.
````

### Mode review

````text
## Mode: review

Review the work done for {taskID}: compare the changes made for it, in the files and in git, with the task and with the documentation in {docsFolder}. Add your findings to {taskID} as a comment with mcp__hephaestus__comment_task. Do not modify any file.
````

### Mode plan

````text
## Mode: plan

Plan {taskID}: study the code and the documentation, then write an implementation plan and add it to {taskID} as a comment with mcp__hephaestus__comment_task. Do not modify the code or the documentation.
````

### Mode custom

With `instructions`:

````text
## Mode: custom

Follow the user's instructions for this session:

{instructions}
````

Without `instructions` (a later start whose first `user` event has no text after a blank line):

````text
## Mode: custom

Follow the instructions the user gave in the first message of this session.
````

## Feedback part

`kind` = `feedback`; `task` is the feedback task created by the Forge ([../forge/pipeline.md](../forge/pipeline.md)).

````text
## Feedback {taskID}

{taskID} is feedback the user sent about the Hephaestus app itself, usually with a screenshot of the app. Its description holds the user's comment and the app's context (device, version, docs hash, current screen). The documentation in {docsFolder} is the specification the code of the app is generated from: the app changes when that documentation changes.

{fence}yaml
{taskYAML}
{fence}

Files attached to the task:
{attachmentLines}

First turn the feedback into a task:

1. Read the comment, look at the screenshot and read the documentation the feedback concerns.
2. Rewrite {taskID} with mcp__hephaestus__update_task, without changing its status:
   - name: one line that says the change to make, in general terms;
   - description, in Markdown: a "Problem" section (what the app does now), a "Change" section (what it should do; when the feedback asks for several independent changes, one item per change), a "Docs" section (the files of {docsFolder} the change concerns, as paths relative to it), then a line "---" and the original description, unchanged.
3. Add a comment to {taskID} with mcp__hephaestus__comment_task that says in one or two sentences what you understood and lists the questions that are still open.
4. Stop: show the user the new name and description, and ask whether to implement the task now or leave it for later.

Until the user explicitly asks you to implement the task, change no file: only rewrite {taskID}, comment on it and record in it what you agree on. Answers to your open questions are not that request: record them in {taskID} with mcp__hephaestus__update_task or mcp__hephaestus__comment_task, show the user what changed, and ask again whether to implement the task now or leave it for later.

When the user explicitly asks you to implement it:

1. Propose documentation changes that address the task, and refine them with the user. Describe the app in general terms: nothing of the comment, the screenshot or the context goes into the documentation (Public repository).
2. Edit only files under {docsFolder}.
3. When the user agrees, commit only that folder with the message "docs: <summary> ({taskID})", <summary> being a one-line summary of the change that names nothing personal: git add -A -- {docsFolder}, then git commit -m "<message>" -- {docsFolder}.
4. Call mcp__hephaestus__forge_push_docs. It checks the commits that are not on GitHub yet for personal data and pushes them to {branch}; when it returns an error, do what the error says, then call it again. The Forge then regenerates the code, CI builds it and the app updates itself on the user's Macs.

Do not commit or call forge_push_docs before the user agrees, and never change files outside {docsFolder}.
````

## Bundle part

`kind` = `bundle`: the coordinator of a bundle ([../services/bundles.md](../services/bundles.md)).

````text
## Bundle {bundleID}

This session coordinates bundle {bundleID} of {projectName}, "{bundleName}". Its tasks are implemented in parallel, each by its own task session in its own git worktree, on the branch task/<task id> made from {base}; you bring their work together. Call mcp__hephaestus__get_bundle for its current state.

Tasks of the bundle when this session started:
{bundleTaskLines}

Bundle tools: get_bundle, start_bundle_task (start the session of a task, or send instructions to it), update_bundle (set the status to review or running), finish_bundle (remove the worktrees and branches once the work is brought in).

1. Start the task sessions with mcp__hephaestus__start_bundle_task, in the bundle's order, at most {maxParallel} at a time. Each one implements its task, commits on its branch, comments a summary on its task and sets it to review.
2. Hephaestus sends you a message when a task session ends its turn, fails or waits for a permission answer. Then read the task's comments with mcp__hephaestus__get_task and its work with git log and git diff {base}...task/<task id>, start the next waiting task, and send instructions with start_bundle_task when the work is incomplete. Tell the user when a session waits for them.
3. When every task is in review, call mcp__hephaestus__update_bundle with the status review, show the user a summary of each task and of the combined changes, and wait for their agreement. Send the changes they ask for to the task sessions, with the status running while they work.
4. When the user agrees, bring the work into {codeFolder} on {base}, one task at a time in the bundle's order: git cherry-pick {base}..task/<task id>. Resolve conflicts yourself, then git cherry-pick --continue; ask the user when a conflict needs a decision.
{bundlePushLine}
6. Call mcp__hephaestus__finish_bundle and tell the user which branches it kept.

Never edit the files of a task yourself, except to resolve a conflict while bringing its work in.
````

## Bundle task part

Appended to the task part of a `task` session of a bundle.

````text
## Bundle {bundleID}

This session is one of the parallel sessions of bundle {bundleID}. Work only in {workFolder}, a git worktree on the branch task/{taskID}: never change files elsewhere and never switch branches. Commit your changes on task/{taskID} without pushing, and do not wait for the user's agreement first: the coordinator of the bundle reviews the work with the user. When you are blocked, say why in a comment on {taskID} and end your turn.
{bundleScopeLine}
````

## Regeneration part

`kind` = `regeneration`; the procedure itself is [../forge/generation.md](../forge/generation.md).

````text
## Regeneration

The documentation in {docsFolder} is the specification of this app: its code is generated from it. Regenerate the code so that it matches the documentation by following the procedure of {docsFolder}/forge/generation.md step by step, on the branch {branch}. Do not change the documentation.
{regenerationLines}

Once the build and the tests pass, the last steps of the procedure check the changes for personal data and commit them (step 11), then push them to {branch} with mcp__hephaestus__forge_push_regen (step 12). CI then builds the pushed commit and the app updates itself on the user's Macs.
````

`{regenerationLines}`: no line when `regeneration` is nil (later starts). Otherwise these paragraphs in this order, each
preceded by an empty line:

| Condition            | Paragraph                                                                                                                                                                                                                                              |
|----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| always               | `This regeneration starts from commit <targetCommit> (trigger: <trigger>, attempt <attempt>).`                                                                                                                                                         |
| `items` is not empty | the line `It includes the documentation changes of these feedback tasks:`, then one line per item: `- <taskID>`, followed by ` (docs commit <docsCommit>)` when `docsCommit` is set; the title of a feedback task, its user's first words, is left out |
| `failedRun` is set   | `CI run #<number> (<url>) failed with conclusion <conclusion>. The first message of this session holds the end of the logs of its failed jobs: find the cause in the code and fix it.`                                                                 |

## First messages

Sent as the session's first `user` message ([cli.md](cli.md#52-starting-a-session-sessionsstart)).

| Kind           | First message                                                                                                         |
|----------------|-----------------------------------------------------------------------------------------------------------------------|
| `project`      | none: the user's own message                                                                                          |
| `task`         | `Work on {taskID}: {taskName} ({mode}).`, then, when `{instructions}` is not empty, a blank line and `{instructions}` |
| `feedback`     | the text below                                                                                                        |
| `regeneration` | `Regenerate the code from the documentation.`; with `failedRun`, the text below                                       |
| `bundle`       | `Work on bundle {bundleID}: {bundleName}.`                                                                            |

Feedback; the description paragraph is left out when `task.description` is empty after trimming, the attached files
paragraph when `task.attachments` is empty:

````text
Work on {taskID}: {taskName} (feedback).

{taskDescription}

Attached files:
{attachmentLines}
````

`{taskDescription}` is `task.description` trimmed of whitespace and newlines.

Regeneration with a failed CI run: the first paragraph, then one block per job of `failedRun.jobs`, in order, each
preceded by an empty line:

````text
Fix the build: CI run #{runNumber} failed with conclusion {conclusion}: {runURL}
````

````text
Job {jobName} ({jobURL}), end of its log:

{fence}text
{jobLog}
{fence}
````

`{runNumber}`, `{conclusion}`, `{runURL}`: `failedRun.number`, `.conclusion`, `.url`. `{jobName}`, `{jobURL}`: the job's
`name` and `url`. `{jobLog}`: the job's `log` trimmed of trailing whitespace; when its UTF-8 size exceeds 32 KiB, its
last 32,768 bytes, without everything up to and including their first `\n` when they contain one, decoded leniently,
after the line `[… earlier log omitted]`.

Example, task session in mode implement: `Work on HEPH-12: Sidebar breaks on iPad (implement).`

## Title call

The texts of the one-shot call that titles a `project`, `feedback` or `bundle` session from its first message
([cli.md](cli.md#510-generated-titles-sessiontitler)). They were tried with CLI 2.1.309 and the model `haiku`.

`titleSystemPrompt`, passed with `--system-prompt`:

````text
You write short titles for conversations.
````

`titleRequest(text)`, written to stdin; `{message}` is `text` trimmed of whitespace and newlines and cut to its first
4,000 `Character`s:

````text
Write a title of at most 6 words for a conversation that starts with the message below. Reply with the title alone, in the language of the message, without quotes or a final period.

<message>
{message}
</message>
````

## Depends on

| Name                                                               | Defined in                                            |
|--------------------------------------------------------------------|-------------------------------------------------------|
| `SessionKind`, `SessionMode`, `ClaudeDefaults`, `TaskStatus`       | [../protocol/types.md](../protocol/types.md)          |
| bundles, work folders, `bundles.maxParallel`                       | [../services/bundles.md](../services/bundles.md)      |
| `DeviceSettings.forge.branch`                                      | [../data/app-storage.md](../data/app-storage.md)      |
| project.yml fields (`code`, `docs`, `claude`, `skills`)            | [../data/project-yml.md](../data/project-yml.md)      |
| task file format                                                   | [../data/task-yml.md](../data/task-yml.md)            |
| tool names, the tools of each session kind                         | [mcp.md](mcp.md)                                      |
| the public repository rule                                         | [../public-repository.md](../public-repository.md)    |
| the sessions of 3.5 (`publicRepository`)                           | [cli.md](cli.md#35-sessions-in-the-public-repository) |
| the placeholders                                                   | [../general.md](../general.md#placeholders)           |
| the feedback task, `RegenerationContext` values given by the Forge | [../forge/pipeline.md](../forge/pipeline.md)          |
| the regeneration procedure                                         | [../forge/generation.md](../forge/generation.md)      |
