#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import HephClient
@testable import HephCore
@testable import HephHost

/// The recovery of the source Main's migration journal at start, its outcome checks, and `migration.status`
/// (docs/devices/migration.md, "Recovery after a restart"). Each `prepare` writes the source Main S's state: the
/// top-level project HEPH in its projects folder, listed in projects.json, and a migrations.json with one source entry
/// for HEPH.
@MainActor
final class MigrationRecoveryTests: XCTestCase {
    private static let migrationID = UUID(uuidString: "00000000-0000-4000-8000-000000000401")!

    func testCommittedCleanedUp() async throws {
        let source = try await startTestHost { folders in
            try Self.writeSource(folders, state: .committed, targetDeviceID: UUID())
        }
        let root = Self.projectRoot(source.projectsFolder)
        XCTAssertFalse(Self.exists(root))
        XCTAssertTrue(Self.isInTrash(source.trashFolder))
        XCTAssertFalse(ProjectsFile.load(source.appSupport).file.projects.contains(root.path))
        let projects = try await Self.projects(source)
        XCTAssertFalse(projects.contains { $0.id == "HEPH" })
        XCTAssertTrue(Self.journalIsEmpty(source.appSupport))
    }

    func testCommittedFolderGone() async throws {
        let source = try await startTestHost { folders in
            try Self.writeSource(folders, state: .committed, targetDeviceID: UUID(), createsFolder: false)
        }
        let root = Self.projectRoot(source.projectsFolder)
        XCTAssertFalse(ProjectsFile.load(source.appSupport).file.projects.contains(root.path))
        XCTAssertTrue(Self.journalIsEmpty(source.appSupport))
    }

    func testTransferringCleared() async throws {
        let source = try await startTestHost { folders in
            try Self.writeSource(folders, state: .transferring, targetDeviceID: UUID())
        }
        let projects = try await Self.projects(source)
        let project = try XCTUnwrap(projects.first { $0.id == "HEPH" })
        XCTAssertFalse(project.migrating)
        let task = try await Self.createTask(source)
        XCTAssertEqual(task.id, "HEPH-1")
        XCTAssertTrue(Self.journalIsEmpty(source.appSupport))
    }

    func testCommittingWaits() async throws {
        // A Main of the registry that does not run: nothing listens at its address.
        let target = Self.mainRecord(id: UUID(), port: try Self.closedPort())
        let source = try await startTestHost { folders in
            try Self.writeSource(folders, state: .committing, targetDeviceID: target.id,
                                 registry: MeshSnapshot(meshID: testCredentials.meshID, devices: [target],
                                                        presence: []))
        }
        let projects = try await Self.projects(source)
        let project = try XCTUnwrap(projects.first { $0.id == "HEPH" })
        XCTAssertTrue(project.migrating)
        do {
            _ = try await Self.createTask(source)
            XCTFail("tasks.create succeeded on a migrating project")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .locked)
        }
        let entries = MigrationJournal.load(source.appSupport)
        XCTAssertEqual(entries.map(\.migrationID), [Self.migrationID])
        XCTAssertEqual(entries.first?.state, .committing)
        // A move that only waits for an outcome check does not count as active.
        let active = await source.host.migration.isActive()
        XCTAssertFalse(active)
    }

    func testCommittingResolvedCommitted() async throws {
        let destination = try await startTestHost { folders in
            try Self.writeReceived(folders)
        }
        let target = Self.mainRecord(id: destination.identity.id, port: destination.port)
        let source = try await startTestHost { folders in
            try Self.writeSource(folders, state: .committing, targetDeviceID: target.id,
                                 registry: MeshSnapshot(meshID: testCredentials.meshID, devices: [target],
                                                        presence: []))
        }
        let appSupport = source.appSupport
        try await waitUntil { Self.journalIsEmpty(appSupport) }
        XCTAssertTrue(Self.isInTrash(source.trashFolder))
        XCTAssertFalse(Self.exists(Self.projectRoot(source.projectsFolder)))
        let projects = try await Self.projects(source)
        XCTAssertFalse(projects.contains { $0.id == "HEPH" })
    }

    func testCommittingResolvedUnknown() async throws {
        let destination = try await startTestHost()
        let target = Self.mainRecord(id: destination.identity.id, port: destination.port)
        let source = try await startTestHost { folders in
            try Self.writeSource(folders, state: .committing, targetDeviceID: target.id,
                                 registry: MeshSnapshot(meshID: testCredentials.meshID, devices: [target],
                                                        presence: []))
        }
        let appSupport = source.appSupport
        try await waitUntil { Self.journalIsEmpty(appSupport) }
        let projects = try await Self.projects(source)
        let project = try XCTUnwrap(projects.first { $0.id == "HEPH" })
        XCTAssertFalse(project.migrating)
        let task = try await Self.createTask(source)
        XCTAssertEqual(task.id, "HEPH-1")
        XCTAssertTrue(Self.exists(Self.projectRoot(source.projectsFolder)))
    }

    func testStatus() async throws {
        let testHost = try await startTestHost { folders in
            try Self.writeReceived(folders)
        }
        let committed = try await Self.status(of: Self.migrationID, on: testHost)
        XCTAssertEqual(committed, .committed)
        let unknown = try await Self.status(of: UUID(), on: testHost)
        XCTAssertEqual(unknown, .unknown)
    }

    // MARK: - Hosts

    /// The source Main's state: HEPH in the projects folder (unless `createsFolder` is false), projects.json listing
    /// it, migrations.json with one source entry for it in `state`, and `registry` as registry.json.
    private static func writeSource(_ folders: TestHost.Folders, state: MigrationJournalState, targetDeviceID: UUID,
                                    registry: MeshSnapshot? = nil, createsFolder: Bool = true) throws {
        let appSupport = AppSupport(root: folders.appSupport)
        let root = projectRoot(folders.projectsFolder)
        if createsFolder {
            try ProjectFile.create(ProjectFile(id: "HEPH", name: "Hephaestus", description: nil), projectRoot: root)
        }
        var projects = ProjectsFile(projects: [])
        projects.add(root.path)
        try projects.save(appSupport)
        let entry = MigrationJournalEntry(migrationID: migrationID, projectID: "HEPH", rootPath: root.path,
                                          targetDeviceID: targetDeviceID, sourceDeviceID: nil, state: state,
                                          updatedAt: Date())
        try MigrationJournal.save([entry], appSupport)
        if let registry {
            try RegistryCache.save(registry, appSupport)
        }
    }

    /// The destination's journal: a `received` entry of the migration.
    private static func writeReceived(_ folders: TestHost.Folders) throws {
        let entry = MigrationJournalEntry(migrationID: migrationID, projectID: "HEPH",
                                          rootPath: projectRoot(folders.projectsFolder).path, targetDeviceID: nil,
                                          sourceDeviceID: UUID(), state: .received, updatedAt: Date())
        try MigrationJournal.save([entry], AppSupport(root: folders.appSupport))
    }

    /// A Main's registry record reached at 127.0.0.1 and `port`.
    private static func mainRecord(id: UUID, port: Int) -> DeviceRecord {
        DeviceRecord(id: id, name: "Studio", platform: .macOS, isMain: true, addresses: ["127.0.0.1"], port: port,
                     appVersion: "1.0", build: 1, pairedAt: Date(), updatedAt: Date(), revoked: false)
    }

    /// A port of 127.0.0.1 where nothing listens: bound by a socket that is then closed.
    private static func closedPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, length) == 0
                    && Darwin.getsockname(descriptor, socketAddress, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    // MARK: - Requests

    private static func projects(_ testHost: TestHost) async throws -> [ProjectSummary] {
        let data = try await testHost.host.perform(RPCMethod.projectsList.rawValue, params: Data("{}".utf8),
                                                   context: testHost.deviceContext)
        return try WireCoding.decodeJSON(ProjectsListResult.self, from: data).projects
    }

    private static func createTask(_ testHost: TestHost) async throws -> TaskItem {
        let params = try WireCoding.encodeJSON(TasksCreateParams(projectID: "HEPH", name: "Sidebar breaks on iPad"))
        let data = try await testHost.host.perform(RPCMethod.tasksCreate.rawValue, params: params,
                                                   context: testHost.deviceContext)
        return try WireCoding.decodeJSON(TaskItem.self, from: data)
    }

    /// `migration.status` in process: an in-process call counts as a Main.
    private static func status(of migrationID: UUID, on testHost: TestHost) async throws -> MigrationOutcome {
        let params = try WireCoding.encodeJSON(MigrationStatusParams(migrationID: migrationID))
        let data = try await testHost.host.perform(RPCMethod.migrationStatus.rawValue, params: params,
                                                   context: testHost.deviceContext)
        return try WireCoding.decodeJSON(MigrationStatusResult.self, from: data).state
    }

    // MARK: - Files

    private static func projectRoot(_ projectsFolder: URL) -> URL {
        projectsFolder.appendingPathComponent("Hephaestus", isDirectory: true)
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// The Trash folder holds the project's folder.
    private static func isInTrash(_ trashFolder: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(at: trashFolder, includingPropertiesForKeys: nil)) ?? []
        return items.contains { (try? ProjectFile.load(projectRoot: $0))?.id == "HEPH" }
    }

    /// migrations.json is the JSON array `[]`.
    private static func journalIsEmpty(_ appSupport: AppSupport) -> Bool {
        guard let data = try? Data(contentsOf: appSupport.migrationsFile),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return false }
        return entries.isEmpty
    }
}
#endif
