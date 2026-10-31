import Foundation
import Yams

/// `<project root>/.hephaestus/project.yml` (docs/data/project-yml.md): the identity of the project and the state every
/// device shares: sub projects, web tabs, enabled skills and Claude defaults.
public struct ProjectFile: Codable, Sendable, Equatable {
    /// A web tab, item of `webTabs`.
    public struct WebTabEntry: Codable, Sendable, Equatable {
        public var id: UUID
        public var title: String
        public var url: String
        public var locked: Bool

        public init(id: UUID, title: String, url: String, locked: Bool) {
            self.id = id
            self.title = title
            self.url = url
            self.locked = locked
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            url = try container.decode(String.self, forKey: .url)
            locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        }
    }

    public var id: String
    public var name: String
    public var description: String?
    public var created: Date
    public var code: String
    public var docs: String
    public var ticketCounter: Int
    public var feedbackCounter: Int
    public var subprojects: [String]
    public var webTabs: [WebTabEntry]
    public var skills: [String]
    public var claude: ClaudeDefaults?

    /// ".hephaestus/project.yml"
    public static let relativePath = ".hephaestus/project.yml"

    public static let shape: YAMLShape = .mapping([
        "id": .value, "name": .value, "description": .value, "created": .value, "code": .value, "docs": .value,
        "ticketCounter": .value, "feedbackCounter": .value, "subprojects": .value, "skills": .value,
        "webTabs": .list(identity: "id", item: .mapping(["id": .value, "title": .value, "url": .value, "locked": .value])),
        "claude": .mapping(["model": .value, "permissionMode": .value]),
    ])

    /// ["runs", "taskCounter"]: dropped by `encode(preserving:)`.
    public static let retiredKeys: Set<String> = ["runs", "taskCounter"]

    /// A new file with the values of "New file"; `created` = YAMLCoding.now().
    public init(id: String, name: String, description: String?) {
        self.id = id
        self.name = name
        self.description = description
        created = YAMLCoding.now()
        code = "."
        docs = "docs"
        ticketCounter = 0
        feedbackCounter = 0
        subprojects = []
        webTabs = []
        skills = []
        claude = nil
        normalize()
    }

    /// A key absent from the file takes its default; `taskCounter`, the old name of `ticketCounter`, is read when
    /// `ticketCounter` is absent (Renamed keys).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let retired = try decoder.container(keyedBy: RetiredKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        created = try container.decode(Date.self, forKey: .created)
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? "."
        docs = try container.decodeIfPresent(String.self, forKey: .docs) ?? "docs"
        ticketCounter = try container.decodeIfPresent(Int.self, forKey: .ticketCounter)
            ?? retired.decodeIfPresent(Int.self, forKey: .taskCounter) ?? 0
        feedbackCounter = try container.decodeIfPresent(Int.self, forKey: .feedbackCounter) ?? 0
        subprojects = try container.decodeIfPresent([String].self, forKey: .subprojects) ?? []
        webTabs = try container.decodeIfPresent([WebTabEntry].self, forKey: .webTabs) ?? []
        skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        claude = try container.decodeIfPresent(ClaudeDefaults.self, forKey: .claude)
    }

    /// <projectRoot>/.hephaestus/project.yml
    public static func url(projectRoot: URL) -> URL {
        projectRoot
            .appendingPathComponent(".hephaestus", isDirectory: true)
            .appendingPathComponent("project.yml", isDirectory: false)
    }

    /// Decodes, normalizes and validates.
    public static func decode(_ text: String) throws -> ProjectFile {
        var file = try YAMLCoding.decode(ProjectFile.self, from: text, fileName: fileName)
        file.normalize()
        do {
            try file.validate()
        } catch let error as DataError {
            throw DataError.invalid("\(fileName): \(error.message)")
        }
        return file
    }

    public func encode(preserving previousText: String?) throws -> String {
        do {
            return try YAMLCoding.encode(self, shape: Self.shape, preserving: previousText, retiredKeys: Self.retiredKeys)
        } catch let error as DataError {
            throw DataError.io("\(Self.fileName): \(error.message)")
        }
    }

    /// Normalizes in place (docs/data/project-yml.md, "Validation and normalization").
    public mutating func normalize() {
        id = ProjectIdentifier.normalize(id)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if description?.isEmpty == true {
            description = nil
        }
        code = Self.normalizedRelativePath(code) ?? code
        docs = Self.normalizedRelativePath(docs) ?? docs
        var seenPaths = Set<String>()
        subprojects = subprojects
            .map { Self.normalizedRelativePath($0) ?? $0 }
            .filter { seenPaths.insert($0).inserted }
        for index in webTabs.indices {
            webTabs[index].url = webTabs[index].url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var seenSkills = Set<String>()
        skills = skills
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { seenSkills.insert($0).inserted }
        if var defaults = claude {
            if let model = defaults.model?.trimmingCharacters(in: .whitespacesAndNewlines) {
                defaults.model = model.isEmpty ? nil : model
            }
            claude = defaults.model == nil && defaults.permissionMode == nil ? nil : defaults
        }
    }

    /// Throws `DataError.invalid` with the message of the first broken rule.
    public func validate() throws {
        guard ProjectIdentifier.isValid(id) else {
            throw DataError.invalid("the identifier must be 2 to 8 letters A to Z")
        }
        guard Self.isOneLineName(name) else {
            throw DataError.invalid("the name must not be empty and must be on one line")
        }
        guard Self.normalizedRelativePath(code) != nil else {
            throw DataError.invalid("code must be a relative path inside the project")
        }
        guard Self.normalizedRelativePath(docs) != nil else {
            throw DataError.invalid("docs must be a relative path inside the code folder")
        }
        guard ticketCounter >= 0 else {
            throw DataError.invalid("ticketCounter must not be negative")
        }
        guard feedbackCounter >= 0 else {
            throw DataError.invalid("feedbackCounter must not be negative")
        }
        for (index, path) in subprojects.enumerated() {
            guard let normalized = Self.normalizedRelativePath(path), normalized != "." else {
                throw DataError.invalid("subprojects[\(index)] must be a relative path inside the project")
            }
        }
        var tabIDs = Set<UUID>()
        for (index, tab) in webTabs.enumerated() where !tabIDs.insert(tab.id).inserted {
            throw DataError.invalid("webTabs[\(index)].id must be unique")
        }
        for (index, tab) in webTabs.enumerated() where tab.url.isEmpty {
            throw DataError.invalid("webTabs[\(index)].url must not be empty")
        }
        for (index, skill) in skills.enumerated() where !SkillName.isValid(skill) {
            throw DataError.invalid("skills[\(index)] is not a valid skill name")
        }
        if let model = claude?.model, model.contains(where: { $0.isNewline }) {
            throw DataError.invalid("claude.model must be on one line")
        }
    }

    /// .notFound("project.yml: the file does not exist") when the file is missing.
    public static func load(projectRoot: URL) throws -> ProjectFile {
        let data = try readData(projectRoot: projectRoot)
        do {
            return try decode(text(of: data, fileName: fileName))
        } catch let error as DataError {
            Log.core.error("Invalid project.yml in \(projectRoot.path): \(error.message)")
            throw error
        }
    }

    /// Writes a new project.yml, then creates `.hephaestus/tickets/` and the docs folder `<code>/<docs>` when they are
    /// missing. Fails with `.invalid("<project root> already has a .hephaestus/project.yml")` when the file exists.
    public static func create(_ file: ProjectFile, projectRoot: URL) throws {
        let fileURL = url(projectRoot: projectRoot)
        var info = stat()
        if lstat(fileURL.path, &info) == 0 {
            throw DataError.invalid("\(projectRoot.path) already has a .hephaestus/project.yml")
        }
        var file = file
        file.normalize()
        try file.validate()
        let text = try file.encode(preserving: nil)
        try AtomicFile.write(Data(text.utf8), to: fileURL)
        let docsComponents = [file.code, file.docs]
            .flatMap { $0.split(separator: "/").map(String.init) }
            .filter { $0 != "." }
        let docsFolder = docsComponents.reduce(projectRoot) { $0.appendingPathComponent($1, isDirectory: true) }
        for folder in [TicketFile.folder(projectRoot: projectRoot), docsFolder] {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                throw DataError.io("\(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Read-modify-write; returns the file as written.
    @discardableResult
    public static func update(projectRoot: URL, _ change: (inout ProjectFile) throws -> Void) throws -> ProjectFile {
        let fileURL = url(projectRoot: projectRoot)
        let data = try readData(projectRoot: projectRoot)
        let previousText: String
        let original: ProjectFile
        do {
            previousText = try text(of: data, fileName: fileName)
            original = try decode(previousText)
        } catch let error as DataError {
            Log.core.error("Invalid project.yml in \(projectRoot.path): \(error.message)")
            throw DataError.refused("The file is invalid: \(error.message)")
        }
        var file = original
        try change(&file)
        file.normalize()
        guard file.id == original.id else {
            throw DataError.invalid("the project identifier cannot change")
        }
        try file.validate()
        let text = try file.encode(preserving: previousText)
        try AtomicFile.write(Data(text.utf8), to: fileURL)
        return file
    }

    /// WebTab values for Project.
    public var webTabValues: [WebTab] {
        webTabs.map { WebTab(id: $0.id, title: $0.title, url: $0.url, locked: $0.locked) }
    }

    /// ClaudeDefaults for Project: both fields nil when the file has no `claude`.
    public var claudeDefaults: ClaudeDefaults {
        claude ?? ClaudeDefaults(model: nil, permissionMode: nil)
    }

    /// The relative path normalization; nil when invalid.
    public static func normalizedRelativePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return nil
        }
        var components: [Substring] = []
        for component in trimmed.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { return nil }
            components.append(component)
        }
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    /// Trims white space and line breaks; throws DataError.invalid with the name rule's message when the result is
    /// empty or holds a line break. No maximum length.
    public static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOneLineName(name) else {
            throw DataError.invalid("the name must not be empty and must be on one line")
        }
        return name
    }

    // MARK: - Internal

    /// The name rule shared by project names, ticket names and session titles: not empty, no
    /// `Character` whose `isNewline` is true.
    static func isOneLineName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains { $0.isNewline }
    }

    /// The file's bytes as UTF-8 text, else `.unreadable`.
    static func text(of data: Data, fileName: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DataError.unreadable("\(fileName): the file is not UTF-8 text")
        }
        return text
    }

    // MARK: - Private

    private static let fileName = "project.yml"

    /// Keys of earlier versions read on decoding (Renamed keys).
    private enum RetiredKeys: String, CodingKey {
        case taskCounter
    }

    private static func readData(projectRoot: URL) throws -> Data {
        do {
            return try Data(contentsOf: url(projectRoot: projectRoot))
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            throw DataError.notFound("\(fileName): the file does not exist")
        } catch {
            throw DataError.io("\(fileName): \(error.localizedDescription)")
        }
    }
}
