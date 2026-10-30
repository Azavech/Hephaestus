#if os(macOS)
import Foundation
import Observation

/// The status of the self-update (docs/forge/update.md, "Statuses").
public enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case downloading(build: Int)
    case ready(build: Int)
    case installing(build: Int)
    case failed(message: String)
}

/// What UpdateStatusView shows; the shell puts it in the environment. Changed only by UpdateService.
@MainActor @Observable public final class UpdateModel {
    public internal(set) var status: UpdateStatus = .idle
    public internal(set) var currentBuild: Int
    public internal(set) var latestBuild: Int?
    public internal(set) var latestReleaseURL: String?
    public internal(set) var lastChecked: Date?
    public internal(set) var canInstall: Bool
    public internal(set) var installedAppPath: String

    /// The UpdateService attached to this model (UpdateService.init).
    @ObservationIgnored weak var service: UpdateService?
    /// The sequence number of the last values UpdateService copied here.
    @ObservationIgnored var publishedSequence = 0

    public init() {
        currentBuild = UpdateService.currentBuild()
        let installed = UpdateService.installedAppURL()
        installedAppPath = installed.path
        canInstall = UpdateService.canInstall(installed)
    }

    /// Check Now: forwarded to the attached UpdateService.
    public func checkNow() {
        guard let service else { return }
        Task {
            await service.checkNow()
        }
    }

    /// Install: forwarded to the attached UpdateService.
    public func install() {
        guard let service else { return }
        Task {
            await service.install()
        }
    }

    /// Restart Now: forwarded to the attached UpdateService.
    public func restartNow() {
        guard let service else { return }
        Task {
            await service.restartNow()
        }
    }
}
#endif
