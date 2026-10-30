#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// The Forge push gate (docs/forge/pipeline.md, "MCP tools"): `ForgePushGate` alone, without a HostService, on the
/// repositories of a GitSandbox; the rules of `ForgeSessionRules` (docs/claude/cli.md 3.5); `PrivateTerms`
/// (docs/forge/pipeline.md, "Private terms"); and, with a TestHost, the registration of the source project
/// (docs/forge/pipeline.md, "Registering the source project").
final class ForgePushTests: XCTestCase {
    /// A repository from `makeRepository()` with a second commit adding `docs/a.md` and `App/DocsHash.txt`, its origin
    /// from `makeOrigin`, and the gate.
    private struct Fixture {
        let sandbox: GitSandbox
        let repository: URL
        let origin: URL
        /// The commit `makeOrigin` pushed.
        let pushed: String
        let gate: ForgePushGate
    }

    /// The sandbox and the TestHost of the `testRegister…` cases, and `<folder>`: the TestHost's projects folder
    /// followed by `/Hephaestus`, the name of `ForgeConfig.publicRepository`.
    private struct Registration {
        let sandbox: GitSandbox
        let testHost: TestHost
        let folder: URL
    }

    /// The config the `testRegister…` cases pass to `registerSourceProject(_:environment:)`.
    private static let sourceConfig = ForgeConfig(sourceProjectID: "HEPH", repository: "Azavech/Hephaestus",
                                                  branch: "main", autoRegenerate: true)

    // MARK: - Cases

    func testPushesDocs() async throws {
        let fixture = try makeFixture()
        let sha = try commit(fixture, ["docs/a.md": "a\nb\n"])
        let pushed = try await fixture.gate.push(.pushDocs)
        XCTAssertEqual(pushed, ForgePushGate.Pushed(commit: sha, base: fixture.pushed))
        XCTAssertEqual(try originMain(fixture), sha)
    }

    func testPushesRegeneration() async throws {
        let fixture = try makeFixture()
        let sha = try commit(fixture, ["App/x.swift": "let x = 1\n"])
        let pushed = try await fixture.gate.push(.pushRegen)
        XCTAssertEqual(pushed.commit, sha)
        XCTAssertEqual(try originMain(fixture), sha)

        let stale = try commit(fixture, ["App/DocsHash.txt": "0"])
        let refusal = await refusal { try await fixture.gate.push(.pushRegen) }
        XCTAssertTrue(refusal?.message.hasPrefix("App/DocsHash.txt at \(stale.prefix(8)) is 0 but the docs hash of "
                                                     + "that commit is") == true, refusal?.message ?? "")
        XCTAssertEqual(try originMain(fixture), sha)
    }

    func testRefusesPersonalData() async throws {
        let fixture = try makeFixture()
        let sha = try commit(fixture, ["docs/a.md": "a\n\(PublicCheckTests.homePath)\n"])
        let refusal = await refusal { try await fixture.gate.push(.pushDocs) }
        let message = refusal?.message ?? ""
        XCTAssertTrue(message.contains("\(sha.prefix(8)) docs/a.md:2: home path"), message)
        XCTAssertTrue(message.hasSuffix("\n\nRemove the personal data or CI skip markers and rewrite these unpushed "
                                        + "commits (git reset --soft origin/main, then commit again), then call "
                                        + "forge_push_docs again. If a private term is a false positive, the user "
                                        + "narrows or removes that one term in private-terms.txt."), message)
        XCTAssertEqual(refusal?.guardrailPaths, [])
        try assertUnchanged(fixture)
    }

    func testRefusesPrivateTerm() async throws {
        let fixture = try makeFixture(terms: [PublicCheckTests.privateTerm])
        let sha = try commit(fixture, ["docs/a.md": "a\n\(PublicCheckTests.privateTerm)\n"])
        let refusal = await refusal { try await fixture.gate.push(.pushDocs) }
        let message = refusal?.message ?? ""
        XCTAssertTrue(message.contains("\(sha.prefix(8)) docs/a.md:2: private term"), message)
        XCTAssertNil(message.range(of: PublicCheckTests.privateTerm, options: .caseInsensitive))
        try assertUnchanged(fixture)
    }

    func testRefusesMixing() async throws {
        let code = try makeFixture()
        let codeCommit = try commit(code, ["App/x.swift": "let x = 1\n"])
        let docsRefusal = await refusal { try await code.gate.push(.pushDocs) }
        XCTAssertEqual(docsRefusal?.message, "forge_push_docs pushes documentation only: \(codeCommit.prefix(8)) "
                           + "changes App/x.swift. Keep only docs/ in these commits (git reset --soft origin/main, "
                           + "then commit docs/ alone), then call forge_push_docs again.")
        try assertUnchanged(code)

        let docs = try makeFixture()
        let docsCommit = try commit(docs, ["docs/a.md": "a\nb\n"])
        let regenRefusal = await refusal { try await docs.gate.push(.pushRegen) }
        XCTAssertEqual(regenRefusal?.message, "forge_push_regen never pushes documentation: \(docsCommit.prefix(8)) "
                           + "changes docs/a.md. A regeneration does not edit docs/: take that change out of these "
                           + "commits, then call forge_push_regen again.")
        try assertUnchanged(docs)
    }

    func testRefusesGuardrail() async throws {
        let fixture = try makeFixture()
        try commit(fixture, [".gitignore": "build/\n", "docs/general.md": "# General rules\n",
                             "HephaestusKit/Sources/HephHost/Forge/ForgePushGate.swift": "// The gate.\n"])
        let paths = [".gitignore", "HephaestusKit/Sources/HephHost/Forge/ForgePushGate.swift", "docs/general.md"]
        for tool in [ForgePushGate.Tool.pushDocs, .pushRegen] {
            let refusal = await refusal { try await fixture.gate.push(tool) }
            XCTAssertEqual(refusal?.message, "Changes to the personal-data guardrail are pushed by hand after review: "
                               + "\(paths.joined(separator: ", ")).")
            XCTAssertEqual(refusal?.guardrailPaths, paths)
        }
        try assertUnchanged(fixture)
    }

    func testRefusesCaseVariant() async throws {
        let script = try makeFixture()
        try commitIndexEntry(script, path: "Scripts/check-public.sh", content: "#!/bin/bash\n")
        let scriptRefusal = await refusal { try await script.gate.push(.pushDocs) }
        XCTAssertEqual(scriptRefusal?.message, "Changes to the personal-data guardrail are pushed by hand after "
                           + "review: Scripts/check-public.sh.")
        XCTAssertEqual(scriptRefusal?.guardrailPaths, ["Scripts/check-public.sh"])
        try assertUnchanged(script)

        let docs = try makeFixture()
        let sha = try commitIndexEntry(docs, path: "docs/A.md", content: "A\n")
        let docsRefusal = await refusal { try await docs.gate.push(.pushDocs) }
        XCTAssertEqual(docsRefusal?.message,
                       "\(sha.prefix(8)) adds docs/A.md, which differs only in case from docs/a.md.")
        try assertUnchanged(docs)
    }

    func testRefusesBinary() async throws {
        let binary = try makeFixture()
        try write(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]), to: "docs/shot.png", in: binary.repository)
        try commit(binary, [:])
        let binaryRefusal = await refusal { try await binary.gate.push(.pushDocs) }
        XCTAssertEqual(binaryRefusal?.message,
                       "Changes to the personal-data guardrail are pushed by hand after review: docs/shot.png.")
        XCTAssertEqual(binaryRefusal?.guardrailPaths, ["docs/shot.png"])
        try assertUnchanged(binary)

        let attributes = try makeFixture()
        try commit(attributes, ["docs/.gitattributes": "*.md text\n"])
        let attributesRefusal = await refusal { try await attributes.gate.push(.pushDocs) }
        XCTAssertEqual(attributesRefusal?.message,
                       "Changes to the personal-data guardrail are pushed by hand after review: docs/.gitattributes.")
        XCTAssertEqual(attributesRefusal?.guardrailPaths, ["docs/.gitattributes"])
        try assertUnchanged(attributes)
    }

    func testRefusesBinaryDespiteAttributes() async throws {
        let fixture = try makeFixture()
        try write(Data("* diff\n".utf8), to: ".git/info/attributes", in: fixture.repository)
        try write(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]), to: "docs/shot.png", in: fixture.repository)
        try commit(fixture, [:])
        let refusal = await refusal { try await fixture.gate.push(.pushDocs) }
        XCTAssertEqual(refusal?.message,
                       "Changes to the personal-data guardrail are pushed by hand after review: docs/shot.png.")
        XCTAssertEqual(refusal?.guardrailPaths, ["docs/shot.png"])
        try assertUnchanged(fixture)
    }

    func testRefusesNonASCIIPath() async throws {
        // Compared as UTF-8 bytes: Swift's `==` of `String` holds U+212A KELVIN SIGN equal to `K`.
        let guardrail = "Changes to the personal-data guardrail are pushed by hand after review: "
        let hook = try makeFixture()
        let hookPath = ".githoo" + "\u{212A}" + "s/pre-push"
        try commitIndexEntry(hook, path: hookPath, content: "#!/bin/bash\n",
                             options: ["-c", "core.precomposeUnicode=false"])
        let hookRefusal = await refusal { try await hook.gate.push(.pushDocs) }
        XCTAssertEqual(Array((hookRefusal?.message ?? "").utf8), Array("\(guardrail)\(hookPath).".utf8))
        XCTAssertEqual(hookRefusal?.guardrailPaths.map { Array($0.utf8) }, [Array(hookPath.utf8)])
        try assertUnchanged(hook)

        let docs = try makeFixture()
        let docsPath = "docs/caf" + "\u{00E9}" + ".md"
        try commitIndexEntry(docs, path: docsPath, content: "caf\n")
        let docsRefusal = await refusal { try await docs.gate.push(.pushDocs) }
        XCTAssertEqual(Array((docsRefusal?.message ?? "").utf8), Array("\(guardrail)\(docsPath).".utf8))
        XCTAssertEqual(docsRefusal?.guardrailPaths.map { Array($0.utf8) }, [Array(docsPath.utf8)])
        try assertUnchanged(docs)
    }

    func testOriginMoved() async throws {
        let fixture = try makeFixture()
        let other = try pushFromOtherClone(fixture, ["docs/b.md": "b\n"])
        try commit(fixture, ["docs/a.md": "a\nc\n"])
        let refusal = await refusal { try await fixture.gate.push(.pushDocs) }
        XCTAssertEqual(refusal?.message,
                       "origin/main moved: run git pull --rebase origin main, then call forge_push_docs again.")
        XCTAssertEqual(try originMain(fixture), other)
    }

    func testNothingToPush() async throws {
        let fixture = try makeFixture()
        let refusal = await refusal { try await fixture.gate.push(.pushDocs) }
        XCTAssertEqual(refusal?.message, "Nothing to push: commit your change first.")
        try assertUnchanged(fixture)
    }

    func testMergeRefused() async throws {
        let fixture = try makeFixture()
        let other = try pushFromOtherClone(fixture, ["docs/b.md": "b\n"])
        try commit(fixture, ["docs/a.md": "a\nc\n"])
        try fixture.sandbox.git(["fetch", "-q", "origin"], in: fixture.repository)
        try fixture.sandbox.git(["merge", "-q", "--no-ff", "--no-edit", "origin/main"], in: fixture.repository)
        let refusal = await refusal { try await fixture.gate.push(.pushDocs) }
        XCTAssertEqual(refusal?.message,
                       "Rebase instead of merging: git pull --rebase origin main, then call forge_push_docs again.")
        XCTAssertEqual(try originMain(fixture), other)
    }

    func testMissingScript() async throws {
        let fixture = try makeFixture()
        try fixture.sandbox.git(["rm", "-q", "scripts/check-public.sh"], in: fixture.repository)
        let removed = try commit(fixture, [:])
        try fixture.sandbox.git(["push", "-q", "origin", "main"], in: fixture.repository)
        try commit(fixture, ["docs/a.md": "a\nd\n"])
        let refusal = await refusal { try await fixture.gate.push(.pushDocs) }
        XCTAssertEqual(refusal?.message, "scripts/check-public.sh is missing on origin/main.")
        XCTAssertEqual(try originMain(fixture), removed)
    }

    func testHooksNotRun() async throws {
        let fixture = try makeFixture()
        let sha = try commit(fixture, ["docs/a.md": "a\nb\n"])
        try fixture.sandbox.git(["config", "core.hooksPath", ".githooks"], in: fixture.repository)
        try writeExecutable("#!/bin/bash\nexit 1\n", to: ".githooks/pre-push", in: fixture.repository)
        let pushed = try await fixture.gate.push(.pushDocs)
        XCTAssertEqual(pushed.commit, sha)
        XCTAssertEqual(try originMain(fixture), sha)
    }

    func testCheckRunsNoHook() async throws {
        let fixture = try makeFixture()
        let sha = try commit(fixture, ["docs/a.md": "a\nb\n"])
        try fixture.sandbox.git(["config", "core.hooksPath", ".githooks"], in: fixture.repository)
        let ran = fixture.sandbox.folder.appendingPathComponent("ran", isDirectory: false)
        try writeExecutable("#!/bin/bash\ntouch '\(ran.path)'\n", to: ".githooks/post-index-change",
                            in: fixture.repository)
        let pushed = try await fixture.gate.push(.pushDocs)
        XCTAssertEqual(pushed.commit, sha)
        XCTAssertEqual(try originMain(fixture), sha)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path))
    }

    func testReplaceRefIgnored() async throws {
        let fixture = try makeFixture()
        let sandbox = fixture.sandbox
        let repository = fixture.repository
        try write(Data("x\n".utf8), to: "App/x.swift", in: repository)
        try sandbox.git(["add", "-A"], in: repository)
        try sandbox.git(["commit", "-q", "--no-verify", "-m", "Change"], in: repository)
        let sha = try sandbox.git(["rev-parse", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        // The twin: the same parent, adding docs/r.md instead, built on a temporary index of the sandbox.
        let index = ["GIT_INDEX_FILE": sandbox.folder.appendingPathComponent("index-\(UUID().uuidString)").path]
        try sandbox.git(["read-tree", fixture.pushed], in: repository, environment: index)
        let blob = try hashObject("r\n", in: fixture)
        try sandbox.git(["update-index", "--add", "--cacheinfo", "100644,\(blob),docs/r.md"], in: repository,
                        environment: index)
        let tree = try sandbox.git(["write-tree"], in: repository, environment: index)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let twin = try sandbox.git(["commit-tree", tree, "-p", fixture.pushed, "-m", "Twin"], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try sandbox.git(["replace", sha, twin], in: repository)

        let refusal = await refusal { try await fixture.gate.push(.pushDocs) }
        let message = refusal?.message ?? ""
        XCTAssertTrue(message.hasPrefix("forge_push_docs pushes documentation only: \(sha.prefix(8)) changes "
                                        + "App/x.swift."), message)
        try assertUnchanged(fixture)
    }

    func testChecksCommitsPushedElsewhere() async throws {
        let fixture = try makeFixture()
        try pushFromOtherClone(fixture, ["docs/a.md": "a\n\(PublicCheckTests.homePath)\n"])
        try fixture.sandbox.git(["fetch", "-q", "origin"], in: fixture.repository)
        let head = try originMain(fixture)
        let findings = try await fixture.gate.checkPushedElsewhere(from: fixture.pushed, to: head)
        XCTAssertTrue(findings?.contains("\(head.prefix(8)) docs/a.md:2: home path") == true, findings ?? "nil")

        let clean = try makeFixture()
        try pushFromOtherClone(clean, ["docs/a.md": "a\nb\n"])
        try clean.sandbox.git(["fetch", "-q", "origin"], in: clean.repository)
        let cleanHead = try originMain(clean)
        let none = try await clean.gate.checkPushedElsewhere(from: clean.pushed, to: cleanHead)
        XCTAssertNil(none)
    }

    func testGuardrailPushedElsewhere() async throws {
        let fixture = try makeFixture()
        let head = try pushFromOtherClone(fixture, [
            "scripts/check-public.sh": "#!/bin/bash\necho 'Personal data check: clean.'\nexit 0\n",
        ])
        try fixture.sandbox.git(["fetch", "-q", "origin"], in: fixture.repository)
        let findings = try await fixture.gate.checkPushedElsewhere(from: fixture.pushed, to: head)
        XCTAssertNil(findings)
        let paths = try await fixture.gate.guardrailPaths(from: fixture.pushed, to: head)
        XCTAssertEqual(paths, ["scripts/check-public.sh"])

        try fixture.sandbox.git(["pull", "-q", "--rebase", "origin", "main"], in: fixture.repository)
        let sha = try commit(fixture, ["docs/a.md": "a\n\(PublicCheckTests.homePath)\n"])
        let refusal = await refusal { try await fixture.gate.push(.pushDocs, trustedHead: fixture.pushed) }
        let message = refusal?.message ?? ""
        XCTAssertTrue(message.contains("\(sha.prefix(8)) docs/a.md:2: home path"), message)
        XCTAssertEqual(try originMain(fixture), head)
    }

    func testSkipMarkerPushedElsewhere() async throws {
        let fixture = try makeFixture()
        let first = try pushFromOtherClone(fixture, ["docs/s.md": "s\n"], message: "Fix [skip ci]")
        try fixture.sandbox.git(["fetch", "-q", "origin"], in: fixture.repository)
        let none = try await fixture.gate.checkPushedElsewhere(from: fixture.pushed, to: first)
        XCTAssertNil(none)

        let second = try pushFromOtherClone(fixture, ["docs/t.md": "\(PublicCheckTests.homePath)\n"],
                                            message: "Fix [skip ci]")
        try fixture.sandbox.git(["fetch", "-q", "origin"], in: fixture.repository)
        let findings = try await fixture.gate.checkPushedElsewhere(from: fixture.pushed, to: second)
        XCTAssertTrue(findings?.contains("\(second.prefix(8)) message: ci skip marker") == true, findings ?? "nil")
        XCTAssertTrue(findings?.contains("\(second.prefix(8)) docs/t.md:1: home path") == true, findings ?? "nil")

        try fixture.sandbox.git(["pull", "-q", "--rebase", "origin", "main"], in: fixture.repository)
        let sha = try commit(fixture, ["docs/u.md": "u\n"], message: "Fix [skip ci]")
        let refusal = await refusal { try await fixture.gate.push(.pushDocs, trustedHead: fixture.pushed) }
        let message = refusal?.message ?? ""
        XCTAssertTrue(message.contains("\(sha.prefix(8)) message: ci skip marker"), message)
        XCTAssertEqual(try originMain(fixture), second)
    }

    func testSessionRules() {
        let feedback = Self.feedbackRules.map { $0.replacingOccurrences(of: "<branch>", with: "main") }
        XCTAssertEqual(ForgeSessionRules.allowedTools(regeneration: false, branch: "main"), feedback)
        XCTAssertEqual(ForgeSessionRules.allowedTools(regeneration: true, branch: "main"),
                       feedback + Self.regenerationRules)
        let root = "/Users/user/Hephaestus"
        let denied = Self.deniedRules.map { $0.replacingOccurrences(of: "<repository root>", with: root) }
        XCTAssertEqual(ForgeSessionRules.disallowedTools(repositoryRoot: root), denied)

        let login = [
            "PATH": "/usr/bin:/bin",
            "GIT_AUTHOR_NAME": "Jane Appleseed",
            "EMAIL": "user@example.com",
            "GIT_CONFIG_PARAMETERS": "'core.pager=cat'",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.pager",
            "GIT_CONFIG_VALUE_0": "cat",
            "GH_TOKEN": "<token>",
        ]
        XCTAssertEqual(ForgeSessionRules.environment(login), [
            "PATH": "/usr/bin:/bin",
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "url.hephaestus-no-push://blocked/.pushInsteadOf",
            "GIT_CONFIG_VALUE_0": "",
            "GIT_CONFIG_KEY_1": "core.hooksPath",
            "GIT_CONFIG_VALUE_1": "/dev/null",
            "TZ": "UTC",
        ])
    }

    func testPrivateTermForms() {
        // Compared as UTF-8 bytes: Swift's `==` of `String` holds the precomposed and decomposed forms equal.
        let precomposed = "Quokk" + "\u{00E4}" + "ville"
        let decomposed = "Quokka" + "\u{0308}" + "ville"
        let fromPrecomposed = Self.termLines(PrivateTerms.content(suggestions: [precomposed], owner: "Azavech"))
        for term in [precomposed, decomposed, "Quokkaville"] {
            XCTAssertTrue(fromPrecomposed.contains(Array(term.utf8)), "\(Array(term.utf8))")
        }
        let fromDecomposed = Self.termLines(PrivateTerms.content(suggestions: [decomposed], owner: "Azavech"))
        for term in [decomposed, "Quokkaville", precomposed] {
            XCTAssertTrue(fromDecomposed.contains(Array(term.utf8)), "\(Array(term.utf8))")
        }
    }

    func testPrivateTermsReading() throws {
        let folder = try makeTemporaryDirectory()
        let carriageReturns = folder.appendingPathComponent("cr.txt", isDirectory: false)
        try Data("# h\rQuokkaville\r".utf8).write(to: carriageReturns)
        XCTAssertEqual(PrivateTerms.count(at: carriageReturns), 0)

        let text = "# h\nalpha" + "\u{2028}" + "bravo\n"
        let lineSeparator = folder.appendingPathComponent("line-separator.txt", isDirectory: false)
        try Data(text.utf8).write(to: lineSeparator)
        XCTAssertEqual(PrivateTerms.count(at: lineSeparator), 1)
        XCTAssertEqual(PrivateTerms.pending(["alpha", "bravo"], in: text), ["alpha", "bravo"])
    }

    @MainActor
    func testRegisterClone() async throws {
        let registration = try await makeRegistration()
        try makeClone(registration)
        try await register(registration)
        let projects = try await projectsList(registration.testHost)
        XCTAssertEqual(projects.map(\.id), ["HEPH"])
        XCTAssertEqual(projects.first?.name, "Hephaestus")
        XCTAssertEqual(projects.first?.rootPath, registration.folder.path)
        let file = try ProjectFile.load(projectRoot: registration.folder)
        XCTAssertEqual(file.id, "HEPH")
        XCTAssertEqual(file.name, "Hephaestus")

        try await register(registration)
        let again = try await projectsList(registration.testHost)
        XCTAssertEqual(again, projects)
    }

    @MainActor
    func testRegisterExistingFile() async throws {
        let registration = try await makeRegistration()
        try makeClone(registration)
        try ProjectFile.create(ProjectFile(id: "HEPH", name: "Fixture", description: nil),
                               projectRoot: registration.folder)
        let projectFile = ProjectFile.url(projectRoot: registration.folder)
        let bytes = try Data(contentsOf: projectFile)
        try await register(registration)
        let projects = try await projectsList(registration.testHost)
        XCTAssertEqual(projects.map(\.id), ["HEPH"])
        XCTAssertEqual(projects.first?.name, "Fixture")
        XCTAssertEqual(projects.first?.rootPath, registration.folder.path)
        XCTAssertEqual(try Data(contentsOf: projectFile), bytes)
    }

    @MainActor
    func testRegisterNotAClone() async throws {
        let registration = try await makeRegistration()
        let folder = registration.folder
        let dataFolder = folder.appendingPathComponent(".hephaestus", isDirectory: true)
        let notTopFolder = "\(folder.path) is not the top folder of a git repository: clone "
            + "github.com/Azavech/Hephaestus there, or add your clone with Add Existing Folder… and choose it as the "
            + "Source project in Settings ▸ Forge & Updates."
        let notAClone = "\(folder.path) is not a clone of github.com/Azavech/Hephaestus: set its origin remote to "
            + "https://github.com/Azavech/Hephaestus.git, or add your clone with Add Existing Folder… and choose it as "
            + "the Source project in Settings ▸ Forge & Updates."

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await assertRefused(registration, notTopFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataFolder.path))

        // <folder> inside the repository of the projects folder.
        try registration.sandbox.git(["init", "-b", "main"], in: registration.testHost.projectsFolder)
        try await assertRefused(registration, notTopFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataFolder.path))

        // A repository of its own, without origin, then with the origin of another repository.
        try registration.sandbox.git(["init", "-b", "main"], in: folder)
        try await assertRefused(registration, notAClone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataFolder.path))
        try registration.sandbox.git(["remote", "add", "origin", "https://github.com/Azavech/Atlas.git"], in: folder)
        try await assertRefused(registration, notAClone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataFolder.path))
    }

    @MainActor
    func testRegisterWithoutFolder() async throws {
        let registration = try await makeRegistration()
        let folder = registration.folder
        try await assertRefused(registration, "There is no folder \(folder.path): clone github.com/Azavech/Hephaestus "
                                    + "there, or add your clone with Add Existing Folder… and choose it as the Source "
                                    + "project in Settings ▸ Forge & Updates.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    func testRegisterOtherProject() async throws {
        let registration = try await makeRegistration()
        let folder = registration.folder
        try makeClone(registration)
        try ProjectFile.create(ProjectFile(id: "ATLAS", name: "Atlas", description: nil), projectRoot: folder)
        let projectFile = ProjectFile.url(projectRoot: folder)
        let bytes = try Data(contentsOf: projectFile)
        try await assertRefused(registration, "\(folder.path) holds the project ATLAS: choose it as the Source project "
                                    + "in Settings ▸ Forge & Updates, after adding it with Add Existing Folder… when "
                                    + "it is not on this Mac.")
        XCTAssertEqual(try Data(contentsOf: projectFile), bytes)
    }

    // MARK: - Rules of claude/cli.md 3.5

    /// `--allowedTools` of feedback sessions.
    private static let feedbackRules = [
        "mcp__hephaestus",
        "Bash(git status *)",
        "Bash(git diff *)",
        "Bash(git log *)",
        "Bash(git show *)",
        "Bash(git add *)",
        "Bash(git rm *)",
        "Bash(git commit *)",
        "Bash(git reset --soft origin/<branch>)",
        "Bash(git stash *)",
        "Bash(git fetch origin <branch>)",
        "Bash(git fetch --quiet origin <branch>)",
        "Bash(git pull --rebase origin <branch>)",
        "Bash(git pull --ff-only origin <branch>)",
        "Bash(git rev-parse *)",
        "Bash(git ls-files *)",
        "Bash(git branch *)",
        "Bash(scripts/check-public.sh --staged)",
    ]

    /// The rules regeneration sessions add.
    private static let regenerationRules = [
        "Bash(xcodebuild *)",
        "Bash(swift *)",
        "Bash(scripts/*)",
        "Bash(./scripts/*)",
    ]

    /// `--disallowedTools` of the sessions of 3.5; `<repository root>` is the absolute path of the repository root.
    private static let deniedRules = [
        "Bash(git push *)",
        "Bash(git config *)",
        "Bash(git -c *)",
        "Bash(git remote *)",
        "Bash(git update-ref *)",
        "Bash(git filter-branch *)",
        "Bash(git replace *)",
        "Bash(git notes *)",
        "Bash(git fetch *--upl*)",
        "Bash(git pull *--upl*)",
        "Bash(git diff *--output*)",
        "Bash(git log *--output*)",
        "Bash(git show *--output*)",
        "Bash(git stash *--output*)",
        "Edit(/<repository root>/docs/general.md)",
        "Edit(/<repository root>/docs/public-repository.md)",
        "Edit(/<repository root>/scripts/check-public.sh)",
        "Edit(/<repository root>/.githooks/**)",
        "Edit(/<repository root>/.github/**)",
        "Edit(/<repository root>/.gitignore)",
        "Edit(/<repository root>/CLAUDE.md)",
        "Edit(/<repository root>/HephaestusKit/Sources/HephHost/Forge/ForgePushGate.swift)",
        "Edit(/<repository root>/HephaestusKit/Sources/HephHost/Forge/ForgeGit.swift)",
        "Edit(/<repository root>/HephaestusKit/Sources/HephHost/Forge/ForgeChecks.swift)",
        "Edit(/<repository root>/HephaestusKit/Sources/HephHost/Forge/PrivateTerms.swift)",
        "Edit(/<repository root>/HephaestusKit/Sources/HephHost/Claude/ForgeSessionRules.swift)",
        "Edit(/<repository root>/HephaestusKit/Sources/HephHost/Claude/ForgePrompts.swift)",
        "Edit(/<repository root>/HephaestusKit/Sources/HephHost/MCP/MCPToolKinds.swift)",
        "Edit(/<repository root>/HephaestusKit/Tests/HephHostTests/PublicCheckTests.swift)",
        "Edit(/<repository root>/HephaestusKit/Tests/HephHostTests/ForgePushTests.swift)",
        "Edit(.claude/**)",
        "Edit(.mcp.json)",
        "Edit(**/.hephaestus/**)",
    ]

    // MARK: - Helpers

    /// The sandbox (its folder removed at teardown, its `terms` set), a repository from `makeRepository()` with a
    /// second commit adding `docs/a.md` = `a\n` and `App/DocsHash.txt` = the docs hash of that tree, its origin, and
    /// the gate on that repository with the sandbox's environment.
    private func makeFixture(terms: [String] = []) throws -> Fixture {
        let sandbox = try GitSandbox()
        let folder = sandbox.folder
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        sandbox.terms = terms
        let repository = try sandbox.makeRepository()
        try write(Data("a\n".utf8), to: "docs/a.md", in: repository)
        let docsHash = try DocsHash.compute(repositoryRoot: repository)
        try write(Data((docsHash + "\n").utf8), to: "App/DocsHash.txt", in: repository)
        try sandbox.git(["add", "-A"], in: repository)
        try sandbox.git(["commit", "-q", "-m", "Docs"], in: repository)
        let origin = try sandbox.makeOrigin(of: repository)
        let pushed = try sandbox.git(["rev-parse", "HEAD"], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gate = ForgePushGate(git: ForgeGit(executable: "/usr/bin/git", repositoryRoot: repository,
                                               environment: sandbox.environment),
                                 branch: "main", termsFile: sandbox.termsFile)
        return Fixture(sandbox: sandbox, repository: repository, origin: origin, pushed: pushed, gate: gate)
    }

    /// Writes the files, then `git add -A` and a commit with `message`; its full SHA.
    @discardableResult
    private func commit(_ fixture: Fixture, _ files: [String: String], message: String = "Change") throws -> String {
        try commit(fixture.sandbox, fixture.repository, files, message: message)
    }

    @discardableResult
    private func commit(_ sandbox: GitSandbox, _ repository: URL, _ files: [String: String],
                        message: String = "Change") throws -> String {
        for (path, text) in files {
            try write(Data(text.utf8), to: path, in: repository)
        }
        try sandbox.git(["add", "-A"], in: repository)
        try sandbox.git(["commit", "-q", "-m", message], in: repository)
        return try sandbox.git(["rev-parse", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A commit adding `path` with `git <options> update-index --add --cacheinfo`, for a path that differs only in case
    /// from one of the working tree (the disk of a Mac holds only one of them) or whose bytes the disk would change;
    /// its full SHA.
    @discardableResult
    private func commitIndexEntry(_ fixture: Fixture, path: String, content: String,
                                  options: [String] = []) throws -> String {
        let blob = try hashObject(content, in: fixture)
        try fixture.sandbox.git(options + ["update-index", "--add", "--cacheinfo", "100644,\(blob),\(path)"],
                                in: fixture.repository)
        try fixture.sandbox.git(["commit", "-q", "-m", "Change"], in: fixture.repository)
        return try fixture.sandbox.git(["rev-parse", "HEAD"], in: fixture.repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `git hash-object -w` of a file holding `content`: the blob's full SHA.
    private func hashObject(_ content: String, in fixture: Fixture) throws -> String {
        let file = fixture.sandbox.folder.appendingPathComponent("blob-\(UUID().uuidString)", isDirectory: false)
        try Data(content.utf8).write(to: file)
        return try fixture.sandbox.git(["hash-object", "-w", file.path], in: fixture.repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The term lines of a private terms file's content, as UTF-8 bytes: its lines (split at line feeds) that are not
    /// empty and do not start with `#`.
    private static func termLines(_ content: String) -> [[UInt8]] {
        Array(content.utf8).split(separator: 0x0A).map(Array.init).filter { $0.first != UInt8(ascii: "#") }
    }

    /// Another clone of origin commits the files with `message` and pushes them with `--no-verify`; origin's new
    /// `main`.
    @discardableResult
    private func pushFromOtherClone(_ fixture: Fixture, _ files: [String: String],
                                    message: String = "Change") throws -> String {
        let other = fixture.sandbox.folder.appendingPathComponent("other-\(UUID().uuidString)", isDirectory: true)
        try fixture.sandbox.git(["clone", "-q", fixture.origin.path, other.path], in: fixture.sandbox.folder)
        try commit(fixture.sandbox, other, files, message: message)
        try fixture.sandbox.git(["push", "-q", "--no-verify", "origin", "main"], in: other)
        return try originMain(fixture)
    }

    private func write(_ data: Data, to path: String, in repository: URL) throws {
        let url = repository.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func writeExecutable(_ text: String, to path: String, in repository: URL) throws {
        try write(Data(text.utf8), to: path, in: repository)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: repository.appendingPathComponent(path).path)
    }

    /// Origin's `main`.
    private func originMain(_ fixture: Fixture) throws -> String {
        try fixture.sandbox.git(["rev-parse", "main"], in: fixture.origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Origin's `main` is still the commit `makeOrigin` pushed.
    private func assertUnchanged(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try originMain(fixture), fixture.pushed, file: file, line: line)
    }

    /// The Refusal `body` throws; nil (and a failure) when it throws something else or nothing.
    private func refusal<T>(_ body: () async throws -> T, file: StaticString = #filePath,
                            line: UInt = #line) async -> ForgePushGate.Refusal? {
        do {
            _ = try await body()
            XCTFail("Expected a refusal", file: file, line: line)
        } catch let refusal as ForgePushGate.Refusal {
            return refusal
        } catch {
            XCTFail("Expected a refusal, got \(error)", file: file, line: line)
        }
        return nil
    }

    // MARK: - Registering the source project

    /// A sandbox (its folder removed at teardown), a TestHost from `startTestHost()`, whose Forge is never enabled,
    /// and `<folder>`, which does not exist yet.
    @MainActor
    private func makeRegistration() async throws -> Registration {
        let sandbox = try GitSandbox()
        let sandboxFolder = sandbox.folder
        addTeardownBlock {
            try? FileManager.default.removeItem(at: sandboxFolder)
        }
        let testHost = try await startTestHost()
        return Registration(sandbox: sandbox, testHost: testHost,
                            folder: testHost.projectsFolder.appendingPathComponent("Hephaestus", isDirectory: true))
    }

    /// A clone: `<folder>` created, then `git init -b main` and the origin `https://github.com/Azavech/Hephaestus.git`,
    /// which contact nothing.
    @MainActor
    private func makeClone(_ registration: Registration) throws {
        try FileManager.default.createDirectory(at: registration.folder, withIntermediateDirectories: true)
        try registration.sandbox.git(["init", "-b", "main"], in: registration.folder)
        try registration.sandbox.git(["remote", "add", "origin", "https://github.com/Azavech/Hephaestus.git"],
                                     in: registration.folder)
    }

    /// `registerSourceProject(_:environment:)` of the TestHost's Forge, its git commands run with the sandbox's
    /// environment.
    @MainActor
    private func register(_ registration: Registration) async throws {
        try await registration.testHost.host.forge.registerSourceProject(Self.sourceConfig,
                                                                         environment: registration.sandbox.environment)
    }

    /// The registration throws `unavailable` "The Forge source project HEPH is not on this Main. <text>", and nothing
    /// is registered.
    @MainActor
    private func assertRefused(_ registration: Registration, _ text: String, file: StaticString = #filePath,
                               line: UInt = #line) async throws {
        await assertProtocolError(.unavailable, "The Forge source project HEPH is not on this Main. \(text)",
                                  file: file, line: line) {
            try await self.register(registration)
        }
        let projects = try await projectsList(registration.testHost)
        XCTAssertEqual(projects, [], file: file, line: line)
    }

    /// `projects.list` of the TestHost (`TestHost.perform`).
    @MainActor
    private func projectsList(_ testHost: TestHost) async throws -> [ProjectSummary] {
        try await testHost.perform(.projectsList, EmptyPayload(), as: ProjectsListResult.self).projects
    }
}
#endif
