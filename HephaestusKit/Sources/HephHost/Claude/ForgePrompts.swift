#if os(macOS)
import Foundation
import HephCore

/// ForgePrompts.swift: the Forge common part, the feedback part and the regeneration part of docs/claude/prompts.md,
/// rendered with its rules; used by Prompts.systemPrompt. They are the prompts of the sessions of cli.md 3.5, which
/// work in the public Hephaestus repository.
enum ForgePrompts {
    /// The Forge common part: the public repository rule, the session's own tools, no device of the mesh.
    static func commonPart(_ context: PromptContext) -> String {
        var values = Prompts.placeholders(context)
        values["forgeToolLines"] = forgeToolLines(context.kind)
        values["pushLine"] = pushLine(context.kind)
        return Prompts.render(ForgeTemplates.forgeCommon, values)
    }

    /// The feedback part: `kind` = `feedback`; `task` is the feedback task created by the Forge.
    static func feedbackPart(_ context: PromptContext) -> String {
        Prompts.render(ForgeTemplates.feedbackPart, Prompts.placeholders(context))
    }

    /// The regeneration part: `kind` = `regeneration`.
    static func regenerationPart(_ context: PromptContext) -> String {
        var values = Prompts.placeholders(context)
        values["regenerationLines"] = regenerationLines(context.regeneration)
        return Prompts.render(ForgeTemplates.regenerationPart, values)
    }

    /// `{forgeToolLines}`: the tools of the session's kind (claude/mcp.md §6).
    private static func forgeToolLines(_ kind: SessionKind) -> String {
        switch kind {
        case .feedback:
            return [
                "- get_task: the current state of your feedback task, with its comments; only that task.",
                "- update_task: change the name, description or status of your feedback task; only that task.",
                "- comment_task: add a comment to your feedback task; only that task.",
                "- forge_push_docs: check your documentation commits for personal data and push them to GitHub.",
            ].joined(separator: "\n")
        case .regeneration:
            return "- forge_push_regen: check your regeneration commits for personal data and push them to GitHub."
        case .project, .task:
            return Prompts.commonToolLines
        }
    }

    /// `{pushLine}`.
    private static func pushLine(_ kind: SessionKind) -> String {
        switch kind {
        case .feedback, .regeneration:
            return "Never push. The Forge checks your commits for personal data when you call its push tool below, "
                + "and pushes them: when it refuses them, remove what it reports, rewrite the commits and call it "
                + "again."
        case .project, .task:
            return "Never push: the user reviews your commits and pushes them by hand."
        }
    }

    /// `{regenerationLines}`: no line without a regeneration context (later starts); otherwise its paragraphs, each
    /// preceded by an empty line. The title of a feedback task, its user's first words, is left out.
    private static func regenerationLines(_ regeneration: RegenerationContext?) -> String {
        guard let regeneration else { return "" }
        var paragraphs = ["This regeneration starts from commit \(regeneration.targetCommit) (trigger: "
            + "\(regeneration.trigger), attempt \(regeneration.attempt))."]
        if !regeneration.items.isEmpty {
            let items = regeneration.items.map { item in
                "- \(item.taskID)" + (item.docsCommit.map { " (docs commit \($0))" } ?? "")
            }
            paragraphs.append((["It includes the documentation changes of these feedback tasks:"] + items)
                .joined(separator: "\n"))
        }
        if let run = regeneration.failedRun {
            paragraphs.append("CI run #\(run.number) (\(run.url)) failed with conclusion \(run.conclusion). The "
                + "first message of this session holds the end of the logs of its failed jobs: find the cause in the "
                + "code and fix it.")
        }
        return paragraphs.map { "\n" + $0 }.joined(separator: "\n")
    }
}

/// The templates of docs/claude/prompts.md held by this file, without their fences.
private enum ForgeTemplates {
    /// Forge common part: the sessions of cli.md 3.5.
    static let forgeCommon = """
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
        - The personal-data guardrail is changed only by the user, by hand: the protected paths listed in {docsFolder}/public-repository.md (Protected paths), among them {docsFolder}/general.md and {docsFolder}/public-repository.md, and in {codeFolder} scripts/check-public.sh, .gitignore, CLAUDE.md, the files under .githooks/ and .github/, and the Swift files and tests of the Forge's push gate, session rules, prompts and tool kinds. Never edit them; the Forge refuses to push changes to them.

        ## Hephaestus tools

        This session has these mcp__hephaestus__ tools:
        {forgeToolLines}

        When one of them returns an error, do what its message says, then call it again.
        """

    /// Feedback part: `kind` = `feedback`.
    static let feedbackPart = """
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
        4. Stop: show the user the new name and description, and ask whether to implement the task now or leave it for later. Update {taskID} with what you agree on.

        When the user asks you to implement it:

        1. Propose documentation changes that address the task, and refine them with the user. Describe the app in general terms: nothing of the comment, the screenshot or the context goes into the documentation (Public repository).
        2. Edit only files under {docsFolder}, never {docsFolder}/general.md or {docsFolder}/public-repository.md: when the task needs a change there, write the change you propose in your reply, and the user makes it and pushes it by hand.
        3. When the user agrees, commit only that folder with the message "docs: <summary> ({taskID})", <summary> being a one-line summary of the change that names nothing personal: git add -A -- {docsFolder}, then git commit -m "<message>" -- {docsFolder}.
        4. Call mcp__hephaestus__forge_push_docs. It checks the commits that are not on GitHub yet for personal data and pushes them to {branch}; when it returns an error, do what the error says, then call it again. The Forge then regenerates the code, CI builds it and the app updates itself on the user's Macs.

        Do not commit or call forge_push_docs before the user agrees, and never change files outside {docsFolder}.
        """

    /// Regeneration part: `kind` = `regeneration`.
    static let regenerationPart = """
        ## Regeneration

        The documentation in {docsFolder} is the specification of this app: its code is generated from it. Regenerate the code so that it matches the documentation by following the procedure of {docsFolder}/forge/generation.md step by step, on the branch {branch}. Do not change the documentation.
        {regenerationLines}

        Once the build and the tests pass, the last steps of the procedure check the changes for personal data and commit them (step 11), then push them to {branch} with mcp__hephaestus__forge_push_regen (step 12). CI then builds the pushed commit and the app updates itself on the user's Macs.

        When the documentation requires a change of a protected path ({docsFolder}/public-repository.md, Protected paths), you cannot make it: stop as the procedure says for a step you cannot carry out, and tell the user which change they must make by hand.
        """
}
#endif
