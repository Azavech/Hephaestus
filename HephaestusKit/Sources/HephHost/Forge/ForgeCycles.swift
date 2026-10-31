#if os(macOS)
import Foundation
import HephCore

/// Cycles: the regeneration step, session observation, Retry and Completion (docs/forge/pipeline.md).
extension ForgeService {
    // MARK: - Transitions

    /// Moves the cycle to `state` (not `failed`): `updated` set, `failedState` and `error` cleared, the items follow;
    /// forge.json is written and forge.changed sent.
    func setCycleState(_ state: ForgeStage) async {
        guard var cycle else { return }
        cycle.state = state
        cycle.failedState = nil
        cycle.error = nil
        cycle.updated = Date()
        self.cycle = cycle
        syncCycleItems()
        saveStore()
        await broadcastIfChanged()
        Log.host.notice("The Forge cycle is \(state.rawValue, privacy: .public)")
    }

    /// Moves the cycle to `failed` with `failedState` (the current state when nil) and the message.
    func failCycle(_ message: String, failedState: ForgeStage? = nil) async {
        guard var cycle else { return }
        cycle.failedState = failedState ?? (cycle.state == .failed ? cycle.failedState : cycle.state)
        cycle.state = .failed
        cycle.error = message
        cycle.updated = Date()
        self.cycle = cycle
        syncCycleItems()
        saveStore()
        await broadcastIfChanged()
        Log.host.notice("The Forge cycle failed in \(cycle.failedState?.rawValue ?? "", privacy: .public)")
    }

    // MARK: - Regeneration step

    /// Run when a cycle starts and by Retry from `regenerating`; `fixRun` is the failed run to fix, given only by
    /// Retry from `building`.
    func regenerationStep(fixRun: GitHubRun?) async {
        guard let config = configuration, let current = cycle else { return }
        if current.state != .regenerating || current.failedState != nil || current.error != nil {
            await setCycleState(.regenerating)
        }
        // 1. Configuration checks.
        let repository: Repository
        do {
            repository = try await configurationChecks()
        } catch is CancellationError {
            return
        } catch {
            await failCycle(Self.message(of: error), failedState: .regenerating)
            return
        }
        // 2. A check.
        guard await runCheck(), let head else {
            guard !Task.isCancelled else { return }
            await failCycle(lastError ?? "", failedState: .regenerating)
            return
        }
        if var cycle {
            cycle.targetCommit = head.commit
            cycle.updated = Date()
            self.cycle = cycle
        }
        // 3. Docs and code in sync, no failed run to fix: no session is needed.
        if fixRun == nil, head.docsHash == head.codeDocsHash {
            if var cycle {
                cycle.regenCommit = head.commit
                cycle.pushedAt = Date()
                self.cycle = cycle
            }
            await setCycleState(.regenPushed)
            await joinRule()
            saveStore()
            await broadcastIfChanged()
            startPolling()
            return
        }
        // 4. A clean working tree, no unpushed commits.
        let git = repository.git
        do {
            let status = try await git.output(["status", "--porcelain"])
            guard status.isEmpty else {
                await failCycle("The source project has uncommitted changes. Commit or discard them, then retry.")
                return
            }
            let unpushed = try await git.output(["rev-list", "refs/remotes/origin/\(config.branch)..HEAD"])
            guard unpushed.isEmpty else {
                await failCycle("Unpushed commits on \(config.branch): push or remove them, then retry.")
                return
            }
        } catch is CancellationError {
            return
        } catch {
            await failCycle(Self.message(of: error))
            return
        }
        // 5. The join rule, then the regeneration session.
        await joinRule()
        guard let cycle else { return }
        let attempt = cycle.attempts + 1
        var failedRun: FailedCIRun?
        if let fixRun {
            failedRun = await failedCIRun(fixRun)
        }
        let context = RegenerationContext(
            trigger: cycle.trigger.rawValue, attempt: attempt, targetCommit: cycle.targetCommit,
            items: cycleItems().map { RegenerationItem(ticketID: $0.ticketID, docsCommit: $0.docsCommit) },
            failedRun: failedRun)
        var title = "Regeneration \(Self.titleFormatter.string(from: Date()))"
        if attempt > 1 {
            title += " (attempt \(attempt))"
        }
        let mainID: UUID
        if let hostDeviceID {
            mainID = hostDeviceID
        } else {
            mainID = await host.mesh.localDevice().id
        }
        do {
            let session = try await host.sessions.start(SessionStart(projectID: config.sourceProjectID,
                                                                     kind: .regeneration, title: title,
                                                                     permissionMode: .acceptEdits, deviceID: mainID,
                                                                     regeneration: context))
            // 6. The session runs.
            if var cycle = self.cycle {
                cycle.attempts += 1
                cycle.sessionID = session.id
                self.cycle = cycle
            }
            await setCycleState(.regenerating)
            Log.host.notice("Regeneration session \(session.id.uuidString, privacy: .public) started (attempt \(attempt, privacy: .public))")
        } catch {
            await failCycle("The regeneration session could not start: \(Self.message(of: error))")
        }
    }

    /// The failed run for the session's prompt: its failed jobs (at most 3), each with the last 300 lines of its log.
    private func failedCIRun(_ run: GitHubRun) async -> FailedCIRun {
        var jobs: [FailedCIJob] = []
        if let github, let all = try? await github.jobs(runID: run.id) {
            for job in all.filter(Self.isFailedJob).prefix(3) {
                let log: String
                do {
                    log = Self.lastLines(try await github.jobLog(jobID: job.id), count: 300)
                } catch {
                    log = "Log unavailable: \(Self.message(of: error))"
                }
                jobs.append(FailedCIJob(name: job.name, url: job.htmlURL, log: log))
            }
        }
        return FailedCIRun(number: run.runNumber, url: run.htmlURL, conclusion: run.conclusion ?? "", jobs: jobs)
    }

    /// A job whose conclusion is neither `success`, `skipped` nor `neutral`.
    static func isFailedJob(_ job: GitHubJob) -> Bool {
        !["success", "skipped", "neutral"].contains(job.conclusion ?? "")
    }

    /// The last `count` lines of a text.
    static func lastLines(_ text: String, count: Int) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.suffix(count).joined(separator: "\n")
    }

    /// `yyyy-MM-dd HH:mm`, local time.
    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - Session observation

    /// A `session.changed` of the cycle's session while the cycle is `regenerating`.
    func observeSession(_ session: SessionInfo) async {
        guard configuration != nil, let cycle, cycle.state == .regenerating, cycle.sessionID == session.id else {
            return
        }
        switch session.status {
        case .running, .waitingPermission:
            turnsStarted.insert(session.id)
        case .idle, .stopped:
            if turnsStarted.contains(session.id) {
                await failCycle("The regeneration session ended its turn without pushing with forge_push_regen.")
            }
        case .failed:
            await failCycle("The regeneration session failed: \(session.error ?? "")")
        case .starting:
            break
        }
    }

    /// A `session.removed` of the cycle's session while the cycle is `regenerating`.
    func observeSessionRemoval(_ sessionID: String) async {
        guard configuration != nil, let cycle else { return }
        if let id = UUID(uuidString: sessionID) {
            turnsStarted.remove(id)
        }
        guard cycle.state == .regenerating, cycle.sessionID?.uuidString == sessionID else { return }
        await failCycle("The regeneration session was deleted.")
    }

    // MARK: - Retry

    /// Retry of the current cycle when it is `failed` (`forge.retry`, `forge.regenerate`).
    func retryCycle() async {
        guard configuration != nil, let current = cycle, current.state == .failed else { return }
        Log.host.notice("Retrying the Forge cycle from \(current.failedState?.rawValue ?? "", privacy: .public)")
        switch current.failedState {
        case .regenPushed?:
            if var cycle {
                cycle.pushedAt = Date()
                self.cycle = cycle
            }
            await setCycleState(.regenPushed)
            startPolling()
        case .building?:
            guard let run = current.run else {
                await regenerationStep(fixRun: nil)
                return
            }
            guard let conclusion = run.conclusion, conclusion != "success" else {
                await resumeBuilding(status: nil, conclusion: nil)
                return
            }
            guard let github else { return }
            let fresh: GitHubRun
            do {
                fresh = try await github.run(id: run.id)
            } catch {
                lastError = Self.message(of: error)
                await broadcastIfChanged()
                return
            }
            if fresh.status != "completed" || fresh.conclusion == "success" {
                await resumeBuilding(status: fresh.status, conclusion: fresh.conclusion)
                return
            }
            let jobs: [GitHubJob]
            do {
                jobs = try await github.jobs(runID: run.id)
            } catch {
                lastError = Self.message(of: error)
                await broadcastIfChanged()
                return
            }
            await regenerationStep(fixRun: Self.publicCheckFailed(jobs) ? nil : fresh)
        default:
            await regenerationStep(fixRun: nil)
        }
    }

    /// Retry in `building`: state `building`, `run.foundAt` = now, `run.completedAt` = now when it was set, polling
    /// starts; `status` and `conclusion` of a run requested again replace the stored ones.
    private func resumeBuilding(status: String?, conclusion: String?) async {
        guard var cycle, var run = cycle.run else { return }
        let now = Date()
        if let status {
            run.status = status
            run.conclusion = conclusion
        }
        run.foundAt = now
        if run.completedAt != nil {
            run.completedAt = now
        }
        cycle.run = run
        self.cycle = cycle
        await setCycleState(.building)
        startPolling()
    }

    /// The run's `public-check` or `public-check-terms` job concluded `failure` (docs/forge/ci.md).
    static func publicCheckFailed(_ jobs: [GitHubJob]) -> Bool {
        jobs.contains { ["public-check", "public-check-terms"].contains($0.name) && $0.conclusion == "failure" }
    }

    // MARK: - Completion

    /// The release of the cycle's run is found: steps 1 to 3 of Completion.
    func complete(with release: ForgeRelease) async {
        // 1. The release; the cycle and its items are released.
        guard var cycle else { return }
        cycle.release = release
        self.cycle = cycle
        if release.build > (latestRelease?.build ?? Int.min) {
            latestRelease = release
        }
        await setCycleState(.released)
        Log.host.notice("Release \(release.tag, privacy: .public) found")
        // 2 and 3.
        if await completeItems() {
            await finishCycle()
        }
    }

    /// Completion step 2: a comment for each item of the cycle, in order; the ticket's status is left as it is. A
    /// ticket that no longer exists removes its item. Returns false when another error stopped it (the cycle stays `released`).
    func completeItems() async -> Bool {
        guard configuration != nil, let cycle, let release = cycle.release, let run = cycle.run else {
            return true
        }
        let author = await host.mesh.localDevice().name
        for ticketID in cycle.itemTicketIDs {
            guard let item = items.first(where: { $0.ticketID == ticketID && $0.cycleID == cycle.id }),
                  item.state == .released
            else { continue }
            let body = Self.completionComment(item: item, cycle: cycle, run: run, release: release,
                                              repository: ForgeConfig.publicRepository)
            do {
                _ = try await host.tickets.addComment(projectID: item.projectID, ticketID: ticketID, body: body,
                                                    attachments: [], author: author)
                if let index = items.firstIndex(where: { $0.ticketID == ticketID }) {
                    items[index].state = .done
                    items[index].error = nil
                    items[index].updated = Date()
                }
            } catch let error as ProtocolError where error.code == .notFound {
                items.removeAll { $0.ticketID == ticketID }
                if var current = self.cycle {
                    current.itemTicketIDs.removeAll { $0 == ticketID }
                    self.cycle = current
                }
            } catch {
                lastError = Self.message(of: error)
                saveStore()
                await broadcastIfChanged()
                return false
            }
            saveStore()
            await broadcastIfChanged()
        }
        return true
    }

    /// Completion step 3: the cycle is `done`; a check runs (it can start the next cycle).
    func finishCycle() async {
        await setCycleState(.done)
        requestCheck()
    }

    /// The comment of Completion step 2.
    static func completionComment(item: ForgeItem, cycle: ForgeCycle, run: ForgeRun, release: ForgeRelease,
                                  repository: String) -> String {
        var lines = ["Released in build \(release.build).", ""]
        if let docsCommit = item.docsCommit {
            lines.append("- Docs: [\(ForgePushGate.short(docsCommit))](https://github.com/\(repository)/commit/\(docsCommit))")
        }
        if let regenCommit = cycle.regenCommit {
            lines.append("- Built commit: [\(ForgePushGate.short(regenCommit))](https://github.com/\(repository)/commit/\(regenCommit))")
        }
        lines.append("- CI run: [#\(run.number)](\(run.url))")
        lines.append("- Release: [build-\(release.build)](\(release.url))")
        return lines.joined(separator: "\n")
    }
}
#endif
