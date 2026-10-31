#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// Task bundles, their worktrees and branches (docs/services/bundles.md): a TestHost with a project HEPH and the tasks
/// HEPH-1 to HEPH-3, and a GitSandbox whose git makes the repository in the TestHost's projects folder, so that the
/// project is a sub folder of it. A bundle is made running or done by writing its file, since bundles.start and
/// start_bundle_task would run the Claude CLI.
@MainActor
final class BundleServiceTests: XCTestCase {
    private var testHost: TestHost!
    private var sandbox: GitSandbox!

    override func setUp() async throws {
        try await super.setUp()
        testHost = try await startTestHost()
        let sandbox = try GitSandbox()
        let folder = sandbox.folder
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        self.sandbox = sandbox
        _ = try await testHost.perform(.projectsCreate, ProjectsCreateParams(name: "Hephaestus", identifier: "HEPH"),
                                       as: ProjectSummary.self)
        for (index, name) in ["Sidebar", "Toolbar", "Inspector"].enumerated() {
            let task = try await testHost.perform(.tasksCreate, TasksCreateParams(projectID: "HEPH", name: name),
                                                  as: TaskItem.self)
            XCTAssertEqual(task.id, "HEPH-\(index + 1)")
        }
    }

    override func tearDown() async throws {
        testHost = nil
        sandbox = nil
        try await super.tearDown()
    }

    func testOneOpenBundlePerTask() async throws {
        let first = try await createBundle(["HEPH-1"])
        let second = try await createBundle(["HEPH-2"])
        XCTAssertEqual(first.id, "HEPH-B1")
        XCTAssertEqual(second.id, "HEPH-B2")
        await assertProtocolError(.conflict, "HEPH-2 is in HEPH-B2.") {
            try await self.createBundle(["HEPH-3", "HEPH-2", "HEPH-1"])
        }
        XCTAssertFalse(exists(BundleFile.url(projectRoot: projectFolder, id: try XCTUnwrap(BundleID("HEPH-B3")))))
        let before = try bundleFile("HEPH-B2")
        await assertProtocolError(.conflict, "HEPH-1 is in HEPH-B1.") {
            try await self.updateTasks("HEPH-B2", ["HEPH-2", "HEPH-1"])
        }
        XCTAssertEqual(try bundleFile("HEPH-B2"), before)
        let updated = try await updateTasks("HEPH-B2", ["HEPH-2", "HEPH-3"])
        XCTAssertEqual(updated.tasks.map(\.taskID), ["HEPH-2", "HEPH-3"])
        try await setBundle("HEPH-B1") { $0.status = .done }
        let third = try await createBundle(["HEPH-1"])
        XCTAssertEqual(third.id, "HEPH-B3")
    }

    func testStatusToolsNeedRunningBundle() async throws {
        try makeRepository()
        try await makeWorktree(1)
        _ = try await createBundle(["HEPH-1"])
        try await setBundle("HEPH-B1") { $0.base = "main" }
        for status in [BundleStatus.draft, .done] {
            try await setBundle("HEPH-B1") { $0.status = status }
            await assertProtocolError(.conflict, "HEPH-B1 is not running.") {
                try await self.testHost.host.bundles.setStatus(projectID: "HEPH", bundleID: "HEPH-B1", status: .review)
            }
            await assertProtocolError(.conflict, "HEPH-B1 is not running.") {
                try await self.testHost.host.bundles.finish(projectID: "HEPH", bundleID: "HEPH-B1")
            }
            XCTAssertTrue(exists(worktree(1)))
            XCTAssertTrue(try branches().contains("task/HEPH-1"))
            XCTAssertEqual(try bundleFile("HEPH-B1").status, status)
        }
        await assertProtocolError(.badRequest, "Invalid arguments: status must be one of running, review.") {
            try await self.testHost.host.bundles.setStatus(projectID: "HEPH", bundleID: "HEPH-B1", status: .draft)
        }
        try await setBundle("HEPH-B1") { $0.status = .running }
        let bundle = try await testHost.host.bundles.setStatus(projectID: "HEPH", bundleID: "HEPH-B1", status: .review)
        XCTAssertEqual(bundle.status, .review)
        XCTAssertEqual(try bundleFile("HEPH-B1").status, .review)
    }

    func testWorktreeRunsNoHook() async throws {
        try makeRepository()
        let hooks = sandbox.folder.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let ran = sandbox.folder.appendingPathComponent("ran", isDirectory: false)
        let hook = hooks.appendingPathComponent("post-checkout", isDirectory: false)
        try Data("#!/bin/sh\ntouch \"\(ran.path)\"\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try sandbox.git(["config", "core.hooksPath", hooks.path], in: repository)
        try await makeWorktree(1)
        XCTAssertTrue(exists(worktree(1).appendingPathComponent("Hephaestus/README.md", isDirectory: false)))
        XCTAssertFalse(exists(ran))
        let control = sandbox.folder.appendingPathComponent("control", isDirectory: true)
        try sandbox.git(["worktree", "add", "--detach", control.path, "main"], in: repository)
        XCTAssertTrue(exists(ran))
    }

    func testWorktreeLifecycle() async throws {
        try makeRepository()
        let git = bundleGit
        for number in 1...3 {
            try await makeWorktree(number)
            XCTAssertTrue(exists(worktree(number).appendingPathComponent("Hephaestus/README.md", isDirectory: false)))
            let branchExists = try await git.branchExists("task/HEPH-\(number)")
            XCTAssertTrue(branchExists)
            let workFolder = try await testHost.host.bundles.workFolder(projectID: "HEPH", taskID: "HEPH-\(number)")
            XCTAssertEqual(workFolder.path, worktree(number).appendingPathComponent("Hephaestus", isDirectory: true).path)
        }
        // Brought in: a commit cherry-picked onto main, a commit that is not, no commit.
        let first = try commit("one", in: workFolder(1))
        try sandbox.git(["cherry-pick", first], in: repository)
        let second = try commit("two", in: workFolder(2))
        let firstIn = try await git.isBroughtIn(branch: "task/HEPH-1", base: "main")
        let secondIn = try await git.isBroughtIn(branch: "task/HEPH-2", base: "main")
        let thirdIn = try await git.isBroughtIn(branch: "task/HEPH-3", base: "main")
        XCTAssertTrue(firstIn)
        XCTAssertFalse(secondIn)
        XCTAssertTrue(thirdIn)
        // Removed, then created again on the branch that stayed.
        try await git.removeWorktree(at: worktree(2))
        XCTAssertFalse(exists(worktree(2)))
        XCTAssertFalse(try worktreeList().contains(realPath(worktree(2))))
        XCTAssertTrue(try branches().contains("task/HEPH-2"))
        try await makeWorktree(2)
        XCTAssertEqual(try revision("HEAD", in: worktree(2)), second)
        // finish: worktrees removed, the branches brought in deleted, the other kept.
        let main = try revision("main")
        _ = try await createBundle(["HEPH-1", "HEPH-2", "HEPH-3"])
        try await setBundle("HEPH-B1") { file in
            file.status = .running
            file.base = "main"
        }
        let result = try await testHost.host.bundles.finish(projectID: "HEPH", bundleID: "HEPH-B1")
        XCTAssertEqual(result.keptBranches, ["task/HEPH-2"])
        XCTAssertEqual(result.bundle.status, .done)
        XCTAssertEqual(try bundleFile("HEPH-B1").status, .done)
        for number in 1...3 {
            XCTAssertFalse(exists(worktree(number)))
        }
        XCTAssertEqual(try worktreeList(), [realPath(repository)])
        XCTAssertEqual(try branches(), ["main", "task/HEPH-2"])
        XCTAssertEqual(try revision("task/HEPH-2"), second)
        XCTAssertEqual(try revision("main"), main)
        let statuses = try await taskStatuses()
        XCTAssertEqual(statuses, [.done, .todo, .done])
        await assertProtocolError(.notFound, "the worktree of HEPH-1 was removed with its bundle.") {
            try await self.testHost.host.bundles.workFolder(projectID: "HEPH", taskID: "HEPH-1")
        }
    }

    func testDeleteKeepsOtherWork() async throws {
        try makeRepository()
        _ = try await createBundle(["HEPH-1"])
        _ = try await createBundle(["HEPH-2"])
        for id in ["HEPH-B1", "HEPH-B2"] {
            try await setBundle(id) { $0.base = "main" }
        }
        try await makeWorktree(1)
        try await makeWorktree(2)
        try sandbox.git(["branch", "task/HEPH-3"], in: repository)
        let feature = sandbox.folder.appendingPathComponent("feature", isDirectory: true)
        try sandbox.git(["worktree", "add", "-q", "-b", "feature", feature.path], in: repository)
        let other = try bundleFile("HEPH-B2")
        let otherItem = await testHost.host.bundles.list(projectID: "HEPH").last
        XCTAssertEqual(otherItem?.id, "HEPH-B2")
        _ = try await testHost.perform(.bundlesDelete, BundlesDeleteParams(projectID: "HEPH", bundleID: "HEPH-B1"),
                                       as: EmptyPayload.self)
        XCTAssertFalse(exists(worktree(1)))
        XCTAssertTrue(exists(worktree(2).appendingPathComponent("Hephaestus/README.md", isDirectory: false)))
        XCTAssertEqual(Set(try worktreeList()), [realPath(repository), realPath(worktree(2)), realPath(feature)])
        XCTAssertEqual(try branches(), ["feature", "main", "task/HEPH-2", "task/HEPH-3"])
        XCTAssertFalse(exists(BundleFile.url(projectRoot: projectFolder, id: try XCTUnwrap(BundleID("HEPH-B1")))))
        XCTAssertEqual(try bundleFile("HEPH-B2"), other)
        let remaining = await testHost.host.bundles.list(projectID: "HEPH")
        XCTAssertEqual(remaining.map(\.id), ["HEPH-B2"])
        XCTAssertEqual(remaining.first, otherItem)
    }

    func testDeleteSkipsTaskOfOpenBundle() async throws {
        try makeRepository()
        _ = try await createBundle(["HEPH-1", "HEPH-2"])
        try await setBundle("HEPH-B1") { file in
            file.status = .done
            file.base = "main"
        }
        let second = try await createBundle(["HEPH-1"])
        XCTAssertEqual(second.id, "HEPH-B2")
        try await setBundle("HEPH-B2") { file in
            file.status = .running
            file.base = "main"
        }
        try await makeWorktree(1)
        try await makeWorktree(2)
        let broughtIn = try await bundleGit.isBroughtIn(branch: "task/HEPH-1", base: "main")
        XCTAssertTrue(broughtIn)
        _ = try await testHost.perform(.bundlesDelete, BundlesDeleteParams(projectID: "HEPH", bundleID: "HEPH-B1"),
                                       as: EmptyPayload.self)
        XCTAssertFalse(exists(worktree(2)))
        XCTAssertTrue(exists(worktree(1).appendingPathComponent("Hephaestus/README.md", isDirectory: false)))
        XCTAssertEqual(Set(try worktreeList()), [realPath(repository), realPath(worktree(1))])
        XCTAssertEqual(try branches(), ["main", "task/HEPH-1"])
        XCTAssertFalse(exists(BundleFile.url(projectRoot: projectFolder, id: try XCTUnwrap(BundleID("HEPH-B1")))))
        let remaining = await testHost.host.bundles.list(projectID: "HEPH")
        XCTAssertEqual(remaining.map(\.id), ["HEPH-B2"])
        XCTAssertEqual(remaining.first?.status, .running)
    }

    func testFinishWithoutBase() async throws {
        try makeRepository()
        try sandbox.git(["branch", "release"], in: repository)
        try await bundleGit.createWorktree(at: worktree(1), branch: "task/HEPH-1", base: "release")
        _ = try await createBundle(["HEPH-1"])
        try await setBundle("HEPH-B1") { file in
            file.status = .running
            file.base = "release"
        }
        try sandbox.git(["branch", "-D", "release"], in: repository)
        let broughtIn = try await bundleGit.isBroughtIn(branch: "task/HEPH-1", base: "release")
        XCTAssertFalse(broughtIn)
        let result = try await testHost.host.bundles.finish(projectID: "HEPH", bundleID: "HEPH-B1")
        XCTAssertEqual(result.keptBranches, ["task/HEPH-1"])
        XCTAssertEqual(result.bundle.status, .done)
        XCTAssertFalse(exists(worktree(1)))
        XCTAssertEqual(try branches(), ["main", "task/HEPH-1"])
        let statuses = try await taskStatuses()
        XCTAssertEqual(statuses, [.todo, .todo, .todo])
    }

    func testStartNeedsRepository() async throws {
        _ = try await createBundle(["HEPH-1"])
        let message = "Bundles need a git repository on a branch with a commit: \(projectFolder.path) is not in one."
        await assertProtocolError(.badRequest, message) {
            try await self.start("HEPH-B1")
        }
        try sandbox.git(["init", "-b", "main"], in: repository)
        await assertProtocolError(.badRequest, message) {
            try await self.start("HEPH-B1")
        }
        let bundles = await testHost.host.bundles.list(projectID: "HEPH")
        let bundle = try XCTUnwrap(bundles.first)
        XCTAssertEqual(bundle.status, .draft)
        XCTAssertNil(bundle.base)
        XCTAssertEqual(try bundleFile("HEPH-B1").status, .draft)
    }

    // MARK: - Helpers

    /// The TestHost's projects folder, where the repository is made.
    private var repository: URL {
        testHost.projectsFolder
    }

    /// The project's folder, `Hephaestus` in the repository.
    private var projectFolder: URL {
        testHost.projectsFolder.appendingPathComponent("Hephaestus", isDirectory: true)
    }

    /// The BundleGit of the project, with the sandbox's environment.
    private var bundleGit: BundleGit {
        BundleGit(codeFolder: projectFolder, environment: sandbox.environment)
    }

    /// `<worktreesFolder>/HEPH/HEPH-<number>`
    private func worktree(_ number: Int) -> URL {
        testHost.appSupport.worktreesFolder
            .appendingPathComponent("HEPH", isDirectory: true)
            .appendingPathComponent("HEPH-\(number)", isDirectory: true)
    }

    /// The project's place in the worktree of HEPH-<number>.
    private func workFolder(_ number: Int) -> URL {
        worktree(number).appendingPathComponent("Hephaestus", isDirectory: true)
    }

    /// `git init -b main` in the projects folder and a commit of `Hephaestus/README.md`.
    private func makeRepository() throws {
        try Data("Hephaestus\n".utf8).write(to: projectFolder.appendingPathComponent("README.md", isDirectory: false))
        try sandbox.git(["init", "-q", "-b", "main"], in: repository)
        try sandbox.git(["add", "Hephaestus/README.md"], in: repository)
        try sandbox.git(["commit", "-q", "-m", "initial"], in: repository)
    }

    /// The worktree of HEPH-<number>, as start_bundle_task creates it.
    private func makeWorktree(_ number: Int) async throws {
        try await bundleGit.createWorktree(at: worktree(number), branch: "task/HEPH-\(number)", base: "main")
    }

    /// A commit adding `<name>.txt` in `folder`; its SHA.
    private func commit(_ name: String, in folder: URL) throws -> String {
        try Data("\(name)\n".utf8).write(to: folder.appendingPathComponent("\(name).txt", isDirectory: false))
        try sandbox.git(["add", "\(name).txt"], in: folder)
        try sandbox.git(["commit", "-q", "-m", name], in: folder)
        return try revision("HEAD", in: folder)
    }

    /// `git rev-parse --verify <name>`, in the repository unless a folder is given.
    private func revision(_ name: String, in folder: URL? = nil) throws -> String {
        try sandbox.git(["rev-parse", "--verify", name], in: folder ?? repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The branches of the repository, by name.
    private func branches() throws -> [String] {
        try sandbox.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repository)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    /// The folders of `git worktree list --porcelain`.
    private func worktreeList() throws -> [String] {
        try sandbox.git(["worktree", "list", "--porcelain"], in: repository)
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
    }

    /// The path with symlinks resolved, as git prints it.
    private func realPath(_ url: URL) -> String {
        ClaudePathEncoding.canonicalPath(url.path) ?? url.path
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// `bundles.create` of the tasks in HEPH.
    @discardableResult
    private func createBundle(_ taskIDs: [String]) async throws -> BundleItem {
        try await testHost.perform(.bundlesCreate,
                                   BundlesCreateParams(projectID: "HEPH", name: "Polish", taskIDs: taskIDs),
                                   as: BundleItem.self)
    }

    /// `bundles.update` of the tasks of a bundle.
    private func updateTasks(_ bundleID: String, _ taskIDs: [String]) async throws -> BundleItem {
        try await testHost.perform(.bundlesUpdate,
                                   BundlesUpdateParams(projectID: "HEPH", bundleID: bundleID,
                                                       patch: BundlePatch(taskIDs: taskIDs)),
                                   as: BundleItem.self)
    }

    /// `bundles.start` of a bundle.
    private func start(_ bundleID: String) async throws -> BundleItem {
        try await testHost.perform(.bundlesStart, BundlesStartParams(projectID: "HEPH", bundleID: bundleID),
                                   as: BundleItem.self)
    }

    /// Writes the bundle file with `change`, then loads the bundles of HEPH again.
    private func setBundle(_ bundleID: String, _ change: (inout BundleFile) -> Void) async throws {
        try BundleFile.update(projectRoot: projectFolder, id: try XCTUnwrap(BundleID(bundleID)), change)
        await testHost.host.bundles.load(projectID: "HEPH")
    }

    /// The bundle file on disk, decoded.
    private func bundleFile(_ bundleID: String) throws -> BundleFile {
        let id = try XCTUnwrap(BundleID(bundleID))
        let text = try String(contentsOf: BundleFile.url(projectRoot: projectFolder, id: id), encoding: .utf8)
        return try BundleFile.decode(text, fileID: id)
    }

    /// The statuses of HEPH-1 to HEPH-3.
    private func taskStatuses() async throws -> [TaskStatus] {
        var statuses: [TaskStatus] = []
        for number in 1...3 {
            statuses.append(try await testHost.host.tasks.task(projectID: "HEPH", taskID: "HEPH-\(number)").status)
        }
        return statuses
    }
}
#endif
