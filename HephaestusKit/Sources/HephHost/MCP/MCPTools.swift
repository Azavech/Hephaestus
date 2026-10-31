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
            description: #"List the projects of every Main of the mesh with their sub projects. A project is named by its identifier (2 to 8 letters, for example HEPH), which also starts the ids of its tickets. Projects of an offline Main are not listed."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "get_project",
            description: #"Get a project: its settings from project.yml (name, description, code and docs folders, sub projects, web tabs, enabled skills, Claude defaults), the Main hosting it, its root folder and its number of tickets per status."#,
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
            name: "list_tickets",
            description: #"List the tickets of a project in ticket-number order: id, name, status, created and updated dates, and number of comments. Use get_ticket to read a ticket's description and comments."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."},"status":{"type":"string","enum":["todo","in_progress","review","done"],"description":"Only the tickets with this status."}},"required":["project"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "get_ticket",
            description: #"Get a ticket: name, status, dates, Markdown description, and comments with their attachments."#,
            inputSchema: #"{"type":"object","properties":{"ticket":{"type":"string","pattern":"^[A-Za-z]{2,8}-[Ff]?[0-9]+$","description":"Ticket id, for example HEPH-12, or HEPH-F3 for a feedback ticket."}},"required":["ticket"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "create_ticket",
            description: #"Create a ticket in a project. Its id is the project identifier followed by the next ticket number, for example HEPH-13. The name is one line; the description is Markdown."#,
            inputSchema: #"{"type":"object","properties":{"project":{"type":"string","pattern":"^[A-Za-z]{2,8}$","description":"Project identifier, for example HEPH."},"name":{"type":"string","minLength":1,"description":"Ticket name, one line."},"description":{"type":"string","description":"Ticket description in Markdown."},"status":{"type":"string","enum":["todo","in_progress","review","done"],"description":"Initial status. Default: todo."}},"required":["project","name"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "update_ticket",
            description: #"Change the name, Markdown description or status of a ticket."#,
            inputSchema: #"{"type":"object","properties":{"ticket":{"type":"string","pattern":"^[A-Za-z]{2,8}-[Ff]?[0-9]+$","description":"Ticket id, for example HEPH-12, or HEPH-F3 for a feedback ticket."},"name":{"type":"string","minLength":1,"description":"New ticket name, one line."},"description":{"type":"string","description":"New description in Markdown."},"status":{"type":"string","enum":["todo","in_progress","review","done"],"description":"New status."}},"required":["ticket"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "delete_ticket",
            description: #"Delete a ticket with its comments and attachments. Its number is never reused."#,
            inputSchema: #"{"type":"object","properties":{"ticket":{"type":"string","pattern":"^[A-Za-z]{2,8}-[Ff]?[0-9]+$","description":"Ticket id, for example HEPH-12, or HEPH-F3 for a feedback ticket."}},"required":["ticket"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "comment_ticket",
            description: #"Add a comment to a ticket. The body is Markdown. files lists absolute paths of files on this Mac to attach to the comment, of any size; the user sees attached images in the comment."#,
            inputSchema: #"{"type":"object","properties":{"ticket":{"type":"string","pattern":"^[A-Za-z]{2,8}-[Ff]?[0-9]+$","description":"Ticket id, for example HEPH-12, or HEPH-F3 for a feedback ticket."},"body":{"type":"string","minLength":1,"description":"Comment text in Markdown."},"files":{"type":"array","items":{"type":"string"},"description":"Absolute paths of files on this Mac to attach."}},"required":["ticket","body"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "start_ticket_session",
            description: #"Start a Claude session that works on a ticket. It runs on the Main hosting the ticket's project, and the user can follow and answer it from any device. Modes: implement (implement the ticket, keep the docs in sync, build and test, comment a summary), debug (find the root cause, explain it, fix it after the user confirms), review (review the work done for the ticket and comment the findings), plan (comment an implementation plan, no code changes), custom (follow the given instructions). The ticket goes to in_progress when the session starts a turn and to review when it ends it."#,
            inputSchema: #"{"type":"object","properties":{"ticket":{"type":"string","pattern":"^[A-Za-z]{2,8}-[Ff]?[0-9]+$","description":"Ticket id, for example HEPH-12, or HEPH-F3 for a feedback ticket."},"mode":{"type":"string","enum":["implement","debug","review","plan","custom"],"description":"What the session does."},"instructions":{"type":"string","description":"Instructions for the session. Required with mode custom; with another mode they are added to the session's first message."}},"required":["ticket","mode"],"additionalProperties":false}"#
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
            description: #"Search every online Main: projects, tickets, comments, docs, code, skills, web tabs, Claude sessions and devices. Matching ignores case and diacritics, and every word of the query must match. An exact ticket id or project identifier ranks first."#,
            inputSchema: #"{"type":"object","properties":{"query":{"type":"string","minLength":1,"description":"Words to search for."},"scopes":{"type":"array","items":{"type":"string","enum":["projects","tickets","comments","docs","code","skills","webTabs","sessions","devices"]},"description":"Kinds of items to search. Default: every kind."}},"required":["query"],"additionalProperties":false}"#
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
            description: #"Check the documentation commits of this ticket or bundle that are not on GitHub yet for personal data, then push them. Commit first, once the user agrees. On an error, do what the message says, then call it again."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "forge_push_regen",
            description: #"Check the regeneration commits that are not on GitHub yet for personal data, then push them; CI then builds them and the app updates itself. On an error, do what the message says, then call it again."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "get_bundle",
            description: #"Get the bundle this session coordinates: its tickets in order, each with the ticket, its ticket session, its branch and its work folder, and how many ticket sessions may run at once."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "start_bundle_ticket",
            description: #"Start the ticket session of a ticket of your bundle: it implements the ticket in its own git worktree, on the branch ticket/<ticket id>, commits there and comments a summary; the ticket goes to review when its session ends its turn. When the ticket already has a session, send that session instructions instead."#,
            inputSchema: #"{"type":"object","properties":{"ticket":{"type":"string","pattern":"^[A-Za-z]{2,8}-[Ff]?[0-9]+$","description":"Ticket id of your bundle, for example HEPH-12."},"instructions":{"type":"string","description":"Added to the first message of a new session; sent to the existing session of the ticket, where they are required."}},"required":["ticket"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "update_bundle",
            description: #"Set the status of your bundle: review while you wait for the user's agreement on the combined work, running when work resumes."#,
            inputSchema: #"{"type":"object","properties":{"status":{"type":"string","enum":["running","review"],"description":"New status."}},"required":["status"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "finish_bundle",
            description: #"Finish your bundle once the work of its tickets is on its base branch (and pushed, in the Forge repository): removes the worktrees, deletes the branches whose work is on the base branch, and marks the bundle done. Lists the branches it kept."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "rename_session",
            description: #"Rename this Claude session: the title the user sees for it in Hephaestus. Use it only when the user asks you to rename this session or chat. The title is one line."#,
            inputSchema: #"{"type":"object","properties":{"title":{"type":"string","minLength":1,"description":"New title of this session, one line."}},"required":["title"],"additionalProperties":false}"#
        ),
        MCPToolDefinition(
            name: "close_session",
            description: #"Close this session for good: it keeps its transcript, accepts no more messages and cannot be reopened. Its Claude process stops once this turn ends. Close a feedback session as soon as no question is open; close any other session only when the user says the conversation is done or asks you to close it."#,
            inputSchema: #"{"type":"object","properties":{},"additionalProperties":false}"#
        )
    ]

    /// The definitions whose kinds contain `kind`, in catalog order.
    static func tools(for kind: SessionKind) -> [MCPToolDefinition] {
        catalog.filter { $0.kinds.contains(kind) }
    }
}
#endif
