import Foundation

/// The state of an entry of the migration journal.
public enum MigrationJournalState: String, Codable, Sendable, CaseIterable {
    case transferring, committing, committed   // entries of the source
    case received                              // entries of the destination
}

/// One entry of migrations.json.
public struct MigrationJournalEntry: Codable, Sendable, Equatable, Identifiable {
    public var migrationID: UUID
    public var projectID: String
    /// Source entry: the project root on this Main, as `projects.json` holds it. `received` entry: the new root.
    public var rootPath: String
    public var targetDeviceID: UUID?       // source entries
    public var sourceDeviceID: UUID?       // received entries
    public var state: MigrationJournalState
    public var updatedAt: Date

    public var id: UUID { migrationID }

    public init(migrationID: UUID, projectID: String, rootPath: String, targetDeviceID: UUID?, sourceDeviceID: UUID?,
                state: MigrationJournalState, updatedAt: Date) {
        self.migrationID = migrationID
        self.projectID = projectID
        self.rootPath = rootPath
        self.targetDeviceID = targetDeviceID
        self.sourceDeviceID = sourceDeviceID
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// `migrations.json` (Main only): the moves this Main sends, until their cleanup ends, and the moves it received, for
/// 30 days (docs/data/app-storage.md, docs/devices/migration.md).
public enum MigrationJournal {
    /// received entries older than 30 days before `now` are left out.
    public static let receivedRetention: TimeInterval = 2_592_000

    /// The entries, in file order; [] when missing or unreadable (logged).
    public static func load(_ appSupport: AppSupport, now: Date = Date()) -> [MigrationJournalEntry] {
        do {
            let entries = try JSONFile.read([MigrationJournalEntry].self, from: appSupport.migrationsFile) ?? []
            return retained(entries, now: now)
        } catch {
            let message = (error as? DataError)?.message ?? error.localizedDescription
            Log.core.error("Unreadable migrations.json: \(message)")
            return []
        }
    }

    /// Writes every entry with `JSONFile.write`, the expired `received` entries left out.
    public static func save(_ entries: [MigrationJournalEntry], _ appSupport: AppSupport, now: Date = Date()) throws {
        try JSONFile.write(retained(entries, now: now), to: appSupport.migrationsFile)
    }

    /// Leaves out the `received` entries whose `updatedAt` is more than `receivedRetention` before `now`.
    private static func retained(_ entries: [MigrationJournalEntry], now: Date) -> [MigrationJournalEntry] {
        entries.filter { $0.state != .received || now.timeIntervalSince($0.updatedAt) <= receivedRetention }
    }
}
