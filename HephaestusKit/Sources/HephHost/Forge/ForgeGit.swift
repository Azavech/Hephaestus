#if os(macOS)
import Foundation
import HephCore

/// Runs the git commands of docs/forge/pipeline.md ("Git operations") in a repository root with an environment.
///
/// Every command runs as `git -c core.hooksPath=/dev/null -c core.fsmonitor=false <arguments>` with
/// `GIT_NO_REPLACE_OBJECTS=1`: no hook and no file-system monitor of the repository runs in the app's process, and no
/// replace ref makes a command read another commit, tree or file than the one a push sends.
struct ForgeGit: Sendable {
    let executable: String
    let repositoryRoot: URL
    /// The environment given to `init`, with `GIT_NO_REPLACE_OBJECTS` = `1` added.
    let environment: [String: String]

    /// Keeps `environment` with `GIT_NO_REPLACE_OBJECTS` = `1` added.
    init(executable: String, repositoryRoot: URL, environment: [String: String]) {
        self.executable = executable
        self.repositoryRoot = repositoryRoot
        var environment = environment
        environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        self.environment = environment
    }

    /// `git -c core.hooksPath=/dev/null -c core.fsmonitor=false <arguments>` with `GIT_NO_REPLACE_OBJECTS=1`. A
    /// non-zero exit whose status is not in `allowedExitCodes`, or the timeout, throws
    /// ProtocolError(.internal, "git <subcommand> failed: <line>").
    func run(_ arguments: [String], timeout: Duration, allowedExitCodes: Set<Int32> = [0]) async throws
        -> CapturedOutput {
        let subcommand = arguments.first ?? ""
        let configuration = ChildProcessConfiguration(
            executable: executable,
            arguments: ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments,
            workingDirectory: repositoryRoot.path,
            environment: environment)
        let output: CapturedOutput
        do {
            output = try await ChildProcess.capture(configuration, timeout: timeout)
        } catch let error as CancellationError {
            throw error
        } catch let ChildProcessError.spawnFailed(errno: code) {
            throw ProtocolError(.internal, "git \(subcommand) failed: \(String(cString: strerror(code)))")
        } catch {
            throw ProtocolError(.internal, "git \(subcommand) failed: \(error.localizedDescription)")
        }
        if output.timedOut {
            throw ProtocolError(.internal, "git \(subcommand) failed: \(Self.lastLine(output.standardError) ?? "timed out")")
        }
        guard case .exited(let status) = output.termination, allowedExitCodes.contains(status) else {
            let reason = Self.lastLine(output.standardError) ?? "exit status \(output.termination.exitCode)"
            throw ProtocolError(.internal, "git \(subcommand) failed: \(reason)")
        }
        return output
    }

    /// The standard output of a command that must succeed, trimmed (timeout 30 s unless given).
    func output(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> String {
        let output = try await run(arguments, timeout: timeout)
        return Self.text(output.standardOutput)
    }

    /// `git show <revision>:<path>` as bytes; nil when it fails (the file does not exist at that revision).
    func file(_ path: String, at revision: String) async throws -> Data? {
        do {
            return try await run(["show", "\(revision):\(path)"], timeout: .seconds(30)).standardOutput
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
    }

    /// Docs hash of a revision (Git operations): the entries of `git ls-tree -r -z <rev> -- docs` of mode `100644`
    /// or `100755` and type `blob` whose last path component is not `.DS_Store`, each read with `git show`.
    func docsHash(of revision: String) async throws -> String {
        let listing = try await run(["ls-tree", "-r", "-z", revision, "--", "docs"], timeout: .seconds(30))
        var files: [DocsHash.File] = []
        for entry in listing.standardOutput.split(separator: 0, omittingEmptySubsequences: true) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let tab = text.firstIndex(of: "\t") else { continue }
            let fields = text[text.startIndex..<tab].split(separator: " ")
            let path = String(text[text.index(after: tab)...])
            guard fields.count == 3, fields[0] == "100644" || fields[0] == "100755", fields[1] == "blob",
                  !DocsHash.isExcluded(path)
            else { continue }
            let content = try await run(["show", "\(revision):\(path)"], timeout: .seconds(30)).standardOutput
            files.append(DocsHash.File(path: path, content: content))
        }
        return DocsHash.compute(files)
    }

    // MARK: - Helpers

    /// The first executable regular file named `name` in the directories of the environment's `PATH`, in order.
    static func locate(_ name: String, environment: [String: String]) -> String? {
        let fileManager = FileManager.default
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// UTF-8 text, white space and newlines trimmed at both ends.
    static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The non-empty lines of a text, each trimmed.
    static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The last non-empty line of a process output, trimmed; nil when there is none.
    static func lastLine(_ data: Data) -> String? {
        lines(data).last
    }
}
#endif
