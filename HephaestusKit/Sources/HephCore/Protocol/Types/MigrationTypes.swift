import Foundation

// Migration: the wire types of docs/protocol/types.md, section "Migration".

/// One item to transfer when a project moves to another Main.
public struct ManifestEntry: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var isDirectory: Bool
    public var size: Int
    public var sha256: String?
    public var mode: Int
    public var modified: Date
    public var symlinkTarget: String?

    public var id: String { path }

    public init(
        path: String,
        isDirectory: Bool,
        size: Int,
        sha256: String? = nil,
        mode: Int,
        modified: Date,
        symlinkTarget: String? = nil
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.sha256 = sha256
        self.mode = mode
        self.modified = modified
        self.symlinkTarget = symlinkTarget
    }
}

/// The state of a migration.
public enum MigrationState: String, Codable, Sendable, Hashable, CaseIterable {
    /// The source builds the manifest.
    case preparing
    /// Files are being sent.
    case transferring
    /// The destination verifies and installs the files.
    case committing
    /// The project is on the destination and gone from the source.
    case completed
    /// The migration stopped; the project stays on the source.
    case failed
}

/// What the destination knows of a migration (`migration.status`).
public enum MigrationOutcome: String, Codable, Sendable, Hashable, CaseIterable {
    /// The destination's migration journal has a `received` entry with that id.
    case committed
    /// The destination has no record of a committed move with that id.
    case unknown
}
