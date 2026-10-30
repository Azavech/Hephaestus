#if os(macOS)
import Foundation
import XCTest
@testable import HephClient
@testable import HephCore
@testable import HephHost
@testable import HephNet

/// The mesh credentials of the tests: mesh id 00000000-0000-4000-8000-000000000100, a key of 32 bytes 0x01.
let testCredentials = MeshCredentials(meshID: UUID(uuidString: "00000000-0000-4000-8000-000000000100")!,
                                      meshKey: Data(repeating: 0x01, count: 32))

/// The repository root: four levels above this file (HephaestusKit/Tests/HephHostTests/HostTestSupport.swift).
let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// The error thrown by the helpers of this file.
struct TestSupportError: Error, CustomStringConvertible {
    let description: String
}

/// The non-empty lines of `Fixtures/<name>.jsonl`.
func fixtureLines(_ name: String) throws -> [String] {
    guard let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures") else {
        throw TestSupportError(description: "No fixture \(name).jsonl")
    }
    return try String(contentsOf: url, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

extension XCTestCase {
    /// A new folder under the temporary directory, with a UUID in its name, removed at teardown.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephHostTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// A started TestHost, stopped and removed at teardown.
    @MainActor
    func startTestHost(prepare: (TestHost.Folders) throws -> Void = { _ in },
                       beforeStart: (DeviceIdentityStore) throws -> Void = { _ in }) async throws -> TestHost {
        let testHost = try await TestHost.start(prepare: prepare, beforeStart: beforeStart)
        addTeardownBlock { @MainActor in
            await testHost.stop()
            testHost.removeFolders()
        }
        return testHost
    }
}

/// The error thrown by `waitUntil` when the condition does not hold in time.
struct WaitTimedOut: Error {}

/// Waits until `condition` holds, polling every 10 ms; fails the test and throws after `timeout`.
func waitUntil(timeout: Duration = .seconds(5), _ condition: () async throws -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("The condition did not hold within \(timeout).", file: file, line: line)
            throw WaitTimedOut()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Asserts that `body` throws a ProtocolError with `code` (and `message` when given).
func assertProtocolError<T>(_ code: ProtocolError.Code, _ message: String? = nil,
                            file: StaticString = #filePath, line: UInt = #line,
                            _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("Expected the error \(code.rawValue)", file: file, line: line)
    } catch let error as ProtocolError {
        XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        if let message {
            XCTAssertEqual(error.message, message, file: file, line: line)
        }
    } catch {
        XCTFail("Expected a ProtocolError, got \(error)", file: file, line: line)
    }
}

/// Runs a HostService the way the host tests need it (docs/testing.md, "Support files"): Application Support,
/// projects and Trash in temporary folders, the test credentials, a listener on 127.0.0.1 port 0, no Bonjour.
@MainActor
final class TestHost {
    /// What `prepare` gets: the three folders and this Main's device id, before the host starts.
    struct Folders {
        let appSupport: URL
        let projectsFolder: URL
        let trashFolder: URL
        let deviceID: UUID
    }

    let host: HostService
    let identity: DeviceIdentityStore
    /// `boundListenerPort()`, read after `start()`.
    let port: Int
    let appSupport: AppSupport
    let projectsFolder: URL
    let trashFolder: URL
    let settings: SettingsStore
    /// A RequestContext of another device (a new id, `isMain` false), for `host.perform` as a remote would call;
    /// in process (no connection id), so it counts as a Main for the callers rule.
    let deviceContext: RequestContext
    /// `RequestContext.local(device: <the host's device>, author: "Claude")`, as the MCP tools call.
    let claudeContext: RequestContext
    /// The folder that holds the three folders, removed at teardown.
    private let baseFolder: URL

    private init(host: HostService, identity: DeviceIdentityStore, port: Int, appSupport: AppSupport,
                 projectsFolder: URL, trashFolder: URL, settings: SettingsStore, deviceContext: RequestContext,
                 claudeContext: RequestContext, baseFolder: URL) {
        self.host = host
        self.identity = identity
        self.port = port
        self.appSupport = appSupport
        self.projectsFolder = projectsFolder
        self.trashFolder = trashFolder
        self.settings = settings
        self.deviceContext = deviceContext
        self.claudeContext = claudeContext
        self.baseFolder = baseFolder
    }

    /// Creates the folders, the settings (`isMain` true, `projectsFolder`) and the identity, lets `prepare` write
    /// what the host must find at start, creates a HostService, lets `beforeStart` change the identity, then starts
    /// the host. Use `XCTestCase.startTestHost(prepare:beforeStart:)` to stop it and remove its folders at teardown, or
    /// call `stop()` and `removeFolders()`.
    static func start(prepare: (Folders) throws -> Void = { _ in },
                      beforeStart: (DeviceIdentityStore) throws -> Void = { _ in }) async throws -> TestHost {
        let fileManager = FileManager.default
        // 1. Application Support, projects and Trash.
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HephHostTests-\(UUID().uuidString)", isDirectory: true)
        let supportFolder = base.appendingPathComponent("Application Support", isDirectory: true)
        let projectsFolder = base.appendingPathComponent("Projects", isDirectory: true)
        let trashFolder = base.appendingPathComponent("Trash", isDirectory: true)
        for folder in [supportFolder, projectsFolder, trashFolder] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        do {
            // 2. AppSupport with its own Trash, the settings, the identity.
            let appSupport = AppSupport(root: supportFolder, trashItem: { url in
                try TestHost.moveToTrash(url, trash: trashFolder)
            })
            let settings = SettingsStore(appSupport: appSupport)
            try settings.update { settings in
                settings.isMain = true
                settings.projectsFolder = projectsFolder.path
            }
            let identity = DeviceIdentityStore(appSupport: appSupport, settings: settings)
            // 3. What the host must find at start.
            try prepare(Folders(appSupport: supportFolder, projectsFolder: projectsFolder, trashFolder: trashFolder,
                                deviceID: identity.id))
            // 4. The host; `beforeStart` runs once the host and its MeshService exist, as onboarding runs after the
            //    app's launch created them; then start().
            let host = HostService(appSupport: appSupport, settings: settings,
                                   credentialStore: InMemoryCredentialStore(testCredentials),
                                   options: HostOptions(listenerHost: "127.0.0.1", listenerPort: 0, bonjour: false))
            try beforeStart(identity)
            try await host.start()
            guard let port = await host.boundListenerPort() else {
                await host.stop()
                throw TestSupportError(description: "The listener did not start: \(await host.listenerError ?? "")")
            }
            let remote = DeviceInfo(id: UUID(), name: "Sam's iPad", platform: .iPadOS, isMain: false,
                                    appVersion: "1.0", build: 1)
            let local = await host.mesh.localDevice()
            return TestHost(host: host, identity: identity, port: port, appSupport: appSupport,
                            projectsFolder: projectsFolder, trashFolder: trashFolder, settings: settings,
                            deviceContext: RequestContext(device: remote, connectionID: nil, author: nil),
                            claudeContext: .local(device: local, author: "Claude"), baseFolder: base)
        } catch {
            try? fileManager.removeItem(at: base)
            throw error
        }
    }

    /// The folders are removed when the TestHost is released, at the latest.
    deinit {
        try? FileManager.default.removeItem(at: baseFolder)
    }

    /// Stops the host.
    func stop() async {
        await host.stop()
    }

    /// Removes the temporary folders.
    func removeFolders() {
        try? FileManager.default.removeItem(at: baseFolder)
    }

    /// `host.perform` with the params encoded and the result decoded; `deviceContext` unless a context is given.
    func perform<P: Encodable & Sendable, R: Decodable>(_ method: RPCMethod, _ params: P, as type: R.Type,
                                                        context: RequestContext? = nil) async throws -> R {
        let data = try await host.perform(method.rawValue, params: WireCoding.encodeJSON(params),
                                          context: context ?? deviceContext)
        return try WireCoding.decodeJSON(type, from: data)
    }

    /// Moves an item into the test Trash folder, keeping its name when it is free.
    nonisolated static func moveToTrash(_ url: URL, trash: URL) throws {
        var destination = trash.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = trash.appendingPathComponent("\(url.lastPathComponent) \(UUID().uuidString)",
                                                       isDirectory: false)
        }
        try FileManager.default.moveItem(at: url, to: destination)
    }
}

/// Runs git and bash for PublicCheckTests and ForgePushTests in a temporary folder of its own, with an environment
/// that reads nothing of the user's git configuration, identity or private terms (docs/testing.md).
final class GitSandbox {
    /// The temporary folder, removed when the sandbox is released; a test also removes it at teardown.
    let folder: URL
    let home: URL
    let tmp: URL
    /// `<folder>/private-terms.txt`.
    let termsFile: URL
    /// When set, the lines written to `termsFile`.
    var terms: [String]? {
        didSet { writeTerms() }
    }
    /// The standard output, then the standard error, of each process the sandbox ran (`git` and `check`, failed ones
    /// included), in order (PublicCheckTests.testNothingLeaks and testHooks).
    private(set) var outputs: [String] = []

    private var repositoryCount = 0
    private let captures: URL

    init() throws {
        let fileManager = FileManager.default
        folder = fileManager.temporaryDirectory
            .appendingPathComponent("HephHostTests-git-\(UUID().uuidString)", isDirectory: true)
        home = folder.appendingPathComponent("home", isDirectory: true)
        tmp = folder.appendingPathComponent("tmp", isDirectory: true)
        captures = folder.appendingPathComponent("captures", isDirectory: true)
        termsFile = folder.appendingPathComponent("private-terms.txt", isDirectory: false)
        for path in [home, tmp, captures] {
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Exactly the variables of docs/testing.md; `HEPHAESTUS_PRIVATE_TERMS` only when terms are set.
    var environment: [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TMPDIR": tmp.path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "fixture",
            "GIT_COMMITTER_NAME": "fixture",
            "GIT_AUTHOR_EMAIL": "1+fixture@users.noreply.github.com",
            "GIT_COMMITTER_EMAIL": "1+fixture@users.noreply.github.com",
            "TZ": "UTC",
        ]
        if terms != nil {
            environment["HEPHAESTUS_PRIVATE_TERMS"] = termsFile.path
        }
        return environment
    }

    /// `/usr/bin/git` with `environment` in `folder`, in which `changes` sets variables for this command only (the
    /// e-mails of one commit in testCommitIdentity and testTermInCommitEmail, the temporary index of testReplaceRefs);
    /// returns its standard output, and a non-zero exit throws with its standard error.
    @discardableResult
    func git(_ arguments: [String], in folder: URL, environment changes: [String: String] = [:]) throws -> String {
        let result = try run("/usr/bin/git", arguments, in: folder, changes: changes)
        guard result.status == 0 else {
            throw TestSupportError(description: "git \(arguments.first ?? "") failed: \(result.error)")
        }
        return result.output
    }

    /// `/bin/bash <repositoryRoot>/scripts/check-public.sh <arguments>` in `folder`, with `environment`, in which
    /// `changes` sets variables for this run only (PublicCheckTests.testAttributesIgnored and testMessage).
    func check(_ arguments: [String], in folder: URL, environment changes: [String: String] = [:]) throws
        -> (status: Int32, output: String, error: String) {
        let script = repositoryRoot.appendingPathComponent("scripts/check-public.sh", isDirectory: false).path
        return try run("/bin/bash", [script] + arguments, in: folder, changes: changes)
    }

    /// A new folder, `git init -b main`, the repository's `scripts/check-public.sh` and `.githooks/` copied with
    /// mode 755, committed (`initial`).
    func makeRepository() throws -> URL {
        repositoryCount += 1
        let repository = folder.appendingPathComponent("repository-\(repositoryCount)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: repository)
        let scripts = repository.appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("check-public.sh", isDirectory: false)
        try fileManager.copyItem(at: repositoryRoot.appendingPathComponent("scripts/check-public.sh",
                                                                           isDirectory: false),
                                 to: script)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let hooks = repository.appendingPathComponent(".githooks", isDirectory: true)
        try fileManager.createDirectory(at: hooks, withIntermediateDirectories: true)
        let sourceHooks = repositoryRoot.appendingPathComponent(".githooks", isDirectory: true)
        for name in try fileManager.contentsOfDirectory(atPath: sourceHooks.path) {
            let hook = hooks.appendingPathComponent(name, isDirectory: false)
            try fileManager.copyItem(at: sourceHooks.appendingPathComponent(name, isDirectory: false), to: hook)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        }
        try git(["add", "-A"], in: repository)
        try git(["commit", "-q", "-m", "initial"], in: repository)
        return repository
    }

    /// A bare repository (`git init --bare -b main`), added to `repository` as `origin`, and `main` pushed to it.
    func makeOrigin(of repository: URL) throws -> URL {
        repositoryCount += 1
        let origin = folder.appendingPathComponent("origin-\(repositoryCount).git", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try git(["init", "--bare", "-b", "main"], in: origin)
        try git(["remote", "add", "origin", origin.path], in: repository)
        try git(["push", "-q", "origin", "main"], in: repository)
        return origin
    }

    // MARK: - Private

    private func writeTerms() {
        if let terms {
            try? Data((terms.map { $0 + "\n" }.joined()).utf8).write(to: termsFile)
        } else {
            try? FileManager.default.removeItem(at: termsFile)
        }
    }

    /// Runs a process to its end with `environment` (`changes` applied); its output goes through files, so that no
    /// pipe fills up. Both outputs are recorded in `outputs`.
    private func run(_ executable: String, _ arguments: [String], in directory: URL,
                     changes: [String: String] = [:]) throws -> (status: Int32, output: String, error: String) {
        let fileManager = FileManager.default
        let outputURL = captures.appendingPathComponent(UUID().uuidString, isDirectory: false)
        let errorURL = captures.appendingPathComponent(UUID().uuidString, isDirectory: false)
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil)
        else {
            throw TestSupportError(description: "Cannot create the capture files")
        }
        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment.merging(changes) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()
        try outputHandle.close()
        try errorHandle.close()
        let output = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        let error = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        outputs += [output, error]
        return (process.terminationStatus, output, error)
    }
}
#endif
