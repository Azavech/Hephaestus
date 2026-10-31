import Foundation
import Yams

/// The metadata file of a session, `.hephaestus/sessions/<id>.yml` (docs/data/sessions.md). The file holds `stopped`,
/// or `failed` when the last process failed; the live statuses exist only in the memory of `SessionService`.
public struct SessionFile: Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: SessionKind
    public var taskID: String?
    public var mode: SessionMode?
    public var bundleID: String?
    public var title: String
    public var created: Date
    public var updated: Date
    public var permissionMode: PermissionMode
    public var allowsAllTools: Bool
    public var model: String?
    public var status: SessionStatus

    /// The values as given, except `created` and `updated`, which pass through YAMLCoding.wholeSeconds(_:).
    public init(id: UUID, kind: SessionKind, taskID: String?, mode: SessionMode?, bundleID: String?, title: String,
                created: Date, updated: Date, permissionMode: PermissionMode, allowsAllTools: Bool = false,
                model: String?, status: SessionStatus) {
        self.id = id
        self.kind = kind
        self.taskID = taskID
        self.mode = mode
        self.bundleID = bundleID
        self.title = title
        self.created = YAMLCoding.wholeSeconds(created)
        self.updated = YAMLCoding.wholeSeconds(updated)
        self.permissionMode = permissionMode
        self.allowsAllTools = allowsAllTools
        self.model = model
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, taskID, mode, bundleID, title, created, updated, permissionMode, allowsAllTools, model, status
    }

    /// Custom coding for allowsAllTools only: an absent key decodes as false, false is not encoded.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(SessionKind.self, forKey: .kind)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        mode = try container.decodeIfPresent(SessionMode.self, forKey: .mode)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        title = try container.decode(String.self, forKey: .title)
        created = try container.decode(Date.self, forKey: .created)
        updated = try container.decode(Date.self, forKey: .updated)
        permissionMode = try container.decode(PermissionMode.self, forKey: .permissionMode)
        allowsAllTools = try container.decodeIfPresent(Bool.self, forKey: .allowsAllTools) ?? false
        model = try container.decodeIfPresent(String.self, forKey: .model)
        status = try container.decode(SessionStatus.self, forKey: .status)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(taskID, forKey: .taskID)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(bundleID, forKey: .bundleID)
        try container.encode(title, forKey: .title)
        try container.encode(created, forKey: .created)
        try container.encode(updated, forKey: .updated)
        try container.encode(permissionMode, forKey: .permissionMode)
        if allowsAllTools {
            try container.encode(true, forKey: .allowsAllTools)
        }
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(status, forKey: .status)
    }

    /// .mapping of the twelve keys, each .value.
    public static let shape: YAMLShape = .mapping([
        "id": .value, "kind": .value, "taskID": .value, "mode": .value, "bundleID": .value, "title": .value,
        "created": .value, "updated": .value, "permissionMode": .value, "allowsAllTools": .value, "model": .value,
        "status": .value,
    ])

    /// id.uuidString.lowercased(): the name of the files and folder, and the CLI session id.
    public static func fileStem(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// <projectRoot>/.hephaestus/sessions
    public static func folder(projectRoot: URL) -> URL {
        projectRoot
            .appendingPathComponent(".hephaestus", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Decodes, normalizes and validates; `fileName` is "<lowercase id>.yml". A `status` other than `failed` is read
    /// as `stopped`.
    public static func decode(_ text: String, fileName: String) throws -> SessionFile {
        var file = try YAMLCoding.decode(SessionFile.self, from: text, fileName: fileName)
        if file.status != .failed {
            file.status = .stopped
        }
        file.normalize()
        do {
            try file.validate(fileName: fileName)
        } catch let error as DataError {
            throw DataError.invalid("\(fileName): \(error.message)")
        }
        return file
    }

    public func encode(preserving previousText: String?) throws -> String {
        do {
            return try YAMLCoding.encode(self, shape: Self.shape, preserving: previousText)
        } catch let error as DataError {
            throw DataError.io("\(Self.fileStem(id)).yml: \(error.message)")
        }
    }

    /// Normalizes in place (docs/data/sessions.md, "Validation and normalization").
    public mutating func normalize() {
        if let taskID, let parsed = TaskID(taskID) {
            self.taskID = parsed.description
        }
        if let bundleID, let parsed = BundleID(bundleID) {
            self.bundleID = parsed.description
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines) {
            self.model = model.isEmpty ? nil : model
        }
    }

    /// Throws `DataError.invalid` with the message of the first broken rule.
    public func validate(fileName: String) throws {
        let stem = fileName.hasSuffix(".yml") ? String(fileName.dropLast(4)) : fileName
        guard UUID(uuidString: stem) == id else {
            throw DataError.invalid("id \(id.uuidString) does not match the file name \(fileName)")
        }
        let needsTask = kind == .task || kind == .feedback
        let hasValidTask = taskID.map { TaskID($0) != nil } ?? false
        guard needsTask ? hasValidTask : taskID == nil else {
            throw DataError.invalid("taskID must be set for task and feedback sessions only")
        }
        guard (kind == .task) == (mode != nil) else {
            throw DataError.invalid("mode must be set for task sessions only")
        }
        let hasValidBundle = bundleID.map { BundleID($0) != nil } ?? false
        let bundleAllowed: Bool
        switch kind {
        case .bundle: bundleAllowed = hasValidBundle
        case .task: bundleAllowed = bundleID == nil || hasValidBundle
        case .project, .feedback, .regeneration: bundleAllowed = bundleID == nil
        }
        guard bundleAllowed else {
            throw DataError.invalid("bundleID must be set for bundle sessions and allowed for task sessions only")
        }
        guard ProjectFile.isOneLineName(title) else {
            throw DataError.invalid("the title must not be empty and must be on one line")
        }
        if let model, model.contains(where: { $0.isNewline }) {
            throw DataError.invalid("model must be on one line")
        }
    }
}
