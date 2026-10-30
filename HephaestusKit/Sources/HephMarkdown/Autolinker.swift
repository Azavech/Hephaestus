import Foundation

/// Finds bare URLs in the text of `Text` nodes outside links: swift-markdown does not enable the GitHub autolink
/// extension.
enum Autolinker {
    /// The URLs of `scalars`, as offsets: `http://` or `https://` at the start of the text or after a character that
    /// is neither a letter nor a digit, up to the first white space or `<`. Trailing `.`, `,`, `:`, `;`, `!`, `?`,
    /// `'`, `"` are left out, and so is a trailing `)` when the URL before it has no unmatched `(` (no more `(` than
    /// `)`), until the URL ends with none of them.
    static func urlRanges(in scalars: [Unicode.Scalar]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "h",
                  index == 0 || !MarkdownSlug.isLetterOrDigit(scalars[index - 1]),
                  let schemeLength = schemeLength(in: scalars, at: index) else {
                index += 1
                continue
            }
            var end = index + schemeLength
            while end < scalars.count, !scalars[end].properties.isWhitespace, scalars[end] != "<" { end += 1 }
            let scanEnd = end
            end = trimmedEnd(scalars, start: index, end: end)
            ranges.append(index..<end)
            index = max(scanEnd, index + 1)
        }
        return ranges
    }

    /// The length of `http://` or `https://` at `index`, nil when neither is there.
    private static func schemeLength(in scalars: [Unicode.Scalar], at index: Int) -> Int? {
        for scheme in schemes where index + scheme.count <= scalars.count {
            if scalars[index..<(index + scheme.count)].elementsEqual(scheme) { return scheme.count }
        }
        return nil
    }

    /// Leaves out trailing punctuation, and a trailing `)` that matches no `(` of the URL.
    private static func trimmedEnd(_ scalars: [Unicode.Scalar], start: Int, end: Int) -> Int {
        var end = end
        while end > start {
            let last = scalars[end - 1]
            if trailingPunctuation.contains(last) {
                end -= 1
                continue
            }
            if last == ")" {
                let url = scalars[start..<(end - 1)]
                let opening = url.filter { $0 == "(" }.count
                let closing = url.filter { $0 == ")" }.count
                if opening <= closing {
                    end -= 1
                    continue
                }
            }
            break
        }
        return end
    }

    private static let schemes: [[Unicode.Scalar]] = [Array("https://".unicodeScalars), Array("http://".unicodeScalars)]
    private static let trailingPunctuation: Set<Unicode.Scalar> = [".", ",", ":", ";", "!", "?", "'", "\""]
}
