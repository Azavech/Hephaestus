import Foundation

/// The `.id` of each heading view, for `ScrollViewReader.scrollTo`.
public struct MarkdownAnchor: Hashable, Sendable {
    public let slug: String

    public init(slug: String) {
        self.slug = slug
    }
}

/// Heading slugs.
enum MarkdownSlug {
    /// From a heading's plain text: lowercased; every character that is not a letter or a digit (Unicode), a space,
    /// `-` or `_` removed; each space replaced by `-`.
    static func slug(for text: String) -> String {
        var slug = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " {
                slug.append("-")
            } else if scalar == "-" || scalar == "_" || isLetterOrDigit(scalar) {
                slug.append(scalar)
            }
        }
        return String(slug)
    }

    /// A letter (general category L) or a decimal digit.
    static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
            return true
        default:
            return false
        }
    }

    /// Makes the slugs of one document unique, in document order: a repeated slug gets `-1`, then `-2`, … (the first
    /// one not used yet).
    struct Registry {
        private var used: Set<String> = []

        mutating func unique(_ slug: String) -> String {
            var candidate = slug
            var suffix = 0
            while used.contains(candidate) {
                suffix += 1
                candidate = "\(slug)-\(suffix)"
            }
            used.insert(candidate)
            return candidate
        }
    }
}
