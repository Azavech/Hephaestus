import Foundation

// Files: the wire types of docs/protocol/types.md, section "Files".

/// A file or folder of a project.
public struct FileEntry: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int
    public var modified: Date

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, size: Int, modified: Date) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }
}

/// A file attached to a request: a complete upload of the request's project, sent before with `uploads.begin` and
/// `uploads.chunk`.
public struct UploadRef: Codable, Sendable, Hashable {
    public var uploadID: UUID
    public var fileName: String

    public init(uploadID: UUID, fileName: String) {
        self.uploadID = uploadID
        self.fileName = fileName
    }
}
