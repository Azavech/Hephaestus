#if os(macOS)
import Foundation
import HephCore

/// The session plugin folder (docs/claude/skills.md §6):
///
///     <AppSupport.sessionPluginsFolder>/<session id>/
///       hephaestus/
///         .claude-plugin/plugin.json
///         skills/<name>  →  <AppSupport.skillsFolder>/<name>
extension SkillsService {
    /// The exact bytes of `plugin.json` (no trailing newline).
    static let pluginManifest = #"{"name":"hephaestus","version":"1.0.0","description":"Skills managed by Hephaestus"}"#

    /// `enabled` = project.yml skills ([] = every skill). Returns the `hephaestus` folder.
    public func buildPluginFolder(sessionID: UUID, enabled: [String]) throws -> URL {
        let appSupport = try library()
        let index = scan()
        let fileManager = FileManager.default
        let sessionFolder = appSupport.sessionPluginsFolder
            .appendingPathComponent(SessionFile.fileStem(sessionID), isDirectory: true)
        let pluginFolder = sessionFolder.appendingPathComponent("hephaestus", isDirectory: true)
        let skillsLinks = pluginFolder.appendingPathComponent("skills", isDirectory: true)
        let manifestFolder = pluginFolder.appendingPathComponent(".claude-plugin", isDirectory: true)

        // The session's skills: the enabled skills that exist in the library and have no problem.
        let candidates: [String]
        if enabled.isEmpty {
            candidates = index.entries.filter { !$0.value.deleted }.keys.sorted()
        } else {
            var seen = Set<String>()
            candidates = enabled.filter { SkillName.isValid($0) && seen.insert($0).inserted }
        }
        let sessionSkills = candidates.filter { name in
            let folder = appSupport.skillsFolder.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return false
            }
            return validation(of: name, in: folder).problem == nil
        }

        do {
            // 1. A fresh folder.
            if Self.exists(sessionFolder) {
                try fileManager.removeItem(at: sessionFolder)
            }
            try fileManager.createDirectory(at: manifestFolder, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: skillsLinks, withIntermediateDirectories: true)
            // 2. plugin.json.
            try Data(Self.pluginManifest.utf8).write(to: manifestFolder.appendingPathComponent("plugin.json",
                                                                                            isDirectory: false))
            // 3. One link per session skill, to its library folder.
            for name in sessionSkills {
                try fileManager.createSymbolicLink(
                    atPath: skillsLinks.appendingPathComponent(name, isDirectory: false).path,
                    withDestinationPath: appSupport.skillsFolder.appendingPathComponent(name, isDirectory: true).path)
            }
        } catch {
            throw ProtocolError(.internal, error.localizedDescription)
        }
        Log.host.debug("Built the plugin folder of session \(sessionID.uuidString, privacy: .public) with \(sessionSkills.count, privacy: .public) skills")
        // 4.
        return pluginFolder
    }

    /// Removes `SessionPlugins/<session id>/` with everything in it (the plugin folder and the prompt file).
    public func removePluginFolder(sessionID: UUID) {
        guard let appSupport else { return }
        let sessionFolder = appSupport.sessionPluginsFolder
            .appendingPathComponent(SessionFile.fileStem(sessionID), isDirectory: true)
        guard Self.exists(sessionFolder) else { return }
        do {
            try FileManager.default.removeItem(at: sessionFolder)
        } catch {
            Log.host.error("Could not remove the plugin folder of session \(sessionID.uuidString, privacy: .public): \(error.localizedDescription)")
        }
    }
}
#endif
