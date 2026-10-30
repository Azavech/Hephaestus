#if os(macOS)
import Foundation
import XCTest
@testable import HephHost

/// The personal data check (docs/public-repository.md): the repository's own `scripts/check-public.sh` and
/// `.githooks/`, run by a GitSandbox on repositories made with `makeRepository()` (docs/testing.md,
/// "PublicCheckTests").
final class PublicCheckTests: XCTestCase {
    // MARK: - Planted values

    // The fictional values the cases plant, assembled at run time from pieces so that no line of this file matches a
    // rule of the check. ForgePushTests plants the same values.
    static let homePath = "/Us" + "ers/" + "jdoe"
    static let encodedHomePath = "-Us" + "ers-" + "jdoe-x"
    static let emailAddress = "jdoe" + "@" + "corp.test"
    static let signingIdentity = "Apple Development: " + "John Doe (" + "QWERTY" + "1234)"
    static let teamID = "DEVELOPMENT_TEAM = " + "QWERTY" + "1234"
    static let secret = "gh" + "p_" + String(repeating: "a", count: 36)
    static let privateKey = "-----BEGIN " + "RSA PRIVATE KEY-----"
    static let lanAddress = "10.0." + "0.7"
    static let hiddenCharacter = "Zor" + "\u{200B}" + "bulon"
    static let privateTerm = "Zor" + "bulon"
    static let generatedValue = "Hx4Kp9" + "Wm2Qz7Rt5Vn8"
    /// A /32 and a /31, which are addresses, not networks.
    static let hostAddress32 = "192.168." + "1.20/32"
    static let hostAddress31 = "10.0." + "0.4/31"
    static let invisibleCharacters = ["\u{AD}", "\u{202E}", "\u{2066}", "\u{E0041}", "\u{3164}"]

    /// The text rules, in the order of public-repository.md, each with its planted value.
    static let textRules: [(rule: String, value: String)] = [
        ("home path", homePath),
        ("encoded home path", encodedHomePath),
        ("e-mail address", emailAddress),
        ("signing identity", signingIdentity),
        ("team id", teamID),
        ("secret", secret),
        ("private key", privateKey),
        ("lan address", lanAddress),
        ("hidden character", hiddenCharacter),
        ("private term", privateTerm),
    ]

    /// Every planted value, each with a name for the failure messages of testNothingLeaks.
    static let plantedValues: [(name: String, value: String)] = textRules.map { (name: $0.rule, value: $0.value) }
        + [("generated value", generatedValue), ("host address /32", hostAddress32),
           ("host address /31", hostAddress31)]
        + invisibleCharacters.map { (name: "invisible character \(codePoint($0))", value: $0) }

    /// Every placeholder of docs/general.md, and addresses of the ranges it gives.
    private static let placeholders = """
        Jane Appleseed
        user, /Users/user, -Users-user-…
        user@example.com, user@example.org, user@example.net
        Sam's iPad, Sam's MacBook Pro, Studio
        Sams-Mac-mini.local
        192.0.2.x, 198.51.100.x, 203.0.113.x, 127.0.0.1
        192.0.2.10, 198.51.100.10, 203.0.113.10
        xx:xx:xx:xx:xx:xx
        Apple Development: Jane Appleseed (ABCDE12345), team ABCDE12345
        Atlas, API, Fixture, /Users/user/…
        <token>, <base64 key>

        """

    private static let noTermsNote = "Note: no private terms file; private terms were not checked."

    /// A check script that prints `Personal data check: clean.` whatever it is given.
    private static let cleanScript = "#!/bin/bash\necho 'Personal data check: clean.'\n"

    /// The sandboxes of the cases run by this test, whose outputs testNothingLeaks reads.
    private var sandboxes: [GitSandbox] = []

    // MARK: - Cases

    func testCleanTree() throws {
        try cleanTree()
    }

    func testTextRules() throws {
        try textRules()
    }

    func testStructuralRules() throws {
        try structuralRules()
    }

    func testMessage() throws {
        try message()
    }

    func testStaged() throws {
        try staged()
    }

    func testCommitsRange() throws {
        try commitsRange()
    }

    func testCommitsNewBranch() throws {
        try commitsNewBranch()
    }

    func testCommitIdentity() throws {
        try commitIdentity()
    }

    func testTermInCommitEmail() throws {
        try termInCommitEmail()
    }

    func testTermAfterEscape() throws {
        try termAfterEscape()
    }

    func testCommitSignature() throws {
        try commitSignature()
    }

    func testCommitHeader() throws {
        try commitHeader()
    }

    func testCISkipMarker() throws {
        try ciSkipMarker()
    }

    func testCaseCollision() throws {
        try caseCollision()
    }

    func testPrivateTermMasked() throws {
        try privateTermMasked()
    }

    func testAttributesIgnored() throws {
        try attributesIgnored()
    }

    func testHooks() throws {
        try hooks()
    }

    func testReplaceRefs() throws {
        try replaceRefs()
    }

    func testSecretUnquoted() throws {
        try secretUnquoted()
    }

    func testInvisibleCharacters() throws {
        try invisibleCharacterFiles()
    }

    func testHostPrefixes() throws {
        try hostPrefixes()
    }

    func testPrePushRefs() throws {
        try prePushRefs()
    }

    func testPrePushStaleRef() throws {
        try prePushStaleRef()
    }

    func testPrePushReplacedBase() throws {
        try prePushReplacedBase()
    }

    func testExitCodes() throws {
        try exitCodes()
    }

    /// Every case above runs again; the standard output and error of every process they ran hold none of the planted
    /// values and never the planted term in any letter case.
    func testNothingLeaks() throws {
        let cases: [() throws -> Void] = [
            cleanTree, textRules, structuralRules, message, staged, commitsRange, commitsNewBranch, commitIdentity,
            termInCommitEmail, termAfterEscape, commitSignature, commitHeader, ciSkipMarker, caseCollision,
            privateTermMasked, attributesIgnored, hooks, replaceRefs, secretUnquoted, invisibleCharacterFiles,
            hostPrefixes, prePushRefs, prePushStaleRef, prePushReplacedBase, exitCodes,
        ]
        for run in cases {
            try run()
        }
        let outputs = sandboxes.flatMap(\.outputs)
        XCTAssertFalse(outputs.isEmpty)
        for output in outputs {
            // Compared as UTF-8 bytes: an invisible character can join the character before it in a Character.
            let bytes = Data(output.utf8)
            for planted in Self.plantedValues {
                XCTAssertNil(bytes.range(of: Data(planted.value.utf8)), "An output holds the planted \(planted.name)")
            }
            XCTAssertNil(output.range(of: Self.privateTerm, options: .caseInsensitive), "An output holds the term")
        }
    }

    // MARK: - Case bodies

    private func cleanTree() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        try write(Self.placeholders, to: "docs/a.md", in: repository)
        try commit(sandbox, repository, "Placeholders")
        let result = try sandbox.check(["--tree", "HEAD"], in: repository)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(lines(result.output), [Self.noTermsNote, "Personal data check: clean."])
    }

    private func textRules() throws {
        let sandbox = try makeSandbox()
        sandbox.terms = [Self.privateTerm]
        let repository = try sandbox.makeRepository()
        for (index, planted) in Self.textRules.enumerated() {
            try write("Case \(index + 1)\n\(planted.value)\n", to: "docs/\(index + 1).md", in: repository)
        }
        try commit(sandbox, repository, "Planted values")
        let result = try sandbox.check(["--tree", "HEAD"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        let expected = Self.textRules.enumerated().map { "docs/\($0.offset + 1).md:2: \($0.element.rule)" }
        XCTAssertEqual(lines(result.output), expected + ["Personal data check: 10 finding(s)."])
    }

    private func structuralRules() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        try write("name: Fixture\n", to: ".hephaestus/project.yml", in: repository)
        try sandbox.git(["add", "-f", ".hephaestus/project.yml"], in: repository)
        try write("*.md text\n", to: ".gitattributes", in: repository)
        try FileManager.default.createSymbolicLink(atPath: repository.appendingPathComponent("link").path,
                                                   withDestinationPath: "target.md")
        try write(Data([0x61, 0x00, 0x62]), to: "data.bin", in: repository)
        try sandbox.git(["add", ".gitattributes", "link", "data.bin"], in: repository)
        let sha = try head(sandbox, repository)
        try sandbox.git(["update-index", "--add", "--cacheinfo", "160000,\(sha),lib"], in: repository)
        let result = try sandbox.check(["--staged"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        let found = findings(result.output)
        for line in [".hephaestus/project.yml: forbidden path", ".gitattributes: forbidden path", "link: symbolic link",
                     "lib: submodule", "data.bin: binary file"] {
            XCTAssertTrue(found.contains(line), "\(line) is not among \(found)")
        }

        // The same bytes as a PNG file of the app icon are allowed; elsewhere they are a binary file.
        let icons = try sandbox.makeRepository()
        try write(Data([0x61, 0x00, 0x62]), to: "App/Assets.xcassets/AppIcon.appiconset/icon-test.png", in: icons)
        try sandbox.git(["add", "-A"], in: icons)
        let icon = try sandbox.check(["--staged"], in: icons)
        XCTAssertEqual(icon.status, 0, icon.output)
        XCTAssertEqual(findings(icon.output), [])
        try write(Data([0x61, 0x00, 0x62]), to: "App/Assets.xcassets/photo.png", in: icons)
        try sandbox.git(["add", "-A"], in: icons)
        let photo = try sandbox.check(["--staged"], in: icons)
        XCTAssertEqual(photo.status, 1, photo.output)
        XCTAssertEqual(findings(photo.output), ["App/Assets.xcassets/photo.png: binary file"])
    }

    private func message() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        let file = sandbox.folder.appendingPathComponent("message.txt", isDirectory: false)
        try Data("\(Self.emailAddress)\n# \(Self.homePath)\n".utf8).write(to: file)
        // An edited message: its comment line is not checked.
        let result = try sandbox.check(["--message", file.path], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(lines(result.output),
                       [Self.noTermsNote, "message: e-mail address", "Personal data check: 1 finding(s)."])

        // A message git does not edit (GIT_EDITOR is ":"): every line is checked.
        let unedited = try sandbox.check(["--message", file.path], in: repository, environment: ["GIT_EDITOR": ":"])
        XCTAssertEqual(unedited.status, 1, unedited.output)
        XCTAssertEqual(findings(unedited.output), ["message: home path", "message: e-mail address"])
        XCTAssertEqual(lines(unedited.output).last, "Personal data check: 2 finding(s).")

        // Only the exact scissors line ends a message: followed by " x", it is a comment line.
        let scissors = sandbox.folder.appendingPathComponent("scissors.txt", isDirectory: false)
        try Data("Fix\n# ------------------------ >8 ------------------------ x\n\(Self.homePath)\n".utf8)
            .write(to: scissors)
        let notEnded = try sandbox.check(["--message", scissors.path], in: repository)
        XCTAssertEqual(notEnded.status, 1, notEnded.output)
        XCTAssertEqual(findings(notEnded.output), ["message: home path"])
    }

    private func staged() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        try write("\(Self.homePath)\n", to: "docs/b.md", in: repository)
        try sandbox.git(["add", "docs/b.md"], in: repository)
        let result = try sandbox.check(["--staged"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(findings(result.output), ["docs/b.md:1: home path"])
        try sandbox.git(["rm", "-q", "--cached", "docs/b.md"], in: repository)
        let after = try sandbox.check(["--staged"], in: repository)
        XCTAssertEqual(after.status, 0, after.output)
    }

    private func commitsRange() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        try write("clean\n", to: "docs/a.md", in: repository)
        let first = try commit(sandbox, repository, "A")
        try write("\(Self.lanAddress)\n", to: "docs/c.md", in: repository)
        let second = try commit(sandbox, repository, "B")
        let result = try sandbox.check(["--commits", "\(first)..\(second)"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(findings(result.output), ["\(second.prefix(8)) docs/c.md:1: lan address"])
        let empty = try sandbox.check(["--commits", "\(second)..\(second)"], in: repository)
        XCTAssertEqual(empty.status, 0, empty.output)
    }

    private func commitsNewBranch() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        // A finding already on origin's main: it is not checked again.
        try write("\(Self.lanAddress)\n", to: "docs/main.md", in: repository)
        try commit(sandbox, repository, "Main")
        _ = try sandbox.makeOrigin(of: repository)
        try sandbox.git(["checkout", "-q", "-b", "topic"], in: repository)
        try write("\(Self.secret)\n", to: "docs/topic.md", in: repository)
        let topic = try commit(sandbox, repository, "Topic")
        let result = try sandbox.check(["--commits", "topic", "--not", "--remotes=origin"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(findings(result.output), ["\(topic.prefix(8)) docs/topic.md:1: secret"])
    }

    /// The e-mails of a commit are checked against the private terms only: an address that is not a GitHub no-reply
    /// address passes.
    private func commitIdentity() throws {
        let sandbox = try makeSandbox()
        sandbox.terms = [Self.privateTerm]
        let repository = try sandbox.makeRepository()
        let email = Self.emailAddress
        try write("identity\n", to: "docs/i.md", in: repository)
        let sha = try commit(sandbox, repository, "Identity",
                             environment: ["GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_EMAIL": email])
        let result = try sandbox.check(["--commits", "\(sha)~1..\(sha)"], in: repository)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(lines(result.output), ["Personal data check: clean."])
    }

    private func termInCommitEmail() throws {
        let sandbox = try makeSandbox()
        sandbox.terms = [Self.privateTerm]
        let repository = try sandbox.makeRepository()
        let email = Self.privateTerm + "@" + "corp.test"
        try write("identity\n", to: "docs/i.md", in: repository)
        let sha = try commit(sandbox, repository, "Identity",
                             environment: ["GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_EMAIL": email])
        let result = try sandbox.check(["--commits", "\(sha)~1..\(sha)"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(lines(result.output), ["\(sha.prefix(8)) author: private term",
                                              "\(sha.prefix(8)) committer: private term",
                                              "Personal data check: 2 finding(s)."])
    }

    private func termAfterEscape() throws {
        let sandbox = try makeSandbox()
        sandbox.terms = [Self.privateTerm]
        let repository = try sandbox.makeRepository()
        try write("Hello\\n" + Self.privateTerm + "\n" + "%2F" + Self.privateTerm + "%2F\n", to: "docs/escaped.md",
                  in: repository)
        try write("Hello\\n" + Self.privateTerm + "ish\n" + "%2F" + Self.privateTerm + "ish%2F\n", to: "docs/ish.md",
                  in: repository)
        try commit(sandbox, repository, "Escapes")
        let result = try sandbox.check(["--tree", "HEAD"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(lines(result.output), ["docs/escaped.md:1: private term", "docs/escaped.md:2: private term",
                                              "Personal data check: 2 finding(s)."])
    }

    private func commitSignature() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        let parent = try head(sandbox, repository)
        let tree = try head(sandbox, repository, "HEAD^{tree}")
        let identity = "fixture <1+fixture@users.noreply.github.com> 1700000000 +0000"
        let object = "tree \(tree)\nparent \(parent)\nauthor \(identity)\ncommitter \(identity)\n"
            + "gpgsig -----BEGIN PGP SIGNATURE-----\n \n fictional signature\n -----END PGP SIGNATURE-----\n"
            + "\nSigned commit\n"
        let file = sandbox.folder.appendingPathComponent("commit-object.txt", isDirectory: false)
        try Data(object.utf8).write(to: file)
        let sha = try sandbox.git(["hash-object", "-t", "commit", "-w", file.path], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try sandbox.check(["--commits", "\(parent)..\(sha)"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(findings(result.output), ["\(sha.prefix(8)) signature: commit signature"])
    }

    /// The text rules read every other header of a commit, its continuation lines included.
    private func commitHeader() throws {
        let sandbox = try makeSandbox()
        sandbox.terms = [Self.privateTerm]
        let repository = try sandbox.makeRepository()
        let parent = try head(sandbox, repository)
        let noted = try commitObject(headers: "x-note \(Self.emailAddress)\n \(Self.privateTerm)\n", sandbox,
                                     repository)
        let result = try sandbox.check(["--commits", "\(parent)..\(noted)"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(lines(result.output), ["\(noted.prefix(8)) header: e-mail address",
                                              "\(noted.prefix(8)) header: private term",
                                              "Personal data check: 2 finding(s)."])
        let encoded = try commitObject(headers: "encoding UTF-8\n", sandbox, repository)
        let clean = try sandbox.check(["--commits", "\(parent)..\(encoded)"], in: repository)
        XCTAssertEqual(clean.status, 0, clean.output)
    }

    /// The markers that make GitHub skip CI, in any letter case, in a commit message and never in a file.
    private func ciSkipMarker() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        let file = sandbox.folder.appendingPathComponent("message.txt", isDirectory: false)
        let markers = ["[skip ci]", "[ci skip]", "[no ci]", "[skip actions]", "[actions skip]", "skip-checks:true",
                       "skip-checks: true"]
        for marker in markers + markers.map({ $0.uppercased() }) {
            try Data("Fix\n\(marker)\n".utf8).write(to: file)
            let result = try sandbox.check(["--message", file.path], in: repository)
            XCTAssertEqual(result.status, 1, marker)
            XCTAssertEqual(lines(result.output),
                           [Self.noTermsNote, "message: ci skip marker", "Personal data check: 1 finding(s)."], marker)
        }
        try Data("Explain skip ci and skip-checks\n".utf8).write(to: file)
        let words = try sandbox.check(["--message", file.path], in: repository)
        XCTAssertEqual(words.status, 0, words.output)

        try write("n\n", to: "docs/n.md", in: repository)
        let bracketed = try commit(sandbox, repository, "Fix [No CI]")
        try write("k\n", to: "docs/k.md", in: repository)
        try sandbox.git(["add", "-A"], in: repository)
        try sandbox.git(["commit", "-q", "--cleanup=verbatim", "-m", "Fix\n\n\nSkip-Checks: TRUE"], in: repository)
        let trailer = try head(sandbox, repository)
        for sha in [bracketed, trailer] {
            let result = try sandbox.check(["--commits", "\(sha)~1..\(sha)"], in: repository)
            XCTAssertEqual(result.status, 1, result.output)
            XCTAssertEqual(findings(result.output), ["\(sha.prefix(8)) message: ci skip marker"])
        }

        try write("[skip ci]\nskip-checks: true\n", to: "docs/s.md", in: repository)
        let notes = try commit(sandbox, repository, "Add notes")
        let inFile = try sandbox.check(["--commits", "\(notes)~1..\(notes)"], in: repository)
        XCTAssertEqual(inFile.status, 0, inFile.output)
    }

    private func caseCollision() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        try write("a\n", to: "docs/a.md", in: repository)
        try commit(sandbox, repository, "Docs")
        let hook = try blob("#!/bin/bash\n", sandbox, repository)
        let notes = try blob("notes\n", sandbox, repository)
        try sandbox.git(["update-index", "--add", "--cacheinfo", "100644,\(hook),.GITHOOKS/pre-commit"], in: repository)
        try sandbox.git(["update-index", "--add", "--cacheinfo", "100644,\(notes),Docs/notes.md"], in: repository)
        try sandbox.git(["commit", "-q", "-m", "Case variants"], in: repository)
        let sha = try head(sandbox, repository)
        let result = try sandbox.check(["--commits", "\(sha)~1..\(sha)"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(findings(result.output), ["\(sha.prefix(8)) .GITHOOKS/pre-commit: case collision",
                                                 "\(sha.prefix(8)) Docs/notes.md: case collision"])

        let tree = try sandbox.check(["--tree", "HEAD"], in: repository)
        XCTAssertEqual(tree.status, 1, tree.output)
        let found = findings(tree.output)
        let paths = lines(try sandbox.git(["ls-tree", "-r", "--name-only", "HEAD"], in: repository))
        let colliding = paths.filter { path in
            [".githooks/", ".GITHOOKS/", "docs/", "Docs/"].contains { path.hasPrefix($0) }
        }
        XCTAssertEqual(colliding.count, 6)
        for path in colliding {
            XCTAssertTrue(found.contains("\(path): case collision"), "\(path) is not reported")
        }
        XCTAssertFalse(found.contains("scripts/check-public.sh: case collision"))

        // A file and a folder whose names differ only in case, staged.
        try sandbox.git(["update-index", "--add", "--cacheinfo", "100644,\(notes),Notes"], in: repository)
        try sandbox.git(["update-index", "--add", "--cacheinfo", "100644,\(notes),notes/a.md"], in: repository)
        let staged = try sandbox.check(["--staged"], in: repository)
        XCTAssertEqual(staged.status, 1, staged.output)
        XCTAssertEqual(findings(staged.output), ["Notes: case collision", "notes/a.md: case collision"])
    }

    private func privateTermMasked() throws {
        let sandbox = try makeSandbox()
        sandbox.terms = [Self.privateTerm]
        let repository = try sandbox.makeRepository()
        try write("notes\n", to: "docs/\(Self.privateTerm)-notes.md", in: repository)
        try commit(sandbox, repository, "Notes")
        let result = try sandbox.check(["--tree", "HEAD"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(findings(result.output), ["docs/***-notes.md: private term"])
        let ref = try sandbox.check(["--ref", "refs/heads/\(Self.privateTerm)-topic"], in: repository)
        XCTAssertEqual(ref.status, 1, ref.output)
        XCTAssertEqual(findings(ref.output), ["ref refs/heads/***-topic: private term"])
    }

    private func attributesIgnored() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        // Were they read, these attributes would make docs/blob.dat text and the icon binary.
        let attributes = "*.dat diff\n*.png -diff\n"
        let infoAttributes = ".git/info/attributes"
        try write(attributes, to: infoAttributes, in: repository)
        let icon = "App/Assets.xcassets/AppIcon.appiconset/icon-mac-16@1x.png"
        try write(Data("data\0\u{1}".utf8), to: "docs/blob.dat", in: repository)
        try write("\(Self.emailAddress)\n", to: icon, in: repository)
        try sandbox.git(["add", "docs/blob.dat", icon], in: repository)
        let expected = ["docs/blob.dat: binary file", "\(icon):1: e-mail address"].sorted()
        let staged = try sandbox.check(["--staged"], in: repository)
        XCTAssertEqual(staged.status, 1, staged.output)
        XCTAssertEqual(findings(staged.output).sorted(), expected)

        // Without .git/info/attributes: the same lines in the file of core.attributesFile, given through
        // GIT_CONFIG_COUNT, then in a tree given as GIT_ATTR_SOURCE.
        try FileManager.default.removeItem(at: repository.appendingPathComponent(infoAttributes, isDirectory: false))
        let attributesFile = sandbox.folder.appendingPathComponent("attributes", isDirectory: false)
        try Data(attributes.utf8).write(to: attributesFile)
        let configured = try sandbox.check(["--staged"], in: repository, environment: [
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.attributesFile",
            "GIT_CONFIG_VALUE_0": attributesFile.path,
        ])
        XCTAssertEqual(configured.status, 1, configured.output)
        XCTAssertEqual(findings(configured.output).sorted(), expected)
        let attributesBlob = try sandbox.git(["hash-object", "-w", attributesFile.path], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = sandbox.folder.appendingPathComponent("attributes-tree.txt", isDirectory: false)
        try Data("100644 blob \(attributesBlob)\t.gitattributes\n".utf8).write(to: entries)
        // git mktree reads its entries on its standard input, which the sandbox's processes do not get: a shell alias
        // gives it the file.
        let attributesTree = try sandbox.git(["-c", "alias.mktree-from=!f() { git mktree < \"$1\"; }; f",
                                              "mktree-from", entries.path], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = try sandbox.check(["--staged"], in: repository, environment: ["GIT_ATTR_SOURCE": attributesTree])
        XCTAssertEqual(source.status, 1, source.output)
        XCTAssertEqual(findings(source.output).sorted(), expected)

        // Committed, with .git/info/attributes back.
        try sandbox.git(["commit", "-q", "--no-verify", "-m", "Attributes"], in: repository)
        try write(attributes, to: infoAttributes, in: repository)
        let sha = try head(sandbox, repository)
        let commits = try sandbox.check(["--commits", "HEAD^..HEAD"], in: repository)
        XCTAssertEqual(commits.status, 1, commits.output)
        XCTAssertEqual(findings(commits.output).sorted(), expected.map { "\(sha.prefix(8)) \($0)" })
        let tree = try sandbox.check(["--tree", "HEAD"], in: repository)
        XCTAssertEqual(tree.status, 1, tree.output)
        XCTAssertEqual(findings(tree.output).sorted(), expected)
    }

    private func hooks() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        try sandbox.git(["config", "core.hooksPath", ".githooks"], in: repository)
        let initial = try head(sandbox, repository)

        // pre-commit: a staged home path.
        try write("\(Self.homePath)\n", to: "docs/h.md", in: repository)
        try sandbox.git(["add", "docs/h.md"], in: repository)
        XCTAssertThrowsError(try sandbox.git(["commit", "-q", "-m", "Home"], in: repository))
        XCTAssertEqual(try head(sandbox, repository), initial)

        // commit-msg: an e-mail address in the message.
        try write("clean\n", to: "docs/h.md", in: repository)
        try sandbox.git(["add", "docs/h.md"], in: repository)
        XCTAssertThrowsError(try sandbox.git(["commit", "-q", "-m", Self.emailAddress], in: repository))
        XCTAssertEqual(try head(sandbox, repository), initial)

        // pre-push: a commit made with --no-verify that holds a team id.
        let origin = try sandbox.makeOrigin(of: repository)
        try write("\(Self.teamID)\n", to: "docs/t.md", in: repository)
        try sandbox.git(["add", "-A"], in: repository)
        try sandbox.git(["commit", "-q", "--no-verify", "-m", "Team"], in: repository)
        XCTAssertThrowsError(try sandbox.git(["push", "-q", "origin", "main"], in: repository))
        XCTAssertEqual(try head(sandbox, origin, "main"), initial)

        // pre-push: every tag is refused.
        try sandbox.git(["tag", "v1"], in: repository)
        XCTAssertThrowsError(try sandbox.git(["push", "-q", "origin", "v1"], in: repository))
        XCTAssertTrue(lastOutputs(sandbox).contains("Tags are created only by CI releases."))

        // pre-push: a commit that replaces the check is also judged by the remote's check.
        try sandbox.git(["reset", "-q", "--hard", initial], in: repository)
        try write(Self.cleanScript, to: "scripts/check-public.sh", in: repository)
        try write("\(Self.emailAddress)\n", to: "docs/m.md", in: repository)
        try sandbox.git(["add", "-A"], in: repository)
        try sandbox.git(["commit", "-q", "--no-verify", "-m", "Replace the check"], in: repository)
        let replaced = try head(sandbox, repository)
        XCTAssertThrowsError(try sandbox.git(["push", "-q", "origin", "main"], in: repository))
        XCTAssertTrue(lastOutputs(sandbox).contains("\(replaced.prefix(8)) docs/m.md:1: e-mail address"))
        XCTAssertEqual(try head(sandbox, origin, "main"), initial)
    }

    /// A replace ref (`git replace`) changes neither what the check reads nor what the pre-push hook judges.
    private func replaceRefs() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        let origin = try sandbox.makeOrigin(of: repository)
        let pushed = try head(sandbox, repository)
        try sandbox.git(["config", "core.hooksPath", ".githooks"], in: repository)
        try write("\(Self.homePath)\n", to: "docs/r.md", in: repository)
        let planted = try commit(sandbox, repository, "D", noVerify: true)
        let parent = try head(sandbox, repository, "\(planted)^")
        let replacement = try twin(of: planted, path: "docs/r.md", content: "r\n", message: "D", sandbox, repository)
        try sandbox.git(["replace", planted, replacement], in: repository)

        let commits = try sandbox.check(["--commits", "\(parent)..\(planted)"], in: repository)
        XCTAssertEqual(commits.status, 1, commits.output)
        XCTAssertEqual(findings(commits.output), ["\(planted.prefix(8)) docs/r.md:1: home path"])
        let tree = try sandbox.check(["--tree", planted], in: repository)
        XCTAssertEqual(tree.status, 1, tree.output)
        XCTAssertEqual(findings(tree.output), ["docs/r.md:1: home path"])
        XCTAssertThrowsError(try sandbox.git(["push", "-q", "origin", "main"], in: repository))
        XCTAssertEqual(try head(sandbox, origin, "main"), pushed)
    }

    /// Values given unquoted to a secret's name.
    private func secretUnquoted() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        try write("PASS" + "WORD=" + Self.generatedValue, to: "s/env.txt", in: repository)
        try write("api_" + "key: " + Self.generatedValue, to: "s/yaml.txt", in: repository)
        try write("mesh" + "Key=" + Self.generatedValue + " # x", to: "s/comment.txt", in: repository)
        try write("x(\"TO" + "KEN=" + Self.generatedValue + "\")", to: "s/string.txt", in: repository)
        let code = ["let token = makeToken(seed: 42)", "meshKey: credentials.meshKey,", "token: abcdefghijklmnopqrstu"]
        try write(code.joined(separator: "\n") + "\n", to: "s/code.swift", in: repository)
        try sandbox.git(["add", "-A"], in: repository)
        let result = try sandbox.check(["--staged"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        let found = findings(result.output)
        XCTAssertEqual(found.sorted(), ["s/env.txt:1: secret", "s/yaml.txt:1: secret", "s/comment.txt:1: secret",
                                        "s/string.txt:1: secret"].sorted())
        XCTAssertFalse(found.contains { $0.hasPrefix("s/code.swift") }, "\(found)")
    }

    /// Each invisible character splitting a word; an emoji's variation selector is not one.
    private func invisibleCharacterFiles() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        var expected: [String] = []
        for character in Self.invisibleCharacters {
            let path = "h/\(Self.codePoint(character)).txt"
            try write("Zor" + character + "bulon", to: path, in: repository)
            expected.append("\(path):1: hidden character")
        }
        try write("\u{26A0}\u{FE0F}", to: "h/emoji.txt", in: repository)
        try sandbox.git(["add", "-A"], in: repository)
        let result = try sandbox.check(["--staged"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        let found = findings(result.output)
        XCTAssertEqual(found.sorted(), expected.sorted())
        XCTAssertFalse(found.contains { $0.hasPrefix("h/emoji.txt") }, "\(found)")
    }

    /// A /31 and a /32 are addresses; a /30 whose host bits are zero is a network.
    private func hostPrefixes() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        try write(Self.hostAddress32, to: "n/32.txt", in: repository)
        try write(Self.hostAddress31, to: "n/31.txt", in: repository)
        try write("10.0." + "0.0/30", to: "n/30.txt", in: repository)
        try sandbox.git(["add", "-A"], in: repository)
        let result = try sandbox.check(["--staged"], in: repository)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertEqual(findings(result.output), ["n/31.txt:1: lan address", "n/32.txt:1: lan address"])
    }

    /// The pre-push hook pushes only commits, only to branches.
    private func prePushRefs() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        let origin = try sandbox.makeOrigin(of: repository)
        try sandbox.git(["config", "core.hooksPath", ".githooks"], in: repository)

        try sandbox.git(["tag", "-a", "v1", "-m", "Release"], in: repository)
        XCTAssertThrowsError(try sandbox.git(["push", "-q", "origin", "v1:refs/custom/x"], in: repository))
        XCTAssertTrue(lines(lastOutputs(sandbox)).contains("Only branches are pushed: refs/heads/<name>."),
                      lastOutputs(sandbox))

        let object = try blob("blob\n", sandbox, repository)
        XCTAssertThrowsError(try sandbox.git(["push", "-q", "origin", "\(object):refs/heads/x"], in: repository))
        XCTAssertTrue(lines(lastOutputs(sandbox)).contains("Only commits are pushed."), lastOutputs(sandbox))

        let refs = try refNames(sandbox, origin)
        XCTAssertFalse(refs.contains("refs/custom/x"), "\(refs)")
        XCTAssertFalse(refs.contains("refs/heads/x"), "\(refs)")
    }

    /// A remote-tracking ref left by a branch deleted on the remote does not exclude the commits it holds.
    private func prePushStaleRef() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        let origin = try sandbox.makeOrigin(of: repository)
        try sandbox.git(["config", "core.hooksPath", ".githooks"], in: repository)
        try sandbox.git(["checkout", "-q", "-b", "wip"], in: repository)
        try write("\(Self.homePath)\n", to: "docs/w.md", in: repository)
        let wip = try commit(sandbox, repository, "Work in progress", noVerify: true)
        try sandbox.git(["push", "-q", "--no-verify", "origin", "wip"], in: repository)

        let second = sandbox.folder.appendingPathComponent("second-clone", isDirectory: true)
        try sandbox.git(["clone", "-q", origin.path, second.path], in: sandbox.folder)
        try sandbox.git(["config", "core.hooksPath", ".githooks"], in: second)
        try sandbox.git(["push", "-q", "--no-verify", "origin", ":wip"], in: repository)
        try sandbox.git(["fetch", "-q", "origin"], in: second)
        XCTAssertEqual(try head(sandbox, second, "refs/remotes/origin/wip"), wip)

        try sandbox.git(["checkout", "-q", "-b", "feature", "origin/wip"], in: second)
        try write("feature\n", to: "docs/f.md", in: second)
        try commit(sandbox, second, "Feature")
        XCTAssertThrowsError(try sandbox.git(["push", "-q", "origin", "feature"], in: second))
        XCTAssertTrue(lines(lastOutputs(sandbox)).contains("\(wip.prefix(8)) docs/w.md:1: home path"),
                      lastOutputs(sandbox))
        let refs = try refNames(sandbox, origin)
        XCTAssertFalse(refs.contains("refs/heads/feature"), "\(refs)")
    }

    /// A replace ref cannot choose the remote's check that the pre-push hook runs.
    private func prePushReplacedBase() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        let origin = try sandbox.makeOrigin(of: repository)
        let pushed = try head(sandbox, repository)
        try sandbox.git(["config", "core.hooksPath", ".githooks"], in: repository)
        let replacement = try twin(of: pushed, path: "scripts/check-public.sh", content: Self.cleanScript,
                                   mode: "100755", message: "initial", sandbox, repository)
        try sandbox.git(["replace", pushed, replacement], in: repository)

        try write(Self.cleanScript, to: "scripts/check-public.sh", in: repository)
        try write("\(Self.emailAddress)\n", to: "docs/m.md", in: repository)
        let replaced = try commit(sandbox, repository, "Replace the check", noVerify: true)
        XCTAssertThrowsError(try sandbox.git(["push", "-q", "origin", "main"], in: repository))
        XCTAssertTrue(lines(lastOutputs(sandbox)).contains("\(replaced.prefix(8)) docs/m.md:1: e-mail address"),
                      lastOutputs(sandbox))
        XCTAssertEqual(try head(sandbox, origin, "main"), pushed)
    }

    private func exitCodes() throws {
        let sandbox = try makeSandbox()
        let repository = try sandbox.makeRepository()
        let outside = sandbox.folder.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        var results = [
            try sandbox.check([], in: repository),
            try sandbox.check(["--unknown"], in: repository),
            try sandbox.check(["--tree", "no-such-revision"], in: repository),
            try sandbox.check(["--tree", "HEAD"], in: outside),
        ]
        sandbox.terms = [Self.privateTerm]
        try FileManager.default.removeItem(at: sandbox.termsFile)
        results.append(try sandbox.check(["--tree", "HEAD"], in: repository))
        for result in results {
            XCTAssertEqual(result.status, 2, result.output)
            let errors = lines(result.error)
            XCTAssertEqual(errors.count, 1, result.error)
            XCTAssertTrue(errors.first?.hasPrefix("check-public.sh: ") == true, result.error)
        }
    }

    // MARK: - Helpers

    /// A GitSandbox whose folder is removed at teardown.
    private func makeSandbox() throws -> GitSandbox {
        let sandbox = try GitSandbox()
        sandboxes.append(sandbox)
        let folder = sandbox.folder
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        return sandbox
    }

    /// Writes `text` to `path` of the repository, creating its folders.
    private func write(_ text: String, to path: String, in repository: URL) throws {
        try write(Data(text.utf8), to: path, in: repository)
    }

    private func write(_ data: Data, to path: String, in repository: URL) throws {
        let url = repository.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// `git add -A`, then a commit with the sandbox's environment (`changes` applied), with `--no-verify` when asked;
    /// its full SHA.
    @discardableResult
    private func commit(_ sandbox: GitSandbox, _ repository: URL, _ message: String,
                        environment changes: [String: String] = [:], noVerify: Bool = false) throws -> String {
        try sandbox.git(["add", "-A"], in: repository)
        try sandbox.git(["commit", "-q"] + (noVerify ? ["--no-verify"] : []) + ["-m", message], in: repository,
                        environment: changes)
        return try head(sandbox, repository)
    }

    /// The full SHA of a revision.
    private func head(_ sandbox: GitSandbox, _ repository: URL, _ revision: String = "HEAD") throws -> String {
        try sandbox.git(["rev-parse", revision], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes `content` to a new file of the sandbox and stores it as a blob of the repository; the blob's SHA.
    private func blob(_ content: String, _ sandbox: GitSandbox, _ repository: URL) throws -> String {
        let file = sandbox.folder.appendingPathComponent("blob-\(UUID().uuidString)", isDirectory: false)
        try Data(content.utf8).write(to: file)
        return try sandbox.git(["hash-object", "-w", file.path], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A twin of `commit`: a commit with its parents whose tree is its tree with `path` holding `content`, made with
    /// `git read-tree`, `git update-index --cacheinfo` and `git write-tree` on a temporary index of the sandbox, then
    /// `git commit-tree`; its full SHA.
    private func twin(of commit: String, path: String, content: String, mode: String = "100644", message: String,
                      _ sandbox: GitSandbox, _ repository: URL) throws -> String {
        let index = ["GIT_INDEX_FILE": sandbox.folder.appendingPathComponent("index-\(UUID().uuidString)",
                                                                             isDirectory: false).path]
        try sandbox.git(["read-tree", commit], in: repository, environment: index)
        let object = try blob(content, sandbox, repository)
        try sandbox.git(["update-index", "--cacheinfo", "\(mode),\(object),\(path)"], in: repository,
                        environment: index)
        let tree = try sandbox.git(["write-tree"], in: repository, environment: index)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parents = try sandbox.git(["show", "-s", "--format=%P", commit], in: repository)
            .split(whereSeparator: \.isWhitespace)
        return try sandbox.git(["commit-tree", tree] + parents.flatMap { ["-p", String($0)] } + ["-m", message],
                               in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A commit object whose parent is HEAD and whose tree is HEAD's, made with the fixture identity, holding `headers`
    /// after `committer`, written with `git hash-object -t commit -w`; its full SHA.
    private func commitObject(headers: String, _ sandbox: GitSandbox, _ repository: URL) throws -> String {
        let parent = try head(sandbox, repository)
        let tree = try head(sandbox, repository, "HEAD^{tree}")
        let identity = "fixture <1+fixture@users.noreply.github.com> 1700000000 +0000"
        let object = "tree \(tree)\nparent \(parent)\nauthor \(identity)\ncommitter \(identity)\n\(headers)\nHeaders\n"
        let file = sandbox.folder.appendingPathComponent("commit-\(UUID().uuidString).txt", isDirectory: false)
        try Data(object.utf8).write(to: file)
        return try sandbox.git(["hash-object", "-t", "commit", "-w", file.path], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The names of the refs of a repository.
    private func refNames(_ sandbox: GitSandbox, _ repository: URL) throws -> [String] {
        lines(try sandbox.git(["for-each-ref", "--format=%(refname)"], in: repository))
    }

    /// The code point of a one-scalar string, in uppercase hex (`AD`, `202E`).
    private static func codePoint(_ character: String) -> String {
        character.unicodeScalars.map { String($0.value, radix: 16, uppercase: true) }.joined(separator: "+")
    }

    /// The standard output and error of the last process the sandbox ran (a hook writes to git's standard output).
    private func lastOutputs(_ sandbox: GitSandbox) -> String {
        sandbox.outputs.suffix(2).joined(separator: "\n")
    }

    /// The non-empty lines of an output.
    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    /// The finding lines of an output: without the note and the summary line.
    private func findings(_ text: String) -> [String] {
        lines(text).filter { !$0.hasPrefix("Note: ") && !$0.hasPrefix("Personal data check: ") }
    }
}
#endif
