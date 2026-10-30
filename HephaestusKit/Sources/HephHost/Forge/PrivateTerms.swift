#if os(macOS)
import Foundation
import HephCore
import IOKit
import SystemConfiguration

/// Private terms (docs/forge/pipeline.md, "Private terms"): the pre-filled `private-terms.txt`, the suggestions and the
/// count of the terms the personal data check reads from it.
enum PrivateTerms {
    /// The header comment of a new file.
    static let header = """
        # Private terms of the Hephaestus personal-data check (docs/public-repository.md).
        # The check refuses every file, file name, commit message, commit author and branch name of the public repository
        # that holds one of these terms as a whole word, ignoring case. One term per line; lines starting with # are
        # comments; terms shorter than 3 characters are ignored; a line "# not private: <term>" dismisses a suggestion.
        # Hephaestus never sends this file anywhere; you copy it to the PRIVATE_TERMS secret and to your other Macs yourself.
        # Hephaestus suggested the terms below from this Mac's account, names and serial number, the mesh's devices, the
        # other projects of this Mac, git, the signing identities and their teams, and the GitHub logins. Remove a term that
        # is not private; add the names of your people and places, and of your other projects.
        """

    /// The prefix of a line that dismisses a suggestion.
    static let dismissedPrefix = "# not private: "

    /// Never suggested, compared case-insensitively (with the owner of `forge.repository` and the terms shorter than
    /// 3 characters): the app's names, the placeholders of docs/general.md and their words, the default and model
    /// names of devices.
    static let neverSuggested: [String] = [
        "Hephaestus", "HEPH",
        "Jane Appleseed", "Jane", "Appleseed", "user", "/Users/user", "user@example.com", "Sam's iPad",
        "Sam's MacBook Pro", "Studio", "Sams-Mac-mini.local", "Sams-Mac-mini", "ABCDE12345", "Atlas", "API", "Fixture",
        "Mac", "Mac mini", "MacBook", "MacBook Air", "MacBook Pro", "iMac", "Mac Studio", "Mac Pro", "iPad", "iPad Air",
        "iPad Pro", "iPad mini", "iPhone",
    ]

    /// The header and the suggested terms, without the excluded ones (Private terms): one per line, in the order of
    /// the sources, each term once.
    static func content(suggestions: [String], owner: String) -> String {
        ([header] + terms(suggestions: suggestions, owner: owner)).joined(separator: "\n") + "\n"
    }

    /// The terms the Forge suggests from the values of the sources: trimmed, without the excluded ones, each once
    /// (compared by their UTF-8 bytes with ASCII letters lowercased, the first spelling kept), a term holding the
    /// typographic apostrophe followed by the same with `'`, and a term holding a letter outside ASCII followed by its
    /// precomposed, decomposed, lowercase, uppercase and diacritic-free forms, each when its UTF-8 bytes differ from
    /// the term's. Swift's `==` and `Hashable` of `String` treat canonically equivalent strings as equal, so these
    /// comparisons use the bytes.
    static func terms(suggestions: [String], owner: String) -> [String] {
        let excluded = Set((neverSuggested + [owner]).map { $0.lowercased() })
        var seen = Set<[UInt8]>()
        var terms: [String] = []
        func add(_ term: String) {
            guard characterCount(term) >= 3, !excluded.contains(term.lowercased()),
                  seen.insert(comparisonKey(term)).inserted
            else { return }
            terms.append(term)
        }
        for suggestion in suggestions {
            let term = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            for spelling in [term] + apostropheVariant(of: term) {
                add(spelling)
                guard spelling.contains(where: { $0.isLetter && !$0.isASCII }) else { continue }
                for variant in [spelling.precomposedStringWithCanonicalMapping,
                                spelling.decomposedStringWithCanonicalMapping, spelling.lowercased(),
                                spelling.uppercased(), spelling.folding(options: .diacriticInsensitive, locale: nil)]
                    where !variant.utf8.elementsEqual(spelling.utf8) {
                    add(variant)
                }
            }
        }
        return terms
    }

    /// Runs the sources of Private terms, in order; `devices`: the registry's records; `projects`: the other projects
    /// of this Main, without the source project and its sub projects. The commands run with the login environment and
    /// the home folder as working directory; `git` and `gh` are nil when unavailable.
    static func suggestions(devices: [DeviceRecord], projects: [HostedProject], environment: [String: String],
                            git: String?, gh: String?) async -> [String] {
        var terms: [String] = []
        func add(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            terms.append(value)
        }

        // The full name, then each of its words (separated by white space, - or ') of 3 letters or more.
        let fullName = NSFullUserName()
        add(fullName)
        for word in fullName.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "'" }) where word.count >= 3 {
            add(String(word))
        }
        // The account name and the home folder.
        add(NSUserName())
        add(NSHomeDirectory())
        // The computer name; the local host name, then the same followed by .local.
        add(SCDynamicStoreCopyComputerName(nil, nil) as String?)
        if let localHostName = (SCDynamicStoreCopyLocalHostName(nil) as String?)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !localHostName.isEmpty {
            add(localHostName)
            add(localHostName + ".local")
        }
        // The Mac's serial number.
        add(serialNumber())
        // The mesh's devices: each name, then each address ending with .local, followed by the same without .local.
        for device in devices {
            add(device.name)
            for address in device.addresses where address.hasSuffix(".local") {
                add(address)
                add(String(address.dropLast(".local".count)))
            }
        }
        // The other projects of this Main: name, identifier and the last component of the root folder.
        for project in projects {
            add(project.file.name)
            add(project.id)
            add(project.root.lastPathComponent)
        }
        let home = NSHomeDirectory()
        // The names of git's global identity, never its e-mails: every commit publishes them, and as terms they would
        // refuse the user's own commits. git runs as in Git operations, with `GIT_NO_REPLACE_OBJECTS=1` added to its
        // environment.
        if let git {
            var gitEnvironment = environment
            gitEnvironment["GIT_NO_REPLACE_OBJECTS"] = "1"
            for key in ["user.name", "author.name", "committer.name"] {
                add(await capture(git, ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "config",
                                        "--global", "--get", key],
                                  environment: gitEnvironment, home: home, timeout: .seconds(10)))
            }
        }
        // The code signing identities `<kind>: <holder> (<id>)`: the holder, the id, then the team IDs of the
        // identity's certificate.
        if let identities = await capture("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"],
                                          environment: environment, home: home, timeout: .seconds(30)) {
            for line in identities.split(whereSeparator: \.isNewline) {
                guard let identity = identityParts(String(line)) else { continue }
                add(identity.holder)
                add(identity.id)
                for team in await teamIDs(identityName: identity.name, environment: environment, home: home) {
                    add(team)
                }
            }
        }
        // The login of every account of every host gh is signed in to.
        if let gh, let status = await capture(gh, ["auth", "status", "--json", "hosts"], environment: environment,
                                              home: home, timeout: .seconds(10)) {
            for login in logins(inAuthStatus: Data(status.utf8)) {
                add(login)
            }
        }
        return terms
    }

    /// The suggestions that `content` holds neither as a term nor in a "# not private: <term>" line, its lines read as
    /// the check reads them (`lines(of:)`, the `<term>` trimmed the same way), compared by their UTF-8 bytes with the
    /// case of ASCII letters only ignored, in their order.
    static func pending(_ suggestions: [String], in content: String) -> [String] {
        var known = Set<[UInt8]>()
        for line in lines(of: content) {
            if line.starts(with: dismissedPrefix.utf8) {
                known.insert(comparisonKey(trimmed(line.dropFirst(dismissedPrefix.utf8.count))))
            } else if isTerm(line) {
                known.insert(comparisonKey(line))
            }
        }
        return suggestions.filter { !known.contains(comparisonKey($0)) }
    }

    /// `content` with `line` added at its end, after a line feed when its last byte is not one.
    static func appending(_ line: String, to content: String) -> String {
        if content.isEmpty || content.utf8.last == 0x0A {
            return content + line + "\n"
        }
        return content + "\n" + line + "\n"
    }

    /// The number of terms the check reads from the file at `url` (`lines(of:)`): the lines that are then not empty,
    /// do not start with `#` and have 3 characters or more; 0 when it is missing, unreadable or not UTF-8.
    static func count(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url), let text = utf8Text(data) else { return 0 }
        return lines(of: text).filter(isTerm).count
    }

    /// The text of a file's bytes when they are UTF-8, every byte kept (a byte order mark included); nil when they are
    /// not UTF-8.
    static func utf8Text(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        return text.utf8.elementsEqual(data) ? text : nil
    }

    // MARK: - Helpers

    /// The characters of a term as the check counts them: its Unicode scalars (UTF-8 bytes that are not continuation
    /// bytes).
    private static func characterCount(_ term: String) -> Int {
        term.unicodeScalars.count
    }

    /// The lines of a terms file as the check reads them: its UTF-8 bytes split at each line feed (LF) only, never at a
    /// CR, U+2028 or another line break; each line without a leading byte order mark (EF BB BF), then without the ASCII
    /// white space at both ends (`trimmed(_:)`).
    private static func lines(of text: String) -> [ArraySlice<UInt8>] {
        Array(text.utf8).split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
            trimmed(line.starts(with: [0xEF, 0xBB, 0xBF]) ? line.dropFirst(3) : line)
        }
    }

    /// `bytes` without the ASCII white space at both ends: space, tab, LF, vertical tab, form feed and CR, the
    /// `[:space:]` of `LC_ALL=C`; never another white space such as U+00A0.
    private static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || (0x09...0x0D).contains(byte)
        }
        guard let first = bytes.firstIndex(where: { !isSpace($0) }),
              let last = bytes.lastIndex(where: { !isSpace($0) })
        else { return [] }
        return bytes[first...last]
    }

    /// A line of the file, read with `lines(of:)`, that is a term: not empty, not starting with `#`, of 3 characters
    /// (Unicode scalars: UTF-8 bytes that are not continuation bytes) or more.
    private static func isTerm(_ line: ArraySlice<UInt8>) -> Bool {
        guard let first = line.first, first != UInt8(ascii: "#") else { return false }
        return line.filter { !(0x80...0xBF).contains($0) }.count >= 3
    }

    /// The key two terms are compared by: their UTF-8 bytes, ASCII letters in lowercase (the check matches case only
    /// for ASCII letters and compares bytes, so the case forms of a letter outside ASCII, and the precomposed and
    /// decomposed forms of a term, are different terms).
    private static func comparisonKey(_ term: String) -> [UInt8] {
        comparisonKey(term.utf8)
    }

    private static func comparisonKey<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> [UInt8] {
        bytes.map(\.asciiLowercased)
    }

    /// The same term with `'` in place of the typographic apostrophe, when it holds one.
    private static func apostropheVariant(of term: String) -> [String] {
        term.contains("\u{2019}") ? [term.replacingOccurrences(of: "\u{2019}", with: "'")] : []
    }

    /// The `IOPlatformSerialNumber` property of the `IOPlatformExpertDevice` service; nil when it is unavailable.
    private static func serialNumber() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString,
                                                       kCFAllocatorDefault, 0)
        return property?.takeRetainedValue() as? String
    }

    /// The team IDs of a signing identity: each `OU=` value of the subject of its certificate, printed by
    /// `openssl x509 -noout -subject -nameopt sep_multiline` from the output of `security find-certificate -a -c
    /// <identity name> -p`.
    private static func teamIDs(identityName: String, environment: [String: String], home: String) async -> [String] {
        guard let pem = await captureData("/usr/bin/security", ["find-certificate", "-a", "-c", identityName, "-p"],
                                          input: nil, environment: environment, home: home, timeout: .seconds(30)),
              let subject = await capture("/usr/bin/openssl", ["x509", "-noout", "-subject", "-nameopt",
                                                                "sep_multiline"],
                                          input: pem, environment: environment, home: home, timeout: .seconds(30))
        else { return [] }
        return subject.split(whereSeparator: \.isNewline).compactMap { line in
            let field = line.trimmingCharacters(in: .whitespaces)
            guard field.hasPrefix("OU=") else { return nil }
            return String(field.dropFirst("OU=".count))
        }
    }

    /// The quoted name, the holder and the id of a line of `security find-identity`, whose quoted name has the form
    /// `<kind>: <holder> (<id>)`; nil for other lines.
    static func identityParts(_ line: String) -> (name: String, holder: String, id: String)? {
        guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else {
            return nil
        }
        let name = line[line.index(after: open)..<close]
        guard let colon = name.range(of: ": "), name.hasSuffix(")"),
              let parenthesis = name.range(of: " (", options: .backwards), colon.upperBound <= parenthesis.lowerBound
        else { return nil }
        let holder = String(name[colon.upperBound..<parenthesis.lowerBound])
        let id = String(name[parenthesis.upperBound..<name.index(before: name.endIndex)])
        guard !holder.isEmpty, !id.isEmpty else { return nil }
        return (String(name), holder, id)
    }

    /// The `login` of every account of every host of `gh auth status --json hosts`
    /// (`{"hosts": {"<host>": [{"login": …}, …]}}`).
    static func logins(inAuthStatus data: Data) -> [String] {
        struct Status: Decodable {
            struct Account: Decodable {
                var login: String?
            }

            var hosts: [String: [Account]]
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return [] }
        return status.hosts.keys.sorted().flatMap { host in
            (status.hosts[host] ?? []).compactMap(\.login)
        }
    }

    /// The trimmed standard output of a command that exits with status 0; nil otherwise.
    private static func capture(_ executable: String, _ arguments: [String], input: Data? = nil,
                                environment: [String: String], home: String, timeout: Duration) async -> String? {
        guard let data = await captureData(executable, arguments, input: input, environment: environment, home: home,
                                           timeout: timeout)
        else { return nil }
        let text = ForgeGit.text(data)
        return text.isEmpty ? nil : text
    }

    /// The standard output of a command that exits with status 0; nil otherwise.
    private static func captureData(_ executable: String, _ arguments: [String], input: Data?,
                                    environment: [String: String], home: String, timeout: Duration) async -> Data? {
        let configuration = ChildProcessConfiguration(executable: executable, arguments: arguments,
                                                      workingDirectory: home, environment: environment)
        guard let output = try? await ChildProcess.capture(configuration, input: input, timeout: timeout),
              !output.timedOut, output.termination == .exited(0)
        else { return nil }
        return output.standardOutput
    }
}

private extension UInt8 {
    /// The ASCII lowercase form of an ASCII letter; the byte itself otherwise.
    var asciiLowercased: UInt8 {
        (65...90).contains(self) ? self + 32 : self
    }
}

extension ForgeService {
    /// Private terms: appSupport.root + "private-terms.txt".
    public nonisolated var privateTermsURL: URL {
        host.appSupport.root.appendingPathComponent("private-terms.txt", isDirectory: false)
    }

    /// Private terms: the number of terms the check reads from the file; 0 when it is missing or unreadable.
    public nonisolated func privateTermsCount() -> Int {
        PrivateTerms.count(at: privateTermsURL)
    }

    /// Private terms: writes the pre-filled file when it is missing, never rewriting it; returns privateTermsURL.
    /// Called at enabling, by the push tools and by Settings "Edit…" (AppModel.editPrivateTerms, ui/shell.md).
    public func preparePrivateTerms() async throws -> URL {
        let url = privateTermsURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        let (suggestions, owner) = await suggestedTermSources()
        let content = PrivateTerms.content(suggestions: suggestions, owner: owner)
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        try AtomicFile.write(Data(content.utf8), to: url)
        Log.host.notice("Wrote private-terms.txt with suggested terms")
        return url
    }

    /// Private terms: the pending suggestions, in source order; [] when the file is missing or unreadable.
    public func privateTermSuggestions() async -> [String] {
        guard let content = readPrivateTerms() else { return [] }
        let (suggestions, owner) = await suggestedTermSources()
        return PrivateTerms.pending(PrivateTerms.terms(suggestions: suggestions, owner: owner), in: content)
    }

    /// Private terms: adds the term as a line of the file (Settings "Add"). Writes nothing and throws when the file
    /// is missing or cannot be read (the read error) or is not UTF-8 text
    /// (DataError.unreadable("private-terms.txt: the file is not UTF-8 text")).
    public func addPrivateTerm(_ term: String) async throws {
        try appendPrivateTermsLine(term)
    }

    /// Private terms: adds the line "# not private: <term>" to the file (Settings "Dismiss"); throws as addPrivateTerm.
    public func dismissPrivateTerm(_ term: String) async throws {
        try appendPrivateTermsLine(PrivateTerms.dismissedPrefix + term)
    }

    /// The text of private-terms.txt; nil when it is missing, unreadable or not UTF-8 text.
    private func readPrivateTerms() -> String? {
        guard let data = try? Data(contentsOf: privateTermsURL) else { return nil }
        return PrivateTerms.utf8Text(data)
    }

    /// Writes the whole file with `AtomicFile.write`, `line` added at its end, every other byte kept. Writes nothing
    /// and throws when the file is missing or cannot be read (the read error) or is not UTF-8 text.
    private func appendPrivateTermsLine(_ line: String) throws {
        let data = try Data(contentsOf: privateTermsURL)
        guard let content = PrivateTerms.utf8Text(data) else {
            throw DataError.unreadable("private-terms.txt: the file is not UTF-8 text")
        }
        try AtomicFile.write(Data(PrivateTerms.appending(line, to: content).utf8), to: privateTermsURL)
    }

    /// The values of the sources of Private terms and the owner of `forge.repository`.
    private func suggestedTermSources() async -> (suggestions: [String], owner: String) {
        let environment = await LoginEnvironment.shared.environment()
        let gitAvailable = await host.hostInfo.gitAvailable
        let git = gitAvailable ? ForgeGit.locate("git", environment: environment) : nil
        let gh = ForgeGit.locate("gh", environment: environment)
        let devices = await host.mesh.snapshot().devices
        let settings = await host.settings().forge
        let repository = configuration?.repository ?? settings.repository
        let sourceProjectID = configuration?.sourceProjectID ?? settings.sourceProjectID
        let excluded = Set([sourceProjectID] + (await host.registry.descendants(of: sourceProjectID)))
        let projects = await host.registry.all().filter { !excluded.contains($0.id) }
        let suggestions = await PrivateTerms.suggestions(devices: devices, projects: projects,
                                                         environment: environment, git: git, gh: gh)
        let owner = String(repository.split(separator: "/").first ?? "")
        return (suggestions, owner)
    }
}
#endif
