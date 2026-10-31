import CoreGraphics
import Foundation
import HephCore
import ImageIO

extension Workspace {
    /// A Workspace that is never started, set synchronously from the sample data of `PreviewData`, whose requests
    /// `PreviewData.respond` answers. The SwiftUI previews and the snapshot tests use it.
    public static func preview() -> Workspace {
        let workspace = Workspace(device: PreviewData.macBookProDevice, environment: .preview, isPreview: true)
        workspace.applyPreview(mesh: PreviewData.mesh, credentials: PreviewData.credentials)

        let studio = MainConnection(id: PreviewData.studioID, workspace: workspace)
        studio.applyPreview(serverDevice: PreviewData.studioDevice,
                            hostInfo: PreviewData.hostInfo(of: PreviewData.studioID),
                            projects: PreviewData.projects(of: PreviewData.studioID),
                            skills: [PreviewData.skill])
        workspace.addPreviewConnection(studio)

        // This device is a Main: its connection is the loopback one.
        let macBookPro = MainConnection(id: PreviewData.macBookProID, workspace: workspace, isLoopback: true)
        macBookPro.applyPreview(serverDevice: PreviewData.macBookProDevice,
                                hostInfo: PreviewData.hostInfo(of: PreviewData.macBookProID),
                                projects: PreviewData.projects(of: PreviewData.macBookProID),
                                skills: [PreviewData.skill])
        workspace.addPreviewConnection(macBookPro)

        workspace.addPreviewStore(mainDeviceID: PreviewData.studioID, snapshot: PreviewData.hephaestusSnapshot)
        workspace.addPreviewStore(mainDeviceID: PreviewData.studioID, snapshot: PreviewData.apiSnapshot)
        workspace.forge.apply(PreviewData.forgeState(of: PreviewData.studioID), from: PreviewData.studioID)
        return workspace
    }
}

/// The sample data of the previews and the answers of `Workspace.preview()` (docs/client/workspace.md, "Previews").
/// UUIDs are `00000000-0000-4000-8000-000000000NNN` (#NNN); times are on 2026-10-29, UTC, unless written in full.
public enum PreviewData {
    /// Mesh #100, key: 32 zero bytes.
    public static let credentials = MeshCredentials(meshID: id(0x100), meshKey: Data(repeating: 0, count: 32))

    /// The answer to a request of the preview workspace: `params` and the result are JSON as on the wire.
    public static func respond(mainDeviceID: UUID, method: String, params: Data) throws -> Data {
        switch RPCMethod(rawValue: method) {
        case .meshSnapshot?:
            return try encode(mesh)
        case .hostInfo?:
            return try encode(hostInfo(of: mainDeviceID))
        case .projectsList?:
            return try encode(ProjectsListResult(projects: projects(of: mainDeviceID)))
        case .projectsSnapshot?:
            let request = try decode(ProjectsSnapshotParams.self, method: method, params: params)
            return try encode(try snapshot(of: request.projectID, on: mainDeviceID))
        case .sessionsHistory?:
            let request = try decode(SessionsHistoryParams.self, method: method, params: params)
            return try encode(try history(request, on: mainDeviceID))
        case .filesList?:
            let request = try decode(FilesListParams.self, method: method, params: params)
            return try encode(FilesListResult(entries: try listFiles(request, on: mainDeviceID)))
        case .filesRead?:
            let request = try decode(FilesReadParams.self, method: method, params: params)
            return try encode(try readFile(request, on: mainDeviceID))
        case .attachmentsRead?:
            let request = try decode(AttachmentsReadParams.self, method: method, params: params)
            return try encode(attachmentRange(offset: request.offset, length: request.length))
        case .sessionsReadAttachment?:
            let request = try decode(SessionsReadAttachmentParams.self, method: method, params: params)
            return try encode(attachmentRange(offset: request.offset, length: request.length))
        case .skillsList?:
            return try encode(SkillsListResult(skills: [skill]))
        case .skillsFiles?:
            let request = try decode(SkillsFilesParams.self, method: method, params: params)
            guard request.name == skill.name else { throw skillNotFound(request.name) }
            return try encode(SkillsFilesResult(files: [SkillFile(path: "SKILL.md", size: skillContent.utf8.count,
                                                                  modified: skill.modified)]))
        case .skillsReadFile?:
            let request = try decode(SkillsReadFileParams.self, method: method, params: params)
            guard request.name == skill.name else { throw skillNotFound(request.name) }
            guard ProjectPath.normalize(request.path) == "SKILL.md" else {
                throw ProtocolError(.notFound, "No file at \(request.path).")
            }
            return try encode(SkillsReadFileResult(data: Data(skillContent.utf8)))
        case .searchQuery?:
            return try encode(SearchQueryResult(results: []))
        case .forgeStatus?:
            return try encode(forgeState(of: mainDeviceID))
        case .subscribe?, .unsubscribe?:
            return try encode(EmptyPayload())
        default:
            throw ProtocolError(.unavailable, "Not available in previews")
        }
    }

    // MARK: - Ids and times

    /// `00000000-0000-4000-8000-000000000NNN`, written `#NNN`: `id(0x100)` is #100.
    static func id(_ number: UInt16) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, UInt8(number >> 8), UInt8(number & 0xFF)))
    }

    /// A time of 2026-10-29, UTC.
    static func at(_ hours: Int, _ minutes: Int, _ seconds: Int) -> Date {
        Date(timeIntervalSince1970: 1_793_232_000 + TimeInterval(hours * 3_600 + minutes * 60 + seconds))
    }

    /// 2026-10-01T09:00:00.000Z
    static let pairedAt = Date(timeIntervalSince1970: 1_790_845_200)
    /// 2026-10-28T12:00:00.000Z
    static let skillModified = Date(timeIntervalSince1970: 1_793_188_800)

    static let studioID = id(0x001)
    static let macBookProID = id(0x002)
    static let iPadID = id(0x003)

    // MARK: - Mesh

    static let studioDevice = DeviceInfo(id: studioID, name: "Studio", platform: .macOS, isMain: true,
                                        appVersion: "1.0", build: 42)
    static let macBookProDevice = DeviceInfo(id: macBookProID, name: "Sam's MacBook Pro", platform: .macOS,
                                             isMain: true, appVersion: "1.0", build: 42)

    static let mesh = MeshSnapshot(
        meshID: credentials.meshID,
        devices: PresenceModel.sortedByName([
            DeviceRecord(id: studioID, name: "Studio", platform: .macOS, isMain: true,
                         addresses: ["Sams-Mac-mini.local", "192.0.2.10"], port: 47100, appVersion: "1.0", build: 42,
                         pairedAt: pairedAt, updatedAt: at(8, 0, 0), revoked: false),
            DeviceRecord(id: macBookProID, name: "Sam's MacBook Pro", platform: .macOS, isMain: true,
                         addresses: ["198.51.100.2"], port: 47100, appVersion: "1.0", build: 42,
                         pairedAt: pairedAt, updatedAt: at(8, 0, 0), revoked: false),
            DeviceRecord(id: iPadID, name: "Sam's iPad", platform: .iPadOS, isMain: false, addresses: [], port: 0,
                         appVersion: "1.0", build: 42, pairedAt: pairedAt, updatedAt: at(8, 0, 0), revoked: false),
        ]),
        presence: [
            Presence(deviceID: studioID, online: true, lastSeen: at(21, 0, 0), via: []),
            Presence(deviceID: macBookProID, online: true, lastSeen: at(21, 0, 0), via: []),
            Presence(deviceID: iPadID, online: false, lastSeen: at(18, 30, 0), via: []),
        ]
    )

    static let forgeConfig = ForgeConfig(sourceProjectID: "HEPH", repository: "Azavech/Hephaestus", branch: "main",
                                         autoRegenerate: true)

    /// The host info of both Mains; Studio is the Forge.
    static func hostInfo(of mainDeviceID: UUID) -> HostInfoResult {
        HostInfoResult(device: mainDeviceID == studioID ? studioDevice : macBookProDevice,
                       projectsFolder: "/Users/user/Developer", claudeAvailable: true,
                       claudePath: "/Users/user/.local/bin/claude", gitAvailable: true,
                       forge: mainDeviceID == studioID ? forgeConfig : nil)
    }

    /// The Forge state of a Main: Studio's Forge with its config and no items; Sam's MacBook Pro is not the Forge.
    static func forgeState(of mainDeviceID: UUID) -> ForgeState {
        if mainDeviceID == studioID {
            return ForgeState(enabled: true, hostDeviceID: studioID, config: forgeConfig, appDocsHash: "", items: [])
        }
        return ForgeState(enabled: false, hostDeviceID: mainDeviceID, appDocsHash: "", items: [])
    }

    // MARK: - Projects

    static let hephaestus = Project(
        id: "HEPH", name: "Hephaestus", description: "Multi-device project workbench", created: pairedAt, code: ".",
        docs: "docs", ticketCounter: 4, feedbackCounter: 0, subprojects: ["services/api"],
        webTabs: [
            WebTab(id: id(0x201), title: "GitHub", url: "https://github.com/Azavech/Hephaestus", locked: true),
            WebTab(id: id(0x202), title: "Swift Forums", url: "https://forums.swift.org", locked: false),
        ],
        skills: [], claude: ClaudeDefaults(model: "opus", permissionMode: .acceptEdits), deviceID: studioID,
        rootPath: "/Users/user/Developer/Hephaestus", migrating: false
    )

    static let api = Project(
        id: "API", name: "Hephaestus API", description: "Sync service", created: pairedAt, code: ".", docs: "docs",
        ticketCounter: 1, feedbackCounter: 0, subprojects: [], webTabs: [], skills: [], claude: ClaudeDefaults(),
        deviceID: studioID, rootPath: "/Users/user/Developer/Hephaestus/services/api", migrating: false
    )

    /// The projects tree of a Main: `HEPH` with its sub project `API` on Studio; none on Sam's MacBook Pro.
    static func projects(of mainDeviceID: UUID) -> [ProjectSummary] {
        guard mainDeviceID == studioID else { return [] }
        let apiSummary = ProjectSummary(id: api.id, name: api.name, description: api.description,
                                        deviceID: studioID, rootPath: api.rootPath, children: [], migrating: false,
                                        pendingPermissionCount: 0)
        return [ProjectSummary(id: hephaestus.id, name: hephaestus.name, description: hephaestus.description,
                               deviceID: studioID, rootPath: hephaestus.rootPath, children: [apiSummary],
                               migrating: false, pendingPermissionCount: 1)]
    }

    // MARK: - Tickets

    static let tickets: [TicketItem] = [
        TicketItem(id: "HEPH-1", name: "Set up the repository",
                   description: "Create the Xcode project and the package.", status: .done, created: at(9, 0, 0),
                   updated: at(10, 0, 0), comments: []),
        TicketItem(id: "HEPH-2", name: "Sidebar breaks on iPad",
                   description: "The sidebar overlaps the editor in split view.", status: .inProgress,
                   created: at(11, 0, 0), updated: at(20, 40, 0),
                   comments: [
                       TicketComment(id: id(0x211), author: "Sam's iPad", created: at(11, 5, 0),
                                     body: "Screenshot attached.",
                                     attachments: [TicketAttachment(file: "screenshot.png", type: "image/png",
                                                                    size: 18000)]),
                       TicketComment(id: id(0x212), author: "Claude", created: at(20, 40, 0),
                                     body: "Fixed the width of the sidebar column; please review.", attachments: []),
                   ]),
        TicketItem(id: "HEPH-3", name: "Review the pairing flow",
                   description: "Check the 6-digit code flow on every platform.", status: .review,
                   created: at(12, 0, 0), updated: at(19, 0, 0), comments: []),
        TicketItem(id: "HEPH-4", name: "Add Go highlighting",
                   description: "Keywords, strings, raw strings and comments.", status: .todo, created: at(20, 10, 0),
                   updated: at(20, 10, 0), comments: []),
    ]

    static let apiTickets: [TicketItem] = [
        TicketItem(id: "API-1", name: "Define the endpoints", description: "List the endpoints of the sync service.",
                   status: .todo, created: at(13, 0, 0), updated: at(13, 0, 0), comments: []),
    ]

    // MARK: - Sessions

    static let planSessionID = id(0x301)
    static let ticketSessionID = id(0x302)

    static let permissionRequest = PermissionRequest(requestID: "perm-1", toolName: "Bash",
                                                     input: #"{"command":"./scripts/build.sh ios"}"#,
                                                     suggestions: "[]")

    static let sessions: [SessionInfo] = [
        SessionInfo(id: planSessionID, kind: .project, title: "Plan the release", created: at(20, 0, 0),
                    updated: at(20, 0, 6), permissionMode: .acceptEdits, allowsAllTools: false, status: .idle,
                    pendingPermissions: []),
        SessionInfo(id: ticketSessionID, kind: .ticket, ticketID: "HEPH-2", mode: .implement, title: "Implement HEPH-2",
                    created: at(20, 30, 0), updated: at(20, 30, 5), permissionMode: .acceptEdits, allowsAllTools: false,
                    status: .waitingPermission, pendingPermissions: [permissionRequest]),
    ]

    /// The events of a session, in log order.
    static func events(of sessionID: UUID) -> [SessionEvent]? {
        switch sessionID {
        case planSessionID:
            return [
                SessionEvent(id: id(0x401).uuidString, at: at(20, 0, 1), type: .user,
                             text: "Plan the 1.1 release and create the tickets.", deviceID: macBookProID),
                SessionEvent(id: id(0x402).uuidString, at: at(20, 0, 2), type: .assistant,
                             text: "I will create the missing ticket."),
                SessionEvent(id: id(0x403).uuidString, at: at(20, 0, 3), type: .toolUse, toolUseID: "toolu_1",
                             name: "mcp__hephaestus__create_ticket",
                             input: #"{"project":"HEPH","name":"Add Go highlighting"}"#),
                SessionEvent(id: id(0x404).uuidString, at: at(20, 0, 4), type: .toolResult, text: "Created HEPH-4",
                             toolUseID: "toolu_1", isError: false),
                SessionEvent(id: id(0x405).uuidString, at: at(20, 0, 5), type: .assistant, text: "Created HEPH-4."),
                SessionEvent(id: id(0x406).uuidString, at: at(20, 0, 6), type: .result, isError: false,
                             durationMS: 8200, costUSD: 0.04, stopReason: "end_turn"),
            ]
        case ticketSessionID:
            return [
                SessionEvent(id: id(0x411).uuidString, at: at(20, 30, 1), type: .user,
                             text: "Work on HEPH-2: Sidebar breaks on iPad (implement).", deviceID: macBookProID),
                SessionEvent(id: id(0x412).uuidString, at: at(20, 30, 2), type: .assistant,
                             text: "The sidebar width is fixed at 320 pt; I will make it flexible."),
                SessionEvent(id: id(0x413).uuidString, at: at(20, 30, 3), type: .toolUse, toolUseID: "toolu_2",
                             name: "Edit",
                             input: #"{"file_path":"/Users/user/Developer/Hephaestus/Sources/App.swift"}"#),
                SessionEvent(id: id(0x414).uuidString, at: at(20, 30, 4), type: .toolResult,
                             text: "The file has been updated.", toolUseID: "toolu_2", isError: false),
                SessionEvent(id: id(0x415).uuidString, at: at(20, 30, 5), type: .permission,
                             input: permissionRequest.input, requestID: permissionRequest.requestID,
                             toolName: permissionRequest.toolName, suggestions: permissionRequest.suggestions),
            ]
        default:
            return nil
        }
    }

    // MARK: - Snapshots

    /// `projects.snapshot` of HEPH: tickets by number, sessions by `created`.
    static let hephaestusSnapshot = ProjectsSnapshotResult(project: hephaestus, tickets: tickets, bundles: [],
                                                           sessions: sessions)

    static let apiSnapshot = ProjectsSnapshotResult(project: api, tickets: apiTickets, bundles: [], sessions: [])

    // MARK: - Files

    /// The files of HEPH by path; the folders `docs` and `Sources`. Every entry is modified at 20:00:00.
    static let files: [String: String] = [
        "README.md": "# Hephaestus\n\nMulti-device project workbench.\n",
        "docs/README.md": "# Documentation\n\n- [Tickets](tickets.md)\n- Code\n",
        "docs/tickets.md": "# Tickets\n\nEvery ticket has an id, a name and a status.\n",
        "Sources/App.swift": "import SwiftUI\n\n@main\nstruct DemoApp: App {\n    var body: some Scene {\n"
            + "        WindowGroup { Text(\"Hello\") }\n    }\n}\n",
    ]

    static let folders: Set<String> = ["", "docs", "Sources"]

    // MARK: - Skill

    static let skill = SkillSummary(name: "release-notes", description: "Write release notes from the done tickets",
                                    modified: skillModified)

    static let skillContent = "---\nname: release-notes\ndescription: Write release notes from the done tickets\n"
        + "---\n\nList the tickets done since the last release, one line per ticket.\n"

    // MARK: - Attachments

    /// A 160 × 100 PNG filled with sRGB (0.95, 0.42, 0.18): the content of every attachment.
    static let attachmentPNG: Data = {
        let width = 160
        let height = 100
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.42, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1,
                                                                 nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }()

    // MARK: - Answers

    private static func encode(_ value: some Encodable) throws -> Data {
        do {
            return try WireCoding.encodeJSON(value)
        } catch {
            throw ProtocolError(error)
        }
    }

    private static func decode<P: Decodable>(_ type: P.Type, method: String, params: Data) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }

    private static func projectNotFound(_ projectID: String) -> ProtocolError {
        ProtocolError(.notFound, "Project \(projectID) is not hosted on this Main.")
    }

    private static func skillNotFound(_ name: String) -> ProtocolError {
        ProtocolError(.notFound, "Skill \(name) does not exist.")
    }

    private static func snapshot(of projectID: String, on mainDeviceID: UUID) throws -> ProjectsSnapshotResult {
        guard mainDeviceID == studioID else { throw projectNotFound(projectID) }
        switch projectID {
        case hephaestus.id: return hephaestusSnapshot
        case api.id: return apiSnapshot
        default: throw projectNotFound(projectID)
        }
    }

    /// A page of a session's events, as `sessions.history` pages them.
    private static func history(_ request: SessionsHistoryParams, on mainDeviceID: UUID) throws
        -> SessionsHistoryResult {
        _ = try snapshot(of: request.projectID, on: mainDeviceID)
        guard request.projectID == hephaestus.id, let events = events(of: request.sessionID) else {
            throw ProtocolError(.notFound, "session \(request.sessionID.uuidString) not found")
        }
        let total = events.count
        let end = min(max(request.before ?? total, 0), total)
        let limit = min(max(request.limit ?? 1_000, 1), 5_000)
        let start = max(0, end - limit)
        let page = Array(events[start..<end])
        return SessionsHistoryResult(events: page, firstIndex: page.isEmpty ? end : start, total: total)
    }

    private static func listFiles(_ request: FilesListParams, on mainDeviceID: UUID) throws -> [FileEntry] {
        _ = try snapshot(of: request.projectID, on: mainDeviceID)
        let folder = ProjectPath.normalize(request.path)
        guard request.projectID == hephaestus.id else {
            guard folder.isEmpty else { throw ProtocolError(.notFound, "No folder at \(request.path).") }
            return []
        }
        if files[folder] != nil {
            throw ProtocolError(.badRequest, "\(request.path) is a file.")
        }
        guard folders.contains(folder) else {
            throw ProtocolError(.notFound, "No folder at \(request.path).")
        }
        let modified = at(20, 0, 0)
        let subfolders = folders.filter { !$0.isEmpty && ProjectPath.parent(of: $0) == folder }
            .map { FileEntry(name: ProjectPath.name(of: $0), path: $0, isDirectory: true, size: 0, modified: modified) }
        let contents = files.filter { ProjectPath.parent(of: $0.key) == folder }
            .map { FileEntry(name: ProjectPath.name(of: $0.key), path: $0.key, isDirectory: false,
                             size: $0.value.utf8.count, modified: modified) }
        let byName: (FileEntry, FileEntry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return subfolders.sorted(by: byName) + contents.sorted(by: byName)
    }

    private static func readFile(_ request: FilesReadParams, on mainDeviceID: UUID) throws -> FilesReadResult {
        _ = try snapshot(of: request.projectID, on: mainDeviceID)
        let path = ProjectPath.normalize(request.path)
        guard request.projectID == hephaestus.id, let content = files[path] else {
            if request.projectID == hephaestus.id, folders.contains(path) {
                throw ProtocolError(.badRequest, "\(request.path) is a folder.")
            }
            throw ProtocolError(.notFound, "No file at \(request.path).")
        }
        let data = Data(content.utf8)
        if request.offset == nil, request.length == nil {
            return FilesReadResult(data: data, revision: Revision.of(data), size: data.count)
        }
        return FilesReadResult(data: range(of: data, offset: request.offset, length: request.length), revision: "",
                               size: data.count)
    }

    private static func attachmentRange(offset: Int?, length: Int?) -> AttachmentsReadResult {
        let png = attachmentPNG
        return AttachmentsReadResult(data: range(of: png, offset: offset, length: length), size: png.count,
                                     mimeType: "image/png")
    }

    /// The bytes from `offset` (default 0): `min(length, size − offset)`, `length` defaulting to and capped at 4 MiB.
    private static func range(of data: Data, offset: Int?, length: Int?) -> Data {
        let start = min(max(offset ?? 0, 0), data.count)
        let count = min(max(length ?? MethodLimits.maxChunkSize, 1), MethodLimits.maxChunkSize)
        let end = min(start + count, data.count)
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
    }
}
