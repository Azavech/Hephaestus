import Foundation

/// Where a Markdown link or image points.
public enum MarkdownLinkTarget: Hashable, Sendable {
    /// `#slug`: a heading of the same document.
    case anchor(String)
    /// A project-relative path, with an optional heading slug.
    case project(path: String, anchor: String?)
    /// A URL with a scheme.
    case external(URL)

    /// The target of a link destination or an image source in a document of the project-relative folder `basePath`
    /// (`""` is the project root); nil when it does not resolve.
    public static func resolve(_ destination: String, basePath: String) -> MarkdownLinkTarget? {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return nil }
        if destination.hasPrefix("#") {
            let fragment = decoded(destination.dropFirst()).lowercased()
            return fragment.isEmpty ? nil : .anchor(fragment)
        }
        if hasScheme(destination) {
            return URL(string: destination).map { .external($0) }
        }
        var path = Substring(destination)
        var anchor: String?
        if let hash = path.firstIndex(of: "#") {
            let fragment = decoded(path[path.index(after: hash)...]).lowercased()
            anchor = fragment.isEmpty ? nil : fragment
            path = path[..<hash]
        }
        if let query = path.firstIndex(of: "?") {
            path = path[..<query]
        }
        let decodedPath = decoded(path)
        let base = decodedPath.hasPrefix("/") ? [] : basePath.split(separator: "/")
        var components: [Substring] = []
        for component in base + decodedPath.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return .project(path: components.joined(separator: "/"), anchor: anchor)
    }

    private static func decoded(_ text: Substring) -> String {
        let text = String(text)
        return text.removingPercentEncoding ?? text
    }

    /// `^[A-Za-z][A-Za-z0-9+.-]*:`
    private static func hasScheme(_ text: String) -> Bool {
        var scalars = text.unicodeScalars.makeIterator()
        guard let first = scalars.next(), isASCIILetter(first) else { return false }
        while let scalar = scalars.next() {
            if scalar == ":" { return true }
            guard isASCIILetter(scalar) || ("0"..."9").contains(scalar) || scalar == "+" || scalar == "."
                || scalar == "-" else { return false }
        }
        return false
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
    }
}
