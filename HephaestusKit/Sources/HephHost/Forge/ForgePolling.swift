#if os(macOS)
import Foundation
import HephCore

/// Checks and triggers, and Polling (docs/forge/pipeline.md).
extension ForgeService {
    // MARK: - Checks

    /// A check: configuration checks, fetch, `head`, the commits pushed elsewhere, then `releases/latest`. Returns true
    /// when steps 1 to 3 succeeded; `lastError` is cleared when every step succeeded.
    @discardableResult
    func runCheck() async -> Bool {
        guard let config = configuration else { return false }
        // 1. Configuration checks.
        let repository: Repository
        do {
            repository = try await configurationChecks()
        } catch {
            return false
        }
        // 2 and 3. Fetch, then head; a failure keeps the previous head.
        let git = repository.git
        let commit: String
        do {
            _ = try await git.run(["fetch", "--quiet", "origin", config.branch], timeout: .seconds(120))
            commit = try await git.output(["rev-parse", "--verify", "refs/remotes/origin/\(config.branch)"])
            let docsHash = try await git.docsHash(of: commit)
            let codeDocsHash = try await git.file("App/DocsHash.txt", at: commit).map(ForgeGit.text) ?? ""
            head = ForgeHead(commit: commit, docsHash: docsHash, codeDocsHash: codeDocsHash, checkedAt: Date())
        } catch is CancellationError {
            return false
        } catch {
            lastError = Self.message(of: error)
            await broadcastIfChanged()
            return false
        }
        // 4. The commits pushed elsewhere; a failure keeps the new head.
        let pushedElsewhereError = await checkCommitsPushedElsewhere(git: git, branch: config.branch, head: commit)
        guard !Task.isCancelled else { return false }
        // 5. The latest release, skipped while rate limited; a failure keeps the new head.
        var releaseError: String?
        if let github {
            if let until = github.rateLimitedUntil, until > Date() {
                releaseError = Self.message(of: GitHubError.rateLimited(until: until))
            } else {
                do {
                    if let release = try await github.latestRelease(), let build = Self.buildNumber(release.tagName),
                       build > (latestRelease?.build ?? Int.min) {
                        latestRelease = ForgeRelease(tag: release.tagName, build: build, url: release.htmlURL,
                                                     publishedAt: release.publishedAt)
                        saveStore()
                    }
                } catch {
                    releaseError = Self.message(of: error)
                }
            }
        }
        // 6. The check succeeded: lastError is cleared when every step succeeded. The error of the commits pushed
        // elsewhere is kept over that of the release request.
        lastError = pushedElsewhereError ?? releaseError
        head?.checkedAt = Date()
        await broadcastIfChanged()
        return true
    }

    /// Checks step 4, the commits pushed elsewhere: when `trustedHead` is nil, it becomes `head`; when it differs from
    /// `head`, the published check as it was at `trustedHead` judges the commits it does not have, and `trustedHead`
    /// becomes `head` when they are clean. forge.json is written when `trustedHead` changes. Returns the step's error
    /// for `lastError`, nil when none.
    private func checkCommitsPushedElsewhere(git: ForgeGit, branch: String, head commit: String) async -> String? {
        guard let trusted = trustedHead else {
            trustedHead = commit
            saveStore()
            return nil
        }
        guard trusted != commit else { return nil }
        let gate = ForgePushGate(git: git, branch: branch, termsFile: privateTermsURL)
        do {
            if let findings = try await gate.checkPushedElsewhere(from: trusted, to: commit) {
                Log.host.error("Commits pushed outside the Forge hold personal data")
                return "Commits pushed to \(branch) outside the Forge hold personal data: follow \"If personal data "
                    + "was pushed\" in docs/public-repository.md.\n\n" + findings
            }
            trustedHead = commit
            saveStore()
            Log.host.notice("The commits pushed outside the Forge passed the personal data check")
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            // The reason, without its final period: the git error of `git show`, else that of MCP tools step 6.
            let reason = (error as? ForgePushGate.Refusal)?.message ?? Self.message(of: error)
            return "The commits pushed to \(branch) outside the Forge could not be checked: "
                + "\(ForgePushGate.withoutFinalPeriod(reason))."
        }
    }

    /// `head` is trusted while `trustedHead` equals `head.commit`.
    var headIsTrusted: Bool {
        guard let head else { return false }
        return trustedHead == head.commit
    }

    /// Enqueues a check followed by the `automatic` trigger, unless one already waits in the queue (it is used
    /// instead).
    func requestCheck() {
        guard configuration != nil, !checkQueued else { return }
        checkQueued = true
        enqueue {
            await self.checkAndTrigger()
        }
    }

    /// A check; then Completion again for a cycle still `released`, whatever the check's outcome; then, after a
    /// successful check, the `automatic` trigger.
    private func checkAndTrigger() async {
        checkQueued = false
        guard configuration != nil else { return }
        let succeeded = await runCheck()
        await resumeCompletion()
        if succeeded {
            await automaticTrigger()
        }
    }

    /// After each check: a cycle still `released` (an error stopped its Completion) runs Completion again from step 2.
    func resumeCompletion() async {
        guard configuration != nil, cycle?.state == .released else { return }
        if await completeItems() {
            await finishCycle()
        }
    }

    /// The 5-minute timer of checks.
    func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    return
                }
                await self?.requestCheck()
            }
        }
    }

    /// `N` of a tag `build-<N>` (`N` decimal); nil for other tags.
    static func buildNumber(_ tag: String) -> Int? {
        guard tag.hasPrefix("build-") else { return nil }
        let digits = tag.dropFirst("build-".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    // MARK: - Triggers

    /// The `automatic` trigger: `forge.autoRegenerate`, no active cycle, the last cycle not `failed`, docs and code
    /// not in sync, `head` trusted.
    func automaticTrigger() async {
        guard let config = configuration, config.autoRegenerate, let head, head.docsHash != head.codeDocsHash,
              headIsTrusted
        else { return }
        if let cycle, Self.isActive(cycle.state) || cycle.state == .failed {
            return
        }
        await startCycle(trigger: .automatic)
    }

    /// Starts a cycle (`trigger` set, `started` = now, `attempts` 0); the regeneration step follows in the queue.
    /// A new cycle replaces `cycle`; its items are those the join rule adds.
    func startCycle(trigger: ForgeTrigger) async {
        let now = Date()
        cycle = ForgeCycle(id: UUID(), trigger: trigger, state: .regenerating, started: now, updated: now,
                           targetCommit: head?.commit ?? "", attempts: 0, itemTaskIDs: [])
        saveStore()
        await broadcastIfChanged()
        Log.host.notice("A Forge cycle started (\(trigger.rawValue, privacy: .public))")
        enqueue {
            await self.regenerationStep(fixRun: nil)
        }
    }

    // MARK: - Polling

    /// One polling step at once (after the operation in progress), then every 20 s (later when rate limited), while
    /// the cycle is `regenPushed` or `building`.
    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let delay = await self.pollingStepInQueue() else { return }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    /// Runs one polling step as an operation of the queue; the delay before the next one, nil when polling ends.
    private func pollingStepInQueue() async -> Duration? {
        let delay = try? await perform {
            await self.pollingStep()
        }
        return delay ?? nil
    }

    /// One polling step (Polling).
    func pollingStep() async -> Duration? {
        guard configuration != nil, let github, let current = cycle else { return nil }
        switch current.state {
        case .regenPushed:
            await pollRunLookup(github: github)
        case .building:
            await pollBuilding(github: github)
        default:
            return nil
        }
        guard let state = cycle?.state, state == .regenPushed || state == .building else { return nil }
        let pause = Duration.seconds(20)
        if let until = github.rateLimitedUntil {
            let remaining = until.timeIntervalSinceNow
            if remaining > 20 {
                return .seconds(remaining)
            }
        }
        return pause
    }

    /// `regenPushed`: the run lookup of `regenCommit`: the runs of that full SHA pushed to the branch by
    /// `.github/workflows/ci.yml`, the one with the greatest `id`.
    private func pollRunLookup(github: GitHubClient) async {
        guard let branch = configuration?.branch, var cycle, let sha = cycle.regenCommit else { return }
        do {
            let runs = try await github.runs(headSHA: sha).filter { run in
                run.headSHA == sha && run.headBranch == branch && run.event == "push"
                    && run.path == ".github/workflows/ci.yml"
            }
            if let run = runs.max(by: { $0.id < $1.id }) {
                let now = Date()
                let succeeded = run.status == "completed" && run.conclusion == "success"
                cycle.run = ForgeRun(id: run.id, number: run.runNumber, url: run.htmlURL, status: run.status,
                                     conclusion: run.conclusion, headSHA: run.headSHA, foundAt: now,
                                     completedAt: succeeded ? now : nil)
                self.cycle = cycle
                Log.host.notice("CI run #\(run.runNumber, privacy: .public) found")
                await setCycleState(.building)
            } else if let pushedAt = cycle.pushedAt, Date().timeIntervalSince(pushedAt) >= 600 {
                await failCycle("No CI run for \(ForgePushGate.short(sha)) after 10 minutes.")
            }
        } catch is CancellationError {
            return
        } catch {
            lastError = Self.message(of: error)
            await broadcastIfChanged()
        }
    }

    /// `building`: the run until it completes, then the release `build-<N>`.
    private func pollBuilding(github: GitHubClient) async {
        guard var cycle, var run = cycle.run else { return }
        if run.status == "completed", run.conclusion == "success" {
            await pollRelease(github: github, run: run)
            return
        }
        let fresh: GitHubRun
        do {
            fresh = try await github.run(id: run.id)
        } catch is CancellationError {
            return
        } catch {
            lastError = Self.message(of: error)
            await broadcastIfChanged()
            return
        }
        run.status = fresh.status
        run.conclusion = fresh.conclusion
        if fresh.status == "completed", fresh.conclusion == "success" {
            run.completedAt = Date()
            cycle.run = run
            cycle.updated = Date()
            self.cycle = cycle
            saveStore()
            await broadcastIfChanged()
            Log.host.notice("CI run #\(run.number, privacy: .public) succeeded")
        } else if fresh.status == "completed" {
            cycle.run = run
            self.cycle = cycle
            let message: String
            if let jobs = try? await github.jobs(runID: run.id), Self.publicCheckFailed(jobs) {
                message = "Personal data check failed on GitHub for \(ForgePushGate.short(run.headSHA)): personal "
                    + "data may be public. Follow \"If personal data was pushed\" in docs/public-repository.md."
            } else {
                message = "CI run #\(run.number) concluded \(fresh.conclusion ?? "")."
            }
            await failCycle(message)
        } else if Date().timeIntervalSince(run.foundAt) >= 5_400 {
            cycle.run = run
            self.cycle = cycle
            await failCycle("CI run #\(run.number) did not complete within 90 minutes.")
        } else if run != cycle.run {
            cycle.run = run
            cycle.updated = Date()
            self.cycle = cycle
            saveStore()
            await broadcastIfChanged()
        }
    }

    /// `building`, the run succeeded: `releases/tags/build-<N>`.
    private func pollRelease(github: GitHubClient, run: ForgeRun) async {
        let tag = "build-\(run.number)"
        do {
            if let release = try await github.release(tag: tag) {
                let build = Self.buildNumber(release.tagName) ?? run.number
                await complete(with: ForgeRelease(tag: release.tagName, build: build, url: release.htmlURL,
                                                  publishedAt: release.publishedAt))
            } else if Date().timeIntervalSince(run.completedAt ?? run.foundAt) >= 600 {
                await failCycle("Release \(tag) was not found 10 minutes after CI run #\(run.number) succeeded.")
            }
        } catch is CancellationError {
            return
        } catch {
            lastError = Self.message(of: error)
            await broadcastIfChanged()
        }
    }
}
#endif
