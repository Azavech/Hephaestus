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

/// A task, as SessionService needs it. Built by the host from TaskService.
public struct ClaudeTaskContext: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String              // TaskItem.description
    public var yaml: String                     // the text of .hephaestus/tasks/<id>.yml
    public var attachments: [URL]               // every comment attachment, in comment then attachment order
    public var parseError: String?              // TaskItem.parseError

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

/// A feedback item of a regeneration cycle.
public struct RegenerationItem: Sendable, Equatable {
    public var taskID: String
    public var docsCommit: String?

    public init(taskID: String, docsCommit: String?) {
        self.taskID = taskID
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
    public var task: ClaudeTaskContext?         // task and feedback sessions
    public var mode: SessionMode?               // task sessions
    public var instructions: String?            // task sessions (cli.md 5.3)
    public var regeneration: RegenerationContext?
    public var branch: String                   // the setting forge.branch (DeviceSettings.forge.branch)

    public init(kind: SessionKind, publicRepository: Bool, mainName: String, devices: [PromptDevice],
                project: ClaudeProjectContext, task: ClaudeTaskContext?, mode: SessionMode?, instructions: String?,
                regeneration: RegenerationContext?, branch: String) {
        self.kind = kind
        self.publicRepository = publicRepository
        self.mainName = mainName
        self.devices = devices
        self.project = project
        self.task = task
        self.mode = mode
        self.instructions = instructions
        self.regeneration = regeneration
        self.branch = branch
    }
}

/// The texts the Main gives Claude (docs/claude/prompts.md): the system prompt appended to Claude Code's own and the
/// generated first message of task, feedback and regeneration sessions. The Forge common part, the feedback part and
/// the regeneration part are in ForgePrompts.swift.
public enum Prompts {
    /// Common part or Forge common part, a blank line, then the part of the session kind.
    public static func systemPrompt(_ context: PromptContext) -> String {
        let values = placeholders(context)
        let common = context.publicRepository ? ForgePrompts.commonPart(context) : render(Templates.common, values)
        switch context.kind {
        case .project:
            return common + "\n\n" + render(Templates.projectPart, values)
        case .task:
            // The task part, a blank line, then the part of the session's mode.
            var text = common + "\n\n" + render(Templates.taskPart, values)
            if let mode = modeTemplate(context) {
                text += "\n\n" + render(mode, values)
            }
            return text
        case .feedback:
            return common + "\n\n" + ForgePrompts.feedbackPart(context)
        case .regeneration:
            return common + "\n\n" + ForgePrompts.regenerationPart(context)
        }
    }

    /// The generated first message; nil for project sessions.
    public static func firstMessage(_ context: PromptContext) -> String? {
        switch context.kind {
        case .project:
            return nil
        case .task:
            let task = context.task
            var text = "Work on \(task?.id ?? ""): \(task?.name ?? "") (\(context.mode?.rawValue ?? ""))."
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
                if index == 1, trimmed(context.task?.description).isEmpty { continue }
                if index == 2, context.task?.attachments.isEmpty ?? true { continue }
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
        }
    }

    // MARK: - Placeholders

    /// The values of the placeholders shared by the parts and the feedback first message. ForgePrompts adds
    /// `{forgeToolLines}`, `{pushLine}` and `{regenerationLines}`.
    static func placeholders(_ context: PromptContext) -> [String: String] {
        let project = context.project
        let taskYAML = withoutTrailingNewlines(context.task?.yaml ?? "")
        return [
            "mainName": context.mainName,
            "deviceLines": deviceLines(context.devices),
            "projectName": project.name,
            "projectID": project.id,
            "projectRoot": project.root.path,
            "codeFolder": project.codeFolder.path,
            "docsFolder": project.docsFolder.path,
            "parentLines": project.parent.map { "- Parent project: \($0.name) (\($0.id)), \($0.root.path)" } ?? "",
            "subprojectLines": subprojectLines(project.subprojects),
            "taskID": context.task?.id ?? "",
            "taskName": context.task?.name ?? "",
            "taskYAML": taskYAML,
            "taskDescription": trimmed(context.task?.description),
            "attachmentLines": attachmentLines(context.task?.attachments ?? []),
            "fence": fence(for: taskYAML),
            "mode": context.mode?.rawValue ?? "",
            "instructions": trimmed(context.instructions),
            "branch": context.branch,
        ]
    }

    /// The nine tool lines of the Common part, from `- list_devices:` to `- list_skills, get_skill, save_skill:`
    /// (`{forgeToolLines}` of project and task sessions in the Forge common part).
    static let commonToolLines: String = {
        let lines = Templates.common.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.hasPrefix("- list_devices:") }),
              let last = lines.firstIndex(where: { $0.hasPrefix("- list_skills, get_skill, save_skill:") }),
              first <= last
        else { return "" }
        return lines[first...last].joined(separator: "\n")
    }()

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

/// The templates of docs/claude/prompts.md held by this file, without their fences.
private enum Templates {
    /// Common part: `project` and `task` sessions.
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

        - project.yml: the project (identifier, name, description, code and docs folders, sub projects, web tabs, run configurations, enabled skills, Claude defaults).
        - tasks/<task id>.yml: one file per task, for example tasks/{projectID}-12.yml.
        - attachments/<task id>/: the files attached to the comments of a task.
        - sessions/: the Claude sessions of the project, this one included.

        A task id is the project identifier, a hyphen and the task number. A task file looks like this:

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

        - list_devices: the devices of the mesh and whether they are online.
        - list_projects, get_project, create_project, update_project: the projects of every Main, with their sub projects and settings.
        - list_tasks, get_task, create_task, update_task, delete_task: the tasks of a project.
        - comment_task: add a comment to a task, with files.
        - start_task_session: start a Claude session that works on a task (implement, debug, review, plan, or custom instructions).
        - list_runs, start_run, stop_run, get_run_output: the run configurations of a project and their runs.
        - list_web_tabs, open_web_tab: the web tabs of a project.
        - search: search projects, tasks, comments, docs, code, skills, web tabs, sessions and devices.
        - list_skills, get_skill, save_skill: the Hephaestus skills library.

        Rules:

        - Use these tools to create and change projects, tasks, comments and web tabs, and to delete tasks. Never create, edit or delete files under .hephaestus/ yourself.
        - Run configurations are created and changed by the user, in the app.
        - To run a run configuration of a project, use start_run.
        - Reach other projects, on this Mac or on another Main, through these tools and their identifier.
        """

    /// Project part: `kind` = `project`.
    static let projectPart = """
        ## This session

        This is the Claude chat of {projectName}. Here the user plans and coordinates the project with you: creating and updating many tasks at once, commenting on them, starting task sessions, running the project, working in its code and documentation, and acting on other projects.
        """

    /// Task part: `kind` = `task`, followed by a blank line and the part of the mode.
    static let taskPart = """
        ## Task {taskID}

        This session works on task {taskID} of {projectName}. Its file as it was when the session started is below; call mcp__hephaestus__get_task to see its current state.

        {fence}yaml
        {taskYAML}
        {fence}

        Files attached to the task:
        {attachmentLines}
        """

    /// Mode implement.
    static let modeImplement = """
        ## Mode: implement

        Implement {taskID}:

        1. Make the changes the task asks for.
        2. Keep the documentation in {docsFolder} in sync with your changes.
        3. Build the project and run its tests, and fix what fails.
        4. Add a comment to {taskID} with mcp__hephaestus__comment_task that summarizes what you changed and how you checked it.
        5. Set the status of {taskID} to review with mcp__hephaestus__update_task.
        """

    /// Mode debug.
    static let modeDebug = """
        ## Mode: debug

        Debug {taskID}: find the root cause of the problem it describes. Reproduce the problem or collect evidence from the code, logs and runs, then explain the root cause to the user with that evidence. Propose a fix, and apply it only after the user confirms.
        """

    /// Mode review.
    static let modeReview = """
        ## Mode: review

        Review the work done for {taskID}: compare the changes made for it, in the files and in git, with the task and with the documentation in {docsFolder}. Add your findings to {taskID} as a comment with mcp__hephaestus__comment_task. Do not modify any file.
        """

    /// Mode plan.
    static let modePlan = """
        ## Mode: plan

        Plan {taskID}: study the code and the documentation, then write an implementation plan and add it to {taskID} as a comment with mcp__hephaestus__comment_task. Do not modify the code or the documentation.
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

    /// First message of a feedback session.
    static let feedbackFirstMessage = """
        Work on {taskID}: {taskName} (feedback).

        {taskDescription}

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
}
#endif
