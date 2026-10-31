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
    /// renamed to `forge.json.bad` (replacing an older one) and the Forge starts with no cycle and no items. Before it
    /// is decoded, its JSON object goes through `renameTaskMembers(_:)`; when that changed it, the decoded state is
    /// written back at once, with the new names.
    func loadStore() {
        let url = host.appSupport.forgeFile
        do {
            guard let loaded = try Self.readForgeFile(url) else {
                cycle = nil
                items = []
                latestRelease = nil
                trustedHead = nil
                return
            }
            let file = loaded.file
            guard file.version == ForgeFile.currentVersion else {
                throw DataError.unreadable("forge.json: version \(file.version)")
            }
            cycle = file.cycle
            items = file.items
            latestRelease = file.latestRelease
            trustedHead = file.trustedHead
            Log.host.info("Loaded forge.json: \(file.items.count, privacy: .public) items")
            if loaded.renamed {
                saveStore()
            }
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

    /// The renaming of the members of a forge.json written before tasks were renamed tickets: `taskID` → `ticketID` in
    /// each item of `items`, `itemTaskIDs` → `itemTicketIDs` in `cycle`; where the new name is already present, the old
    /// member is removed. Returns true when it changed `object`.
    static func renameTaskMembers(_ object: inout [String: Any]) -> Bool {
        var changed = false
        if var items = object["items"] as? [Any] {
            for index in items.indices {
                guard var item = items[index] as? [String: Any] else { continue }
                if renameMember(&item, from: "taskID", to: "ticketID") {
                    items[index] = item
                    changed = true
                }
            }
            if changed {
                object["items"] = items
            }
        }
        if var cycle = object["cycle"] as? [String: Any], renameMember(&cycle, from: "itemTaskIDs", to: "itemTicketIDs") {
            object["cycle"] = cycle
            changed = true
        }
        return changed
    }

    /// Renames the member `old` to `new`, or removes it when `new` is already present; true when it changed `object`.
    private static func renameMember(_ object: inout [String: Any], from old: String, to new: String) -> Bool {
        guard let value = object.removeValue(forKey: old) else { return false }
        if object[new] == nil {
            object[new] = value
        }
        return true
    }

    /// Reads and decodes `forge.json` as `JSONFile.read` does (`WireCoding.makeDecoder()`), its JSON object renamed
    /// first by `renameTaskMembers(_:)`; nil when the file does not exist. `renamed`: the renaming changed it.
    private static func readForgeFile(_ url: URL) throws -> (file: ForgeFile, renamed: Bool)? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        } catch {
            throw DataError.io("forge.json: \(error.localizedDescription)")
        }
        var decoded = data
        var renamed = false
        if var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           renameTaskMembers(&object) {
            renamed = true
            decoded = try JSONSerialization.data(withJSONObject: object)
        }
        do {
            return (try WireCoding.makeDecoder().decode(ForgeFile.self, from: decoded), renamed)
        } catch {
            throw DataError.unreadable("forge.json: \(error.localizedDescription)")
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
