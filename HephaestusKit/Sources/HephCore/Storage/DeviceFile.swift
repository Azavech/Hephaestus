import Foundation

/// `device.json`: the identity of this device (docs/data/app-storage.md). docs/devices/roles.md creates and changes it.
public struct DeviceFile: Codable, Sendable, Equatable {
    /// Device id, a UUID generated once and never changed.
    public var id: UUID
    /// Device name, as shown on every device of the mesh.
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    /// nil when device.json does not exist.
    public static func load(_ appSupport: AppSupport) throws -> DeviceFile? {
        try JSONFile.read(DeviceFile.self, from: appSupport.deviceFile)
    }

    public func save(_ appSupport: AppSupport) throws {
        try JSONFile.write(self, to: appSupport.deviceFile)
    }
}
