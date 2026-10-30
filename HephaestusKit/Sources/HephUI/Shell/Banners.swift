import Foundation
import HephCore
import Observation

/// A transient message at the bottom of a window (docs/ui/shell.md §8).
public struct Banner: Identifiable, Equatable, Sendable {
    public enum Style: Sendable { case error, info }

    public let id: UUID
    public var style: Style
    public var message: String

    public init(style: Style, message: String) {
        id = UUID()
        self.style = style
        self.message = message
    }

    /// The message shown for an error (§8.1): the `message` of a `ProtocolError` or a `DataError`, the
    /// `errorDescription` of another `LocalizedError`, else the `localizedDescription`.
    static func message(of error: any Error) -> String {
        if let protocolError = error as? ProtocolError {
            return protocolError.message
        }
        if let dataError = error as? DataError {
            return dataError.message
        }
        if let localizedError = error as? any LocalizedError, let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

/// The banners of one window (§8.1): every main window and the macOS Settings window have one, in their environment.
@MainActor @Observable
public final class WindowBanners {
    /// The visible banners, oldest first.
    public private(set) var banners: [Banner] = []

    /// The removal timer of each visible banner.
    @ObservationIgnored private var timers: [Banner.ID: Task<Void, Never>] = [:]

    /// Banners stay 4 s after they were posted or after their timer last restarted.
    private static let lifetime: Duration = .seconds(4)
    /// At most this many banners are visible.
    private static let maximumCount = 3

    public init() {}

    /// Adds a banner; a visible banner with the same style and message restarts its timer instead.
    public func post(_ banner: Banner) {
        if let existing = banners.first(where: { $0.style == banner.style && $0.message == banner.message }) {
            startTimer(existing.id)
            return
        }
        banners.append(banner)
        startTimer(banner.id)
        while banners.count > Self.maximumCount {
            let oldest = banners.removeFirst()
            timers.removeValue(forKey: oldest.id)?.cancel()
        }
    }

    /// Shows an error banner with the message of `error`; a `CancellationError` shows nothing.
    public func showError(_ error: any Error) {
        if error is CancellationError {
            return
        }
        post(Banner(style: .error, message: Banner.message(of: error)))
    }

    public func showError(_ message: String) {
        post(Banner(style: .error, message: message))
    }

    public func showInfo(_ message: String) {
        post(Banner(style: .info, message: message))
    }

    /// Removes the banner and cancels its timer.
    public func dismiss(_ id: Banner.ID) {
        banners.removeAll { $0.id == id }
        timers.removeValue(forKey: id)?.cancel()
    }

    /// Runs `operation`; a thrown error goes to `showError`. Returns whether it succeeded.
    @discardableResult
    public func perform(_ operation: @MainActor () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private func startTimer(_ id: Banner.ID) {
        timers[id]?.cancel()
        timers[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.lifetime)
            } catch {
                return
            }
            self?.dismiss(id)
        }
    }
}

/// Posts banners to the active window (§8.2).
@MainActor
public final class AppBannerRouter {
    /// The banners of the window that became active last.
    private weak var target: WindowBanners?
    /// The latest banner posted without a live target.
    private var pending: Banner?

    public init() {}

    /// The window that became active becomes the target; a kept banner is posted to it.
    public func activate(_ banners: WindowBanners) {
        target = banners
        if let pending {
            self.pending = nil
            banners.post(pending)
        }
    }

    /// Posts to the target; without a live target the banner is kept (only the latest one).
    public func post(_ banner: Banner) {
        if let target {
            target.post(banner)
        } else {
            pending = banner
        }
    }
}
