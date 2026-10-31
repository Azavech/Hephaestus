# Hephaestus

Hephaestus is a SwiftUI app for macOS, iPadOS and iOS that coordinates the work on all of the user's projects, whatever
device is in hand. Projects live on Macs set as **Mains**. Every device, Macs included, is a **remote**: it connects to
every Main and views and controls everything on it in real time, as if it were the machine doing the work. The Mac is
the main work machine; the UI adapts to the iPad and the iPhone.

## Platforms

| Platform | Minimum version | Roles            |
|----------|-----------------|------------------|
| macOS    | 15.0            | remote, and Main |
| iPadOS   | 18.0            | remote           |
| iOS      | 18.0            | remote           |

One multiplatform app target and one Swift package hold the whole app ([architecture.md](architecture.md)).

## Devices

- **Main**: a Mac where projects live. It runs the host service: the network listener, Claude CLI sessions, file
  watching, search, the skills library, and the Forge when configured. Only Macs can be Mains, because Mains run the
  Claude CLI and the user's toolchains. A Mac becomes a Main with "Use this Mac as a Main".
- **Remote**: every device. It connects to every Main of the mesh and can view and control everything on it.
- **Mesh**: the user's paired devices. A device joins with a 6-digit code shown on a Main; all mesh traffic is
  encrypted with the mesh key.
- **Presence**: every device shows which devices of the mesh are online, and when the others were last seen.
- **Moving projects**: a project moves from one Main to another with "Move to…", for example from the Mac mini at home
  to the MacBook when working away, and back.

Details: [devices/roles.md](devices/roles.md), [devices/mesh.md](devices/mesh.md),
[devices/migration.md](devices/migration.md).

## Projects

A project is a folder on a Main with a `.hephaestus/project.yml` file ([data/project-yml.md](data/project-yml.md)).

| Part         | Content                                                                                    | Docs                                                             |
|--------------|--------------------------------------------------------------------------------------------|------------------------------------------------------------------|
| Identity     | Identifier of 2–8 letters set at creation (`HEPH`), name, description                      | [data/project-yml.md](data/project-yml.md)                       |
| Sub projects | Normal projects inside the project folder; nesting can continue                            | [ui/overview.md](ui/overview.md)                                 |
| Tasks        | Id `HEPH-12`, name, description, created date, status, comments with files, Claude section | [ui/tasks.md](ui/tasks.md), [data/task-yml.md](data/task-yml.md) |
| Code         | File browser and code editor, with Swift and Go highlighting                               | [ui/code.md](ui/code.md), [ui/editor.md](ui/editor.md)           |
| Docs         | Markdown files of the docs folder (default `docs/` in the code folder), viewed and edited  | [ui/docs.md](ui/docs.md)                                         |
| Web tabs     | Integrated browser tabs shared by all devices; locked tabs cannot be closed                | [ui/web.md](ui/web.md)                                           |
| Claude       | Project chat sessions; task sessions; Claude acts on Hephaestus through its tools          | [ui/sessions.md](ui/sessions.md), [claude/cli.md](claude/cli.md) |
| Skills       | Which skills of the library the project's sessions get                                     | [claude/skills.md](claude/skills.md)                             |

Workspace features, not tied to a project: Devices, Skills (the skills library), Forge, Search, Feedback.

## User interface

- A path bar at the top selects `{Main} ▸ {project} ▸ {sub project}`, like Xcode's; every segment is a menu.
- A sidebar lists the project sections Overview, Tasks, Code, Docs, Web, Claude, and the workspace sections
  Devices, Skills, Forge.
- Search (⌘K) covers projects, tasks, comments, docs, code, skills, web tabs, sessions and devices.
- Feedback (⌘⇧F, toolbar, Help menu, shake on iOS/iPadOS) can be started anywhere.

| Device | Layout                                                                                                                                                                          |
|--------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Mac    | Main work machine. Several windows, each with its own selection; sidebar split view; toolbar path bar; Settings window; keyboard shortcuts                                      |
| iPad   | Same split view layout; several windows; keyboard shortcuts with a hardware keyboard; docs editor beside its live preview                                                       |
| iPhone | The split view collapses into a navigation stack; the path bar is a compact button opening a sheet with the pickers; docs Edit/Preview toggle; Settings is a sheet from Devices |

Details: [ui/shell.md](ui/shell.md).

## Real time

Every change on a Main is pushed to every connected device as it happens, whatever made it: a device, Claude, an
editor, git. Session transcripts and file changes stream live to the devices showing them
([client/workspace.md](client/workspace.md), [protocol/events.md](protocol/events.md)).

## Feedback and Forge

The app is built from this documentation by a GitHub pipeline. Feedback sent from any screen (a screenshot and a
comment) opens a Claude discussion that updates the docs; once the docs are pushed, the code is regenerated from them
and pushed, GitHub CI rebuilds the app, and every Mac updates and restarts itself
([forge/feedback.md](forge/feedback.md), [forge/pipeline.md](forge/pipeline.md), [forge/update.md](forge/update.md)).

## Glossary

| Term               | Meaning                                                                                             |
|--------------------|-----------------------------------------------------------------------------------------------------|
| Main               | A Mac where projects live; it runs the host service and the Claude CLI                              |
| remote             | Any device viewing and controlling the Mains; every device is a remote                              |
| mesh               | The set of the user's paired devices, sharing a mesh key                                            |
| pairing            | Joining a device to the mesh with a 6-digit code shown on a Main                                    |
| presence           | Online state and last-seen time of each device of the mesh                                          |
| registry           | The list of device records of the mesh, synced between Mains                                        |
| project            | A folder on a Main with `.hephaestus/project.yml`                                                   |
| project identifier | 2–8 uppercase letters set at creation, unique in the mesh, never changed (`HEPH`); the project's id |
| sub project        | A normal project inside another project's folder                                                    |
| task               | A unit of work of a project (the user also says ticket)                                             |
| task id            | `<project identifier>-<number>` (`HEPH-12`); numbers are never reused                               |
| comment            | A Markdown message on a task, with optional attached files                                          |
| code folder        | The project's code root, relative to the project root (default: the project root)                   |
| docs folder        | The project's documentation folder, relative to the code folder (default `docs`)                    |
| web tab            | A browser tab stored in the project, shown on every device; a locked tab cannot be closed           |
| session            | A Claude CLI conversation run on a Main: project chat, task session, feedback or regeneration       |
| permission mode    | How a session asks before acting: `manual`, `acceptEdits`, `auto`, `plan`, `bypassPermissions`      |
| skill              | A Claude skill (folder with `SKILL.md`) of a Main's skills library, separate from `~/.claude`       |
| Move to…           | Moving a project from one Main to another (migration)                                               |
| Forge              | The feedback → docs → regeneration → CI → update pipeline                                           |
| Forge host         | The Main that hosts the Hephaestus source project and runs the Forge                                |
| docs hash          | SHA-256 over the files of `docs/`, naming the documentation a build was generated from              |
| path bar           | The toolbar selector `{Main} ▸ {project} ▸ {sub project}`                                           |
| host service       | The Main side of the app (`HostService`), running inside the app on a Main                          |
