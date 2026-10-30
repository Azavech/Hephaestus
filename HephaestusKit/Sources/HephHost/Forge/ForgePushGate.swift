#if os(macOS)
import Darwin
import Foundation
import HephCore

/// Steps 2 to 7 of the push tools (docs/forge/pipeline.md, "MCP tools"), on a repository whose origin and branch are
/// given: the branch, the commits, their paths, the docs hash (`forge_push_regen`), the personal data check published
/// at the last head of the branch the Forge trusts, then the push. Also step 4 of "Checks and triggers": the check of
/// the commits that reached the branch another way, and the changes of the guardrail among them.
struct ForgePushGate: Sendable {
    enum Tool: String, Sendable { case pushDocs = "forge_push_docs", pushRegen = "forge_push_regen" }

    /// A refused push: `message` is the tool's error text; `guardrailPaths` lists the paths of step 4 that only the
    /// user pushes (empty for the other refusals).
    struct Refusal: Error, Sendable, Equatable {
        var message: String
        var guardrailPaths: [String]
    }

    /// A push: the full SHA pushed and the base of step 2.
    struct Pushed: Sendable, Equatable {
        var commit: String
        var base: String
    }

    /// The protected paths of public-repository.md, in the order of MCP tools step 4; a folder ends with "/".
    static let protectedPaths: [String] = [
        "docs/general.md",
        "docs/public-repository.md",
        "scripts/check-public.sh",
        ".gitignore",
        "CLAUDE.md",
        "HephaestusKit/Sources/HephHost/Forge/ForgePushGate.swift",
        "HephaestusKit/Sources/HephHost/Forge/ForgeGit.swift",
        "HephaestusKit/Sources/HephHost/Forge/ForgeChecks.swift",
        "HephaestusKit/Sources/HephHost/Forge/PrivateTerms.swift",
        "HephaestusKit/Sources/HephHost/Claude/ForgeSessionRules.swift",
        "HephaestusKit/Sources/HephHost/Claude/ForgePrompts.swift",
        "HephaestusKit/Sources/HephHost/MCP/MCPToolKinds.swift",
        "HephaestusKit/Tests/HephHostTests/PublicCheckTests.swift",
        "HephaestusKit/Tests/HephHostTests/ForgePushTests.swift",
        ".githooks/",
        ".github/",
    ]

    let git: ForgeGit
    let branch: String
    /// Passed as HEPHAESTUS_PRIVATE_TERMS (the caller writes it first when it is missing).
    let termsFile: URL

    /// `termsFile`: passed as HEPHAESTUS_PRIVATE_TERMS (the caller writes it first when it is missing).
    init(git: ForgeGit, branch: String, termsFile: URL) {
        self.git = git
        self.branch = branch
        self.termsFile = termsFile
    }

    /// Steps 2 to 7. Throws Refusal, whose message is also the text of git and bash failures. `trustedHead`: the commit
    /// whose scripts/check-public.sh step 6 runs; `<base>` when nil.
    func push(_ tool: Tool, trustedHead: String? = nil) async throws -> Pushed {
        do {
            return try await gate(tool, trustedHead: trustedHead)
        } catch let refusal as Refusal {
            throw refusal
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Refusal(message: Self.message(of: error), guardrailPaths: [])
        }
    }

    /// Checks and triggers step 4: nil when the commits of `head` that `trusted` does not have are clean (`ci skip
    /// marker` findings alone count as clean), else the finding lines; throws Refusal (its message is the reason) when
    /// the check cannot run.
    ///
    /// The check is `scripts/check-public.sh` as it is at `trusted`, run as in MCP tools step 6 with
    /// `--ref refs/heads/<branch> --commits <head> --not <trusted>`: the published check as it was before these commits
    /// judges them, with the private terms. They are clean when it exits 0, or when it exits 1 with only `ci skip
    /// marker` findings (`holdsOnlySkipMarkers(_:)`): GitHub ran no CI for such commits, and this check stands in for
    /// the personal data check of that run.
    func checkPushedElsewhere(from trusted: String, to head: String) async throws -> String? {
        let script: Data
        do {
            script = try await git.run(["show", "\(trusted):scripts/check-public.sh"], timeout: .seconds(30))
                .standardOutput
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Refusal(message: Self.message(of: error), guardrailPaths: [])
        }
        do {
            switch try await runCheck(script, arguments: ["--ref", "refs/heads/\(branch)",
                                                          "--commits", head, "--not", trusted]) {
            case .clean:
                return nil
            case .findings(let output):
                return Self.holdsOnlySkipMarkers(output) ? nil : ForgeGit.text(output)
            }
        } catch let failure as CheckFailure {
            throw Refusal(message: failure.reason, guardrailPaths: [])
        }
    }

    /// Checks and triggers step 4: the paths that differ between `trusted` and `head` that step 4 of the push tools
    /// leaves to the user by their name, each once, sorted in byte order; throws Refusal (the git error) on failure.
    ///
    /// The paths of `git diff-tree --name-only -r -z <trusted> <head>` for which `isGuardrail(_:)` is true: a protected
    /// path, a `.gitattributes` or `.mailmap` file, a path holding a character outside ASCII. A change of the guardrail
    /// that holds no personal data passes `checkPushedElsewhere`, yet it can weaken the checks of the next pushes.
    func guardrailPaths(from trusted: String, to head: String) async throws -> [String] {
        let output: Data
        do {
            output = try await git.run(["diff-tree", "--name-only", "-r", "-z", trusted, head], timeout: .seconds(30))
                .standardOutput
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Refusal(message: Self.message(of: error), guardrailPaths: [])
        }
        return Self.sortedOnce(Self.paths(output).filter(Self.isGuardrail))
    }

    // MARK: - Steps

    private func gate(_ tool: Tool, trustedHead: String?) async throws -> Pushed {
        let name = tool.rawValue
        // 2. Branch: `<sha>` and `<base>` are resolved once; the later steps check and push exactly them.
        _ = try await git.run(["fetch", "--quiet", "origin", branch], timeout: .seconds(120))
        let current = try await git.output(["rev-parse", "--abbrev-ref", "HEAD"])
        guard current == branch else {
            throw refusal("The repository is on \(current), not \(branch): switch to \(branch), then call \(name) "
                          + "again.")
        }
        let sha = try await git.output(["rev-parse", "--verify", "HEAD"])
        let base = try await git.output(["rev-parse", "--verify", "refs/remotes/origin/\(branch)"])

        // 3. Commits, oldest first.
        let commits = ForgeGit.lines(try await git.run(["rev-list", "--reverse", "\(base)..\(sha)"],
                                                       timeout: .seconds(30)).standardOutput)
        guard !commits.isEmpty else {
            throw refusal("Nothing to push: commit your change first.")
        }
        guard try await isAncestor(base, of: sha) else {
            throw refusal(movedMessage(name))
        }
        let merges = try await git.output(["rev-list", "--merges", "\(base)..\(sha)"])
        guard merges.isEmpty else {
            throw refusal("Rebase instead of merging: git pull --rebase origin \(branch), then call \(name) again.")
        }

        // 4. Paths.
        try await checkPaths(of: commits, tool: tool)

        // 5. Docs hash (forge_push_regen only).
        if tool == .pushRegen {
            let recorded = try await git.file("App/DocsHash.txt", at: sha).map(ForgeGit.text) ?? "missing"
            let actual = try await git.docsHash(of: sha)
            guard recorded == actual else {
                throw refusal("App/DocsHash.txt at \(Self.short(sha)) is \(recorded) but the docs hash of that commit "
                              + "is \(actual). Run scripts/docs-hash.sh > App/DocsHash.txt, commit, then call "
                              + "forge_push_regen again.")
            }
        }

        // 6. Personal data: the published check of `trustedHead` (of `<base>` while it is nil), never the working
        // tree's, which a session can change, nor one that reached the branch outside the gate and was not trusted.
        guard let script = try await git.file("scripts/check-public.sh", at: trustedHead ?? base) else {
            throw refusal("scripts/check-public.sh is missing on origin/\(branch).")
        }
        do {
            switch try await runCheck(script, arguments: ["--ref", "refs/heads/\(branch)",
                                                          "--commits", "\(base)..\(sha)"]) {
            case .clean:
                break
            case .findings(let output):
                throw refusal(ForgeGit.text(output) + "\n\n"
                              + "Remove the personal data or CI skip markers and rewrite these unpushed commits (git "
                              + "reset --soft origin/\(branch), then commit again), then call \(name) again. If a "
                              + "private term is a false positive, the user narrows or removes that one term in "
                              + "private-terms.txt.")
            }
        } catch let failure as CheckFailure {
            throw refusal("The personal data check could not run: \(Self.withoutFinalPeriod(failure.reason)).")
        }

        // 7. Push, never forced; no hook runs.
        do {
            _ = try await git.run(["push", "--no-follow-tags", "origin", "\(sha):refs/heads/\(branch)"],
                                  timeout: .seconds(120))
        } catch let error as CancellationError {
            throw error
        } catch {
            let pushError = Self.message(of: error)
            if (try? await git.run(["fetch", "--quiet", "origin", branch], timeout: .seconds(120))) != nil,
               let ancestor = try? await isAncestor("refs/remotes/origin/\(branch)", of: sha), !ancestor {
                throw refusal(movedMessage(name))
            }
            throw refusal(pushError)
        }
        return Pushed(commit: sha, base: base)
    }

    // MARK: - Step 4

    /// What step 4 reads of a commit.
    private struct CommitPaths {
        let commit: String
        /// The paths it changes: added, modified, deleted, and both names of a renamed file.
        let changed: [String]
        /// The binary files it adds or changes, decided with no git attributes (`binaryFiles(of:)`).
        let binary: [String]
        /// The paths of its tree.
        let tree: [String]
    }

    /// Step 4: the guardrail (every commit at once), then the paths that differ only in case, then the paths each
    /// tool may push, each over the commits oldest first and, within a commit, over its paths in the order of
    /// `git diff-tree`; paths are compared after ASCII lowercasing. A Mac's disk also folds some characters outside
    /// ASCII onto ASCII letters (U+212A KELVIN SIGN onto `k`, U+017F LONG S onto `s`), so a path holding a character
    /// outside ASCII is left to the user with the guardrail (`isGuardrail(_:)`).
    private func checkPaths(of commits: [String], tool: Tool) async throws {
        var read: [CommitPaths] = []
        for commit in commits {
            let changed = Self.paths(try await git.run(["diff-tree", "--no-commit-id", "--name-only", "-r", "-z",
                                                        commit], timeout: .seconds(30)).standardOutput)
            let binary = try await binaryFiles(of: commit)
            let tree = Self.paths(try await git.run(["ls-tree", "-r", "-z", "--name-only", commit],
                                                    timeout: .seconds(30)).standardOutput)
            read.append(CommitPaths(commit: commit, changed: changed, binary: binary, tree: tree))
        }

        // The guardrail: each such path of the commits once, as the commit writes it, sorted in byte order.
        var guardrail: [String] = []
        for entry in read {
            guardrail += entry.changed.filter(Self.isGuardrail)
            guardrail += entry.binary
        }
        if !guardrail.isEmpty {
            let paths = Self.sortedOnce(guardrail)
            throw Refusal(message: "Changes to the personal-data guardrail are pushed by hand after review: "
                              + "\(paths.joined(separator: ", ")).",
                          guardrailPaths: paths)
        }

        // A path that differs only in case from another path, or folder, of its tree.
        for entry in read {
            if let clash = Self.caseClash(entry) {
                throw refusal("\(Self.short(entry.commit)) adds \(clash.path), which differs only in case from "
                              + "\(clash.other).")
            }
        }

        // forge_push_docs pushes docs/ only; forge_push_regen never pushes docs/.
        for entry in read {
            for path in entry.changed {
                let inDocs = Self.lowercasedASCII(path).hasPrefix("docs/")
                switch tool {
                case .pushDocs where !inDocs:
                    throw refusal("forge_push_docs pushes documentation only: \(Self.short(entry.commit)) changes "
                                  + "\(path). Keep only docs/ in these commits (git reset --soft origin/\(branch), "
                                  + "then commit docs/ alone), then call forge_push_docs again.")
                case .pushRegen where inDocs:
                    throw refusal("forge_push_regen never pushes documentation: \(Self.short(entry.commit)) changes "
                                  + "\(path). A regeneration does not edit docs/: take that change out of these "
                                  + "commits, then call forge_push_regen again.")
                default:
                    continue
                }
            }
        }
    }

    /// A path that step 4 leaves to the user by its name: a protected path (a folder of `protectedPaths` holds every
    /// path under it), or a file named `.gitattributes` or `.mailmap` in any folder, compared after ASCII lowercasing;
    /// or a path holding a character outside ASCII (a byte above 0x7F), which a Mac's disk can store as one of the
    /// others (`.githoo<U+212A>s/pre-push` is `.githooks/pre-push` there).
    static func isGuardrail(_ path: String) -> Bool {
        if path.utf8.contains(where: { $0 >= 0x80 }) {
            return true
        }
        let lowered = lowercasedASCII(path)
        for protected in protectedPaths.map(lowercasedASCII) {
            if protected.hasSuffix("/") ? lowered.hasPrefix(protected) : lowered == protected {
                return true
            }
        }
        let name = lowered.split(separator: "/").last.map(String.init) ?? lowered
        return name == ".gitattributes" || name == ".mailmap"
    }

    /// The first path the commit adds or changes that equals, ignoring ASCII case, another path of its tree, or one of
    /// whose folders equals, ignoring ASCII case, another folder of its tree; `other` is that path, or that folder
    /// followed by "/".
    private static func caseClash(_ entry: CommitPaths) -> (path: String, other: String)? {
        var paths: [String: [String]] = [:]
        var folders: [String: [String]] = [:]
        var seenFolders = Set<String>()
        for path in entry.tree {
            paths[lowercasedASCII(path), default: []].append(path)
            for folder in parentFolders(of: path) where seenFolders.insert(folder).inserted {
                folders[lowercasedASCII(folder), default: []].append(folder)
            }
        }
        let present = Set(entry.tree)
        for path in entry.changed where present.contains(path) {
            if let other = paths[lowercasedASCII(path)]?.first(where: { $0 != path }) {
                return (path, other)
            }
            for folder in parentFolders(of: path) {
                if let other = folders[lowercasedASCII(folder)]?.first(where: { $0 != folder }) {
                    return (path, other + "/")
                }
            }
        }
        return nil
    }

    /// The folders of a path, outermost first: `a/b/c.md` → `a`, `a/b`.
    private static func parentFolders(of path: String) -> [String] {
        var result: [String] = []
        var start = path.startIndex
        while let slash = path[start...].firstIndex(of: "/") {
            result.append(String(path[..<slash]))
            start = path.index(after: slash)
        }
        return result
    }

    /// The NUL-terminated paths of a git output.
    private static func paths(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Each path once, sorted in byte order, both by its UTF-8 bytes: Swift's `==` and `Hashable` of `String` treat
    /// canonically equivalent paths as equal, which git keeps apart.
    private static func sortedOnce(_ paths: [String]) -> [String] {
        let sorted = paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var result: [String] = []
        for path in sorted where !(result.last.map { $0.utf8.elementsEqual(path.utf8) } ?? false) {
            result.append(path)
        }
        return result
    }

    /// The binary files a commit adds or changes, in the order of `git diff-tree`, decided as the check script decides
    /// them, with no git attributes: each record of `git diff-tree --no-commit-id --root --raw --no-abbrev
    /// --no-renames -r -z <commit>` whose new mode is `100644` or `100755` and whose new object is not all zeros, when
    /// that blob (`git cat-file blob <sha>`) holds a NUL byte in its first 8000 bytes. A file it deletes does not
    /// count.
    private func binaryFiles(of commit: String) async throws -> [String] {
        let raw = try await git.run(["diff-tree", "--no-commit-id", "--root", "--raw", "--no-abbrev", "--no-renames",
                                     "-r", "-z", commit], timeout: .seconds(30)).standardOutput
        var result: [String] = []
        for file in Self.changedFiles(raw) where file.newMode == "100644" || file.newMode == "100755" {
            guard !file.newObject.allSatisfy({ $0 == "0" }) else { continue }
            let blob = try await git.run(["cat-file", "blob", file.newObject], timeout: .seconds(30)).standardOutput
            if blob.prefix(8000).contains(0) {
                result.append(file.path)
            }
        }
        return result
    }

    /// The records of `git diff-tree --raw -z`: a field `:<old mode> <new mode> <old sha> <new sha> <status>`, then
    /// the path (the two names of a copy or a rename, the new one last); the new mode, new object and path of each.
    private static func changedFiles(_ data: Data) -> [(newMode: String, newObject: String, path: String)] {
        let fields = paths(data)
        var result: [(newMode: String, newObject: String, path: String)] = []
        var index = 0
        while index < fields.count {
            let header = fields[index].split(separator: " ", omittingEmptySubsequences: true)
            index += 1
            guard header.count == 5, header[0].hasPrefix(":") else { continue }
            let names = header[4].hasPrefix("C") || header[4].hasPrefix("R") ? 2 : 1
            guard index + names <= fields.count else { break }
            result.append((newMode: String(header[1]), newObject: String(header[3]), path: fields[index + names - 1]))
            index += names
        }
        return result
    }

    // MARK: - Step 6

    /// The outcome of a personal data check that ran: clean (exit status 0), or findings (exit status 1) with its
    /// standard output as it is; Checks and triggers step 4 reads its lines, and both callers give it trimmed (one line
    /// per finding).
    private enum CheckOutcome {
        case clean
        case findings(Data)
    }

    /// The check could not run (another exit status, the timeout, a script that cannot be written or started).
    private struct CheckFailure: Error {
        let reason: String
    }

    /// Runs `script` (a published `scripts/check-public.sh`) with `/bin/bash` from a new file of the temporary folder,
    /// in the repository root, with the environment of step 6 and a timeout of 120 s; the file is deleted after.
    private func runCheck(_ script: Data, arguments: [String]) async throws -> CheckOutcome {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("check-public-\(UUID().uuidString).sh", isDirectory: false)
        do {
            try script.write(to: scriptURL, options: .withoutOverwriting)
        } catch {
            throw CheckFailure(reason: error.localizedDescription)
        }
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
        }
        let configuration = ChildProcessConfiguration(executable: "/bin/bash", arguments: [scriptURL.path] + arguments,
                                                      workingDirectory: git.repositoryRoot.path,
                                                      environment: checkEnvironment)
        let output: CapturedOutput
        do {
            output = try await ChildProcess.capture(configuration, timeout: .seconds(120))
        } catch let error as CancellationError {
            throw error
        } catch let ChildProcessError.spawnFailed(errno: code) {
            throw CheckFailure(reason: String(cString: strerror(code)))
        } catch {
            throw CheckFailure(reason: error.localizedDescription)
        }
        if output.timedOut {
            throw CheckFailure(reason: "timed out")
        }
        switch output.termination {
        case .exited(0):
            return .clean
        case .exited(1):
            return .findings(output.standardOutput)
        default:
            throw CheckFailure(reason: ForgeGit.lastLine(output.standardError)
                                   ?? "exit status \(output.termination.exitCode)")
        }
    }

    /// Checks and triggers step 4: the standard output of a check that exited 1 holds only `ci skip marker` findings:
    /// an optional first line starting with `Note: `, then one or more lines `<sha8> message: ci skip marker`, then a
    /// last line starting with `Personal data check: `. The output is read as it is, not trimmed: a line ends at a line
    /// feed, and its bytes are compared, `<sha8>` being 8 lowercase hexadecimal digits (the first 8 characters of a
    /// full SHA).
    private static func holdsOnlySkipMarkers(_ output: Data) -> Bool {
        var lines = output.split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        if lines.first?.starts(with: "Note: ".utf8) == true {
            lines.removeFirst()
        }
        guard let summary = lines.popLast(), summary.starts(with: "Personal data check: ".utf8) else { return false }
        let marker = Array(" message: ci skip marker".utf8)
        return !lines.isEmpty && lines.allSatisfy { line in
            line.prefix(8).allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
                && line.dropFirst(8).elementsEqual(marker)
        }
    }

    /// The environment of the check: the git environment (which has `GIT_NO_REPLACE_OBJECTS=1`) without
    /// `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT` and the `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>` variables,
    /// with `core.hooksPath=/dev/null` and `core.fsmonitor=false` given through `GIT_CONFIG_COUNT`,
    /// `GIT_NO_REPLACE_OBJECTS=1` and the private terms file. Without the five `GIT_CONFIG_*` variables, the script's
    /// `git update-index` would run the `post-index-change` hook of the working tree.
    private var checkEnvironment: [String: String] {
        var environment = git.environment.filter { name, _ in !Self.isGitConfigVariable(name) }
        environment["GIT_CONFIG_COUNT"] = "2"
        environment["GIT_CONFIG_KEY_0"] = "core.hooksPath"
        environment["GIT_CONFIG_VALUE_0"] = "/dev/null"
        environment["GIT_CONFIG_KEY_1"] = "core.fsmonitor"
        environment["GIT_CONFIG_VALUE_1"] = "false"
        environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        environment["HEPHAESTUS_PRIVATE_TERMS"] = termsFile.path
        return environment
    }

    /// `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>`.
    private static func isGitConfigVariable(_ name: String) -> Bool {
        if name == "GIT_CONFIG_PARAMETERS" || name == "GIT_CONFIG_COUNT" {
            return true
        }
        for prefix in ["GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"] where name.hasPrefix(prefix) {
            let number = name.dropFirst(prefix.count)
            return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return false
    }

    // MARK: - Helpers

    /// `git merge-base --is-ancestor <a> <b>`: exit 0 = ancestor, 1 = not.
    private func isAncestor(_ ancestor: String, of commit: String) async throws -> Bool {
        let output = try await git.run(["merge-base", "--is-ancestor", ancestor, commit], timeout: .seconds(30),
                                       allowedExitCodes: [0, 1])
        return output.termination == .exited(0)
    }

    private func movedMessage(_ tool: String) -> String {
        "origin/\(branch) moved: run git pull --rebase origin \(branch), then call \(tool) again."
    }

    private func refusal(_ message: String) -> Refusal {
        Refusal(message: message, guardrailPaths: [])
    }

    /// The message of a git error (a ProtocolError), else the localized description.
    private static func message(of error: any Error) -> String {
        (error as? ProtocolError)?.message ?? error.localizedDescription
    }

    /// `text` without its final period, when it ends with one: the `<reason>` of step 6, and of Checks and triggers
    /// step 4, is written without it (the script's error lines end with one).
    static func withoutFinalPeriod(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    /// ASCII letters in lowercase, every other character as it is.
    static func lowercasedASCII(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
        }))
    }

    /// The first 8 characters of a full SHA.
    static func short(_ sha: String) -> String {
        String(sha.prefix(8))
    }
}
#endif
