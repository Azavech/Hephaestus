import Foundation

// Runs: the wire types of docs/protocol/types.md, section "Runs".

/// A run configuration of project.yml.
public struct RunConfig: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var command: String
    public var cwd: String?

    public var id: String { name }

    public init(name: String, command: String, cwd: String? = nil) {
        self.name = name
        self.command = command
        self.cwd = cwd
    }
}

/// The state of a run.
public enum RunState: String, Codable, Sendable, Hashable, CaseIterable {
    /// The process runs.
    case running
    /// The process exited with status 0 and no stop was requested.
    case succeeded
    /// No stop was requested, and the process exited with another status or was killed by a signal.
    case failed
    /// The process ended after a stop was requested.
    case stopped
}

/// An execution of a run configuration.
public struct RunInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var projectID: String
    public var name: String
    public var command: String
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int?
    public var state: RunState

    public init(
        id: UUID,
        projectID: String,
        name: String,
        command: String,
        startedAt: Date,
        endedAt: Date? = nil,
        exitCode: Int? = nil,
        state: RunState
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.command = command
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.state = state
    }
}
