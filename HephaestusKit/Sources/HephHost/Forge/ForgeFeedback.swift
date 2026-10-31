#if os(macOS)
import Foundation
import HephCore

/// Feedback intake, Items and the join rule (docs/forge/pipeline.md).
extension ForgeService {
    // MARK: - Feedback intake

    /// `forge.feedback`: creates the feedback ticket, attaches the screenshot, starts the feedback session and adds the
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

        // 2. The feedback ticket, in the project's feedback series.
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let name = "Feedback: " + String(firstLine.prefix(60))
        let description = text + "\n\n---\n\n" + Self.contextBlock(context, devices: snapshot.devices)
        let ticket = try await host.tickets.create(projectID: projectID, name: name, description: description,
                                                   status: .todo, feedback: true)
        Log.host.notice("Feedback ticket \(ticket.id, privacy: .public) created")

        // 3. The screenshot, in a comment.
        if let screenshot {
            let author = snapshot.devices.first(where: { $0.id == deviceID })?.name ?? context.deviceName
            _ = try await host.tickets.addComment(projectID: projectID, ticketID: ticket.id, body: "Screenshot",
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
                                                                 ticketID: ticket.id, permissionMode: .acceptEdits,
                                                                 deviceID: mainID))

        // 5. The item.
        let now = Date()
        dropOldItemsForNewItem()
        items.append(ForgeItem(ticketID: ticket.id, projectID: projectID, title: ticket.name, state: .discussing,
                               feedbackSessionID: session.id, created: now, updated: now))
        saveStore()
        await broadcastIfChanged()

        // 6. The result.
        return ForgeFeedbackResult(projectID: projectID, ticketID: ticket.id, sessionID: session.id)
    }

    /// The context block of the feedback ticket's description.
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

    /// `forge_push_docs` pushed `sha` for the item's ticket (Items).
    func recordDocsPush(_ sha: String, ticketID: String) {
        guard let index = items.firstIndex(where: { $0.ticketID == ticketID }) else { return }
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

    /// Its ticket changes name (`ticket.changed`): `title` = the new name; a ticket whose name equals the item's `title`
    /// changes nothing.
    func renameItem(projectID: String, ticket: TicketItem) async {
        guard storeLoaded,
              let index = items.firstIndex(where: { $0.ticketID == ticket.id && $0.projectID == projectID }),
              items[index].title != ticket.name
        else { return }
        items[index].title = ticket.name
        items[index].updated = Date()
        saveStore()
        await broadcastIfChanged()
    }

    /// Its ticket is deleted (`ticket.removed`): removed from `items` and from its cycle's `itemTicketIDs`.
    func removeItem(projectID: String, ticketID: String) async {
        guard storeLoaded,
              let index = items.firstIndex(where: { $0.ticketID == ticketID && $0.projectID == projectID })
        else { return }
        items.remove(at: index)
        if var cycle, cycle.itemTicketIDs.contains(ticketID) {
            cycle.itemTicketIDs.removeAll { $0 == ticketID }
            self.cycle = cycle
        }
        saveStore()
        await broadcastIfChanged()
    }

    /// The items of the current cycle, in the order of its `itemTicketIDs`.
    func cycleItems() -> [ForgeItem] {
        guard let cycle else { return [] }
        return cycle.itemTicketIDs.compactMap { ticketID in
            items.first { $0.ticketID == ticketID && $0.cycleID == cycle.id }
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
    /// reference commit (`regenCommit` when set, else `targetCommit`). `ticketIDs` nil: every such item.
    func joinRule(ticketIDs: [String]? = nil) async {
        guard var cycle, Self.isActive(cycle.state) else { return }
        let reference = cycle.regenCommit ?? cycle.targetCommit
        guard !reference.isEmpty else { return }
        let candidates = items.filter { item in
            (item.state == .docsPushed || item.state == .failed) && item.cycleID != cycle.id
                && item.docsCommit != nil && (ticketIDs?.contains(item.ticketID) ?? true)
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
            guard ancestor, let index = items.firstIndex(where: { $0.ticketID == candidate.ticketID }) else { continue }
            items[index].cycleID = cycle.id
            items[index].state = cycle.state
            items[index].error = cycle.state == .failed ? cycle.error : nil
            items[index].updated = Date()
            if !cycle.itemTicketIDs.contains(candidate.ticketID) {
                cycle.itemTicketIDs.append(candidate.ticketID)
            }
            joined = true
            Log.host.info("Forge item \(candidate.ticketID, privacy: .public) joined the cycle")
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
