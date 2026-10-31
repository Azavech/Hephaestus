#if os(macOS)
import Foundation
import HephCore

/// The git commands of the bundle worktrees (docs/services/bundles.md, "Worktrees"):
/// `git -c core.hooksPath=/dev/null -c core.fsmonitor=false <arguments>`, so that no hook or file-system monitor of
/// the repository runs in the app's process; the first `git` of the environment's `PATH`, run with
/// `ChildProcess.capture`, no shell, a timeout of 60 s. A failure throws
/// ProtocolError(.internal, "git <subcommand> failed: <last non-empty stderr line>"). The caller runs it only while
/// `host.info` reports `gitAvailable`.
struct BundleGit: Sendable {
    /// The project's code folder.
    let codeFolder: URL
    /// The login environment.
    let environment: [String: String]

    init(codeFolder: URL, environment: [String: String]) {
        self.codeFolder = codeFolder
        self.environment = environment
    }

    /// The repository check: `<top>` = `git rev-parse --show-toplevel` in the code folder and the code folder's path
    /// relative to it (empty when they are equal). `HEAD` must be a branch with a commit, else badRequest.
    func repository() async throws -> (top: URL, relative: String) {
        let notInOne = ProtocolError(.badRequest, "Bundles need a git repository on a branch with a commit: "
                                     + "\(codeFolder.path) is not in one.")
        let topPath: String
        do {
            topPath = try await output(["rev-parse", "--show-toplevel"], in: codeFolder)
            _ = try await output(["symbolic-ref", "--short", "HEAD"], in: codeFolder)
            _ = try await output(["rev-parse", "--verify", "HEAD"], in: codeFolder)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw notInOne
        }
        let top = URL(fileURLWithPath: topPath, isDirectory: true)
        // git gives the top folder with symlinks resolved: the code folder is compared in the same form.
        let realTop = ClaudePathEncoding.canonicalPath(topPath) ?? topPath
        let realCode = ClaudePathEncoding.canonicalPath(codeFolder.path) ?? codeFolder.path
        if realCode == realTop {
            return (top, "")
        }
        guard realCode.hasPrefix(realTop + "/") else { throw notInOne }
        return (top, String(realCode.dropFirst(realTop.count + 1)))
    }

    /// `git symbolic-ref --short HEAD` in the code folder.
    func currentBranch() async throws -> String {
        try await output(["symbolic-ref", "--short", "HEAD"], in: codeFolder)
    }

    /// Creating: `git worktree prune`, then `git worktree add <folder> <branch>` when the branch exists, else
    /// `git worktree add -b <branch> <folder> <base>`; the parent folders are created first. Runs in `<top>`.
    func createWorktree(at folder: URL, branch: String, base: String) async throws {
        let top = try await topFolder()
        _ = try await run(["worktree", "prune"], in: top)
        do {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw ProtocolError(.internal, "Cannot create \(folder.deletingLastPathComponent().path): "
                                + error.localizedDescription)
        }
        if try await branchExists(branch, in: top) {
            _ = try await run(["worktree", "add", folder.path, branch], in: top)
        } else {
            _ = try await run(["worktree", "add", "-b", branch, folder.path, base], in: top)
        }
    }

    /// Removing: `git worktree remove --force <folder>`; when the folder is still there, it is deleted; then
    /// `git worktree prune`. Runs in `<top>`.
    func removeWorktree(at folder: URL) async throws {
        let top = try await topFolder()
        do {
            _ = try await run(["worktree", "remove", "--force", folder.path], in: top)
        } catch let error as CancellationError {
            throw error
        } catch {
            Log.host.error("\(ProjectRegistry.protocolError(error).message)")
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                throw ProtocolError(.internal, "Cannot delete \(folder.path): \(error.localizedDescription)")
            }
        }
        _ = try await run(["worktree", "prune"], in: top)
    }

    /// Brought in: `git cherry <base> <branch>` prints no line starting with `+`; the work is not on a `<base>` that
    /// does not exist (`branchExists`). Runs in `<top>`.
    func isBroughtIn(branch: String, base: String) async throws -> Bool {
        let top = try await topFolder()
        guard try await branchExists(base, in: top) else { return false }
        let output = try await run(["cherry", base, branch], in: top)
        return !Self.lines(output.standardOutput).contains { $0.hasPrefix("+") }
    }

    /// `git branch -D <branch>`. Runs in `<top>`.
    func deleteBranch(_ branch: String) async throws {
        let top = try await topFolder()
        _ = try await run(["branch", "-D", branch], in: top)
    }

    /// `git rev-parse --verify --quiet refs/heads/<branch>`: exit 0 = exists, 1 = does not exist. Runs in `<top>`.
    func branchExists(_ branch: String) async throws -> Bool {
        try await branchExists(branch, in: try await topFolder())
    }

    /// Old branches: `git branch -m task/<ticketID> ticket/<ticketID>` when the first exists and the second does not.
    /// Returns true when it renamed the branch. Runs in `<top>`.
    func renameOldBranch(ticketID: String) async throws -> Bool {
        let top = try await topFolder()
        let old = "task/\(ticketID)"
        let new = "ticket/\(ticketID)"
        guard try await branchExists(old, in: top), !(try await branchExists(new, in: top)) else { return false }
        _ = try await run(["branch", "-m", old, new], in: top)
        return true
    }

    // MARK: - Private

    private static let timeout = Duration.seconds(60)

    private func branchExists(_ branch: String, in top: URL) async throws -> Bool {
        let output = try await run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: top,
                                   allowedExitCodes: [0, 1])
        return output.termination == .exited(0)
    }

    /// `git rev-parse --show-toplevel` in the code folder.
    private func topFolder() async throws -> URL {
        URL(fileURLWithPath: try await output(["rev-parse", "--show-toplevel"], in: codeFolder), isDirectory: true)
    }

    /// The trimmed standard output of a command that must succeed.
    private func output(_ arguments: [String], in folder: URL) async throws -> String {
        let output = try await run(arguments, in: folder)
        return String(decoding: output.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `git -c core.hooksPath=/dev/null -c core.fsmonitor=false <arguments>` in `folder`; a non-zero exit not in
    /// `allowedExitCodes`, or the timeout, throws.
    private func run(_ arguments: [String], in folder: URL, allowedExitCodes: Set<Int32> = [0]) async throws
        -> CapturedOutput {
        let subcommand = arguments.first ?? ""
        guard let executable = Self.locateGit(environment: environment) else {
            throw ProtocolError(.internal, "git \(subcommand) failed: \(String(cString: strerror(ENOENT)))")
        }
        let configuration = ChildProcessConfiguration(executable: executable,
                                                      arguments: ["-c", "core.hooksPath=/dev/null",
                                                                  "-c", "core.fsmonitor=false"] + arguments,
                                                      workingDirectory: folder.path, environment: environment)
        let output: CapturedOutput
        do {
            output = try await ChildProcess.capture(configuration, timeout: Self.timeout)
        } catch let error as CancellationError {
            throw error
        } catch let ChildProcessError.spawnFailed(errno: code) {
            throw ProtocolError(.internal, "git \(subcommand) failed: \(String(cString: strerror(code)))")
        } catch {
            throw ProtocolError(.internal, "git \(subcommand) failed: \(error.localizedDescription)")
        }
        if output.timedOut {
            throw ProtocolError(.internal,
                                "git \(subcommand) failed: \(Self.lines(output.standardError).last ?? "timed out")")
        }
        guard case .exited(let status) = output.termination, allowedExitCodes.contains(status) else {
            let reason = Self.lines(output.standardError).last ?? "exit status \(output.termination.exitCode)"
            throw ProtocolError(.internal, "git \(subcommand) failed: \(reason)")
        }
        return output
    }

    /// The first executable regular file named `git` in the directories of the environment's `PATH`, in order.
    private static func locateGit(environment: [String: String]) -> String? {
        let fileManager = FileManager.default
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = (String(directory) as NSString).appendingPathComponent("git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// The non-empty lines of a process output, each trimmed.
    private static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
#endif
