import Foundation

/// The folders where the Claude CLI keeps the transcripts of its sessions (docs/devices/migration.md, "Claude folder
/// names").
public enum ClaudePathEncoding {
    /// The folder name the Claude CLI uses under <config>/projects/ for the working directory `path`.
    public static func folderName(for path: String) -> String {
        let dash = UInt16(UInt8(ascii: "-"))
        let units = path.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return unit   // 0-9, A-Z, a-z
            default: return dash
            }
        }
        // Every unit of `units` is ASCII, so one unit is one character.
        let encoded = String(decoding: units, as: UTF16.self)
        guard units.count > maxLength else { return encoded }
        var hash: Int32 = 0
        for unit in path.utf16 {
            hash = (hash &<< 5) &- hash &+ Int32(unit)
        }
        let magnitude = Int64(hash).magnitude
        return String(decoding: units.prefix(maxLength), as: UTF16.self) + "-" + String(magnitude, radix: 36)
    }

    /// realpath(3) of an existing path; nil when it does not exist.
    public static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// CLAUDE_CONFIG_DIR of `environment` when set and not empty, else <home>/.claude.
    public static func configDirectory(environment: [String: String], home: URL) -> URL {
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// <configDirectory>/projects/<folderName(for: canonicalPath(projectRoot) ?? projectRoot)>
    public static func transcriptsFolder(projectRoot: String, configDirectory: URL) -> URL {
        configDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(folderName(for: canonicalPath(projectRoot) ?? projectRoot), isDirectory: true)
    }

    /// Names longer than this are cut and followed by a hash.
    private static let maxLength = 200
}
