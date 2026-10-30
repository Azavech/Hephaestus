#if os(macOS)
import AppKit
import Foundation
import HephCore

/// The self-update of macOS (docs/forge/update.md): checks the newest release `build-<N>`, downloads, verifies and
/// re-signs it, then installs it and restarts the app when no work is active.
public actor UpdateService {
    private let model: UpdateModel
    private let isBusy: @Sendable () async -> Bool

    private let currentBuild: Int
    private let installedApp: URL
    private let canInstall: Bool
    private var status: UpdateStatus = .idle
    private var latestBuild: Int?
    private var latestReleaseURL: String?
    private var lastChecked: Date?
    /// No check starts before this time.
    private var rateLimitedUntil: Date?

    private var started = false
    /// The next scheduled check.
    private var scheduleTask: Task<Void, Never>?
    /// The check in progress.
    private var checkTask: Task<Void, Never>?
    /// The install attempts every 10 s while `ready`.
    private var readyTask: Task<Void, Never>?
    /// The number of copies sent to the model.
    private var publications = 0

    /// Attaches itself to `model`. `isBusy` is the busy condition of Installing.
    public init(model: UpdateModel, isBusy: @escaping @Sendable () async -> Bool) {
        self.model = model
        self.isBusy = isBusy
        currentBuild = Self.currentBuild()
        installedApp = Self.installedAppURL()
        canInstall = Self.canInstall(installedApp)
        let service = self
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                model.service = service
            }
        } else {
            Task { @MainActor in
                model.service = service
            }
        }
    }

    /// After-restart steps, first check in 10 s, 15-minute schedule. Called once by the shell at launch.
    public func start() {
        guard !started else { return }
        started = true
        if let message = UpdateInstaller.afterRestart(currentBuild: currentBuild,
                                                      updatesFolder: Self.workingDirectory()) {
            status = .failed(message: message)
            Log.host.error("The last update was not installed")
        }
        publish()
        schedule(after: .seconds(10))
    }

    /// Check Now.
    public func checkNow() {
        startCheck(fromInstall: false)
    }

    /// Install (Schedule): a check that does not stop at step 5 for updates.enabled.
    public func install() {
        guard status == .idle else { return }
        startCheck(fromInstall: true)
    }

    /// Restart Now: installs the ready update at once, busy or not.
    public func restartNow() {
        guard case .ready(let build) = status else { return }
        readyTask?.cancel()
        readyTask = nil
        Task {
            await self.installNow(build: build)
        }
    }

    /// A release build seen in a ForgeState (ForgeModel.releaseObserver, ../ui/forge.md).
    public func releaseNoticed(build: Int) {
        guard build > currentBuild, build > (latestBuild ?? Int.min) else { return }
        startCheck(fromInstall: false)
    }

    /// The code signing identities offered in Settings (Re-signing).
    public func signingIdentities() async -> [SigningIdentity] {
        await CodeSigning.identities()
    }

    /// Cancels the schedule (app termination).
    public func stop() {
        scheduleTask?.cancel()
        scheduleTask = nil
        readyTask?.cancel()
        readyTask = nil
        checkTask?.cancel()
        checkTask = nil
    }

    // MARK: - Schedule

    /// The next check `delay` from now.
    private func schedule(after delay: Duration) {
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.startCheck(fromInstall: false)
        }
    }

    /// Starts a check unless one runs, the status is `checking`, `downloading` or `installing`, or the GitHub API is
    /// rate limited.
    private func startCheck(fromInstall: Bool) {
        guard checkTask == nil else { return }
        switch status {
        case .checking, .downloading, .installing:
            return
        case .idle, .ready, .failed:
            break
        }
        if let rateLimitedUntil, rateLimitedUntil > Date() {
            schedule(after: .seconds(900))
            return
        }
        scheduleTask?.cancel()
        scheduleTask = nil
        checkTask = Task {
            await self.check(fromInstall: fromInstall)
            self.checkEnded()
        }
    }

    /// Every 15 minutes, counted from the end of the previous check.
    private func checkEnded() {
        checkTask = nil
        schedule(after: .seconds(900))
    }

    // MARK: - Check

    private func check(fromInstall: Bool) async {
        // 1. Checking, except while ready.
        var readyBuild: Int?
        if case .ready(let build) = status {
            readyBuild = build
        } else {
            status = .checking
            publish()
        }
        // 2 to 4. The latest release.
        let settings = Self.readSettings()
        let client = GitHubClient(repository: ForgeConfig.publicRepository, token: await GitHubClient.readToken())
        let release: GitHubRelease?
        do {
            release = try await client.latestRelease()
        } catch is CancellationError {
            return
        } catch {
            if case GitHubError.rateLimited(let until) = error {
                rateLimitedUntil = until
            }
            if readyBuild == nil {
                status = .failed(message: "Could not check for updates: \(error.localizedDescription)")
            }
            publish()
            return
        }
        let build = release.flatMap { Self.buildNumber($0.tagName) }
        latestBuild = build
        latestReleaseURL = release?.htmlURL
        lastChecked = Date()
        // 5. Nothing more for a ready build at least as new, or when nothing newer can be installed.
        if let readyBuild, readyBuild >= (build ?? Int.min) {
            publish()
            return
        }
        guard let release, let build, build > currentBuild, canInstall, settings.updates.enabled || fromInstall else {
            status = .idle
            publish()
            return
        }
        // 6. The asset.
        guard let asset = release.assets.first(where: { $0.name == "Hephaestus-macOS.zip" }) else {
            status = .failed(message: "Release build-\(build) has no Hephaestus-macOS.zip.")
            publish()
            return
        }
        // 7. Download and unpack, verification, re-signing, then ready.
        await prepare(asset: asset, build: build, settings: settings)
    }

    /// Download and unpack, Verification, Re-signing, then `ready` and Installing.
    private func prepare(asset: GitHubAsset, build: Int, settings: DeviceSettings) async {
        let updates = Self.workingDirectory()
        let folder = updates.appendingPathComponent("build-\(build)", isDirectory: true)
        // Download and unpack.
        readyTask?.cancel()
        readyTask = nil
        status = .downloading(build: build)
        publish()
        UpdateInstaller.removeBuildFolders(in: updates)
        let zip = folder.appendingPathComponent("Hephaestus-macOS.zip", isDirectory: false)
        do {
            try await download(asset, to: zip, folder: folder)
        } catch let failure as DownloadFailure where !Task.isCancelled {
            switch failure {
            case .failed(let reason):
                fail("The download of build \(build) failed: \(reason).", removing: folder)
            case .incomplete:
                fail("The download of build \(build) is incomplete.", removing: folder)
            }
            return
        } catch {
            // Cancelled (app termination).
            try? FileManager.default.removeItem(at: folder)
            return
        }
        let unpack = ChildProcessConfiguration(executable: "/usr/bin/ditto",
                                               arguments: ["-x", "-k", zip.path, folder.path],
                                               workingDirectory: updates.path,
                                               environment: await LoginEnvironment.shared.environment())
        _ = try? await ChildProcess.capture(unpack, timeout: .seconds(120))
        try? FileManager.default.removeItem(at: zip)
        let app = folder.appendingPathComponent("Hephaestus.app", isDirectory: true)

        // Verification.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            fail("The update archive does not contain Hephaestus.app.", removing: folder)
            return
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist", isDirectory: false))
        let identifier = info?["CFBundleIdentifier"] as? String ?? ""
        guard identifier == Self.runningBundleIdentifier else {
            fail("The update has the bundle identifier \(identifier).", removing: folder)
            return
        }
        let version = info?["CFBundleVersion"] as? String ?? ""
        guard version == String(build) else {
            fail("The update is build \(version), not \(build).", removing: folder)
            return
        }
        do {
            try await CodeSigning.verify(app)
        } catch {
            fail("The signature of build \(build) is not valid: \(error.localizedDescription)", removing: folder)
            return
        }

        // Re-signing.
        var identity = settings.updates.signingIdentity
        if identity.isEmpty {
            identity = await CodeSigning.identities().first?.sha1 ?? ""
        }
        if !identity.isEmpty, identity != "-" {
            do {
                try await CodeSigning.sign(app, identity: identity)
            } catch {
                fail("Re-signing build \(build) with \(identity) failed: \(error.localizedDescription)",
                     removing: folder)
                return
            }
        }

        // Ready; then Installing.
        status = .ready(build: build)
        publish()
        Log.host.notice("Build \(build, privacy: .public) is ready to install")
        startReadyLoop(build: build)
    }

    /// Why a download failed (Download and unpack step 2).
    private enum DownloadFailure: Error {
        /// `The download of build <N> failed: <reason>.`
        case failed(reason: String)
        /// The file's size differs from the asset's: `The download of build <N> is incomplete.`
        case incomplete
    }

    /// Downloads the asset (no Authorization header; request timeout 60 s, resource timeout 10 minutes) and moves the
    /// file into `folder`; its size must equal the asset's. Throws DownloadFailure, or CancellationError.
    private func download(_ asset: GitHubAsset, to zip: URL, folder: URL) async throws {
        guard let url = URL(string: asset.browserDownloadURL) else {
            throw DownloadFailure.failed(reason: "Invalid download URL")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer {
            session.finishTasksAndInvalidate()
        }
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(from: url)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw DownloadFailure.failed(reason: Self.reason(error))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw DownloadFailure.failed(reason: "HTTP \(http.statusCode)")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: zip)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw DownloadFailure.failed(reason: Self.reason(error))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.intValue ?? -1
        guard size == asset.size else {
            throw DownloadFailure.incomplete
        }
    }

    /// The error's `localizedDescription` without its final period.
    private static func reason(_ error: any Error) -> String {
        var text = error.localizedDescription
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    /// Deletes the build folder and sets `failed` with the message.
    private func fail(_ message: String, removing folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        status = .failed(message: message)
        publish()
        Log.host.error("The update failed: \(message)")
    }

    // MARK: - Installing

    /// On entering `ready`, and every 10 s while `ready`: when not busy, install.
    private func startReadyLoop(build: Int) {
        readyTask?.cancel()
        readyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await !self.isBusy() {
                    await self.installNow(build: build)
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
            }
        }
    }

    /// Installing steps 1 to 5.
    private func installNow(build: Int) async {
        guard status == .ready(build: build) else { return }
        readyTask = nil
        status = .installing(build: build)
        publish()
        let updates = Self.workingDirectory()
        let app = updates.appendingPathComponent("build-\(build)", isDirectory: true)
            .appendingPathComponent("Hephaestus.app", isDirectory: true)
        do {
            try await UpdateInstaller.install(newApp: app, build: build, updatesFolder: updates)
        } catch {
            status = .failed(message: error.localizedDescription)
            publish()
            Log.host.error("Could not install build \(build, privacy: .public): \(error.localizedDescription)")
            return
        }
        Log.host.notice("Installing build \(build, privacy: .public); the app quits")
        // From a timer of the main run loop, once this main-actor job has returned: called inside it, `terminate`
        // would wait in a nested event loop for a reply that only another main-actor task sends.
        await MainActor.run {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }

    // MARK: - Model

    /// Copies the values to the UpdateModel on the main actor; a copy older than the one applied is dropped.
    private func publish() {
        publications += 1
        let sequence = publications
        let model = model
        let status = status
        let currentBuild = currentBuild
        let latestBuild = latestBuild
        let latestReleaseURL = latestReleaseURL
        let lastChecked = lastChecked
        let canInstall = canInstall
        let installedAppPath = installedApp.path
        Task { @MainActor in
            guard sequence > model.publishedSequence else { return }
            model.publishedSequence = sequence
            model.status = status
            model.currentBuild = currentBuild
            model.latestBuild = latestBuild
            model.latestReleaseURL = latestReleaseURL
            model.lastChecked = lastChecked
            model.canInstall = canInstall
            model.installedAppPath = installedAppPath
        }
    }

    // MARK: - Values

    /// `CFBundleVersion` of the running app as an integer; 0 when it is not one.
    nonisolated static func currentBuild() -> Int {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
    }

    /// `Bundle.main.bundleURL` with symlinks resolved.
    nonisolated static func installedAppURL() -> URL {
        Bundle.main.bundleURL.resolvingSymlinksInPath()
    }

    /// The installed app's parent folder is `/Applications` or `<home>/Applications`.
    nonisolated static func canInstall(_ app: URL) -> Bool {
        let parent = app.deletingLastPathComponent().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true).standardizedFileURL.path
        return parent == "/Applications" || parent == home
    }

    /// The Updates folder, created when needed; the temporary folder when Application Support is not available.
    nonisolated static func workingDirectory() -> URL {
        do {
            let folder = try AppSupport.standard().updatesFolder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            Log.host.error("The Updates folder is not available: \(error.localizedDescription)")
            return FileManager.default.temporaryDirectory
        }
    }

    /// The bundle identifier of the running app.
    private static var runningBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "ca.azavech.hephaestus"
    }

    /// `settings.json` read when used; `DeviceSettings()` when missing or unreadable.
    private static func readSettings() -> DeviceSettings {
        guard let appSupport = try? AppSupport.standard() else { return DeviceSettings() }
        return (try? JSONFile.read(DeviceSettings.self, from: appSupport.settingsFile)) ?? DeviceSettings()
    }

    /// `N` of a tag `build-<N>` (`N` decimal); nil otherwise.
    private static func buildNumber(_ tag: String) -> Int? {
        ForgeService.buildNumber(tag)
    }
}
#endif
