import Foundation

/// `registry.json`: the last `MeshSnapshot` this device knows, in the wire JSON form (docs/data/app-storage.md). On a
/// Main it is the registry the Main serves and syncs; on other devices a cache shown while no Main is reachable.
public enum RegistryCache {
    /// nil when missing or unreadable (logged).
    public static func load(_ appSupport: AppSupport) -> MeshSnapshot? {
        do {
            return try JSONFile.read(MeshSnapshot.self, from: appSupport.registryFile)
        } catch {
            let message = (error as? DataError)?.message ?? error.localizedDescription
            Log.core.error("Unreadable registry.json: \(message)")
            return nil
        }
    }

    public static func save(_ snapshot: MeshSnapshot, _ appSupport: AppSupport) throws {
        try JSONFile.write(snapshot, to: appSupport.registryFile)
    }

    /// Removes registry.json; a missing file is not an error.
    public static func delete(_ appSupport: AppSupport) throws {
        let url = appSupport.registryFile
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            throw DataError.io("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
