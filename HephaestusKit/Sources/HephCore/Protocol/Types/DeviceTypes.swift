import Foundation

// Devices: the wire types of docs/protocol/types.md, section "Devices".

/// The platform of a device.
public enum DevicePlatform: String, Codable, Sendable, Hashable, CaseIterable {
    /// A Mac.
    case macOS
    /// An iPhone.
    case iOS
    /// An iPad.
    case iPadOS
}

/// What a device says about itself in `hello` and in pairing.
public struct DeviceInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var platform: DevicePlatform
    public var isMain: Bool
    public var appVersion: String
    public var build: Int

    public init(id: UUID, name: String, platform: DevicePlatform, isMain: Bool, appVersion: String, build: Int) {
        self.id = id
        self.name = name
        self.platform = platform
        self.isMain = isMain
        self.appVersion = appVersion
        self.build = build
    }
}

/// A device of the mesh registry.
public struct DeviceRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var platform: DevicePlatform
    public var isMain: Bool
    public var addresses: [String]
    public var port: Int
    public var appVersion: String
    public var build: Int
    public var pairedAt: Date
    public var updatedAt: Date
    public var revoked: Bool

    public init(
        id: UUID,
        name: String,
        platform: DevicePlatform,
        isMain: Bool,
        addresses: [String],
        port: Int,
        appVersion: String,
        build: Int,
        pairedAt: Date,
        updatedAt: Date,
        revoked: Bool
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.isMain = isMain
        self.addresses = addresses
        self.port = port
        self.appVersion = appVersion
        self.build = build
        self.pairedAt = pairedAt
        self.updatedAt = updatedAt
        self.revoked = revoked
    }
}

/// One device's online state in a Main's presence report.
public struct Presence: Codable, Sendable, Hashable, Identifiable {
    public var deviceID: UUID
    public var online: Bool
    public var lastSeen: Date
    public var via: [UUID]

    public var id: UUID { deviceID }

    public init(deviceID: UUID, online: Bool, lastSeen: Date, via: [UUID]) {
        self.deviceID = deviceID
        self.online = online
        self.lastSeen = lastSeen
        self.via = via
    }
}

/// A Main's registry and presence report.
public struct MeshSnapshot: Codable, Sendable, Hashable {
    public var meshID: UUID
    public var devices: [DeviceRecord]
    public var presence: [Presence]

    public init(meshID: UUID, devices: [DeviceRecord], presence: [Presence]) {
        self.meshID = meshID
        self.devices = devices
        self.presence = presence
    }
}
