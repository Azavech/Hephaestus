#if os(macOS)
import Foundation
import HephCore

/// Feedback intake, Items and the join rule (docs/forge/pipeline.md).
extension ForgeService {
    // MARK: - Feedback intake

    /// `forge.feedback`: creates the feedback task, attaches the screenshot, starts the feedback session and adds the
    /// item.
    func intake(screenshot: UploadRef?, comment: String, context: FeedbackContext,
                from deviceID: UUID) async throws -> ForgeFeedbackResult {
        // 1. Checks.
        guard let config = configuration else { throw Self.notTheForge }
        _ = try await configurationChecks()
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ProtocolError(.badRequest, "The comment is empty.")
        }
        let projectID = config.sourceProjectID
        if let screenshot {
            try await host.uploads.check([screenshot], projectID: projectID)
        }
        let snapshot = await host.mesh.snapshot()

        // 2. The task.
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let name = "Feedback: " + String(firstLine.prefix(60))
        let description = text + "\n\n---\n\n" + Self.contextBlock(context, devices: snapshot.devices)
        let task = try await host.tasks.create(projectID: projectID, name: name, description: description,
                                               status: .todo)
        Log.host.notice("Feedback task \(task.id, privacy: .public) created")

        // 3. The screenshot, in a comment.
        if let screenshot {
            let author = snapshot.devices.first(where: { $0.id == deviceID })?.name ?? context.deviceName
            _ = try await host.tasks.addComment(projectID: projectID, taskID: task.id, body: "Screenshot",
                                                attachments: [UploadRef(uploadID: screenshot.uploadID,
                                                                        fileName: "screenshot.png")],
                                                author: author)
        }

        // 4. The feedback session.
        let mainID: UUID
        if let hostDeviceID {
            mainID = hostDeviceID
        } else {
            mainID = await host.mesh.localDevice().id
        }
        let session = try await host.sessions.start(SessionStart(projectID: projectID, kind: .feedback,
                                                                 taskID: task.id, permissionMode: .acceptEdits,
                                                                 deviceID: mainID))

        // 5. The item.
        let now = Date()
        dropOldItemsForNewItem()
        items.append(ForgeItem(taskID: task.id, projectID: projectID, title: task.name, state: .discussing,
                               feedbackSessionID: session.id, created: now, updated: now))
        saveStore()
        await broadcastIfChanged()

        // 6. The result.
        return ForgeFeedbackResult(projectID: projectID, taskID: task.id, sessionID: session.id)
    }

    /// The context block of the feedback task's description.
    static func contextBlock(_ context: FeedbackContext, devices: [DeviceRecord]) -> String {
        var lines = [
            "Feedback from \(context.deviceName) (\(context.platform.rawValue)), Hephaestus \(context.appVersion) "
                + "(\(context.build)), docs \(context.docsHash)",
            "",
            "- Device ID: \(context.deviceID.uuidString)",
        ]
        let selection = context.selection
        if let mainID = selection.mainDeviceID {
            if let main = devices.first(where: { $0.id == mainID }) {
                lines.append("- Main: \(main.name) (\(mainID.uuidString))")
            } else {
                lines.append("- Main: \(mainID.uuidString)")
            }
        }
        if let projectID = selection.projectID {
            lines.append("- Project: \(projectID)")
        }
        if let section = selection.section {
            lines.append("- Section: \(section)")
        }
        if let item = selection.item {
            lines.append("- Item: \(item)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Items

    /// `forge_push_docs` of the item's feedback session pushed `sha` (Items).
    func recordDocsPush(_ sha: String, taskID: String) {
        guard let index = items.firstIndex(where: { $0.taskID == taskID }) else { return }
        var item = items[index]
        switch item.state {
        case .discussing, .docsPushed, .done, .failed:
            item.state = .docsPushed
            item.cycleID = nil
            item.error = nil
        case .regenerating, .regenPushed, .building, .released:
            break
        }
        item.docsCommit = sha
        item.updated = Date()
        items[index] = item
    }

    /// Its task changes name (`task.changed`): `title` = the new name; a task whose name equals the item's `title`
    /// changes nothing.
    func renameItem(projectID: String, task: TaskItem) async {
        guard storeLoaded,
              let index = items.firstIndex(where: { $0.taskID == task.id && $0.projectID == projectID }),
              items[index].title != task.name
        else { return }
        items[index].title = task.name
        items[index].updated = Date()
        saveStore()
        await broadcastIfChanged()
    }

    /// Its task is deleted: removed from `items` and from its cycle's `itemTaskIDs`.
    func removeItem(projectID: String, taskID: String) async {
        guard storeLoaded,
              let index = items.firstIndex(where: { $0.taskID == taskID && $0.projectID == projectID })
        else { return }
        items.remove(at: index)
        if var cycle, cycle.itemTaskIDs.contains(taskID) {
            cycle.itemTaskIDs.removeAll { $0 == taskID }
            self.cycle = cycle
        }
        saveStore()
        await broadcastIfChanged()
    }

    /// The items of the current cycle, in the order of its `itemTaskIDs`.
    func cycleItems() -> [ForgeItem] {
        guard let cycle else { return [] }
        return cycle.itemTaskIDs.compactMap { taskID in
            items.first { $0.taskID == taskID && $0.cycleID == cycle.id }
        }
    }

    /// The items of a cycle follow its state; `error` is the cycle's error while it is `failed`, else nil.
    func syncCycleItems() {
        guard let cycle else { return }
        let now = Date()
        for index in items.indices where items[index].cycleID == cycle.id && items[index].state != .done {
            let error = cycle.state == .failed ? cycle.error : nil
            guard items[index].state != cycle.state || items[index].error != error else { continue }
            items[index].state = cycle.state
            items[index].error = error
            items[index].updated = now
        }
    }

    // MARK: - Join rule

    /// An item in `docsPushed` or `failed` joins the active cycle when its `docsCommit` is an ancestor of the cycle's
    /// reference commit (`regenCommit` when set, else `targetCommit`). `taskIDs` nil: every such item.
    func joinRule(taskIDs: [String]? = nil) async {
        guard var cycle, Self.isActive(cycle.state) else { return }
        let reference = cycle.regenCommit ?? cycle.targetCommit
        guard !reference.isEmpty else { return }
        let candidates = items.filter { item in
            (item.state == .docsPushed || item.state == .failed) && item.cycleID != cycle.id
                && item.docsCommit != nil && (taskIDs?.contains(item.taskID) ?? true)
        }
        guard !candidates.isEmpty, let git = await sourceGit() else { return }
        var joined = false
        for candidate in candidates {
            guard let docsCommit = candidate.docsCommit else { continue }
            let ancestor: Bool
            do {
                let output = try await git.run(["merge-base", "--is-ancestor", docsCommit, reference],
                                               timeout: .seconds(30), allowedExitCodes: [0, 1])
                ancestor = output.termination == .exited(0)
            } catch {
                lastError = Self.message(of: error)
                continue
            }
            guard ancestor, let index = items.firstIndex(where: { $0.taskID == candidate.taskID }) else { continue }
            items[index].cycleID = cycle.id
            items[index].state = cycle.state
            items[index].error = cycle.state == .failed ? cycle.error : nil
            items[index].updated = Date()
            if !cycle.itemTaskIDs.contains(candidate.taskID) {
                cycle.itemTaskIDs.append(candidate.taskID)
            }
            joined = true
            Log.host.info("Forge item \(candidate.taskID, privacy: .public) joined the cycle")
        }
        if joined {
            cycle.updated = Date()
            self.cycle = cycle
            saveStore()
        }
    }

    /// The git of the source project's repository, without the configuration checks; nil when unavailable.
    func sourceGit() async -> ForgeGit? {
        guard let config = configuration,
              let project = try? await host.registry.hosted(config.sourceProjectID),
              await host.hostInfo.gitAvailable
        else { return nil }
        let environment = await LoginEnvironment.shared.environment()
        guard let executable = ForgeGit.locate("git", environment: environment) else { return nil }
        return ForgeGit(executable: executable, repositoryRoot: Self.repositoryRoot(of: project),
                        environment: environment)
    }
}
#endif
