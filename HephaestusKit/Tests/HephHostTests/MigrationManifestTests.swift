#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// The manifest, its checksums, the destination's verification and the transcript entries (docs/devices/migration.md,
/// "Manifest", "migration.commit").
final class MigrationManifestTests: XCTestCase {
    private let fileDate = Date(timeIntervalSince1970: 1_790_000_000.25)
    private let folderDate = Date(timeIntervalSince1970: 1_790_000_100.5)

    /// A project with a file, a folder, a symbolic link, `.git/HEAD`, `.build/x`, `DerivedData/y`, `node_modules/z` and
    /// `.DS_Store`.
    private func makeProject() throws -> URL {
        let root = try makeTemporaryDirectory().appendingPathComponent("Fixture", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("folder", isDirectory: true),
                                        withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try Data("inside\n".utf8).write(to: root.appendingPathComponent("folder/inside.txt"))
        try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("link").path,
                                           withDestinationPath: "file.txt")
        try fileManager.createDirectory(at: root.appendingPathComponent(".git", isDirectory: true),
                                        withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        for (folder, file) in [(".build", "x"), ("DerivedData", "y"), ("node_modules", "z")] {
            try fileManager.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true),
                                            withIntermediateDirectories: true)
            try Data(file.utf8).write(to: root.appendingPathComponent(folder + "/" + file))
        }
        try Data("ds".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try fileManager.setAttributes([.posixPermissions: 0o640, .modificationDate: fileDate],
                                      ofItemAtPath: root.appendingPathComponent("file.txt").path)
        try fileManager.setAttributes([.posixPermissions: 0o750, .modificationDate: folderDate],
                                      ofItemAtPath: root.appendingPathComponent("folder").path)
        return root
    }

    func testManifest() throws {
        let root = try makeProject()
        let entries = try ManifestBuilder.entries(of: root, prefix: "")
        let paths = entries.map(\.path)
        XCTAssertEqual(Set(paths), ["file.txt", "folder", "folder/inside.txt", "link", ".git", ".git/HEAD"])
        XCTAssertEqual(paths.count, 6)
        for excluded in [".build", "DerivedData", "node_modules", ".DS_Store"] {
            XCTAssertFalse(paths.contains { $0 == excluded || $0.hasPrefix(excluded + "/") }, excluded)
        }
        // Each folder comes before its content.
        XCTAssertLessThan(try XCTUnwrap(paths.firstIndex(of: "folder")),
                          try XCTUnwrap(paths.firstIndex(of: "folder/inside.txt")))
        XCTAssertLessThan(try XCTUnwrap(paths.firstIndex(of: ".git")), try XCTUnwrap(paths.firstIndex(of: ".git/HEAD")))

        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let file = try XCTUnwrap(byPath["file.txt"])
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.size, 6)
        XCTAssertNotNil(file.sha256)
        XCTAssertNil(file.symlinkTarget)
        XCTAssertEqual(file.mode, 0o640)
        XCTAssertEqual(file.modified.timeIntervalSince1970, fileDate.timeIntervalSince1970, accuracy: 0.001)

        let folder = try XCTUnwrap(byPath["folder"])
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.size, 0)
        XCTAssertNil(folder.sha256)
        XCTAssertNil(folder.symlinkTarget)
        XCTAssertEqual(folder.mode, 0o750)
        XCTAssertEqual(folder.modified.timeIntervalSince1970, folderDate.timeIntervalSince1970, accuracy: 0.001)

        let head = try XCTUnwrap(byPath[".git/HEAD"])
        XCTAssertFalse(head.isDirectory)
        XCTAssertEqual(head.size, 21)

        let link = try XCTUnwrap(byPath["link"])
        XCTAssertFalse(link.isDirectory)
        XCTAssertEqual(link.symlinkTarget, "file.txt")
        XCTAssertEqual(link.size, 0)
        XCTAssertNil(link.sha256)

        // Every mode and date is the item's own (lstat).
        for entry in entries {
            var info = stat()
            XCTAssertEqual(lstat(root.appendingPathComponent(entry.path).path, &info), 0, entry.path)
            XCTAssertEqual(entry.mode, Int(info.st_mode & 0o7777), entry.path)
            let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
            XCTAssertEqual(entry.modified.timeIntervalSince1970, modified, accuracy: 0.000_001, entry.path)
        }

        // With a prefix, every path starts with it.
        let prefixed = try ManifestBuilder.entries(of: root, prefix: "-Users-user-Projects-Fixture")
        XCTAssertEqual(prefixed.map(\.path), paths.map { "-Users-user-Projects-Fixture/" + $0 })
    }

    func testChecksums() throws {
        let root = try makeProject()
        // A file of several 1 MiB blocks.
        var big = Data(count: 2_621_440)
        for index in big.indices {
            big[index] = UInt8(truncatingIfNeeded: index &* 31)
        }
        try big.write(to: root.appendingPathComponent("folder/big.bin"))
        let files = try ManifestBuilder.entries(of: root, prefix: "")
            .filter { !$0.isDirectory && $0.symlinkTarget == nil }
        XCTAssertEqual(Set(files.map(\.path)), ["file.txt", "folder/inside.txt", "folder/big.bin", ".git/HEAD"])
        for entry in files {
            let data = try Data(contentsOf: root.appendingPathComponent(entry.path))
            XCTAssertEqual(entry.size, data.count, entry.path)
            XCTAssertEqual(entry.sha256, Self.hex(SHA256.hash(data: data)), entry.path)
        }
    }

    func testVerification() throws {
        let content = Data("The content of the manifest.\n".utf8)
        let entry = ManifestEntry(path: "notes/a.txt", isDirectory: false, size: content.count,
                                  sha256: Self.hex(SHA256.hash(data: content)), mode: 0o644, modified: fileDate)
        let folder = ManifestEntry(path: "notes", isDirectory: true, size: 0, mode: 0o755, modified: folderDate)
        let project = ProjectSummary(id: "HEPH", name: "Hephaestus", deviceID: UUID(),
                                     rootPath: "/Users/user/Projects/Fixture", children: [], migrating: true,
                                     pendingPermissionCount: 0)
        let params = MigrationBeginParams(migrationID: UUID(), project: project, folderName: "Fixture",
                                          manifest: [folder, entry], claudeFiles: [])
        let transcriptRoots = try MigrationReceiver.checkLists(params)

        func receiver() throws -> MigrationReceiver {
            let base = try makeTemporaryDirectory()
            let destination = base.appendingPathComponent("Fixture", isDirectory: true)
            let staging = base.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            return MigrationReceiver(params: params, sourceDeviceID: UUID(), connectionID: nil,
                                     transcriptRoots: transcriptRoots, destination: destination, staging: staging,
                                     configDirectory: base.appendingPathComponent("claude", isDirectory: true))
        }

        // Bytes that differ from the manifest entry, with its size: checksum mismatch.
        let changed = try receiver()
        var other = content
        other[0] = UInt8(ascii: "t")
        try changed.receive(MigrationChunkParams(migrationID: params.migrationID, path: entry.path, offset: 0,
                                                 data: other, transcript: false))
        XCTAssertThrowsError(try changed.verify()) { error in
            XCTAssertEqual(error as? ProtocolError, ProtocolError(.badRequest, "Checksum mismatch for notes/a.txt."))
        }

        // Fewer bytes than the entry's size: missing data.
        let partial = try receiver()
        XCTAssertThrowsError(try partial.verify()) { error in
            XCTAssertEqual(error as? ProtocolError, ProtocolError(.badRequest, "Missing data for notes/a.txt."))
        }

        // The bytes of the manifest pass, and are written at their path.
        let intact = try receiver()
        try intact.receive(MigrationChunkParams(migrationID: params.migrationID, path: entry.path, offset: 0,
                                                data: content, transcript: false))
        XCTAssertNoThrow(try intact.verify())
        XCTAssertEqual(try Data(contentsOf: intact.destination.appendingPathComponent(entry.path)), content)

        // A file of size 0 must have the SHA-256 of empty data.
        let empty = ManifestEntry(path: "empty.txt", isDirectory: false, size: 0,
                                  sha256: Self.hex(SHA256.hash(data: content)), mode: 0o644, modified: fileDate)
        let emptyParams = MigrationBeginParams(migrationID: UUID(), project: project, folderName: "Fixture",
                                               manifest: [empty], claudeFiles: [])
        let base = try makeTemporaryDirectory()
        let emptyReceiver = MigrationReceiver(params: emptyParams, sourceDeviceID: UUID(), connectionID: nil,
                                              transcriptRoots: try MigrationReceiver.checkLists(emptyParams),
                                              destination: base.appendingPathComponent("Fixture", isDirectory: true),
                                              staging: base.appendingPathComponent("staging", isDirectory: true),
                                              configDirectory: base.appendingPathComponent("claude", isDirectory: true))
        XCTAssertThrowsError(try emptyReceiver.verify()) { error in
            XCTAssertEqual(error as? ProtocolError, ProtocolError(.badRequest, "Checksum mismatch for empty.txt."))
        }
    }

    func testTranscripts() throws {
        let base = try makeTemporaryDirectory()
        let project = base.appendingPathComponent("Atlas", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let configDirectory = base.appendingPathComponent("claude", isDirectory: true)
        let name = ClaudePathEncoding.folderName(for: try XCTUnwrap(ClaudePathEncoding.canonicalPath(project.path)))
        let folder = configDirectory.appendingPathComponent("projects/" + name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = Data("{\"type\":\"user\"}\n".utf8)
        try transcript.write(to: folder.appendingPathComponent("s.jsonl"))

        let result = try ManifestBuilder.claudeFiles(projectRoots: [project.path], configDirectory: configDirectory)
        XCTAssertEqual(result.folders.map(\.lastPathComponent), [name])
        XCTAssertEqual(result.entries.map(\.path), [name, name + "/s.jsonl"])
        for entry in result.entries {
            XCTAssertTrue(entry.path == name || entry.path.hasPrefix(name + "/"), entry.path)
        }
        let folderEntry = try XCTUnwrap(result.entries.first)
        XCTAssertTrue(folderEntry.isDirectory)
        let file = try XCTUnwrap(result.entries.last)
        XCTAssertEqual(file.size, transcript.count)
        XCTAssertEqual(file.sha256, Self.hex(SHA256.hash(data: transcript)))

        // A root without a transcript folder adds nothing; a folder is included once.
        let other = base.appendingPathComponent("API", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let again = try ManifestBuilder.claudeFiles(projectRoots: [project.path, other.path, project.path],
                                                    configDirectory: configDirectory)
        XCTAssertEqual(again.entries.map(\.path), [name, name + "/s.jsonl"])
        XCTAssertEqual(again.folders.count, 1)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
