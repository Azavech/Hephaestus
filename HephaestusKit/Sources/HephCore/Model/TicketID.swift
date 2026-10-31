import Foundation

/// A ticket id, `<projectID>-<n>`, or `<projectID>-F<n>` for a feedback ticket (docs/data/ticket-yml.md, "Ticket id"):
/// pattern `^[A-Z]{2,8}-F?[1-9][0-9]*$`, for example `HEPH-12` or `HEPH-F3`, with `n` from 1 to `Int.max`. Ids are
/// compared as `(projectID, feedback, number)`, tickets before feedback tickets: `HEPH-9` comes before `HEPH-10`, which
/// comes before `HEPH-F1`.
public struct TicketID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let projectID: String
    public let number: Int
    /// true for a feedback ticket id, <projectID>-F<n>.
    public let feedback: Bool

    /// projectID must be a valid identifier and number ≥ 1 (precondition).
    public init(projectID: String, number: Int, feedback: Bool = false) {
        precondition(ProjectIdentifier.isValid(projectID) && number >= 1,
                     "Invalid ticket id \(projectID)-\(feedback ? "F" : "")\(number)")
        self.projectID = projectID
        self.number = number
        self.feedback = feedback
    }

    /// Trims, maps ASCII a–z to A–Z, then matches ^[A-Z]{2,8}-F?[1-9][0-9]*$.
    public init?(_ text: String) {
        self.init(exactly: ProjectIdentifier.normalize(text))
    }

    /// Matches "<id>.yml" exactly.
    public init?(fileName: String) {
        let suffix = ".yml"
        guard fileName.hasSuffix(suffix) else { return nil }
        self.init(exactly: String(fileName.dropLast(suffix.count)))
    }

    /// "HEPH-12", "HEPH-F3"
    public var description: String { "\(projectID)-\(feedback ? "F" : "")\(number)" }

    /// "HEPH-12.yml", "HEPH-F3.yml"
    public var fileName: String { description + ".yml" }

    /// Ordered as (projectID, feedback, number), false before true.
    public static func < (lhs: TicketID, rhs: TicketID) -> Bool {
        if lhs.projectID != rhs.projectID { return lhs.projectID < rhs.projectID }
        if lhs.feedback != rhs.feedback { return !lhs.feedback }
        return lhs.number < rhs.number
    }

    /// Coded as one string, "HEPH-12".
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = TicketID(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ticket id \(text).")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Matches ^[A-Z]{2,8}-F?[1-9][0-9]*$ without any mapping; a number above Int.max is not a ticket id.
    private init?(exactly text: String) {
        guard let dash = text.firstIndex(of: "-") else { return nil }
        let projectID = String(text[..<dash])
        var digits = text[text.index(after: dash)...]
        let feedback = digits.hasPrefix("F")
        if feedback {
            digits = digits.dropFirst()
        }
        guard ProjectIdentifier.isValid(projectID),
              let first = digits.unicodeScalars.first, ("1"..."9").contains(first),
              digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let number = Int(digits)
        else { return nil }
        self.projectID = projectID
        self.number = number
        self.feedback = feedback
    }
}
