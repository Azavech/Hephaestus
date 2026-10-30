#if os(macOS)
import Foundation
import HephCore

/// The sync between Mains (docs/claude/skills.md §7.3, §7.4): each Main only pulls, over its own outgoing peer link.
/// Pulls of one library run one at a time; a pull requested while another runs waits for it.
extension SkillsService {
    /// This Main's peer link to another Main became connected: a pull from that Main.
    public func peerLinkOpened(_ deviceID: UUID) async {
        enqueuePull(from: deviceID)
    }

    /// A skills.changed event arrived from that Main over that link: a pull from that Main.
    public func peerSkillsChanged(_ deviceID: UUID) async {
        enqueuePull(from: deviceID)
    }

    /// Queues a pull after the pulls already requested.
    func enqueuePull(from deviceID: UUID) {
        guard appSupport != nil else { return }
        let previous = lastPull
        let id = UUID()
        let task = Task {
            await previous?.value
            if !Task.isCancelled {
                await self.pull(from: deviceID)
            }
            self.pullEnded(id)
        }
        pulls[id] = task
        lastPull = task
    }

    func pullEnded(_ id: UUID) {
        pulls[id] = nil
    }

    // MARK: - Pull (§7.4)

    func pull(from deviceID: UUID) async {
        guard let appSupport else { return }
        // 1. Scan, then the other Main's manifest.
        scan()
        let items: [SkillManifest]
        do {
            let result = try await host.requestPeer(deviceID, method: RPCMethod.skillsManifest.rawValue,
                                                    params: try WireCoding.encodeJSON(EmptyPayload()))
            items = try WireCoding.decodeJSON(SkillsManifestResult.self, from: result).skills
        } catch {
            Log.host.error("Could not read the skills manifest of \(deviceID.uuidString, privacy: .public): \(Self.protocolError(error).message)")
            return
        }
        // 2. Each item newer than the local entry.
        var changed = false
        for item in items {
            if Task.isCancelled { break }
            guard SkillName.isValid(item.name) else { continue }
            guard isNewer(item) else { continue }
            if item.deleted {
                if pullDeletion(item, appSupport) {
                    changed = true
                }
            } else if await pullSkill(item, from: deviceID, appSupport) {
                changed = true
            }
        }
        // 4. The broadcast of the change; it makes the other Main pull from this one, which finds nothing newer.
        if changed {
            let index = SkillsIndex.load(from: indexURL(appSupport))
            broadcast(index)
        }
    }

    /// No local entry, or the item's `modified` is later than the local entry's (equal dates: the local copy stays).
    private func isNewer(_ item: SkillManifest) -> Bool {
        guard let appSupport else { return false }
        let index = SkillsIndex.load(from: indexURL(appSupport))
        guard let local = index.entries[item.name] else { return true }
        return SkillsIndex.milliseconds(item.modified) > SkillsIndex.milliseconds(local.modified)
    }

    /// Right before a local skill is moved to the Trash or replaced: a scan, then whether the local entry became later
    /// than the item (a change made while the pull awaited the other Main).
    private func localIsLater(than item: SkillManifest) -> Bool {
        let index = scan()
        guard let local = index.entries[item.name] else { return false }
        return SkillsIndex.milliseconds(local.modified) > SkillsIndex.milliseconds(item.modified)
    }

    /// A deleted item: the local folder goes to the Trash; the local entry becomes a tombstone with the item's date.
    private func pullDeletion(_ item: SkillManifest, _ appSupport: AppSupport) -> Bool {
        let folder = appSupport.skillsFolder.appendingPathComponent(item.name, isDirectory: true)
        if Self.exists(folder) {
            if localIsLater(than: item) {
                return false
            }
            do {
                try appSupport.trashItem(folder)
            } catch {
                Log.host.error("Could not move the skill \(item.name, privacy: .public) to the Trash: \(error.localizedDescription)")
                return false
            }
        }
        setEntry(item, appSupport)
        Log.host.info("Pulled the deletion of the skill \(item.name, privacy: .public)")
        return true
    }

    /// Another item: its files are downloaded into `Skills/.incoming/<name>/`, dated with the item's `modified`, then
    /// moved in place of the local folder.
    private func pullSkill(_ item: SkillManifest, from deviceID: UUID, _ appSupport: AppSupport) async -> Bool {
        let fileManager = FileManager.default
        let incoming = appSupport.skillsFolder
            .appendingPathComponent(".incoming", isDirectory: true)
            .appendingPathComponent(item.name, isDirectory: true)
        do {
            if Self.exists(incoming) {
                try fileManager.removeItem(at: incoming)
            }
            try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
            let listing = try await host.requestPeer(deviceID, method: RPCMethod.skillsFiles.rawValue,
                                                     params: try WireCoding.encodeJSON(SkillsFilesParams(name: item.name)))
            let files = try WireCoding.decodeJSON(SkillsFilesResult.self, from: listing).files
            for file in files {
                try Task.checkCancellation()
                let components = try Self.components(file.path)
                let params = try WireCoding.encodeJSON(SkillsReadFileParams(name: item.name, path: file.path))
                let result = try await host.requestPeer(deviceID, method: RPCMethod.skillsReadFile.rawValue,
                                                        params: params)
                let data = try WireCoding.decodeJSON(SkillsReadFileResult.self, from: result).data
                let destination = components.reduce(incoming) { $0.appendingPathComponent($1) }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try data.write(to: destination)
                try fileManager.setAttributes([.modificationDate: item.modified], ofItemAtPath: destination.path)
            }
            let folder = appSupport.skillsFolder.appendingPathComponent(item.name, isDirectory: true)
            if localIsLater(than: item) {
                try? fileManager.removeItem(at: incoming)
                return false
            }
            if Self.exists(folder) {
                try fileManager.removeItem(at: folder)
            }
            try fileManager.moveItem(at: incoming, to: folder)
        } catch {
            Log.host.error("Could not pull the skill \(item.name, privacy: .public): \(Self.protocolError(error).message)")
            try? fileManager.removeItem(at: incoming)
            return false
        }
        setEntry(item, appSupport)
        Log.host.info("Pulled the skill \(item.name, privacy: .public)")
        return true
    }

    /// The local entry becomes the item's: `{modified: <item modified>, deleted: <item deleted>}`; the index is written.
    private func setEntry(_ item: SkillManifest, _ appSupport: AppSupport) {
        var index = SkillsIndex.load(from: indexURL(appSupport))
        _ = index.scan(skillsFolder: appSupport.skillsFolder, now: Date())
        index.entries[item.name] = SkillsIndexEntry(modified: SkillsIndex.truncated(item.modified),
                                                   deleted: item.deleted)
        save(index, appSupport)
    }
}
#endif
