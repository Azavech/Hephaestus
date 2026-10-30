import CryptoKit
import Foundation

/// The docs hash of docs/forge/generation.md.
public enum DocsHash {
    /// A documentation file: its path from the repository root ("docs/forge/ci.md") and its bytes.
    public struct File: Sendable {
        public var path: String
        public var content: Data
        public init(path: String, content: Data) {
            self.path = path
            self.content = content
        }
    }

    /// The docs hash of the given files. Files named .DS_Store are left out.
    public static func compute(_ files: [File]) -> String {
        let kept = files.filter { !isExcluded($0.path) }
        let sorted = kept.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        var lines = Data()
        for file in sorted {
            lines.append(Data("\(hex(SHA256.hash(data: file.content)))  \(file.path)\n".utf8))
        }
        return hex(SHA256.hash(data: lines))
    }

    /// The docs hash of the docs/ folder of a working tree. Throws when docs/ is not a folder.
    public static func compute(repositoryRoot: URL) throws -> String {
        let docs = repositoryRoot.appendingPathComponent("docs", isDirectory: true).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: docs.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: docs.path])
        }
        let base = docs.pathComponents.count
        var files: [File] = []
        if let enumerator = FileManager.default.enumerator(at: docs, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(base).joined(separator: "/")
                files.append(File(path: "docs/" + relative, content: try Data(contentsOf: url)))
            }
        }
        return compute(files)
    }

    /// True for a path whose last component is .DS_Store.
    public static func isExcluded(_ path: String) -> Bool {
        path.split(separator: "/").last == ".DS_Store"
    }

    /// The docs hash the running app was generated from: the bundled App/DocsHash.txt, trimmed,
    /// or "unknown" when the resource is missing or empty.
    public static let embedded: String = {
        guard let url = Bundle.main.url(forResource: "DocsHash", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "unknown" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }()

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
