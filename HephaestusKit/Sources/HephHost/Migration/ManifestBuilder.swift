#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import HephCore

/// The lists of a migration (docs/devices/migration.md, "Manifest"): the files, folders and symbolic links of a folder
/// tree, and the Claude CLI transcripts of a project tree.
enum ManifestBuilder {
    /// Left out with everything inside them, at any depth (case-sensitive).
    static let excludedNames: Set<String> = [".build", "DerivedData", "node_modules", ".DS_Store"]
    /// Files are hashed in blocks of 1 MiB.
    static let hashBlockSize = 1_048_576

    /// Lists the tree under `root`, depth-first, each folder before its content, hidden files included, symbolic links
    /// not followed. Each path is relative to `root`, prefixed with `prefix` and `/` when `prefix` is not empty; the
    /// root itself has no entry. An enumeration error or an item that cannot be read fails the walk.
    static func entries(of root: URL, prefix: String) throws -> [ManifestEntry] {
        let failure = EnumerationFailure()
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [],
            errorHandler: { url, error in
                failure.record(url, error)
                return false
            })
        else {
            throw cannotRead(prefix.isEmpty ? root.lastPathComponent : prefix, "the folder cannot be listed")
        }
        var result: [ManifestEntry] = []
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            if excludedNames.contains(url.lastPathComponent) {
                // skipDescendants() applies to the last folder returned, so it is called for a folder only; the
                // enumerator never enters a symbolic link.
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            // The path relative to `root` is made of the last `level` components of the item's URL.
            let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            let path = prefix.isEmpty ? relative : prefix + "/" + relative
            guard let entry = try entry(at: url, path: path) else { continue }
            result.append(entry)
        }
        if let (url, error) = failure.value {
            // The enumerator reports realpath(3) forms (`/private/var/…` for `/var/…`).
            let realRoot = ClaudePathEncoding.canonicalPath(root.path) ?? root.path
            let relative = ProjectRegistry.relativePath(of: url.path, inside: root.path)
                ?? ProjectRegistry.relativePath(of: url.path, inside: realRoot)
                ?? url.lastPathComponent
            let path = prefix.isEmpty ? relative : (relative.isEmpty ? prefix : prefix + "/" + relative)
            throw cannotRead(path, error.localizedDescription)
        }
        return result
    }

    /// The Claude CLI transcript folders of a project tree (docs/devices/migration.md, "Claude transcripts"): for each
    /// root, in the given order (top-level first, then the sub projects depth-first in `subprojects` order), the folder
    /// `<configDirectory>/projects/<folderName(for: <canonical root>)>`. A folder that does not exist is skipped, a
    /// folder already included is not included again. `entries` holds, for each included folder, an entry for the
    /// folder itself (`path` = its name) and `entries(of: <folder>, prefix: <its name>)`; `folders` the folders.
    static func claudeFiles(projectRoots: [String], configDirectory: URL) throws
        -> (entries: [ManifestEntry], folders: [URL]) {
        let projectsFolder = configDirectory.appendingPathComponent("projects", isDirectory: true)
        var names: Set<String> = []
        var entries: [ManifestEntry] = []
        var folders: [URL] = []
        for root in projectRoots {
            let name = ClaudePathEncoding.folderName(for: ClaudePathEncoding.canonicalPath(root) ?? root)
            guard !names.contains(name) else { continue }
            let folder = projectsFolder.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            guard let folderEntry = try entry(at: folder, path: name) else { continue }
            names.insert(name)
            entries.append(folderEntry)
            entries.append(contentsOf: try Self.entries(of: folder, prefix: name))
            folders.append(folder)
        }
        return (entries, folders)
    }

    /// The entry of one item examined with `lstat`: a file (with its size and SHA-256), a folder or a symbolic link
    /// (with its target, unchanged); nil, logged, for anything else (sockets, FIFOs, devices).
    static func entry(at url: URL, path: String) throws -> ManifestEntry? {
        var info = stat()
        var failure: Int32 = 0
        let status = url.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            let result = lstat(representation, &info)
            failure = result == 0 ? 0 : errno
            return result
        }
        guard status == 0 else {
            throw cannotRead(path, failure == 0 ? "invalid path" : String(cString: strerror(failure)))
        }
        let mode = Int(info.st_mode & 0o7777)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return ManifestEntry(path: path, isDirectory: false, size: Int(info.st_size),
                                 sha256: try sha256(of: url, path: path), mode: mode, modified: modified)
        case S_IFDIR:
            return ManifestEntry(path: path, isDirectory: true, size: 0, mode: mode, modified: modified)
        case S_IFLNK:
            let target: String
            do {
                target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            } catch {
                throw cannotRead(path, error.localizedDescription)
            }
            return ManifestEntry(path: path, isDirectory: false, size: 0, mode: mode, modified: modified,
                                 symlinkTarget: target)
        default:
            Log.host.info("Migration manifest: skipped \(path), which is not a file, a folder or a symbolic link")
            return nil
        }
    }

    /// Lowercase hexadecimal of a digest.
    static func hex(_ digest: SHA256.Digest) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        characters.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    // MARK: - Private

    /// The SHA-256 of the content of a file, read in blocks of 1 MiB.
    private static func sha256(of url: URL, path: String) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw cannotRead(path, error.localizedDescription)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let block = try handle.read(upToCount: hashBlockSize), !block.isEmpty {
                hasher.update(data: block)
            }
        } catch {
            throw cannotRead(path, error.localizedDescription)
        }
        return hex(hasher.finalize())
    }

    /// "Cannot read <path>: <error>".
    private static func cannotRead(_ path: String, _ reason: String) -> ProtocolError {
        ProtocolError(.internal, "Cannot read \(path): \(reason)")
    }

    /// The first enumeration error, kept by the enumerator's error handler; the walk is local to one call.
    private final class EnumerationFailure {
        private(set) var value: (URL, any Error)?

        func record(_ url: URL, _ error: any Error) {
            if value == nil {
                value = (url, error)
            }
        }
    }
}
#endif
