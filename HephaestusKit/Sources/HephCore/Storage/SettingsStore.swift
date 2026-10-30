import Foundation
import Observation

/// The settings of this device, read once at launch from `settings.json` and changed with `update`
/// (docs/data/app-storage.md, "Reading and writing").
@MainActor @Observable
public final class SettingsStore {
    public private(set) var settings: DeviceSettings

    @ObservationIgnored private let appSupport: AppSupport
    @ObservationIgnored private var continuations: [UUID: AsyncStream<DeviceSettings>.Continuation] = [:]

    /// Reads settings.json. A missing or unreadable file gives every default (an unreadable file is logged).
    public init(appSupport: AppSupport) {
        self.appSupport = appSupport
        do {
            settings = try JSONFile.read(DeviceSettings.self, from: appSupport.settingsFile) ?? DeviceSettings()
        } catch {
            let message = (error as? DataError)?.message ?? error.localizedDescription
            Log.core.error("Unreadable settings.json: \(message)")
            settings = DeviceSettings()
        }
    }

    /// Applies, normalizes, validates and writes; publishes the new value. Throws without changing anything on failure.
    public func update(_ change: (inout DeviceSettings) -> Void) throws {
        var newSettings = settings
        change(&newSettings)
        newSettings.normalize()
        try newSettings.validate()
        try JSONFile.write(newSettings, to: appSupport.settingsFile)
        settings = newSettings
        for continuation in continuations.values {
            continuation.yield(newSettings)
        }
    }

    /// A new stream that yields the settings after each successful update.
    public func changes() -> AsyncStream<DeviceSettings> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceSettings.self, bufferingPolicy: .unbounded)
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.continuations[id] = nil
            }
        }
        return stream
    }
}
