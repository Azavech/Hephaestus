#if os(macOS)
import Foundation
import HephCore

/// A project named in a prompt: a parent or a sub project.
public struct ProjectRef: Sendable, Equatable {
    public var id: String
    public var name: String
    public var root: URL

    public init(id: String, name: String, root: URL) {
        self.id = id
        self.name = name
        self.root = root
    }
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

    public init(id: String, name: String, root: URL, codeFolder: URL, docsFolder: URL, parent: ProjectRef?,
                subprojects: [ProjectRef], claude: ClaudeDefaults, skills: [String]) {
        self.id = id
        self.name = name
        self.root = root
        self.codeFolder = codeFolder
        self.docsFolder = docsFolder
        self.parent = parent
        self.subprojects = subprojects
        self.claude = claude
        self.skills = skills
    }
}

/// A ticket, as SessionService needs it. Built by the host from TicketService.
public struct ClaudeTicketContext: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String              // TicketItem.description
    public var yaml: String                     // the text of .hephaestus/tickets/<id>.yml
    public var attachments: [URL]               // every comment attachment, in comment then attachment order
    public var parseError: String?              // TicketItem.parseError

    public init(id: String, name: String, description: String, yaml: String, attachments: [URL],
                parseError: String?) {
        self.id = id
        self.name = name
        self.description = description
        self.yaml = yaml
        self.attachments = attachments
        self.parseError = parseError
    }
}

/// A ticket of a bundle, as the bundle prompts list it.
public struct ClaudeBundleTicket: Sendable, Equatable {
    public var id: String
    public var name: String                     // "" for a deleted ticket
    public var status: TicketStatus?            // nil for a deleted ticket

    public init(id: String, name: String, status: TicketStatus?) {
        self.id = id
        self.name = name
        self.status = status
    }
}

/// A bundle, as SessionService needs it. Built by the host from BundleService and TicketService.
public struct ClaudeBundleContext: Sendable, Equatable {
    public var id: String
    public var name: String
    public var base: String                     // BundleItem.base
    public var tickets: [ClaudeBundleTicket]    // in the bundle's order
    public var maxParallel: Int                 // the setting bundles.maxParallel

    public init(id: String, name: String, base: String, tickets: [ClaudeBundleTicket], maxParallel: Int) {
        self.id = id
        self.name = name
        self.base = base
        self.tickets = tickets
        self.maxParallel = maxParallel
    }
}

/// A feedback item of a regeneration cycle.
public struct RegenerationItem: Sendable, Equatable {
    public var ticketID: String
    public var docsCommit: String?

    public init(ticketID: String, docsCommit: String?) {
        self.ticketID = ticketID
        self.docsCommit = docsCommit
    }
}

/// A failed job of a CI run.
public struct FailedCIJob: Sendable, Equatable {
    public var name: String
    public var url: String
    public var log: String                      // last 300 lines of its log, or "Log unavailable: <error>"

    public init(name: String, url: String, log: String) {
        self.name = name
        self.url = url
        self.log = log
    }
}

/// A failed CI run that a regeneration session fixes.
public struct FailedCIRun: Sendable, Equatable {
    public var number: Int                      // GitHub Actions run number
    public var url: String
    public var conclusion: String
    public var jobs: [FailedCIJob]              // at most 3

    public init(number: Int, url: String, conclusion: String, jobs: [FailedCIJob]) {
        self.number = number
        self.url = url
        self.conclusion = conclusion
        self.jobs = jobs
    }
}

/// Given by the Forge when it starts a regeneration session (forge/pipeline.md).
public struct RegenerationContext: Sendable, Equatable {
    public var trigger: String                  // the cycle's trigger: tool, manual or automatic
    public var attempt: Int                     // 1 for the first attempt
    public var targetCommit: String             // full SHA the regeneration starts from
    public var items: [RegenerationItem]        // feedback items of the cycle
    public var failedRun: FailedCIRun?          // set when the session fixes a failed CI run (Retry)

    public init(trigger: String, attempt: Int, targetCommit: String, items: [RegenerationItem],
                failedRun: FailedCIRun?) {
        self.trigger = trigger
        self.attempt = attempt
        self.targetCommit = targetCommit
        self.items = items
        self.failedRun = failedRun
    }
}

/// A device of the mesh, as the Common part lists it.
public struct PromptDevice: Sendable, Equatable {
    public var name: String
    public var platform: String                 // macOS, iOS or iPadOS
    public var isMain: Bool
    public var isThisMac: Bool

    public init(name: String, platform: String, isMain: Bool, isThisMac: Bool) {
        self.name = name
        self.platform = platform
        self.isMain = isMain
        self.isThisMac = isThisMac
    }
}

/// Everything the prompts of one session are rendered from.
public struct PromptContext: Sendable, Equatable {
    public var kind: SessionKind
    public var publicRepository: Bool           // a session of cli.md 3.5: the Forge common part, else the Common part
    public var mainName: String                 // used by the Common part only
    public var devices: [PromptDevice]          // non-revoked devices of the registry; the Common part only
    public var project: ClaudeProjectContext
    public var ticket: ClaudeTicketContext?     // ticket and feedback sessions
    public var mode: SessionMode?               // ticket sessions
    public var instructions: String?            // ticket sessions (cli.md 5.3)
    public var regeneration: RegenerationContext?
    public var bundle: ClaudeBundleContext?     // bundle sessions and the ticket sessions of a bundle
    public var workFolder: URL?                 // the ticket sessions of a bundle: their work folder
    public var branch: String                   // the setting forge.branch (DeviceSettings.forge.branch)

    public init(kind: SessionKind, publicRepository: Bool, mainName: String, devices: [PromptDevice],
                project: ClaudeProjectContext, ticket: ClaudeTicketContext?, mode: SessionMode?, instructions: String?,
                regeneration: RegenerationContext?, bundle: ClaudeBundleContext?, workFolder: URL?,
                branch: String) {
        self.kind = kind
        self.publicRepository = publicRepository
        self.mainName = mainName
        self.devices = devices
        self.project = project
        self.ticket = ticket
        self.mode = mode
        self.instructions = instructions
        self.regeneration = regeneration
        self.bundle = bundle
        self.workFolder = workFolder
        self.branch = branch
    }
}

/// The texts the Main gives Claude (docs/claude/prompts.md): the system prompt appended to Claude Code's own, the
/// generated first message of ticket, feedback and regeneration sessions, and of the sessions of a ticket bundle, and
/// the texts of the title call. The Forge common part, the feedback part and the regeneration part are in
/// ForgePrompts.swift.
public enum Prompts {
    /// Common part or Forge common part, a blank line, then the part of the session kind.
    public static func systemPrompt(_ context: PromptContext) -> String {
        let values = placeholders(context)
        let common = context.publicRepository ? ForgePrompts.commonPart(context) : render(Templates.common, values)
        switch context.kind {
        case .project:
            return common + "\n\n" + render(Templates.projectPart, values)
        case .ticket:
            // The ticket part, a blank line, then the part of the session's mode; for a ticket session of a bundle, a
            // blank line and the bundle ticket part.
            var text = common + "\n\n" + render(Templates.ticketPart, values)
            if let mode = modeTemplate(context) {
                text += "\n\n" + render(mode, values)
            }
            if context.bundle != nil {
                text += "\n\n" + render(Templates.bundleTicketPart, values)
            }
            return text
        case .feedback:
            return common + "\n\n" + ForgePrompts.feedbackPart(context)
        case .regeneration:
            return common + "\n\n" + ForgePrompts.regenerationPart(context)
        case .bundle:
            return common + "\n\n" + render(Templates.bundlePart, values)
        }
    }

    /// The generated first message; nil for project sessions.
    public static func firstMessage(_ context: PromptContext) -> String? {
        switch context.kind {
        case .project:
            return nil
        case .ticket:
            let ticket = context.ticket
            var text = "Work on \(ticket?.id ?? ""): \(ticket?.name ?? "") (\(context.mode?.rawValue ?? ""))."
            let instructions = trimmed(context.instructions)
            if !instructions.isEmpty {
                text += "\n\n" + instructions
            }
            return text
        case .feedback:
            let values = placeholders(context)
            let paragraphs = Templates.feedbackFirstMessage.components(separatedBy: "\n\n")
            var kept: [String] = []
            for (index, paragraph) in paragraphs.enumerated() {
                // The description paragraph and the attached files paragraph are left out when they are empty.
                if index == 1, trimmed(context.ticket?.description).isEmpty { continue }
                if index == 2, context.ticket?.attachments.isEmpty ?? true { continue }
                kept.append(render(paragraph, values))
            }
            return kept.joined(separator: "\n\n")
        case .regeneration:
            guard let failedRun = context.regeneration?.failedRun else {
                return "Regenerate the code from the documentation."
            }
            var text = render(Templates.failedRunFirstParagraph, [
                "runNumber": String(failedRun.number),
                "conclusion": failedRun.conclusion,
                "runURL": failedRun.url,
            ])
            for job in failedRun.jobs {
                let log = jobLog(job.log)
                text += "\n\n" + render(Templates.failedJobBlock, [
                    "jobName": job.name,
                    "jobURL": job.url,
                    "fence": fence(for: log),
                    "jobLog": log,
                ])
            }
            return text
        case .bundle:
            return "Work on bundle \(context.bundle?.id ?? ""): \(context.bundle?.name ?? "")."
        }
    }

    /// The system prompt of the title call (Title call).
    public static let titleSystemPrompt = Templates.titleSystemPrompt

    /// The stdin text of the title call for a first message's text (Title call): the text trimmed of whitespace and
    /// newlines and cut to its first 4,000 characters.
    public static func titleRequest(_ text: String) -> String {
        render(Templates.titleRequest, ["message": String(trimmed(text).prefix(4_000))])
    }

    // MARK: - Placeholders

    /// The values of the placeholders shared by the parts and the feedback first message. ForgePrompts adds
    /// `{forgeToolLines}`, `{pushLine}` and `{regenerationLines}`. In the ticket sessions of a bundle, `{codeFolder}`
    /// and `{docsFolder}` are the folders of its worktree.
    static func placeholders(_ context: PromptContext) -> [String: String] {
        let project = context.project
        let ticketYAML = withoutTrailingNewlines(context.ticket?.yaml ?? "")
        let (codeFolder, docsFolder) = folders(context)
        let bundle = context.bundle
        var values: [String: String] = [
            "mainName": context.mainName,
            "deviceLines": deviceLines(context.devices),
            "projectName": project.name,
            "projectID": project.id,
            "projectRoot": project.root.path,
            "codeFolder": codeFolder.path,
            "docsFolder": docsFolder.path,
            "parentLines": project.parent.map { "- Parent project: \($0.name) (\($0.id)), \($0.root.path)" } ?? "",
            "subprojectLines": subprojectLines(project.subprojects),
            "toolLines": toolLines(context.kind),
            "ticketID": context.ticket?.id ?? "",
            "ticketName": context.ticket?.name ?? "",
            "ticketYAML": ticketYAML,
            "ticketDescription": trimmed(context.ticket?.description),
            "attachmentLines": attachmentLines(context.ticket?.attachments ?? []),
            "fence": fence(for: ticketYAML),
            "mode": context.mode?.rawValue ?? "",
            "instructions": trimmed(context.instructions),
            "bundleID": bundle?.id ?? "",
            "bundleName": bundle?.name ?? "",
            "base": bundle?.base ?? "",
            "maxParallel": bundle.map { String($0.maxParallel) } ?? "",
            "bundleTicketLines": bundleTicketLines(bundle?.tickets ?? []),
            "workFolder": context.workFolder?.path ?? "",
            "branch": context.branch,
        ]
        // These two lines hold placeholders of their own, rendered first.
        values["bundlePushLine"] = substitute(context.publicRepository
            ? "5. Call mcp__hephaestus__forge_push_docs. It checks the commits that are not on GitHub yet for personal "
                + "data and pushes them to {base}; when it returns an error, do what the error says, then call it "
                + "again."
            : "5. Do not push: tell the user that the commits are on {base} in {codeFolder}, ready for them to push.",
            values)
        values["bundleScopeLine"] = context.publicRepository
            ? substitute("In this repository, change only the documentation in {docsFolder}, and do not build or "
                             + "test: the Forge regenerates the code from the documentation.", values)
            : ""
        // Ticket sessions of 3.5 that are not of a bundle: an empty line, then the text.
        values["forgeImplementLines"] = context.publicRepository && context.kind == .ticket && context.bundle == nil
            ? "\n" + substitute("In this repository, change only the documentation in {docsFolder}, and do not build "
                + "or test: the Forge regenerates the code from the documentation. Show the user your changes; when "
                + "they agree, commit only that folder with the message \"docs: <summary> ({ticketID})\", <summary> "
                + "being a one-line summary of the change that names nothing personal: git add -A -- {docsFolder}, "
                + "then git commit -m \"<message>\" -- {docsFolder}. Then call mcp__hephaestus__forge_push_docs. It "
                + "checks the commits that are not on GitHub yet for personal data and pushes them to {branch}; when "
                + "it returns an error, do what the error says, then call it again. The Forge then regenerates the "
                + "code, CI builds it and the app updates itself on the user's Macs.", values)
            : ""
        return values
    }

    /// The code and documentation folders of the prompts: in the ticket sessions of a bundle, `workFolder` and
    /// `workFolder` followed by the project's docs folder (its path relative to the code folder); otherwise the
    /// project's.
    private static func folders(_ context: PromptContext) -> (code: URL, docs: URL) {
        let project = context.project
        guard context.kind == .ticket, context.bundle != nil, let workFolder = context.workFolder else {
            return (project.codeFolder, project.docsFolder)
        }
        let code = project.codeFolder.standardizedFileURL.pathComponents
        let docs = project.docsFolder.standardizedFileURL.pathComponents
        guard docs.starts(with: code) else { return (workFolder, project.docsFolder) }
        let relative = docs.dropFirst(code.count)
        return (workFolder, relative.reduce(workFolder) { $0.appendingPathComponent($1, isDirectory: true) })
    }

    /// `{toolLines}`: the tool lines of the session's kind, the rename line last. Bundle sessions get the lines of
    /// project and ticket sessions without `start_ticket_session`.
    static func toolLines(_ kind: SessionKind) -> String {
        switch kind {
        case .project, .ticket:
            return [
                ToolLines.devices, ToolLines.projects, ToolLines.tickets, ToolLines.comments, ToolLines.ticketSessions,
                ToolLines.webTabs, ToolLines.search, ToolLines.skills, ToolLines.close, ToolLines.rename,
            ].joined(separator: "\n")
        case .bundle:
            return [
                ToolLines.devices, ToolLines.projects, ToolLines.tickets, ToolLines.comments, ToolLines.webTabs,
                ToolLines.search, ToolLines.skills, ToolLines.close, ToolLines.rename,
            ].joined(separator: "\n")
        case .feedback, .regeneration:
            return ""
        }
    }

    /// One line per ticket of the bundle: `- <id>: <name> (<status raw value>)`, or `- <id>: deleted`.
    private static func bundleTicketLines(_ tickets: [ClaudeBundleTicket]) -> String {
        tickets.map { ticket in
            guard let status = ticket.status else { return "- \(ticket.id): deleted" }
            return "- \(ticket.id): \(ticket.name) (\(status.rawValue))"
        }.joined(separator: "\n")
    }

    /// One line per device, sorted by name: `- <name>: <platform>, Main` or `, remote`, then ` (this Mac)`.
    private static func deviceLines(_ devices: [PromptDevice]) -> String {
        devices
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { device in
                "- \(device.name): \(device.platform), \(device.isMain ? "Main" : "remote")"
                    + (device.isThisMac ? " (this Mac)" : "")
            }
            .joined(separator: "\n")
    }

    /// `- Sub projects:`, then `  - <name> (<id>): <root>` per sub project sorted by name; no line without any.
    private static func subprojectLines(_ subprojects: [ProjectRef]) -> String {
        guard !subprojects.isEmpty else { return "" }
        let lines = subprojects
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { "  - \($0.name) (\($0.id)): \($0.root.path)" }
        return (["- Sub projects:"] + lines).joined(separator: "\n")
    }

    /// `- <path>` per attachment; `- none` when there is none.
    private static func attachmentLines(_ attachments: [URL]) -> String {
        guard !attachments.isEmpty else { return "- none" }
        return attachments.map { "- \($0.path)" }.joined(separator: "\n")
    }

    /// The part of the session's mode; nil without a mode.
    private static func modeTemplate(_ context: PromptContext) -> String? {
        switch context.mode {
        case .implement?: return Templates.modeImplement
        case .debug?: return Templates.modeDebug
        case .review?: return Templates.modeReview
        case .plan?: return Templates.modePlan
        case .custom?:
            return trimmed(context.instructions).isEmpty
                ? Templates.modeCustomWithoutInstructions : Templates.modeCustom
        case nil: return nil
        }
    }

    /// A job's log trimmed of trailing whitespace; over 32 KiB, its last 32,768 bytes from the first line start, after
    /// the line `[… earlier log omitted]`.
    private static func jobLog(_ log: String) -> String {
        var text = log
        while let last = text.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            text.unicodeScalars.removeLast()
        }
        let bytes = Array(text.utf8)
        let limit = 32_768
        guard bytes.count > limit else { return text }
        var tail = bytes[(bytes.count - limit)...]
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = tail[tail.index(after: newline)...]
        }
        return "[… earlier log omitted]" + "\n" + String(decoding: tail, as: UTF8.self)
    }

    /// A run of backticks one longer than the longest run in `text`, at least 3.
    static func fence(for text: String) -> String {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func withoutTrailingNewlines(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isNewline {
            text.removeLast()
        }
        return text
    }

    // MARK: - Rendering

    /// Replaces the placeholders of a template, verbatim. A placeholder alone on its line is a line block: an empty
    /// value (zero lines) removes the line, its newline included.
    static func render(_ template: String, _ values: [String: String]) -> String {
        var lines: [String] = []
        for line in template.components(separatedBy: "\n") {
            if line.count > 2, line.hasPrefix("{"), line.hasSuffix("}"),
               let value = values[String(line.dropFirst().dropLast())] {
                if !value.isEmpty {
                    lines.append(value)
                }
                continue
            }
            lines.append(substitute(line, values))
        }
        return lines.joined(separator: "\n")
    }

    /// One pass over the line: each `{name}` with a value is replaced; inserted values are not scanned again.
    private static func substitute(_ line: String, _ values: [String: String]) -> String {
        var result = ""
        var rest = line[...]
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}"),
               let value = values[String(rest[afterOpen..<close])] {
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                result += "{"
                rest = rest[afterOpen...]
            }
        }
        return result + rest
    }
}

/// The lines of `{toolLines}`, one per group of tools.
enum ToolLines {
    static let devices = "- list_devices: the devices of the mesh and whether they are online."
    static let projects = "- list_projects, get_project, create_project, update_project: the projects of every Main, "
        + "with their sub projects and settings."
    static let tickets = "- list_tickets, get_ticket, create_ticket, update_ticket, delete_ticket: the tickets of a "
        + "project."
    static let comments = "- comment_ticket: add a comment to a ticket, with files."
    static let ticketSessions = "- start_ticket_session: start a Claude session that works on a ticket (implement, "
        + "debug, review, plan, or custom instructions)."
    static let webTabs = "- list_web_tabs, open_web_tab: the web tabs of a project."
    static let search = "- search: search projects, tickets, comments, docs, code, skills, web tabs, sessions and "
        + "devices."
    static let skills = "- list_skills, get_skill, save_skill: the Hephaestus skills library."
    static let close = "- close_session: close this session when the user says the conversation is done or asks you "
        + "to close it; it then accepts no message."
    /// The rename line, last of the tool lines of every kind.
    static let rename = "- rename_session: rename this session when the user asks you to."
}

/// The templates of docs/claude/prompts.md held by this file, without their fences.
private enum Templates {
    /// Common part: `project`, `ticket` and `bundle` sessions.
    static let common = """
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

        - project.yml: the project (identifier, name, description, code and docs folders, sub projects, web tabs, enabled skills, Claude defaults).
        - tickets/<ticket id>.yml: one file per ticket, for example tickets/{projectID}-12.yml.
        - attachments/<ticket id>/: the files attached to the comments of a ticket.
        - sessions/: the Claude sessions of the project, this one included.

        A ticket id is the project identifier, a hyphen and the ticket number. Feedback tickets, which the Forge creates from the user's feedback about the Hephaestus app, are numbered in their own series, with an F before the number: {projectID}-F3. A ticket file looks like this:

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

        status is one of todo, in_progress, review and done. A comment's author is the name of the device it was written on, or Claude for the comments added with the Hephaestus tools; edited is present once a comment was changed; attachments are stored in .hephaestus/attachments/<ticket id>/.

        ## Hephaestus tools

        The mcp__hephaestus__ tools act on the data of every Main of the mesh, and every device of the user shows their changes at once:

        {toolLines}

        Rules:

        - Use these tools to create and change projects, tickets, comments and web tabs, and to delete tickets. Never create, edit or delete files under .hephaestus/ yourself.
        - Reach other projects, on this Mac or on another Main, through these tools and their identifier.

        ## Questions

        When you ask the user two or more questions in a message, label each with a capital letter, in order: A, B, C, and so on, so the user can answer "A: …, B: …". A single question has no letter. A new set of questions starts again at A. A follow-up question on the answer to a lettered question takes that question's letter followed by a number: follow-ups on C are C.1, C.2, and so on.
        """

    /// Project part: `kind` = `project`.
    static let projectPart = """
        ## This session

        This is the Claude chat of {projectName}. Here the user plans and coordinates the project with you: creating and updating many tickets at once, commenting on them, starting ticket sessions, running the project, working in its code and documentation, and acting on other projects.
        """

    /// Ticket part: `kind` = `ticket`, followed by a blank line and the part of the mode.
    static let ticketPart = """
        ## Ticket {ticketID}

        This session works on ticket {ticketID} of {projectName}. Its file as it was when the session started is below; call mcp__hephaestus__get_ticket to see its current state.

        {fence}yaml
        {ticketYAML}
        {fence}

        Files attached to the ticket:
        {attachmentLines}
        """

    /// Mode implement.
    static let modeImplement = """
        ## Mode: implement

        Implement {ticketID}:

        1. Make the changes the ticket asks for.
        2. Keep the documentation in {docsFolder} in sync with your changes.
        3. Build the project and run its tests, and fix what fails.
        4. Add a comment to {ticketID} with mcp__hephaestus__comment_ticket that summarizes what you changed and how you checked it.
        {forgeImplementLines}
        """

    /// Mode debug.
    static let modeDebug = """
        ## Mode: debug

        Debug {ticketID}: find the root cause of the problem it describes. Reproduce the problem or collect evidence from the code and logs, then explain the root cause to the user with that evidence. Propose a fix, and apply it only after the user confirms.
        """

    /// Mode review.
    static let modeReview = """
        ## Mode: review

        Review the work done for {ticketID}: compare the changes made for it, in the files and in git, with the ticket and with the documentation in {docsFolder}. Add your findings to {ticketID} as a comment with mcp__hephaestus__comment_ticket. Do not modify any file.
        """

    /// Mode plan.
    static let modePlan = """
        ## Mode: plan

        Plan {ticketID}: study the code and the documentation, then write an implementation plan and add it to {ticketID} as a comment with mcp__hephaestus__comment_ticket. Do not modify the code or the documentation.
        """

    /// Mode custom, with `instructions`.
    static let modeCustom = """
        ## Mode: custom

        Follow the user's instructions for this session:

        {instructions}
        """

    /// Mode custom, without `instructions`.
    static let modeCustomWithoutInstructions = """
        ## Mode: custom

        Follow the instructions the user gave in the first message of this session.
        """

    /// Bundle part: `kind` = `bundle`, the coordinator of a bundle.
    static let bundlePart = """
        ## Bundle {bundleID}

        This session coordinates bundle {bundleID} of {projectName}, "{bundleName}". Its tickets are implemented in parallel, each by its own ticket session in its own git worktree, on the branch ticket/<ticket id> made from {base}; you bring their work together. Call mcp__hephaestus__get_bundle for its current state.

        Tickets of the bundle when this session started:
        {bundleTicketLines}

        Bundle tools: get_bundle, start_bundle_ticket (start the session of a ticket, or send instructions to it), update_bundle (set the status to review or running), finish_bundle (remove the worktrees and branches once the work is brought in).

        1. Start the ticket sessions with mcp__hephaestus__start_bundle_ticket, in the bundle's order, at most {maxParallel} at a time. Each one implements its ticket, commits on its branch and comments a summary on its ticket; Hephaestus sets the ticket to review when its session ends its turn.
        2. Hephaestus sends you a message when a ticket session ends its turn, fails or waits for a permission answer. Then read the ticket's comments with mcp__hephaestus__get_ticket and its work with git log and git diff {base}...ticket/<ticket id>, start the next waiting ticket, and send instructions with start_bundle_ticket when the work is incomplete. Tell the user when a session waits for them.
        3. When every ticket is in review, call mcp__hephaestus__update_bundle with the status review, show the user a summary of each ticket and of the combined changes, and wait for their agreement. Send the changes they ask for to the ticket sessions, with the status running while they work.
        4. When the user agrees, bring the work into {codeFolder} on {base}, one ticket at a time in the bundle's order: git cherry-pick {base}..ticket/<ticket id>. Resolve conflicts yourself, then git cherry-pick --continue; ask the user when a conflict needs a decision.
        {bundlePushLine}
        6. Call mcp__hephaestus__finish_bundle and tell the user which branches it kept.

        Never edit the files of a ticket yourself, except to resolve a conflict while bringing its work in.
        """

    /// Bundle ticket part: appended to the ticket part of a `ticket` session of a bundle.
    static let bundleTicketPart = """
        ## Bundle {bundleID}

        This session is one of the parallel sessions of bundle {bundleID}. Work only in {workFolder}, a git worktree on the branch ticket/{ticketID}: never change files elsewhere and never switch branches. Commit your changes on ticket/{ticketID} without pushing, and do not wait for the user's agreement first: the coordinator of the bundle reviews the work with the user. When you are blocked, say why in a comment on {ticketID} and end your turn.
        {bundleScopeLine}
        """

    /// First message of a feedback session.
    static let feedbackFirstMessage = """
        Work on {ticketID}: {ticketName} (feedback).

        {ticketDescription}

        Attached files:
        {attachmentLines}
        """

    /// First paragraph of the first message of a regeneration that fixes a failed CI run.
    static let failedRunFirstParagraph = """
        Fix the build: CI run #{runNumber} failed with conclusion {conclusion}: {runURL}
        """

    /// One block per failed job of that first message.
    static let failedJobBlock = """
        Job {jobName} ({jobURL}), end of its log:

        {fence}text
        {jobLog}
        {fence}
        """

    /// The system prompt of the title call, passed with --system-prompt.
    static let titleSystemPrompt = """
        You write short titles for conversations.
        """

    /// The stdin text of the title call.
    static let titleRequest = """
        Write a title of at most 6 words for a conversation that starts with the message below. Reply with the title alone, in the language of the message, without quotes or a final period.

        <message>
        {message}
        </message>
        """
}
#endif
