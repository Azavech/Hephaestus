#if os(macOS)
import Foundation
import HephCore

/// Path safety for project paths (docs/services/files.md §2): a project path is checked, then resolved on the
/// project's realRoot with realpath(3), and must stay inside it.
struct PathResolver {
    let root: URL                             // the project's realRoot: realpath(3) of the project root

    /// Checks a project path (rules below) and returns its components; [] for the root "". Throws badRequest.
    static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty else { return [] }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.contains("\u{0}"), !path.hasPrefix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw ProtocolError(.badRequest, "Invalid path \(path).")
        }
        return components
    }

    /// The absolute URL of `path`. With `followLast`, a symlink in the last component is followed; without it, the
    /// last component is not resolved (rename and delete act on a link itself). Throws badRequest.
    func resolve(_ path: String, followLast: Bool = true) throws -> URL {
        let components = try Self.components(path)
        let resolvedCount = followLast ? components.count : max(components.count - 1, 0)
        var resolved = root.path
        var index = resolvedCount
        // The deepest existing component of the part to resolve, with realpath(3); the rest as written.
        while index >= 0 {
            let candidate = ([root.path] + components[0..<index]).joined(separator: "/")
            if let real = ClaudePathEncoding.canonicalPath(candidate) {
                resolved = ([real] + components[index..<resolvedCount]).joined(separator: "/")
                break
            }
            index -= 1
        }
        if index < 0 {
            resolved = ([root.path] + components[0..<resolvedCount]).joined(separator: "/")
        }
        if !followLast, let last = components.last {
            resolved += "/" + last
        }
        guard resolved == root.path || resolved.hasPrefix(root.path + "/") else {
            throw ProtocolError(.badRequest, "\(path) is outside the project.")
        }
        return URL(fileURLWithPath: resolved, isDirectory: false)
    }

    /// The project path of an absolute URL inside root, "" for root itself; nil when outside.
    func projectPath(of url: URL) -> String? {
        let path = url.path
        if path == root.path {
            return ""
        }
        guard path.hasPrefix(root.path + "/") else { return nil }
        return String(path.dropFirst(root.path.count + 1))
    }
}
#endif
