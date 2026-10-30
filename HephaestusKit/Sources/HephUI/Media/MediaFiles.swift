import CryptoKit
import Foundation

/// Files written for data held in memory, which Share needs (the full-screen viewer) (docs/ui/media.md, "Quick Look
/// files"). Quick Look opens the downloaded files of the attachment cache directly.
@MainActor
enum MediaFiles {
    /// Whether the root of this process was prepared: its first use deletes the files of earlier launches.
    private static var isRootPrepared = false

    /// `<temporary directory>/Hephaestus-Media/`
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Hephaestus-Media", isDirectory: true)
    }

    /// The file holding `data` for `key`: written atomically when it does not exist yet. The same key gives the same
    /// file for the life of the process.
    static func file(for data: Data, fileName: String, key: String) throws -> URL {
        try prepareRoot()
        let url = location(key: key, fileName: fileName)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    /// The file of `key` and `fileName` when it exists.
    static func existingFile(key: String, fileName: String) -> URL? {
        try? prepareRoot()
        let url = location(key: key, fileName: fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// At the first use in a process: deletes the root with its content, then creates it.
    private static func prepareRoot() throws {
        guard !isRootPrepared else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        isRootPrepared = true
    }

    /// The root plus the first 16 hex characters of the SHA-256 of `key`, then `fileName` with `/` and `:` replaced by
    /// `-` (`file` when empty).
    private static func location(key: String, fileName: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let folder = String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
        var name = fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.isEmpty {
            name = "file"
        }
        return root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name)
    }
}
