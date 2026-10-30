#if os(macOS)
import Foundation
import HephCore

/// The content of `forge.json` (docs/forge/pipeline.md, "forge.json"): coded like the wire types; `cycle`,
/// `latestRelease` and `trustedHead` are omitted when nil. `head` and `lastError` are not stored.
struct ForgeFile: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var cycle: ForgeCycle?
    var items: [ForgeItem]
    var latestRelease: ForgeRelease?
    /// The full SHA of the last head of the branch that the Forge pushed or checked.
    var trustedHead: String?
}

extension ForgeService {
    /// At most this many items are kept.
    static let maxItems = 100

    /// Loads `forge.json` (first enabling in the process). A file that does not decode, or has another `version`, is
    /// renamed to `forge.json.bad` (replacing an older one) and the Forge starts with no cycle and no items.
    func loadStore() {
        let url = host.appSupport.forgeFile
        do {
            guard let file = try JSONFile.read(ForgeFile.self, from: url) else {
                cycle = nil
                items = []
                latestRelease = nil
                trustedHead = nil
                return
            }
            guard file.version == ForgeFile.currentVersion else {
                throw DataError.unreadable("forge.json: version \(file.version)")
            }
            cycle = file.cycle
            items = file.items
            latestRelease = file.latestRelease
            trustedHead = file.trustedHead
            Log.host.info("Loaded forge.json: \(file.items.count, privacy: .public) items")
        } catch {
            Log.host.error("forge.json is unreadable and was renamed to forge.json.bad: \(Self.message(of: error))")
            let bad = url.deletingLastPathComponent().appendingPathComponent("forge.json.bad", isDirectory: false)
            let fileManager = FileManager.default
            do {
                if fileManager.fileExists(atPath: bad.path) {
                    try fileManager.removeItem(at: bad)
                }
                try fileManager.moveItem(at: url, to: bad)
            } catch {
                Log.host.error("Could not rename forge.json: \(error.localizedDescription)")
            }
            cycle = nil
            items = []
            latestRelease = nil
            trustedHead = nil
        }
    }

    /// Writes `forge.json` with `JSONFile.write`, after every change of the cycle, the items, `latestRelease` or
    /// `trustedHead`.
    func saveStore() {
        let file = ForgeFile(version: ForgeFile.currentVersion, cycle: cycle, items: items,
                             latestRelease: latestRelease, trustedHead: trustedHead)
        do {
            try JSONFile.write(file, to: host.appSupport.forgeFile)
        } catch {
            Log.host.error("Could not write forge.json: \(Self.message(of: error))")
        }
    }

    /// Makes room for a new item: while there are 100 items, the oldest `done` item is dropped.
    func dropOldItemsForNewItem() {
        while items.count >= Self.maxItems {
            guard let oldest = items.enumerated()
                .filter({ $0.element.state == .done })
                .min(by: { $0.element.created < $1.element.created })
            else { return }
            items.remove(at: oldest.offset)
        }
    }
}
#endif
