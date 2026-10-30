#if os(macOS)
import Foundation
import HephCore

/// Configuration checks (docs/forge/pipeline.md, "Forge host configuration"): run, in this order, at the start of every
/// check, at the start of a regeneration step, before handling `forge.feedback` and at the start of the push tools. The
/// first failure stops the list.
extension ForgeService {
    /// The source project's repository after the configuration checks passed.
    struct Repository: Sendable {
        let git: ForgeGit
        let project: HostedProject
        let root: URL
    }

    /// A failed configuration check: the error of the methods and push tools (`unavailable`, `locked` while the source
    /// project is moved), and the changed paths when the guardrail files hold a local change (none when they cannot
    /// be compared with origin).
    struct ConfigurationCheckFailure: Error, Sendable {
        let error: ProtocolError
        let guardrailPaths: [String]
    }

    /// The configuration checks; the first failure sets `lastError` to its message and is thrown as its ProtocolError.
    func configurationChecks() async throws -> Repository {
        do {
            return try await checkConfiguration()
        } catch let failure as ConfigurationCheckFailure {
            throw failure.error
        }
    }

    /// The configuration checks; the first failure sets `lastError` to its message and is thrown as a
    /// ConfigurationCheckFailure (forge_push_regen also fails its cycle when the guardrail files changed).
    func checkConfiguration() async throws -> Repository {
        do {
            return try await runConfigurationChecks()
        } catch let failure as ConfigurationCheckFailure {
            lastError = failure.error.message
            await broadcastIfChanged()
            throw failure
        }
    }

    private func runConfigurationChecks() async throws -> Repository {
        guard let config = configuration else { throw Self.notTheForge }
        let id = config.sourceProjectID

        // The source project is hosted on this Main, and neither it nor one of its ancestors is migrating
        // (`checkWritable` throws no `locked`; its `notFound` is the first row's failure).
        let notHosted = Self.checkFailure(.unavailable, "The Forge source project \(id) is not on this Main.")
        let project: HostedProject
        do {
            project = try await host.registry.hosted(id)
        } catch {
            throw notHosted
        }
        do {
            try await host.registry.checkWritable(id)
        } catch let error as ProtocolError where error.code == .locked {
            throw Self.checkFailure(.locked, "The Forge source project \(id) is being moved.")
        } catch {
            throw notHosted
        }

        // git is available.
        let environment = await LoginEnvironment.shared.environment()
        guard await host.hostInfo.gitAvailable, let executable = ForgeGit.locate("git", environment: environment)
        else {
            throw Self.checkFailure(.unavailable, "git is not available on this Main.")
        }
        let root = Self.repositoryRoot(of: project)
        let git = ForgeGit(executable: executable, repositoryRoot: root, environment: environment)

        // The repository root is the top folder of the repository, symlinks resolved on both sides.
        let notTopFolder = Self.checkFailure(.unavailable, "\(root.path) is not the top folder of a git repository.")
        let top: String
        do {
            top = try await git.output(["rev-parse", "--show-toplevel"])
        } catch let error as CancellationError {
            throw error
        } catch {
            throw notTopFolder
        }
        guard let realTop = ClaudePathEncoding.canonicalPath(top),
              let realRoot = ClaudePathEncoding.canonicalPath(root.path), realTop == realRoot
        else { throw notTopFolder }

        // origin is the repository on GitHub, it is the only push URL, and no remote.origin.pushurl is set.
        let origin = try await gitStep { try await git.output(["remote", "get-url", "origin"]) }
        guard Self.isOriginURL(origin, repository: config.repository) else {
            throw Self.checkFailure(.unavailable,
                                    "The origin remote of \(id) is \(origin), not github.com/\(config.repository).")
        }
        let pushURLs = try await gitStep {
            ForgeGit.lines(try await git.run(["remote", "get-url", "--push", "--all", "origin"],
                                             timeout: .seconds(30)).standardOutput)
        }
        guard pushURLs.count == 1, Self.isOriginURL(pushURLs[0], repository: config.repository) else {
            throw Self.checkFailure(.unavailable, "The push URL of origin is \(pushURLs.joined(separator: ", ")), "
                                        + "not github.com/\(config.repository).")
        }
        let pushURLSetting = try await gitStep {
            ForgeGit.text(try await git.run(["config", "--get-all", "remote.origin.pushurl"], timeout: .seconds(30),
                                            allowedExitCodes: [0, 1]).standardOutput)
        }
        guard pushURLSetting.isEmpty else {
            throw Self.checkFailure(.unavailable, "origin has a push URL; remove it with git config --unset-all "
                                        + "remote.origin.pushurl.")
        }

        // The hooks path is .githooks; commits are not signed.
        try await setLocalSetting("core.hooksPath", to: ".githooks", git: git)
        try await setLocalSetting("commit.gpgsign", to: "false", git: git)

        // No Claude Code settings in the repository.
        let settings = [".claude/settings.json", ".claude/settings.local.json", ".mcp.json"].filter { path in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path, isDirectory: false).path)
        }
        guard settings.isEmpty else {
            throw Self.checkFailure(.unavailable, "Claude Code settings in \(root.path) would apply to the Forge's "
                                        + "sessions: move \(settings.joined(separator: ", ")) out of the repository, "
                                        + "then retry.")
        }

        // The guardrail files hold no local change; without refs/remotes/origin/<branch> they cannot be compared.
        guard let guardrail = try await gitStep({ try await changedGuardrailFiles(git: git, branch: config.branch) })
        else {
            throw Self.checkFailure(.unavailable, "The guardrail files of \(id) cannot be compared with origin: "
                                        + "\(root.path) has no refs/remotes/origin/\(config.branch). Run git fetch "
                                        + "origin \(config.branch) there, then retry.")
        }
        guard guardrail.isEmpty else {
            throw ConfigurationCheckFailure(
                error: ProtocolError(.unavailable, "The guardrail files of \(id) were changed in \(root.path): "
                                         + "\(guardrail.joined(separator: ", ")). Undo each change (git restore "
                                         + "--source=origin/\(config.branch) --staged --worktree -- <file> for a file "
                                         + "origin has; delete a file origin does not have), or check and push your "
                                         + "reviewed change by hand (docs/public-repository.md#protected-paths)."),
                guardrailPaths: guardrail)
        }

        // The Claude CLI is available.
        guard await host.hostInfo.claudePath != nil else {
            throw Self.checkFailure(.unavailable, "The Claude CLI is not available on this Main.")
        }
        return Repository(git: git, project: project, root: root)
    }

    /// The hooks path and signing rows: when `git config --local --get <key>` does not print `value`, the Forge runs
    /// `git config --local <key> <value>`. A failure is the error of `git config`.
    private func setLocalSetting(_ key: String, to value: String, git: ForgeGit) async throws {
        try await gitStep {
            let current = ForgeGit.text(try await git.run(["config", "--local", "--get", key], timeout: .seconds(30),
                                                          allowedExitCodes: [0, 1]).standardOutput)
            if current != value {
                _ = try await git.run(["config", "--local", key, value], timeout: .seconds(30))
                Log.host.notice("Set \(key, privacy: .public) of the Forge source repository")
            }
        }
    }

    /// Guardrail files: the paths of `ForgePushGate.protectedPaths`, and the files named `.gitattributes` or `.mailmap`
    /// in any folder, changed in the source project since its last commit in common with origin (`<common>` =
    /// `git merge-base HEAD refs/remotes/origin/<branch>`): in the working tree, in the index, or not tracked by git
    /// (ignored files included), each once, in byte order. A clone that is only behind origin passes.
    ///
    /// nil when `refs/remotes/origin/<branch>` does not exist (`git rev-parse --verify --quiet` exits 1), before any
    /// other command: without that ref nothing tells what changed. Any other failure of git throws its error.
    private func changedGuardrailFiles(git: ForgeGit, branch: String) async throws -> [String]? {
        let originBranch = "refs/remotes/origin/\(branch)"
        let exists = try await git.run(["rev-parse", "--verify", "--quiet", originBranch], timeout: .seconds(30),
                                       allowedExitCodes: [0, 1])
        guard exists.termination == .exited(0) else { return nil }
        let common = try await git.output(["merge-base", "HEAD", originBranch])
        let pathspecs = ForgePushGate.protectedPaths + [":(glob)**/.gitattributes", ":(glob)**/.mailmap"]
        let outputs = [
            try await git.run(["diff", "--name-only", "-z", common, "--"] + pathspecs, timeout: .seconds(30)),
            try await git.run(["diff", "--name-only", "-z", "--cached", common, "--"] + pathspecs,
                              timeout: .seconds(30)),
            try await git.run(["ls-files", "--others", "-z", "--"] + pathspecs, timeout: .seconds(30)),
        ]
        var changed = Set<String>()
        for output in outputs {
            for path in output.standardOutput.split(separator: 0, omittingEmptySubsequences: true) {
                changed.insert(String(decoding: path, as: UTF8.self))
            }
        }
        return changed.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// `url` without a trailing `.git`, compared case-insensitively, is `https://github.com/<repository>`,
    /// `ssh://git@github.com/<repository>` or `git@github.com:<repository>`.
    static func isOriginURL(_ url: String, repository: String) -> Bool {
        var value = url.lowercased()
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }
        let name = repository.lowercased()
        return ["https://github.com/\(name)", "ssh://git@github.com/\(name)", "git@github.com:\(name)"].contains(value)
    }

    /// A git step of the configuration checks: its error, as `unavailable` with the git message.
    private func gitStep<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CancellationError {
            throw error
        } catch let failure as ConfigurationCheckFailure {
            throw failure
        } catch {
            throw Self.checkFailure(.unavailable, Self.message(of: error))
        }
    }

    private static func checkFailure(_ code: ProtocolError.Code, _ message: String) -> ConfigurationCheckFailure {
        ConfigurationCheckFailure(error: ProtocolError(code, message), guardrailPaths: [])
    }
}
#endif
