import Foundation

/// The Application Support folder of the app, `<Application Support>/Hephaestus/`, and the function that moves items
/// to the Trash (docs/data/app-storage.md). Tests run on a temporary folder with a Trash of their own.
public struct AppSupport: Sendable {
    public let root: URL
    /// Moves a file or folder to the Trash (Trash section).
    public let trashItem: @Sendable (URL) throws -> Void

    /// Tests pass a temporary root and a trashItem that moves items into a temporary folder.
    public init(root: URL, trashItem: @escaping @Sendable (URL) throws -> Void = AppSupport.defaultTrashItem) {
        self.root = root
        self.trashItem = trashItem
    }

    /// FileManager.default.trashItem(at: url, resultingItemURL: nil)
    public static let defaultTrashItem: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// <Application Support>/Hephaestus, created when missing, with defaultTrashItem.
    public static func standard() throws -> AppSupport {
        let fileManager = FileManager.default
        do {
            let applicationSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true)
            let root = applicationSupport.appendingPathComponent("Hephaestus", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            return AppSupport(root: root)
        } catch {
            throw DataError.io("Hephaestus: \(error.localizedDescription)")
        }
    }

    /// device.json
    public var deviceFile: URL { root.appendingPathComponent("device.json", isDirectory: false) }
    /// settings.json
    public var settingsFile: URL { root.appendingPathComponent("settings.json", isDirectory: false) }
    /// registry.json
    public var registryFile: URL { root.appendingPathComponent("registry.json", isDirectory: false) }
    /// projects.json
    public var projectsFile: URL { root.appendingPathComponent("projects.json", isDirectory: false) }
    /// migrations.json
    public var migrationsFile: URL { root.appendingPathComponent("migrations.json", isDirectory: false) }
    /// forge.json
    public var forgeFile: URL { root.appendingPathComponent("forge.json", isDirectory: false) }
    /// Skills/
    public var skillsFolder: URL { root.appendingPathComponent("Skills", isDirectory: true) }
    /// SessionPlugins/
    public var sessionPluginsFolder: URL { root.appendingPathComponent("SessionPlugins", isDirectory: true) }
    /// Uploads/
    public var uploadsFolder: URL { root.appendingPathComponent("Uploads", isDirectory: true) }
    /// Updates/
    public var updatesFolder: URL { root.appendingPathComponent("Updates", isDirectory: true) }
}
