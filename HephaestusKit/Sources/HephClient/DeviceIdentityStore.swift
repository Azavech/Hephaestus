import Foundation
import HephCore
import Observation
#if os(macOS)
import SystemConfiguration
#endif
#if os(iOS)
import UIKit
#endif

/// The identity of this device: `device.json` (`id`, `name`), the platform, the Main role from the settings and the
/// version of the running app (docs/devices/roles.md, "Identity").
@MainActor @Observable
public final class DeviceIdentityStore {
    public private(set) var id: UUID
    public private(set) var name: String
    public let platform: DevicePlatform
    public let appVersion: String
    public let build: Int

    @ObservationIgnored private let appSupport: AppSupport
    @ObservationIgnored private let settings: SettingsStore

    /// Loads device.json, creating it when it is missing, unreadable or its id is not a UUID. Reads isMain from
    /// `settings`.
    public init(appSupport: AppSupport, settings: SettingsStore) {
        self.appSupport = appSupport
        self.settings = settings
        platform = Self.currentPlatform()
        let info = Bundle.main.infoDictionary
        appVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        build = (info?["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0

        let loaded: DeviceFile?
        do {
            loaded = try DeviceFile.load(appSupport)
        } catch {
            Log.client.error("Unreadable device.json, creating a new identity: \(String(describing: error))")
            loaded = nil
        }
        if let loaded {
            id = loaded.id
            name = loaded.name
        } else {
            id = UUID()
            name = Self.defaultName()
            write()
        }
    }

    /// `settings.settings.isMain`; always false on iOS and iPadOS.
    public var isMain: Bool {
        #if os(macOS)
        return settings.settings.isMain
        #else
        return false
        #endif
    }

    /// The six identity fields, as sent in `hello` and in pairing.
    public var deviceInfo: DeviceInfo {
        DeviceInfo(id: id, name: name, platform: platform, isMain: isMain, appVersion: appVersion, build: build)
    }

    /// The default name of this platform: the computer name on macOS ("Mac" when it is missing, empty or reserved),
    /// "iPad" on iPadOS, "iPhone" on iOS.
    public static func defaultName() -> String {
        #if os(macOS)
        let computerName = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return computerName.flatMap { try? validateName($0) } ?? "Mac"
        #else
        return currentPlatform() == .iPadOS ? "iPad" : "iPhone"
        #endif
    }

    /// The trimmed name. Throws `DataError.invalid("Enter a device name.")` when it is empty and
    /// `DataError.invalid("Claude is a reserved name.")` when it is Claude in any letter case.
    public static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DataError.invalid("Enter a device name.")
        }
        guard trimmed.caseInsensitiveCompare("Claude") != .orderedSame else {
            throw DataError.invalid("Claude is a reserved name.")
        }
        return trimmed
    }

    /// Validates, writes device.json, publishes `name`. Used before the device belongs to a mesh. Throws only the
    /// validation errors: a write failure is logged, the name stays in memory and the file is written again at the
    /// next change.
    public func setName(_ name: String) throws {
        let validated = try Self.validateName(name)
        self.name = validated
        write()
    }

    /// Adopts the name of `device` and writes device.json when it differs from `name` (the registry name wins,
    /// `WorkspaceEnvironment.saveDevice`). Ignores `device` when its id is not this device's id. A write failure is
    /// logged.
    public func save(_ device: DeviceInfo) {
        guard device.id == id, device.name != name else { return }
        name = device.name
        write()
    }

    /// `SettingsStore.update { $0.isMain = isMain }`; throws the SettingsStore error ("only a Mac can be a Main" on
    /// iOS and iPadOS).
    public func setIsMain(_ isMain: Bool) throws {
        try settings.update { $0.isMain = isMain }
    }

    // MARK: - Private

    /// Writes device.json; a failure is logged and the identity stays in memory.
    private func write() {
        do {
            try DeviceFile(id: id, name: name).save(appSupport)
        } catch {
            Log.client.error("Could not write device.json: \(String(describing: error))")
        }
    }

    private static func currentPlatform() -> DevicePlatform {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS
        #else
        return .macOS
        #endif
    }
}
