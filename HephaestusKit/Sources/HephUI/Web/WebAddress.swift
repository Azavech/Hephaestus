import Foundation

/// Turns what was typed in the address field into the URL to load (docs/ui/web.md, "Address field").
public enum WebAddress {
    /// The URL to load: an address, or a DuckDuckGo search of the input; nil for an empty input.
    public static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains(where: { $0.isWhitespace }) {
            return search(text)
        }
        let lowercased = text.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return URL(string: text) ?? search(text)
        }
        if hasSchemeWithSlashes(text) {
            return search(text)
        }
        let host = hostName(of: text).lowercased()
        if host == "localhost" || isIPv4Address(host) || host.hasSuffix(".local") {
            return URL(string: "http://" + text) ?? search(text)
        }
        if isDomainName(host) {
            return URL(string: "https://" + text) ?? search(text)
        }
        return search(text)
    }

    /// `https://duckduckgo.com/?q=<text>`, with every `+` of the query encoded as `%2B`.
    private static func search(_ text: String) -> URL? {
        guard var components = URLComponents(string: "https://duckduckgo.com/") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// `^[A-Za-z][A-Za-z0-9+.-]*://`
    private static func hasSchemeWithSlashes(_ text: String) -> Bool {
        var scalars = Substring(text).unicodeScalars[...]
        guard let first = scalars.first, isASCIILetter(first) else { return false }
        scalars = scalars.dropFirst()
        while let scalar = scalars.first {
            if scalar == ":" {
                return scalars.dropFirst().starts(with: "//".unicodeScalars)
            }
            guard isASCIILetter(scalar) || ("0"..."9").contains(scalar) || scalar == "+" || scalar == "."
                || scalar == "-" else { return false }
            scalars = scalars.dropFirst()
        }
        return false
    }

    /// The text up to the first `/`, `?` or `#`, without a final `:<digits>` port.
    private static func hostName(of text: String) -> String {
        var host = Substring(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        if let colon = host.lastIndex(of: ":") {
            let port = host[host.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) {
                host = host[..<colon]
            }
        }
        return String(host)
    }

    /// Four dot-separated numbers from 0 to 255.
    private static func isIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else {
                return false
            }
            return value <= 255
        }
    }

    /// At least two dot-separated labels, each non-empty and made of letters, digits and `-`; the last label is made
    /// of at least 2 letters.
    private static func isDomainName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last else { return false }
        let labelsAreValid = labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || ($0.isASCII && $0.isNumber) || $0 == "-" }
        }
        return labelsAreValid && last.count >= 2 && last.allSatisfy(\.isLetter)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
    }
}
