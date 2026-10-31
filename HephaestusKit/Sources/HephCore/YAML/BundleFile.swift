import Foundation
import Yams

/// A bundle id, `<projectID>-B<n>` (docs/services/bundles.md, "Bundle id"): pattern `^[A-Z]{2,8}-B[1-9][0-9]*$`, for
/// example `HEPH-B3`, with `n` from 1 to `Int.max`. It never matches the ticket id pattern. Ids are compared as
/// `(projectID, number)`.
public struct BundleID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let projectID: String
    public let number: Int

    /// projectID must be a valid identifier and number ≥ 1 (precondition).
    public init(projectID: String, number: Int) {
        precondition(ProjectIdentifier.isValid(projectID) && number >= 1, "Invalid bundle id \(projectID)-B\(number)")
        self.projectID = projectID
        self.number = number
    }

    /// Trims, maps ASCII a–z to A–Z, then matches ^[A-Z]{2,8}-B[1-9][0-9]*$.
    public init?(_ text: String) {
        self.init(exactly: ProjectIdentifier.normalize(text))
    }

    /// Matches "<id>.yml" exactly.
    public init?(fileName: String) {
        let suffix = ".yml"
        guard fileName.hasSuffix(suffix) else { return nil }
        self.init(exactly: String(fileName.dropLast(suffix.count)))
    }

    /// "HEPH-B3"
    public var description: String { "\(projectID)-B\(number)" }

    /// "HEPH-B3.yml"
    public var fileName: String { description + ".yml" }

    public static func < (lhs: BundleID, rhs: BundleID) -> Bool {
        (lhs.projectID, lhs.number) < (rhs.projectID, rhs.number)
    }

    /// Coded as one string, "HEPH-B3".
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = BundleID(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid bundle id \(text).")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Matches ^[A-Z]{2,8}-B[1-9][0-9]*$ without any mapping; a number above Int.max is not a bundle id.
    private init?(exactly text: String) {
        guard let dash = text.firstIndex(of: "-") else { return nil }
        let projectID = String(text[..<dash])
        let rest = text[text.index(after: dash)...]
        guard rest.hasPrefix("B") else { return nil }
        let digits = rest.dropFirst()
        guard ProjectIdentifier.isValid(projectID),
              let first = digits.unicodeScalars.first, ("1"..."9").contains(first),
              digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let number = Int(digits)
        else { return nil }
        self.projectID = projectID
        self.number = number
    }
}

/// A bundle file, `<project root>/.hephaestus/bundles/<bundle id>.yml` (docs/services/bundles.md, "Bundle file").
public struct BundleFile: Codable, Sendable, Equatable {
    /// An item of `tickets`.
    public struct Item: Codable, Sendable, Equatable {
        /// Ticket id, of the bundle's project. Read from the old key task when ticket is absent (Renamed keys of
        /// project-yml.md).
        public var ticket: String
        /// The ticket session the bundle started for it, the last.
        public var session: UUID?

        public init(ticket: String, session: UUID?) {
            self.ticket = ticket
            self.session = session
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let retired = try decoder.container(keyedBy: RetiredKeys.self)
            if let ticket = try container.decodeIfPresent(String.self, forKey: .ticket) {
                self.ticket = ticket
            } else if let task = try retired.decodeIfPresent(String.self, forKey: .task) {
                ticket = task
            } else {
                ticket = try container.decode(String.self, forKey: .ticket)
            }
            session = try container.decodeIfPresent(UUID.self, forKey: .session)
        }

        /// The key of earlier versions read on decoding.
        private enum RetiredKeys: String, CodingKey {
            case task
        }
    }

    public var id: String
    public var name: String
    public var status: BundleStatus
    public var created: Date
    public var updated: Date
    /// The branch the worktrees branch from; set by the first `bundles.start`.
    public var base: String?
    /// The coordinator session; set by the first `bundles.start`.
    public var coordinator: UUID?
    /// The tickets, in the bundle's order. Read from the old key tasks when tickets is absent (Renamed keys of
    /// project-yml.md).
    public var tickets: [Item]

    public static let shape: YAMLShape = .mapping([
        "id": .value, "name": .value, "status": .value, "created": .value, "updated": .value, "base": .value,
        "coordinator": .value,
        "tickets": .list(identity: "ticket", item: .mapping(["ticket": .value, "session": .value])),
    ])

    /// ["tasks"]: dropped by `encode(preserving:)`.
    public static let retiredKeys: Set<String> = ["tasks"]

    /// The values as given.
    public init(id: String, name: String, status: BundleStatus, created: Date, updated: Date, base: String?,
                coordinator: UUID?, tickets: [Item]) {
        self.id = id
        self.name = name
        self.status = status
        self.created = created
        self.updated = updated
        self.base = base
        self.coordinator = coordinator
        self.tickets = tickets
    }

    /// A key absent from the file takes its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decodeIfPresent(BundleStatus.self, forKey: .status) ?? .draft
        created = try container.decode(Date.self, forKey: .created)
        updated = try container.decode(Date.self, forKey: .updated)
        base = try container.decodeIfPresent(String.self, forKey: .base)
        coordinator = try container.decodeIfPresent(UUID.self, forKey: .coordinator)
        tickets = try container.decodeIfPresent([Item].self, forKey: .tickets)
            ?? retired.decodeIfPresent([Item].self, forKey: .tasks) ?? []
    }

    /// <projectRoot>/.hephaestus/bundles
    public static func folder(projectRoot: URL) -> URL {
        projectRoot
            .appendingPathComponent(".hephaestus", isDirectory: true)
            .appendingPathComponent("bundles", isDirectory: true)
    }

    /// <projectRoot>/.hephaestus/bundles/<id>.yml
    public static func url(projectRoot: URL, id: BundleID) -> URL {
        folder(projectRoot: projectRoot).appendingPathComponent(id.fileName, isDirectory: false)
    }

    /// Decodes, normalizes and validates; `fileID` is the id given by the file name.
    public static func decode(_ text: String, fileID: BundleID) throws -> BundleFile {
        var file = try YAMLCoding.decode(BundleFile.self, from: text, fileName: fileID.fileName)
        file.normalize()
        do {
            try file.validate(fileID: fileID)
        } catch let error as DataError {
            throw DataError.invalid("\(fileID.fileName): \(error.message)")
        }
        return file
    }

    public func encode(preserving previousText: String?) throws -> String {
        do {
            return try YAMLCoding.encode(self, shape: Self.shape, preserving: previousText, retiredKeys: Self.retiredKeys)
        } catch let error as DataError {
            throw DataError.io("\(id).yml: \(error.message)")
        }
    }

    /// Valid files only, by number; broken files are logged and skipped. A missing folder gives no bundle.
    public static func loadAll(projectRoot: URL, projectID: String) -> [BundleFile] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder(projectRoot: projectRoot),
                                                                includingPropertiesForKeys: [.isRegularFileKey])
        } catch {
            return []
        }
        var results: [(number: Int, file: BundleFile)] = []
        for url in urls {
            guard let id = BundleID(fileName: url.lastPathComponent), id.projectID == projectID, isRegularFile(url)
            else { continue }
            do {
                let data: Data
                do {
                    data = try Data(contentsOf: url)
                } catch {
                    throw DataError.io("\(id.fileName): \(error.localizedDescription)")
                }
                results.append((id.number, try decode(ProjectFile.text(of: data, fileName: id.fileName), fileID: id)))
            } catch {
                let message = (error as? DataError)?.message ?? "\(id.fileName): \(error.localizedDescription)"
                Log.host.error("Skipped the bundle file \(id.fileName, privacy: .public): \(message)")
            }
        }
        return results.sorted { $0.number < $1.number }.map(\.file)
    }

    /// The number after the highest number among the entries of `.hephaestus/bundles/` named `<projectID>-B<n>.yml`
    /// (1 when there is none). Throws `.invalid("no bundle number is left in <projectID>")` past `Int.max`.
    public static func allocateID(projectRoot: URL, projectID: String) throws -> BundleID {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(projectRoot: projectRoot).path)) ?? []
        let highest = names
            .compactMap { BundleID(fileName: $0) }
            .filter { $0.projectID == projectID }
            .map(\.number)
            .max() ?? 0
        let (number, overflow) = highest.addingReportingOverflow(1)
        guard !overflow else {
            throw DataError.invalid("no bundle number is left in \(projectID)")
        }
        return BundleID(projectID: projectID, number: number)
    }

    /// Writes a new bundle file. Fails with .invalid("<id> is not a bundle id") when `file.id` is not a bundle id,
    /// and with .invalid("<id>.yml already exists") when the file exists.
    public static func create(_ file: BundleFile, projectRoot: URL) throws {
        guard let id = BundleID(fileName: "\(file.id).yml") else {
            throw DataError.invalid("\(file.id) is not a bundle id")
        }
        let fileURL = url(projectRoot: projectRoot, id: id)
        guard !exists(fileURL) else {
            throw DataError.invalid("\(id.fileName) already exists")
        }
        var file = file
        file.normalize()
        try file.validate(fileID: id)
        let text = try file.encode(preserving: nil)
        try AtomicFile.write(Data(text.utf8), to: fileURL)
    }

    /// Read-modify-write; sets updated; writes nothing when the change leaves the file equal.
    @discardableResult
    public static func update(projectRoot: URL, id: BundleID, _ change: (inout BundleFile) throws -> Void) throws
        -> BundleFile {
        let fileURL = url(projectRoot: projectRoot, id: id)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            throw DataError.notFound("bundle \(id) not found")
        } catch {
            throw DataError.io("\(id.fileName): \(error.localizedDescription)")
        }
        let previousText: String
        let original: BundleFile
        do {
            previousText = try ProjectFile.text(of: data, fileName: id.fileName)
            original = try decode(previousText, fileID: id)
        } catch let error as DataError {
            throw DataError.refused("The file is invalid: \(error.message)")
        }
        var file = original
        try change(&file)
        file.normalize()
        if file == original {
            return original
        }
        file.updated = YAMLCoding.now()
        try file.validate(fileID: id)
        let text = try file.encode(preserving: previousText)
        try AtomicFile.write(Data(text.utf8), to: fileURL)
        return file
    }

    /// Deletes the bundle file.
    public static func delete(projectRoot: URL, id: BundleID) throws {
        do {
            try FileManager.default.removeItem(at: url(projectRoot: projectRoot, id: id))
        } catch CocoaError.fileNoSuchFile {
            throw DataError.notFound("bundle \(id) not found")
        } catch {
            throw DataError.io("\(id.fileName): \(error.localizedDescription)")
        }
    }

    /// Normalizes in place (docs/services/bundles.md, "Bundle file").
    public mutating func normalize() {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let base = base?.trimmingCharacters(in: .whitespacesAndNewlines) {
            self.base = base.isEmpty ? nil : base
        }
        for index in tickets.indices {
            if let parsed = TicketID(tickets[index].ticket) {
                tickets[index].ticket = parsed.description
            }
        }
    }

    /// Throws `DataError.invalid` with the message of the first broken rule.
    public func validate(fileID: BundleID) throws {
        guard id == fileID.description else {
            throw DataError.invalid("id \(id) does not match the file name \(fileID.fileName)")
        }
        guard ProjectFile.isOneLineName(name) else {
            throw DataError.invalid("the name must not be empty and must be on one line")
        }
        if let base, base.contains(where: { $0.isWhitespace }) || base.hasPrefix("-") {
            throw DataError.invalid("base must be a branch name")
        }
        var seen = Set<String>()
        for (index, item) in tickets.enumerated() {
            let isOwnTicket = TicketID(item.ticket).map { $0.projectID == fileID.projectID } ?? false
            guard isOwnTicket, seen.insert(item.ticket).inserted else {
                throw DataError.invalid("tickets[\(index)].ticket must be a ticket of \(fileID.projectID) listed once")
            }
        }
    }

    // MARK: - Private

    /// The key of earlier versions read on decoding (Renamed keys of project-yml.md).
    private enum RetiredKeys: String, CodingKey {
        case tasks
    }

    /// Something exists at `url` (`lstat`: a dangling symbolic link exists).
    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}
