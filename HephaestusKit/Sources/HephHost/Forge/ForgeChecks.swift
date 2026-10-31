#if os(macOS)
import Foundation
import HephCore

/// Configuration checks (docs/forge/pipeline.md, "Forge host configuration"): run, in this order, at the start of every
/// check, at the start of a regeneration step, before handling `forge.feedback` and at the start of the push tools.
/// Before the first one, when this Main does not host the source project, the Forge registers it when it can
/// (Registering the source project). The first failure stops the list.
extension ForgeService {
    /// The source project's repository after the configuration checks passed.
    struct Repository: Sendable {
        let git: ForgeGit
        let project: HostedProject
        let root: URL
    }

    /// A failed configuration check: the error of the methods and push tools (`unavailable`, `locked` while the source
    /// project is moved).
    struct ConfigurationCheckFailure: Error, Sendable {
        let error: ProtocolError
    }

    /// The configuration checks; the first failure sets `lastError` to its message and is thrown as its ProtocolError.
    func configurationChecks() async throws -> Repository {
        do {
            return try await runConfigurationChecks()
        } catch let failure as ConfigurationCheckFailure {
            lastError = failure.error.message
            await broadcastIfChanged()
            throw failure.error
        }
    }

    private func runConfigurationChecks() async throws -> Repository {
        guard let config = configuration else { throw Self.notTheForge }
        let id = config.sourceProjectID
        let environment = await LoginEnvironment.shared.environment()

        // Registering the source project when this Main does not host it; its failure is the first row's.
        do {
            try await registerSourceProject(config, environment: environment)
        } catch let error as ProtocolError {
            throw ConfigurationCheckFailure(error: error)
        }

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
        let repository = ForgeConfig.publicRepository
        let origin = try await gitStep { try await git.output(["remote", "get-url", "origin"]) }
        guard Self.isOriginURL(origin, repository: repository) else {
            throw Self.checkFailure(.unavailable,
                                    "The origin remote of \(id) is \(origin), not github.com/\(repository).")
        }
        let pushURLs = try await gitStep {
            ForgeGit.lines(try await git.run(["remote", "get-url", "--push", "--all", "origin"],
                                             timeout: .seconds(30)).standardOutput)
        }
        guard pushURLs.count == 1, Self.isOriginURL(pushURLs[0], repository: repository) else {
            throw Self.checkFailure(.unavailable, "The push URL of origin is \(pushURLs.joined(separator: ", ")), "
                                        + "not github.com/\(repository).")
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

        // The Claude CLI is available.
        guard await host.hostInfo.claudePath != nil else {
            throw Self.checkFailure(.unavailable, "The Claude CLI is not available on this Main.")
        }
        return Repository(git: git, project: project, root: root)
    }

    /// Registering the source project, run by the configuration checks before their first row: returns when
    /// `config.sourceProjectID` is hosted on this Main, at once or once <folder> is imported; else throws
    /// ProtocolError(.unavailable, "The Forge source project <ID> is not on this Main. <text of the failed step>").
    /// `environment`: the environment of its git commands, LoginEnvironment.shared.environment() in the configuration
    /// checks; the tests pass the environment of a GitSandbox (testing.md). The Forge need not be enabled.
    ///
    /// <folder> is the folder the clone would have in the projects folder, named after the repository's name (the
    /// part of ForgeConfig.publicRepository after its `/`). The steps run in order and the first that fails ends the
    /// registration with nothing imported; a CancellationError of a git command is rethrown. The Forge never clones.
    func registerSourceProject(_ config: ForgeConfig, environment: [String: String]) async throws {
        let id = config.sourceProjectID
        if (try? await host.registry.hosted(id)) != nil { return }
        let repository = ForgeConfig.publicRepository
        let name = repository.split(separator: "/").last.map(String.init) ?? repository
        let folder = (await host.settings()).projectsFolderURL.appendingPathComponent(name).path
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        func refused(_ text: String) -> ProtocolError {
            ProtocolError(.unavailable, "The Forge source project \(id) is not on this Main. \(text)")
        }
        let addYourClone = "or add your clone with Add Existing Folder… and choose it as the Source project in "
            + "Settings ▸ Forge & Updates."

        // 1. <folder> is an existing folder.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw refused("There is no folder \(folder): clone github.com/\(repository) there, \(addYourClone)")
        }

        // 2. git is available.
        guard await host.hostInfo.gitAvailable, let executable = ForgeGit.locate("git", environment: environment)
        else {
            throw refused("git is not available on this Main.")
        }
        let git = ForgeGit(executable: executable, repositoryRoot: root, environment: environment)

        // 3. <folder> is the top folder of a git repository, symlinks resolved on both sides.
        let notTopFolder = refused("\(folder) is not the top folder of a git repository: clone "
                                   + "github.com/\(repository) there, \(addYourClone)")
        let top: String
        do {
            top = try await git.output(["rev-parse", "--show-toplevel"])
        } catch let error as CancellationError {
            throw error
        } catch {
            throw notTopFolder
        }
        guard let realTop = ClaudePathEncoding.canonicalPath(top),
              let realFolder = ClaudePathEncoding.canonicalPath(folder), realTop == realFolder
        else { throw notTopFolder }

        // 4. Its origin is the repository on GitHub, as in the origin row; a missing origin fails too.
        let notAClone = refused("\(folder) is not a clone of github.com/\(repository): set its origin remote to "
                                + "https://github.com/\(repository).git, \(addYourClone)")
        let origin: String
        do {
            origin = try await git.output(["remote", "get-url", "origin"])
        } catch let error as CancellationError {
            throw error
        } catch {
            throw notAClone
        }
        guard Self.isOriginURL(origin, repository: repository) else { throw notAClone }

        // 5. No project.yml, or one whose id is <ID>; a file that cannot be loaded fails with the text of step 6.
        if FileManager.default.fileExists(atPath: ProjectFile.url(projectRoot: root).path) {
            let file: ProjectFile
            do {
                file = try ProjectFile.load(projectRoot: root)
            } catch {
                throw refused("Adding \(folder) failed: \(Self.message(of: error))")
            }
            guard file.id == id else {
                throw refused("\(folder) holds the project \(file.id): choose it as the Source project in "
                              + "Settings ▸ Forge & Updates, after adding it with Add Existing Folder… when it is not "
                              + "on this Mac.")
            }
        }

        // 6. The import, the logic of projects.import.
        do {
            _ = try await host.projects.importFolder(ProjectsImportParams(path: folder, name: name, identifier: id))
        } catch {
            throw refused("Adding \(folder) failed: \(Self.message(of: error))")
        }
        Log.host.notice("Registered the Forge source project \(id, privacy: .public)")
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
        ConfigurationCheckFailure(error: ProtocolError(code, message))
    }
}
#endif
