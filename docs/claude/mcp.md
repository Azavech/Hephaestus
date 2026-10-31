# MCP server (Hephaestus tools)

files:
- HephaestusKit/Sources/HephHost/MCP/MCPServer.swift
- HephaestusKit/Sources/HephHost/MCP/MCPHost.swift
- HephaestusKit/Sources/HephHost/MCP/HTTPRequestParser.swift
- HephaestusKit/Sources/HephHost/MCP/HTTPResponse.swift
- HephaestusKit/Sources/HephHost/MCP/MCPDispatcher.swift
- HephaestusKit/Sources/HephHost/MCP/MCPTools.swift
- HephaestusKit/Sources/HephHost/MCP/MCPToolHandler.swift
- HephaestusKit/Sources/HephHost/MCP/MCPToolKinds.swift

---

Each Main runs one MCP server that gives its Claude sessions the `mcp__hephaestus__*` tools: Streamable HTTP, JSON-RPC
2.0 over `POST /mcp` on `127.0.0.1:<port>`, JSON responses only. A tool executes protocol methods
([../protocol/methods.md](../protocol/methods.md)) on the Main hosting the project it acts on: this Main in process, or
another Main over its peer link. Sessions get the server through `--mcp-config` ([cli.md](cli.md#31-arguments)).

Every file is macOS only and wrapped in `#if os(macOS)`. Logging uses `Log.host` with the rules of
[../architecture.md](../architecture.md#logging): tool names, project and ticket ids and error codes are logged; bearer
tokens, arguments and results never are.

## 1. Lifecycle

- `MCPServer` is the `mcp` service of the host. The host starts it when the Main starts, before any session process,
  and stops it when the Main stops, after `SessionService.stopAll()` ([../services/host.md](../services/host.md)).
- `start()` creates an `NWListener` with `NWParameters.tcp` whose `requiredLocalEndpoint` is
  `.hostPort(host: "127.0.0.1", port: .any)`; the port is the listener's port once its state is `.ready`. Only loopback
  connections can reach it. A failure is thrown; `SessionService` calls `start()` again before the next process start
  ([cli.md](cli.md#53-starting-the-process)).
- `stop()` cancels the listener and every connection and forgets every token.

## 2. Swift API

```swift
/// The session a bearer token belongs to.
public struct MCPSessionContext: Sendable, Equatable {
    public var sessionID: UUID
    public var projectID: String
    public var kind: SessionKind
    public var ticketID: String?
    public var bundleID: String?
    public init(...)   // memberwise: one labeled parameter per property, in order, no default
}

public actor MCPServer {
    public init(host: any MCPHost)
    /// Starts listening on 127.0.0.1 with a port chosen by the system and returns it; returns the port at once when
    /// already running.
    @discardableResult public func start() async throws -> UInt16
    public func stop() async
    public var port: UInt16? { get }
    /// Registers a session process; returns its new bearer token.
    public func register(_ context: MCPSessionContext) -> String
    /// Forgets a token (process ended). Calls in progress complete.
    public func unregister(token: String)
    /// The --mcp-config value (section 5). Call it after start().
    public func configJSON(token: String) -> String
}

/// Implemented by HostService (services/host.md).
public protocol MCPHost: Sendable {
    /// This Main (online is true).
    func localMain() async -> MCPMain
    /// The other non-revoked Mains of the registry; online = an outgoing peer link to it is open.
    func otherMains() async -> [MCPMain]
    /// Executes a protocol method with JSON params and returns the JSON result. On this Main: HostService.perform
    /// with RequestContext.local(device: <this Main's DeviceInfo>, author: "Claude"). On another Main: a request over
    /// the peer link (MeshService.requestPeer). Failures throw ProtocolError.
    func perform(_ method: String, params: Data, on deviceID: UUID) async throws -> Data
    /// Root folder of a project hosted on this Main, nil otherwise.
    func localProjectRoot(_ projectID: String) async -> URL?
    /// ForgeService.pushDocs / pushRegen (forge/pipeline.md): the text given back to Claude, or a thrown
    /// ProtocolError whose message is the error text.
    func forgePushDocs(sessionID: UUID) async throws -> String
    func forgePushRegen(sessionID: UUID) async throws -> String
    /// SessionService.close (cli.md 5.11): closes the session of the token. Failures throw ProtocolError.
    func closeSession(projectID: String, sessionID: UUID) async throws
    /// The BundleService function of a bundle tool (6.21–6.24): its result as JSON text, or a thrown ProtocolError
    /// whose message is the error text.
    func bundleTool(_ name: String, projectID: String, bundleID: String, arguments: Data) async throws -> String
}

public struct MCPMain: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var online: Bool
    public init(...)   // memberwise: one labeled parameter per property, in order, no default
}
```

Internal types (same module): `HTTPRequestParser`, `HTTPRequest`, `HTTPResponse` (section 3), `MCPDispatcher`
(section 4), `MCPTools`, `MCPToolKinds` and `MCPToolHandler` (section 6).

## 3. HTTP/1.1 server

Each accepted `NWConnection` is served by one ticket: it receives up to 65,536 bytes at a time into an
`HTTPRequestParser`, and serves the complete requests in order, one at a time. Connections are served concurrently.

```swift
struct HTTPHeader: Sendable, Equatable { var name: String; var value: String }

struct HTTPRequest: Sendable, Equatable {
    var method: String          // "POST"
    var target: String          // "/mcp" or "/mcp?x=1"
    var path: String            // target up to the first "?"
    var version: String         // "HTTP/1.1" or "HTTP/1.0"
    var headers: [HTTPHeader]   // in order
    var body: Data
    /// First value of a header, name compared case-insensitively.
    func header(_ name: String) -> String?
    /// HTTP/1.1: false only with "Connection: close"; HTTP/1.0: true only with "Connection: keep-alive".
    var keepAlive: Bool { get }
}

enum HTTPParseError: Error, Equatable { case malformed, headersTooLarge, bodyTooLarge }

struct HTTPRequestParser: Sendable {
    init(maxHeaderBytes: Int = 65_536, maxBodyBytes: Int = 8_388_608)
    mutating func append(_ data: Data)
    /// The next complete request, nil when more bytes are needed.
    mutating func nextRequest() throws -> HTTPRequest?
}

struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [HTTPHeader]
    var body: Data
    /// Status line, headers (Content-Length added, Connection: close added when `close`), blank line, body.
    func serialized(close: Bool) -> Data
}
```

Request parsing:

- The head ends at the first `\r\n\r\n`. More than 64 KiB without it → `headersTooLarge`.
- Request line: exactly three parts separated by single spaces: method, target, version. The version must be
  `HTTP/1.1` or `HTTP/1.0`. Anything else → `malformed`.
- Header lines: `name: value`; the name is a non-empty token without spaces, the value is trimmed of spaces and tabs.
  A line without `:` or starting with a space or tab → `malformed`.
- Body framing:
  - `Transfer-Encoding` present: its value must be `chunked` (case-insensitive), else `malformed`; it takes precedence
    over `Content-Length`. Chunks: a line of hex digits (optionally followed by `;` and extensions, which are
    ignored) ending with `\r\n`, that many bytes, `\r\n`; the chunk of size 0 ends the body; trailer lines up to an
    empty line are read and ignored.
  - Else `Content-Length`: a non-negative decimal integer; several `Content-Length` headers must have the same value;
    otherwise `malformed`.
  - Else no body.
  - A body larger than 8 MiB (declared or accumulated) → `bodyTooLarge`.
- Bytes after a complete request stay in the parser for the next request (pipelining).

Responses always carry `Content-Length`; responses with a JSON body carry `Content-Type: application/json`. Status
lines: `200 OK`, `202 Accepted`, `400 Bad Request`, `401 Unauthorized`, `404 Not Found`, `405 Method Not Allowed`,
`413 Content Too Large`, `431 Request Header Fields Too Large`.

Routing: the first matching row applies.

| Condition                                              | Status    | Body and headers                                                         | Connection      |
|--------------------------------------------------------|-----------|--------------------------------------------------------------------------|-----------------|
| `malformed`                                            | 400       | empty                                                                    | closed          |
| `headersTooLarge`                                      | 431       | empty                                                                    | closed          |
| `bodyTooLarge`                                         | 413       | empty                                                                    | closed          |
| `path` is not `/mcp`                                   | 404       | empty                                                                    | per `keepAlive` |
| method is not `POST`                                   | 405       | empty, `Allow: POST`                                                     | per `keepAlive` |
| `Authorization` is not `Bearer <registered token>`     | 401       | empty, `WWW-Authenticate: Bearer`                                        | per `keepAlive` |
| otherwise                                              | section 4 | section 4                                                                | per `keepAlive` |

Keep-alive: after a response the connection stays open when `keepAlive` is true. A connection with no byte received for
120 s is closed. The server sends no `Mcp-Session-Id` header and ignores `Mcp-Session-Id`, `MCP-Protocol-Version`,
`Accept` and `Origin` (the bearer token is the protection).

## 4. JSON-RPC and MCP methods (`MCPDispatcher`)

```swift
struct MCPDispatcher: Sendable {
    init(tools: MCPToolHandler)
    /// Handles one authenticated POST /mcp body for the token's session.
    func handle(body: Data, context: MCPSessionContext) async -> HTTPResponse
}
```

The body is decoded with `JSONSerialization`. Error responses have the form
`{"jsonrpc":"2.0","id":<id or null>,"error":{"code":<code>,"message":"<text>"}}`; `id` is echoed exactly as received
(string or number). Successful responses are `{"jsonrpc":"2.0","id":<id>,"result":{…}}`. The first matching row
applies.

| Body                                                                                        | HTTP | Answer                                                                                |
|---------------------------------------------------------------------------------------------|------|---------------------------------------------------------------------------------------|
| not JSON                                                                                    | 400  | error `-32700`, `Parse error`, id null                                                |
| a JSON array (batch)                                                                        | 400  | error `-32600`, `Batch requests are not supported`, id null                           |
| not an object, `jsonrpc` ≠ `"2.0"`, or `id` present and not a string or number              | 400  | error `-32600`, `Invalid Request`, id null                                            |
| an object with `result` or `error` and no `method` (a response from the client)             | 202  | empty                                                                                 |
| `method` absent or not a string                                                             | 400  | error `-32600`, `Invalid Request`, id echoed or null                                  |
| no `id` (a notification: `notifications/initialized`, `notifications/cancelled`, any other) | 202  | empty; ignored                                                                        |
| `params` present and not an object                                                          | 200  | error `-32602`, `Invalid params`                                                      |
| `initialize`                                                                                | 200  | result below                                                                          |
| `ping`                                                                                      | 200  | result `{}`                                                                           |
| `tools/list`                                                                                | 200  | result `{"tools":[…]}`: the tools of the session's kind (section 6), in catalog order |
| `tools/call`                                                                                | 200  | result of section 8, or the errors below                                              |
| any other method                                                                            | 200  | error `-32601`, `Method not found: <method>`                                          |
| an unexpected failure while handling                                                        | 200  | error `-32603`, `Internal error`                                                      |

The CLI's first request is `server/discover` (header `MCP-Protocol-Version: 2026-07-28`); the row "any other method"
answers it (HTTP 200, `-32601`) and the CLI then sends `initialize` (verified with CLI 2.1.309).

`initialize` result (`params.protocolVersion` is echoed when it is `2025-11-25`, `2025-06-18`, `2025-03-26` or
`2024-11-05`, else `2025-11-25` is answered; CLI 2.1.309 sends `2025-11-25`; `version` is the app's marketing
version, `CFBundleShortVersionString`, or `""` when the bundle has none):

```json
{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"hephaestus","version":"1.0"}}
```

`tools/call` params `{"name":"<tool>","arguments":{…}}`: `name` missing, not a string, or not a tool of the session's
kind → error `-32602`, `Unknown tool: <name>`; `arguments` present and not an object → error `-32602`,
`Invalid params`; `arguments` absent = `{}`. Argument problems inside an object (missing or wrong values) are tool
errors (section 8), so Claude can correct them.

## 5. Sessions, tokens and `--mcp-config`

- `SessionService` registers each session process before spawning it: `register(MCPSessionContext{sessionID,
  projectID, kind, ticketID, bundleID})` returns a new token, 32 random bytes (`SecRandomCopyBytes`) as 64 lowercase hex
  characters. It unregisters the token when the process ends ([cli.md](cli.md#57-errors-and-the-end-of-a-process)).
- A request's token selects its `MCPSessionContext`: the tools listed and callable depend on its `kind` (section 6),
  `get_ticket`, `update_ticket` and `comment_ticket` in a `feedback` session are limited to its `ticketID`, and the
  Forge tools pass its `sessionID`.
- `configJSON(token:)` returns, compact, with the current port:

```json
{"mcpServers":{"hephaestus":{"type":"http","url":"http://127.0.0.1:<port>/mcp","headers":{"Authorization":"Bearer <token>"}}}}
```

The server name `hephaestus` makes Claude Code expose the tools as `mcp__hephaestus__<tool>`; `--allowedTools
mcp__hephaestus` lets sessions call them without permission prompts.

## 6. Tools

`MCPTools.catalog` holds the definitions below in this order: `name`, `description` and `inputSchema` exactly as
written here (served compact by `tools/list`). Each definition has the session kinds that list it and may call it,
given by `MCPToolKinds.kinds(for:)` from this table:

| Tools                                                        | Session kinds                                                   |
|--------------------------------------------------------------|-----------------------------------------------------------------|
| 6.1–6.6, 6.8, 6.10, 6.13–6.18                                | `project`, `ticket`, `bundle`                                   |
| 6.7 `get_ticket`, 6.9 `update_ticket`, 6.11 `comment_ticket` | `project`, `ticket`, `bundle`, `feedback` (its own ticket only) |
| 6.12 `start_ticket_session`                                  | `project`, `ticket`                                             |
| 6.19 `forge_push_docs`                                       | `ticket`, `bundle`                                              |
| 6.20 `forge_push_regen`                                      | `regeneration`                                                  |
| 6.21–6.24 the bundle tools                                   | `bundle`                                                        |
| 6.25 `rename_session`                                        | `project`, `ticket`, `bundle`, `feedback`, `regeneration`       |
| 6.26 `close_session`                                         | `project`, `ticket`, `bundle`, `feedback`                       |

A `feedback` session therefore lists `get_ticket`, `update_ticket`, `comment_ticket`, `rename_session` and
`close_session`, and a `regeneration` session lists `forge_push_regen` and `rename_session`. A feedback session uses
`update_ticket` and `comment_ticket` to turn its feedback into a ticket, then `close_session` once no question is open
([prompts.md](prompts.md#feedback-part)); it has no push tool, since it changes no file. Forge sessions write to the
public repository ([../public-repository.md](../public-repository.md)): they get no tool that reads the devices,
projects, tickets, web tabs, sessions or skills of the mesh beyond their own feedback ticket, none that changes them
beyond the name, description, status and comments of that ticket and the title of their own session, and none that runs
a command or starts a session, so nothing they call can push around the Forge push gate
([../forge/pipeline.md](../forge/pipeline.md#mcp-tools)). `MCPToolKinds.swift` holds this table and nothing else:
`kinds(for:)` names each tool of the table (the first row: the 14 tools of 6.1–6.6, 6.8, 6.10 and 6.13–6.18) and returns
an empty set for any other name, so a tool added to the catalog is listed and callable in no session until the table
names it.

A `bundle` session, the coordinator of a bundle ([../services/bundles.md](../services/bundles.md)), gets the tools
that read and change projects and tickets, the bundle tools and `forge_push_docs`, which pushes only for the bundles of
the Forge source project. It starts its ticket sessions with `start_bundle_ticket` alone, and gets no tool that runs a
command: in the Forge source project it holds a push tool.

A `ticket` session lists `forge_push_docs` too. It pushes only for a ticket session of the Forge source project, on the
Forge host, that is not a session of a bundle ([../forge/pipeline.md](../forge/pipeline.md#mcp-tools)): implementing a
feedback ticket there pushes its documentation and starts the regeneration, as a bundle does. The ticket sessions of a
bundle leave the push to their coordinator.

```swift
struct MCPToolDefinition: Sendable {
    var name: String
    var description: String
    var inputSchema: String                 // JSON text of the schema below
    var kinds: Set<SessionKind>             // MCPToolKinds.kinds(for: name)
}

/// The table of section 6: the session kinds that list each tool and may call it.
enum MCPToolKinds {
    static func kinds(for toolName: String) -> Set<SessionKind>
}

enum MCPTools {
    static let catalog: [MCPToolDefinition]
    /// The definitions whose kinds contain `kind`, in catalog order.
    static func tools(for kind: SessionKind) -> [MCPToolDefinition]
}

struct MCPToolResult: Sendable, Equatable {
    var text: String
    var isError: Bool
}

struct MCPToolHandler: Sendable {
    init(host: any MCPHost)
    /// Runs one tool; never throws: failures are results with isError (section 8).
    func call(name: String, arguments: Data, context: MCPSessionContext) async -> MCPToolResult
}
```

Argument rules for every tool:

- `project`: uppercased, then it must match `^[A-Z]{2,8}$`.
- `ticket`: uppercased, then it must match `^[A-Z]{2,8}-F?[0-9]+$` (a ticket id or a feedback ticket id,
  [../data/ticket-yml.md](../data/ticket-yml.md#ticket-id)); its project is the part before the `-`.
- The arguments are checked in the order of the schema's `properties`, before the tool's own checks and calls; the
  first problem ends the call with `Invalid arguments: <what is wrong>.` (section 8). An argument set to `null` counts
  as absent. Arguments the schema does not list are ignored.

  | Problem                                                              | `<what is wrong>`                                                      |
  |----------------------------------------------------------------------|------------------------------------------------------------------------|
  | a required argument is absent                                        | `<name> is missing`                                                    |
  | a string argument is not a string                                    | `<name> must be a string`                                              |
  | a string is shorter than its `minLength`                             | `<name> must not be empty`                                             |
  | a boolean argument is not a boolean                                  | `<name> must be a boolean`                                             |
  | an array argument is not an array of strings                         | `<name> must be an array of strings`                                   |
  | a value is not in its `enum`                                         | `<name> must be one of <values>` (the `enum` values, joined with `, `) |
  | an item of an array is not in its `enum` (`scopes`)                  | `<name> must hold values among <values>`                               |
  | `project`, `identifier` or `parent` breaks the `project` rule above  | `<name> is not a project identifier`                                   |
  | `ticket` breaks the `ticket` rule above                                  | `ticket is not a ticket id`                                                |
  | the `name` of `get_skill` or `save_skill` breaks `^[a-z0-9-]{1,64}$` | `name is not a skill name`                                             |

- A tool acting on a project first locates its Main (section 7). The calls of a tool go to that Main.
- Results that are JSON are encoded compact with `JSONEncoder` (`.sortedKeys`, `.withoutEscapingSlashes`, dates as in
  the wire protocol); protocol types are encoded exactly as on the wire ([../protocol/types.md](../protocol/types.md)).

### 6.1 list_devices

```json
{
  "name": "list_devices",
  "description": "List the devices of the user's Hephaestus mesh with their platform, role (Main or remote), addresses and versions, and whether each one is online.",
  "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
}
```

Calls `mesh.snapshot {}` on this Main. Result: the `MeshSnapshot` `{meshID, devices, presence}`.

### 6.2 list_projects

```json
{
  "name": "list_projects",
  "description": "List the projects of every Main of the mesh with their sub projects. A project is named by its identifier (2 to 8 letters, for example HEPH), which also starts the ids of its tickets. Projects of an offline Main are not listed.",
  "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
}
```

Calls `projects.list {}` on this Main and, in parallel, on every online Main of `otherMains()`. Result:

```json
{"mains":[{"id":"<device id>","name":"Studio","online":true,"projects":[<ProjectSummary>]},{"id":"<device id>","name":"Sam's MacBook Pro","online":false}]}
```

This Main first, then the other Mains sorted by name. `projects` is present for online Mains. A Main whose call fails is
listed with `"online": false` and `"error": "<code>: <message>"`.

### 6.3 get_project

```json
{
  "name": "get_project",
  "description": "Get a project: its settings from project.yml (name, description, code and docs folders, sub projects, web tabs, enabled skills, Claude defaults), the Main hosting it, its root folder and its number of tickets per status.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "project": {"type": "string", "pattern": "^[A-Za-z]{2,8}$", "description": "Project identifier, for example HEPH."}
    },
    "required": ["project"],
    "additionalProperties": false
  }
}
```

Calls `projects.snapshot {projectID}`. Result:

```json
{"main":{"id":"<device id>","name":"Studio"},"project":<Project>,"ticketCounts":{"todo":3,"in_progress":1,"review":0,"done":8,"broken":0}}
```

`project.rootPath` is the root folder; `broken` counts the tickets with a `parseError`, which count in no status.

### 6.4 create_project

```json
{
  "name": "create_project",
  "description": "Create a project: its folder, .hephaestus/project.yml and docs folder. Without parent, it is created in the projects folder of a Main; with parent, it is created as a sub project inside the parent's folder, on the parent's Main. The identifier must not be used by any other project of the mesh.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "name": {"type": "string", "minLength": 1, "description": "Project name. It is also the name of the project's folder."},
      "identifier": {"type": "string", "pattern": "^[A-Za-z]{2,8}$", "description": "Identifier of the new project: 2 to 8 letters, stored in uppercase."},
      "parent": {"type": "string", "pattern": "^[A-Za-z]{2,8}$", "description": "Identifier of the parent project, to create a sub project."},
      "device": {"type": "string", "description": "Name or device id of the Main that hosts the new project. Default: the Main running this session. Not used with parent."}
    },
    "required": ["name", "identifier"],
    "additionalProperties": false
  }
}
```

- With `parent`: locates the parent, then calls `projects.create {name, identifier, parentID: <parent>}` on the
  parent's Main.
- Without `parent`: the target is the Main whose device id equals `device`, else the Main whose name equals `device`
  compared case-insensitively, among this Main and `otherMains()`; it must be online (else a tool error `Main "<device>"
  is not online.`; no match: `No Main named "<device>".`). Without `device`, this Main. Calls `projects.create {name,
  identifier}` there.
- `identifier` is uppercased. Result: the `ProjectSummary`.

### 6.5 update_project

```json
{
  "name": "update_project",
  "description": "Change the name or description of a project.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "project": {"type": "string", "pattern": "^[A-Za-z]{2,8}$", "description": "Project identifier, for example HEPH."},
      "name": {"type": "string", "minLength": 1, "description": "New project name."},
      "description": {"type": "string", "description": "New description. An empty string removes it."}
    },
    "required": ["project"],
    "additionalProperties": false
  }
}
```

Calls `projects.update {projectID, patch: {name?, description?}}` with the given fields only. Result: the `Project`.

### 6.6 list_tickets

```json
{
  "name": "list_tickets",
  "description": "List the tickets of a project in ticket-number order: id, name, status, created and updated dates, and number of comments. Use get_ticket to read a ticket's description and comments.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "project": {"type": "string", "pattern": "^[A-Za-z]{2,8}$", "description": "Project identifier, for example HEPH."},
      "status": {"type": "string", "enum": ["todo", "in_progress", "review", "done"], "description": "Only the tickets with this status."}
    },
    "required": ["project"],
    "additionalProperties": false
  }
}
```

Calls `projects.snapshot {projectID}`. Result, sorted by ticket number:

```json
{"project":"HEPH","tickets":[{"id":"HEPH-1","name":"Sidebar breaks on iPad","status":"todo","created":"2026-10-29T21:04:00.000Z","updated":"2026-10-29T22:10:00.000Z","comments":2},{"id":"HEPH-7","parseError":"<message>"}]}
```

A ticket with a `parseError` is listed with `id` and `parseError` only, and left out when `status` is given.

### 6.7 get_ticket

```json
{
  "name": "get_ticket",
  "description": "Get a ticket: name, status, dates, Markdown description, and comments with their attachments.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "ticket": {"type": "string", "pattern": "^[A-Za-z]{2,8}-[Ff]?[0-9]+$", "description": "Ticket id, for example HEPH-12, or HEPH-F3 for a feedback ticket."}
    },
    "required": ["ticket"],
    "additionalProperties": false
  }
}
```

In a `feedback` session, `ticket` uppercased must be the session's `ticketID`, else tool error `Forge sessions can only
read their own feedback ticket.` Calls `projects.snapshot {projectID}` and takes the ticket (absent: tool error
`notFound: Ticket <id> does not exist.`). Result:
`{"ticket":<TicketItem>,"attachmentsFolder":"<project root>/.hephaestus/attachments/<ticket id>"}`;
`attachmentsFolder` is present only when the project is hosted on this Main (`localProjectRoot`), so Claude can read the
files.

### 6.8 create_ticket

```json
{
  "name": "create_ticket",
  "description": "Create a ticket in a project. Its id is the project identifier followed by the next ticket number, for example HEPH-13. The name is one line; the description is Markdown.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "project": {"type": "string", "pattern": "^[A-Za-z]{2,8}$", "description": "Project identifier, for example HEPH."},
      "name": {"type": "string", "minLength": 1, "description": "Ticket name, one line."},
      "description": {"type": "string", "description": "Ticket description in Markdown."},
      "status": {"type": "string", "enum": ["todo", "in_progress", "review", "done"], "description": "Initial status. Default: todo."}
    },
    "required": ["project", "name"],
    "additionalProperties": false
  }
}
```

Calls `tickets.create {projectID, name, description?, status?}`. Result: the `TicketItem`.

### 6.9 update_ticket

```json
{
  "name": "update_ticket",
  "description": "Change the name, Markdown description or status of a ticket.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "ticket": {"type": "string", "pattern": "^[A-Za-z]{2,8}-[Ff]?[0-9]+$", "description": "Ticket id, for example HEPH-12, or HEPH-F3 for a feedback ticket."},
      "name": {"type": "string", "minLength": 1, "description": "New ticket name, one line."},
      "description": {"type": "string", "description": "New description in Markdown."},
      "status": {"type": "string", "enum": ["todo", "in_progress", "review", "done"], "description": "New status."}
    },
    "required": ["ticket"],
    "additionalProperties": false
  }
}
```

In a `feedback` session, `ticket` uppercased must be the session's `ticketID`, else tool error `Forge sessions can only
change their own feedback ticket.` Calls `tickets.update {projectID, ticketID, patch: {name?, description?, status?}}`
with the given fields only. Result: the `TicketItem`.

### 6.10 delete_ticket

```json
{
  "name": "delete_ticket",
  "description": "Delete a ticket with its comments and attachments. Its number is never reused.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "ticket": {"type": "string", "pattern": "^[A-Za-z]{2,8}-[Ff]?[0-9]+$", "description": "Ticket id, for example HEPH-12, or HEPH-F3 for a feedback ticket."}
    },
    "required": ["ticket"],
    "additionalProperties": false
  }
}
```

Calls `tickets.delete {projectID, ticketID}`. Result: `{"deleted":"HEPH-12"}`.

### 6.11 comment_ticket

```json
{
  "name": "comment_ticket",
  "description": "Add a comment to a ticket. The body is Markdown. files lists absolute paths of files on this Mac to attach to the comment, of any size; the user sees attached images in the comment.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "ticket": {"type": "string", "pattern": "^[A-Za-z]{2,8}-[Ff]?[0-9]+$", "description": "Ticket id, for example HEPH-12, or HEPH-F3 for a feedback ticket."},
      "body": {"type": "string", "minLength": 1, "description": "Comment text in Markdown."},
      "files": {"type": "array", "items": {"type": "string"}, "description": "Absolute paths of files on this Mac to attach."}
    },
    "required": ["ticket", "body"],
    "additionalProperties": false
  }
}
```

- In a `feedback` session, `ticket` uppercased must be the session's `ticketID`, else tool error `Forge sessions can
  only change their own feedback ticket.`, checked before the files.
- Each path must be absolute and name a readable regular file on this Main; otherwise a tool error
  `Cannot attach <path>: <reason>.` and nothing is sent. Files have no size limit. Every path is checked before any
  upload, in this order: not absolute, `the path is not absolute`; nothing there, the system's text for the error
  (`strerror`, for example `No such file or directory`); not a regular file, `it is not a regular file`; not readable,
  the system's text (`Permission denied`).
- Each file is uploaded to the Main hosting the ticket's project, in order, with `perform(_:params:on:)` (in process on
  this Main, forwarded over the peer link otherwise, section 7): `uploads.begin {projectID, fileName: <last path
  component>, size}`, then `uploads.chunk {uploadID, offset, data}` with the file's bytes read in order with a
  `FileHandle`, `MethodLimits.maxChunkSize` bytes at a time (the last chunk shorter), one request at a time
  ([../protocol/methods.md](../protocol/methods.md#uploads)). A file of size 0 gets no chunk. A failure (a read error,
  a file that changes size, an error response) sends `uploads.cancel` for each upload begun (errors ignored) and gives
  the tool error `Cannot attach <path>: <reason>.`; no comment is added. `<reason>`: `<code>: <message>` for an error
  response, the error's message for a read error, `the file changed while it was read` for a file that ends before its
  size or goes on after it; its final period is left out.
- Then calls `tickets.addComment {projectID, ticketID, body, attachments, author: "Claude"}` with one `UploadRef
  {uploadID, fileName: <last path component>}` per file, in the order of `files`. On this Main the in-process request
  context has the author `Claude`; on another Main the `author` param is honored because it comes over a peer link
  ([../services/host.md](../services/host.md)). Either way the comment's author is `Claude`, and the comment can be
  deleted but not edited ([../protocol/methods.md](../protocol/methods.md#ticketsupdatecomment)). When
  `tickets.addComment` fails, `uploads.cancel` is sent for each upload (errors ignored) and its error is the tool error.
- Result: the `TicketItem`.

### 6.12 start_ticket_session

```json
{
  "name": "start_ticket_session",
  "description": "Start a Claude session that works on a ticket. It runs on the Main hosting the ticket's project, and the user can follow and answer it from any device. Modes: implement (implement the ticket, keep the docs in sync, build and test, comment a summary), debug (find the root cause, explain it, fix it after the user confirms), review (review the work done for the ticket and comment the findings), plan (comment an implementation plan, no code changes), custom (follow the given instructions). The ticket goes to in_progress when the session starts a turn and to review when it ends it.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "ticket": {"type": "string", "pattern": "^[A-Za-z]{2,8}-[Ff]?[0-9]+$", "description": "Ticket id, for example HEPH-12, or HEPH-F3 for a feedback ticket."},
      "mode": {"type": "string", "enum": ["implement", "debug", "review", "plan", "custom"], "description": "What the session does."},
      "instructions": {"type": "string", "description": "Instructions for the session. Required with mode custom; with another mode they are added to the session's first message."}
    },
    "required": ["ticket", "mode"],
    "additionalProperties": false
  }
}
```

Mode `custom` without non-empty `instructions` → tool error `Mode custom needs instructions.` Calls `sessions.start
{projectID, kind: "ticket", ticketID, mode, message: instructions}` (`message` omitted when absent). Result: the
`SessionInfo`.

### 6.13 list_web_tabs

```json
{
  "name": "list_web_tabs",
  "description": "List the web tabs of a project: id, title, URL and whether the tab is locked.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "project": {"type": "string", "pattern": "^[A-Za-z]{2,8}$", "description": "Project identifier, for example HEPH."}
    },
    "required": ["project"],
    "additionalProperties": false
  }
}
```

Calls `projects.snapshot {projectID}`. Result: `{"tabs":[<WebTab>]}` (the project's `webTabs`, in order).

### 6.14 open_web_tab

```json
{
  "name": "open_web_tab",
  "description": "Open a web tab in a project. Every device of the user shows the project's web tabs. A locked tab cannot be closed by mistake.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "project": {"type": "string", "pattern": "^[A-Za-z]{2,8}$", "description": "Project identifier, for example HEPH."},
      "url": {"type": "string", "minLength": 1, "description": "Absolute http or https URL."},
      "title": {"type": "string", "description": "Tab title. Default: set by the page once loaded."},
      "locked": {"type": "boolean", "description": "Lock the tab. Default: false."}
    },
    "required": ["project", "url"],
    "additionalProperties": false
  }
}
```

`url` must parse as a URL with scheme `http` or `https` and a host (else tool error `Use an absolute http or https
URL.`). Calls `tabs.open {projectID, url, title?, locked?}`. Result: the `WebTab`.

### 6.15 search

```json
{
  "name": "search",
  "description": "Search every online Main: projects, tickets, comments, docs, code, skills, web tabs, Claude sessions and devices. Matching ignores case and diacritics, and every word of the query must match. An exact ticket id or project identifier ranks first.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query": {"type": "string", "minLength": 1, "description": "Words to search for."},
      "scopes": {
        "type": "array",
        "items": {"type": "string", "enum": ["projects", "tickets", "comments", "docs", "code", "skills", "webTabs", "sessions", "devices"]},
        "description": "Kinds of items to search. Default: every kind."
      }
    },
    "required": ["query"],
    "additionalProperties": false
  }
}
```

Calls `search.query {query, scopes?, limit: 50}` on this Main and, in parallel, on every online Main of
`otherMains()`. Result: `{"results":[<SearchResult>]}`: this Main's results in its order, then each other Main's in
the order of 6.2; a Main whose call fails is skipped.

### 6.16 list_skills

```json
{
  "name": "list_skills",
  "description": "List the skills of the Hephaestus skills library (separate from ~/.claude): name, description, date of the last change, and the problem of an invalid SKILL.md. The skills enabled in a project are available in its Claude sessions as hephaestus:<name>.",
  "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
}
```

Calls `skills.list {}` on this Main. Result: `{"skills":[<SkillSummary>]}`.

### 6.17 get_skill

```json
{
  "name": "get_skill",
  "description": "Get a skill of the Hephaestus library: the content of its SKILL.md and the list of its files.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "name": {"type": "string", "pattern": "^[a-z0-9-]{1,64}$", "description": "Skill name."}
    },
    "required": ["name"],
    "additionalProperties": false
  }
}
```

Calls `skills.files {name}` and `skills.readFile {name, path: "SKILL.md"}` on this Main. Result:
`{"name":"<name>","content":"<SKILL.md as UTF-8 text>","files":[<SkillFile>]}`, for example
`"files":[{"modified":"2026-10-29T21:04:00.123Z","path":"SKILL.md","size":512}]`.

### 6.18 save_skill

```json
{
  "name": "save_skill",
  "description": "Create a skill of the Hephaestus library, or replace its SKILL.md. content is the whole SKILL.md: YAML front matter between --- lines with name (equal to the skill name) and description, then the instructions in Markdown. Skill names use lowercase letters, digits and hyphens, 1 to 64 characters.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "name": {"type": "string", "pattern": "^[a-z0-9-]{1,64}$", "description": "Skill name."},
      "content": {"type": "string", "minLength": 1, "description": "Complete SKILL.md content."}
    },
    "required": ["name", "content"],
    "additionalProperties": false
  }
}
```

1. `content` must pass the SKILL.md validation of [skills.md](skills.md#4-skillmd) for the skill `name`; otherwise a
   tool error with the problem text, and nothing is written.
2. When the skill does not exist (`skills.list`): `skills.create {name, description}` with the front matter's
   description.
3. `skills.writeFile {name, path: "SKILL.md", data: <content as UTF-8>}`.
4. Result: the skill's `SkillSummary` from `skills.list`.

### 6.19 forge_push_docs (ticket and bundle sessions)

```json
{
  "name": "forge_push_docs",
  "description": "Check the documentation commits of this ticket or bundle that are not on GitHub yet for personal data, then push them. Commit first, once the user agrees. On an error, do what the message says, then call it again.",
  "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
}
```

Calls `MCPHost.forgePushDocs(sessionID:)` with the token's session: the Forge push gate of
[../forge/pipeline.md](../forge/pipeline.md#mcp-tools). Result: the returned text.

### 6.20 forge_push_regen (regeneration sessions only)

```json
{
  "name": "forge_push_regen",
  "description": "Check the regeneration commits that are not on GitHub yet for personal data, then push them; CI then builds them and the app updates itself. On an error, do what the message says, then call it again.",
  "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
}
```

Calls `MCPHost.forgePushRegen(sessionID:)` with the token's session, as for 6.19. Result: the returned text.

### 6.21 get_bundle

```json
{
  "name": "get_bundle",
  "description": "Get the bundle this session coordinates: its tickets in order, each with the ticket, its ticket session, its branch and its work folder, and how many ticket sessions may run at once.",
  "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
}
```

Result: `BundleDetails` ([../services/bundles.md](../services/bundles.md#swift-api)).

### 6.22 start_bundle_ticket

```json
{
  "name": "start_bundle_ticket",
  "description": "Start the ticket session of a ticket of your bundle: it implements the ticket in its own git worktree, on the branch task/<ticket id>, commits there and comments a summary; the ticket goes to review when its session ends its turn. When the ticket already has a session, send that session instructions instead.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "ticket": {"type": "string", "pattern": "^[A-Za-z]{2,8}-[Ff]?[0-9]+$", "description": "Ticket id of your bundle, for example HEPH-12."},
      "instructions": {"type": "string", "description": "Added to the first message of a new session; sent to the existing session of the ticket, where they are required."}
    },
    "required": ["ticket"],
    "additionalProperties": false
  }
}
```

`BundleService.startTicket` ([../services/bundles.md](../services/bundles.md#tools-of-the-coordinator)); `instructions`
empty after trimming counts as absent. Result: the `SessionInfo`.

### 6.23 update_bundle

```json
{
  "name": "update_bundle",
  "description": "Set the status of your bundle: review while you wait for the user's agreement on the combined work, running when work resumes.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "status": {"type": "string", "enum": ["running", "review"], "description": "New status."}
    },
    "required": ["status"],
    "additionalProperties": false
  }
}
```

`BundleService.setStatus`. Result: the `BundleItem`.

### 6.24 finish_bundle

```json
{
  "name": "finish_bundle",
  "description": "Finish your bundle once the work of its tickets is on its base branch (and pushed, in the Forge repository): removes the worktrees, deletes the branches whose work is on the base branch, and marks the bundle done. Lists the branches it kept.",
  "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
}
```

`BundleService.finish`. Result: `{"bundle":<BundleItem>,"keptBranches":[…]}`.

The bundle tools check their arguments first (section 6); then a session without a `bundleID` gets the tool error
`Only the coordinator of a bundle can use this tool.`, and the others call
`MCPHost.bundleTool(_:projectID:bundleID:arguments:)` with the token's `projectID` and `bundleID`.

### 6.25 rename_session

```json
{
  "name": "rename_session",
  "description": "Rename this Claude session: the title the user sees for it in Hephaestus. Use it only when the user asks you to rename this session or chat. The title is one line.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "title": {"type": "string", "minLength": 1, "description": "New title of this session, one line."}
    },
    "required": ["title"],
    "additionalProperties": false
  }
}
```

It renames the session of the token, and no other. `title` is trimmed of whitespace and line breaks; empty or holding
a line break → tool error `The title must not be empty and must be on one line.` Calls `sessions.update {projectID,
sessionID, patch: {title}}` with the token's `projectID` and `sessionID` on this Main
(`MCPHost.perform(_:params:on:)` with the id of `localMain()`), which hosts every project whose sessions it runs. The
same rules as Rename… in the app apply, and the running process is not restarted: the title shows at once and reaches
the CLI at its next start ([cli.md](cli.md#56-interrupt-stop-idle-stop-option-changes)). Result: the `SessionInfo`.

### 6.26 close_session

```json
{
  "name": "close_session",
  "description": "Close this session for good: it keeps its transcript, accepts no more messages and cannot be reopened. Its Claude process stops once this turn ends. Close a feedback session as soon as no question is open; close any other session only when the user says the conversation is done or asks you to close it.",
  "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}
}
```

Calls `MCPHost.closeSession(projectID:sessionID:)` with the token's `projectID` and `sessionID`
([cli.md](cli.md#511-closing-a-session)). Result: `This conversation is over. End your turn now: the session accepts no
more messages.`

## 7. Locating a project and forwarding

A tool acting on a project (every tool with `project`, `ticket` or `parent`) finds the Main hosting it:

1. `projects.list {}` on this Main. The project is found when it or one of its sub projects, at any depth
   (`ProjectSummary.children`), has that identifier.
2. Otherwise `projects.list {}` on every online Main of `otherMains()`, in parallel; the first Main whose tree holds the
   identifier hosts it.
3. Not found → tool error `No online Main hosts project <ID>.`

The tool's protocol calls then go to that Main with `MCPHost.perform(_:params:on:)`: on this Main they run in process,
on another Main they are requests over the peer link ([../services/host.md](../services/host.md)), exactly like the
requests of a remote device. Nothing else is forwarded: `list_devices` and the skills tools use this Main (the registry
and the skills library are synced between Mains), `rename_session` renames a session of this Main, and the Forge,
bundle and close tools call the local hooks.

## 8. Results and errors

`tools/call` result:

```json
{"content":[{"type":"text","text":"<JSON or message>"}],"isError":false}
```

| Situation                                                                | `isError` | `text`                                                                  |
|--------------------------------------------------------------------------|-----------|-------------------------------------------------------------------------|
| success                                                                  | false     | the result of the tool (section 6)                                      |
| an argument is missing, of the wrong type, or breaks a rule of section 6 | true      | `Invalid arguments: <what is wrong>.`                                   |
| a protocol call fails with `ProtocolError`                               | true      | `<code>: <message>`, for example `locked: Project HEPH is being moved.` |
| a tool-specific check fails                                              | true      | the message given in section 6                                          |
| a Forge, bundle or close tool's `MCPHost` call throws (6.19–6.24, 6.26)  | true      | the error's message alone                                               |

## Depends on

| Name                                                                                                                                                                                                                                 | Defined in                                         |
|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------|
| `SessionKind`, `MeshSnapshot`, `ProjectSummary` (`children`), `Project` (`rootPath`), `TicketItem` (`parseError`), `WebTab`, `SearchResult`, `SearchScope`, `SkillSummary`, `SkillFile`, `SessionInfo`, `UploadRef`, `ProtocolError` | [../protocol/types.md](../protocol/types.md)       |
| `mesh.snapshot`, `projects.*`, `tickets.*` (`tickets.addComment` with `author`), `sessions.start`, `sessions.update`, `tabs.open`, `search.query`, `skills.*`, `uploads.*`, `maxChunkSize`                                           | [../protocol/methods.md](../protocol/methods.md)   |
| `HostService` (conformance to `MCPHost`, `perform`), `RequestContext.local(device:author:)`, `MeshService.requestPeer`, starting and stopping the server                                                                             | [../services/host.md](../services/host.md)         |
| `ForgeService.pushDocs`, `ForgeService.pushRegen`, the Forge push gate                                                                                                                                                               | [../forge/pipeline.md](../forge/pipeline.md)       |
| the public repository rule that limits the tools of Forge sessions                                                                                                                                                                   | [../public-repository.md](../public-repository.md) |
| `Log.host`, logging rules                                                                                                                                                                                                            | [../architecture.md](../architecture.md)           |
| SKILL.md validation                                                                                                                                                                                                                  | [skills.md](skills.md)                             |
| token registration by session processes, `SessionService.close` (closing a session)                                                                                                                                                  | [cli.md](cli.md)                                   |
