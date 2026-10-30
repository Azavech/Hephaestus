import Foundation

/// A task id, `<projectID>-<n>` (docs/data/task-yml.md, "Task id"): pattern `^[A-Z]{2,8}-[1-9][0-9]*$`, for example
/// `HEPH-12`, with `n` from 1 to `Int.max`. Ids are compared as `(projectID, number)`: `HEPH-9` comes before `HEPH-10`.
public struct TaskID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let projectID: String
    public let number: Int

    /// projectID must be a valid identifier and number ≥ 1 (precondition).
    public init(projectID: String, number: Int) {
        precondition(ProjectIdentifier.isValid(projectID) && number >= 1, "Invalid task id \(projectID)-\(number)")
        self.projectID = projectID
        self.number = number
    }

    /// Trims, maps ASCII a–z to A–Z, then matches ^[A-Z]{2,8}-[1-9][0-9]*$.
    public init?(_ text: String) {
        self.init(exactly: ProjectIdentifier.normalize(text))
    }

    /// Matches "<id>.yml" exactly.
    public init?(fileName: String) {
        let suffix = ".yml"
        guard fileName.hasSuffix(suffix) else { return nil }
        self.init(exactly: String(fileName.dropLast(suffix.count)))
    }

    /// "HEPH-12"
    public var description: String { "\(projectID)-\(number)" }

    /// "HEPH-12.yml"
    public var fileName: String { description + ".yml" }

    public static func < (lhs: TaskID, rhs: TaskID) -> Bool {
        (lhs.projectID, lhs.number) < (rhs.projectID, rhs.number)
    }

    /// Coded as one string, "HEPH-12".
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = TaskID(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid task id \(text).")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Matches ^[A-Z]{2,8}-[1-9][0-9]*$ without any mapping; a number above Int.max is not a task id.
    private init?(exactly text: String) {
        guard let dash = text.firstIndex(of: "-") else { return nil }
        let projectID = String(text[..<dash])
        let digits = text[text.index(after: dash)...]
        guard ProjectIdentifier.isValid(projectID),
              let first = digits.unicodeScalars.first, ("1"..."9").contains(first),
              digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let number = Int(digits)
        else { return nil }
        self.projectID = projectID
        self.number = number
    }
}
