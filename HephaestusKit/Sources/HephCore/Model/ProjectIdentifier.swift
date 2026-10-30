import Foundation

/// The project identifier: 2 to 8 letters A–Z, the `projectID` of the protocol (docs/data/project-yml.md,
/// "Identifier"). It is set at creation and never changes.
public enum ProjectIdentifier {
    /// Trims whitespace, maps ASCII a–z to A–Z. No other character is mapped: `ß` stays `ß`.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var scalars = String.UnicodeScalarView()
        for scalar in trimmed.unicodeScalars {
            if ("a"..."z").contains(scalar), let upper = Unicode.Scalar(scalar.value - 32) {
                scalars.append(upper)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// True when `value` matches ^[A-Z]{2,8}$.
    public static func isValid(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return (2...8).contains(scalars.count) && scalars.allSatisfy { ("A"..."Z").contains($0) }
    }

    /// normalize, then check; throws DataError.invalid("the identifier must be 2 to 8 letters A to Z").
    public static func validated(_ raw: String) throws -> String {
        let value = normalize(raw)
        guard isValid(value) else {
            throw DataError.invalid("the identifier must be 2 to 8 letters A to Z")
        }
        return value
    }
}
