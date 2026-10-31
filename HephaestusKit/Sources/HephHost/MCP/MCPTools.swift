#if os(macOS)
import Foundation
import HephCore

/// The definition of one Hephaestus tool (docs/claude/mcp.md §6).
struct MCPToolDefinition: Sendable {
    var name: String
    var description: String
    var inputSchema: String                 // JSON text of the schema below
    var kinds: Set<SessionKind>             // MCPToolKinds.kinds(for: name)
}

extension MCPToolDefinition {
    /// A definition whose kinds come from the table of section 6 (MCPToolKinds).
    init(name: String, description: String, inputSchema: String) {
        self.init(name: name, description: description, inputSchema: inputSchema,
                  kinds: MCPToolKinds.kinds(for: name))
    }
}

/// The tools of the MCP server, in catalog order: `name`, `description` and `inputSchema` as docs/claude/mcp.md §6
/// writes them, the schema as compact JSON text.
enum MCPTools {
    static let catalog: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_devices",
            description: #"List the devices of the user's Hephaestus mesh with their platform, role (Main or remote), addresses and versions, and whether each one is online."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "list_projects",
            description: #"List the projects of every Main of the mesh with their sub projects. A project is named by its identifier (2 to 8 letters, for example HEPH), which also starts the ids of its tasks. Projects of an offline Main are not listed."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "get_project",
            description: #"Get a project: its settings from project.yml (name, description, code and docs folders, sub projects, web tabs, run configurations, enabled skills, Claude defaults), the Main hosting it, its root folder, its number of tasks per status and its recent runs."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."}},"required":["project"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "create_project",
            description: #"Create a project: its folder, .hephaestus/project.yml and docs folder. Without parent, it is created in the projects folder of a Main; with parent, it is created as a sub project inside the parent's folder, on the parent's Main. The identifier must not be used by any other project of the mesh."#,
            inputSchema: #"{"type":"object","properties":{"name":{"type":"string","minLength":1,"description":"Project name. It is also the name of the project's folder."},"identifier":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Identifier of the new project: 2 to 8 letters, stored in uppercase."},"parent":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Identifier of the parent project, to create a sub project."},"device":{"type":"string","description":"Name or device id of the Main that hosts the new project. Default: the Main running this session. Not used with parent."}},"required":["name","identifier"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "update_project",
            description: #"Change the name or description of a project."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."},"name":{"type":"string","minLength":1,"description":"New project name."},"description":{"type":"string","description":"New description. An empty string removes it."}},"required":["project"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "list_tasks",
            description: #"List the tasks of a project in task-number order: id, name, status, created and updated dates, and number of comments. Use get_task to read a task's description and comments."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."},"status":{"type":"string","enum":["todo","in_progress","review","done"],"description":"Only the tasks with this status."}},"required":["project"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "get_task",
            description: #"Get a task: name, status, dates, Markdown description, and comments with their attachments."#,
            inputSchema: #"{"type":"object","properties":{"task":{"type":"string","pattern":"^[A-Za-z]{2,8}-[0-9]+$","description":"Task id, for example HEPH-12."}},"required":["task"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "create_task",
            description: #"Create a task in a project. Its id is the project identifier followed by the next task number, for example HEPH-13. The name is one line; the description is Markdown."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."},"name":{"type":"string","minLength":1,"description":"Task name, one line."},"description":{"type":"string","description":"Task description in Markdown."},"status":{"type":"string","enum":["todo","in_progress","review","done"],"description":"Initial status. Default: todo."}},"required":["project","name"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "update_task",
            description: #"Change the name, Markdown description or status of a task."#,
            inputSchema: #"{"type":"object","properties":{"task":{"type":"string","pattern":"^[A-Za-z]{2,8}-[0-9]+$","description":"Task id, for example HEPH-12."},"name":{"type":"string","minLength":1,"description":"New task name, one line."},"description":{"type":"string","description":"New description in Markdown."},"status":{"type":"string","enum":["todo","in_progress","review","done"],"description":"New status."}},"required":["task"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "delete_task",
            description: #"Delete a task with its comments and attachments. Its number is never reused."#,
            inputSchema: #"{"type":"object","properties":{"task":{"type":"string","pattern":"^[A-Za-z]{2,8}-[0-9]+$","description":"Task id, for example HEPH-12."}},"required":["task"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "comment_task",
            description: #"Add a comment to a task. The body is Markdown. files lists absolute paths of files on this Mac to attach to the comment, of any size; the user sees attached images in the comment."#,
            inputSchema: #"{"type":"object","properties":{"task":{"type":"string","pattern":"^[A-Za-z]{2,8}-[0-9]+$","description":"Task id, for example HEPH-12."},"body":{"type":"string","minLength":1,"description":"Comment text in Markdown."},"files":{"type":"array","items":{"type":"string"},"description":"Absolute paths of files on this Mac to attach."}},"required":["task","body"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "start_task_session",
            description: #"Start a Claude session that works on a task. It runs on the Main hosting the task's project, and the user can follow and answer it from any device. Modes: implement (implement the task, keep the docs in sync, build and test, comment a summary, set the status to review), debug (find the root cause, explain it, fix it after the user confirms), review (review the work done for the task and comment the findings), plan (comment an implementation plan, no code changes), custom (follow the given instructions)."#,
            inputSchema: #"{"type":"object","properties":{"task":{"type":"string","pattern":"^[A-Za-z]{2,8}-[0-9]+$","description":"Task id, for example HEPH-12."},"mode":{"type":"string","enum":["implement","debug","review","plan","custom"],"description":"What the session does."},"instructions":{"type":"string","description":"Instructions for the session. Required with mode custom; with another mode they are added to the session's first message."}},"required":["task","mode"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "list_runs",
            description: #"List the run configurations of a project (name, command, working directory) and its recent runs (id, state, start and end dates, exit code)."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."}},"required":["project"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "start_run",
            description: #"Start a run configuration of a project by name. Every device of the user shows its output live; read it with get_run_output."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."},"name":{"type":"string","minLength":1,"description":"Name of the run configuration."}},"required":["project","name"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "stop_run",
            description: #"Stop a run of a project."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."},"run":{"type":"string","minLength":1,"description":"Run id, from list_runs or start_run."}},"required":["project","run"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "get_run_output",
            description: #"Get the output of a run, stdout and stderr together: at most its last 64 KiB."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."},"run":{"type":"string","minLength":1,"description":"Run id, from list_runs or start_run."}},"required":["project","run"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "list_web_tabs",
            description: #"List the web tabs of a project: id, title, URL and whether the tab is locked."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."}},"required":["project"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "open_web_tab",
            description: #"Open a web tab in a project. Every device of the user shows the project's web tabs. A locked tab cannot be closed by mistake."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."},"url":{"type":"string","minLength":1,"description":"Absolute http or https URL."},"title":{"type":"string","description":"Tab title. Default: set by the page once loaded."},"locked":{"type":"boolean","description":"Lock the tab. Default: false."}},"required":["project","url"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "search",
            description: #"Search every online Main: projects, tasks, comments, docs, code, skills, web tabs, Claude sessions and devices. Matching ignores case and diacritics, and every word of the query must match. An exact task id or project identifier ranks first."#,
            inputSchema: #"{"type":"object","properties":{"query":{"type":"string","minLength":1,"description":"Words to search for."},"scopes":{"type":"array","items":{"type":"string","enum":["projects","tasks","comments","docs","code","skills","webTabs","sessions","devices"]},"description":"Kinds of items to search. Default: every kind."}},"required":["query"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "list_skills",
            description: #"List the skills of the Hephaestus skills library (separate from ~/.claude): name, description, date of the last change, and the problem of an invalid SKILL.md. The skills enabled in a project are available in its Claude sessions as hephaestus:<name>."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "get_skill",
            description: #"Get a skill of the Hephaestus library: the content of its SKILL.md and the list of its files."#,
            inputSchema: #"{"type":"object","properties":{"name":{"type":"string","pattern":"^[a-z0-9-]{1,64}$","description":"Skill name."}},"required":["name"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "save_skill",
            description: #"Create a skill of the Hephaestus library, or replace its SKILL.md. content is the whole SKILL.md: YAML front matter between --- lines with name (equal to the skill name) and description, then the instructions in Markdown. Skill names use lowercase letters, digits and hyphens, 1 to 64 characters."#,
            inputSchema: #"{"type":"object","properties":{"name":{"type":"string","pattern":"^[a-z0-9-]{1,64}$","description":"Skill name."},"content":{"type":"string","minLength":1,"description":"Complete SKILL.md content."}},"required":["name","content"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "forge_push_docs",
            description: #"Check the documentation commits of this feedback or bundle that are not on GitHub yet for personal data, then push them. Commit first, once the user agrees. On an error, do what the message says, then call it again."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "forge_push_regen",
            description: #"Check the regeneration commits that are not on GitHub yet for personal data, then push them; CI then builds them and the app updates itself. On an error, do what the message says, then call it again."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "get_bundle",
            description: #"Get the bundle this session coordinates: its tasks in order, each with the task, its task session, its branch and its work folder, and how many task sessions may run at once."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "start_bundle_task",
            description: #"Start the task session of a task of your bundle: it implements the task in its own git worktree, on the branch task/<task id>, commits there and sets the task to review. When the task already has a session, send that session instructions instead."#,
            inputSchema: #"{"type":"object","properties":{"task":{"type":"string","pattern":"^[A-Za-z]{2,8}-[0-9]+$","description":"Task id of your bundle, for example HEPH-12."},"instructions":{"type":"string","description":"Added to the first message of a new session; sent to the existing session of the task, where they are required."}},"required":["task"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "update_bundle",
            description: #"Set the status of your bundle: review while you wait for the user's agreement on the combined work, running when work resumes."#,
            inputSchema: #"{"type":"object","properties":{"status":{"type":"string","enum":["running","review"],"description":"New status."}},"required":["status"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "finish_bundle",
            description: #"Finish your bundle once the work of its tasks is on its base branch (and pushed, in the Forge repository): removes the worktrees, deletes the branches whose work is on the base branch, and marks the bundle done. Lists the branches it kept."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        )
    ]

    /// The definitions whose kinds contain `kind`, in catalog order.
    static func tools(for kind: SessionKind) -> [MCPToolDefinition] {
        catalog.filter { $0.kinds.contains(kind) }
    }
}
#endif
