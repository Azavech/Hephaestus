#if os(macOS)
import Foundation
import HephCore

/// The result of a tool call: the text given back to Claude.
struct MCPToolResult: Sendable, Equatable {
    var text: String
    var isError: Bool
}

/// Runs the Hephaestus tools (docs/claude/mcp.md §6–8): each tool executes protocol methods on the Main hosting the
/// project it acts on, through `MCPHost.perform`.
struct MCPToolHandler: Sendable {
    private let host: any MCPHost

    init(host: any MCPHost) {
        self.host = host
    }

    /// Runs one tool; never throws: failures are results with isError (section 8).
    func call(name: String, arguments: Data, context: MCPSessionContext) async -> MCPToolResult {
        Log.host.info("MCP tool \(name, privacy: .public) called by session \(context.sessionID.uuidString, privacy: .public)")
        do {
            guard MCPTools.tools(for: context.kind).contains(where: { $0.name == name }) else {
                throw ToolFailure.message("Unknown tool: \(name)")
            }
            let arguments = try Arguments(arguments)
            let text: String
            switch name {
            case "list_devices": text = try await listDevices()
            case "list_projects": text = try await listProjects()
            case "get_project": text = try await getProject(arguments)
            case "create_project": text = try await createProject(arguments)
            case "update_project": text = try await updateProject(arguments)
            case "list_tasks": text = try await listTasks(arguments)
            case "get_task": text = try await getTask(arguments, context: context)
            case "create_task": text = try await createTask(arguments)
            case "update_task": text = try await updateTask(arguments)
            case "delete_task": text = try await deleteTask(arguments)
            case "comment_task": text = try await commentTask(arguments)
            case "start_task_session": text = try await startTaskSession(arguments)
            case "list_runs": text = try await listRuns(arguments)
            case "start_run": text = try await startRun(arguments)
            case "stop_run": text = try await stopRun(arguments)
            case "get_run_output": text = try await getRunOutput(arguments)
            case "list_web_tabs": text = try await listWebTabs(arguments)
            case "open_web_tab": text = try await openWebTab(arguments)
            case "search": text = try await search(arguments)
            case "list_skills": text = try await listSkills()
            case "get_skill": text = try await getSkill(arguments)
            case "save_skill": text = try await saveSkill(arguments)
            case "forge_push_docs": text = try await forgePush(context: context, docs: true)
            case "forge_push_regen": text = try await forgePush(context: context, docs: false)
            default: throw ToolFailure.message("Unknown tool: \(name)")
            }
            return MCPToolResult(text: text, isError: false)
        } catch let failure as ToolFailure {
            if case .protocolError(let error) = failure {
                Log.host.notice("MCP tool \(name, privacy: .public) failed: \(error.code.rawValue, privacy: .public)")
            }
            return MCPToolResult(text: failure.text, isError: true)
        } catch let error as ProtocolError {
            Log.host.notice("MCP tool \(name, privacy: .public) failed: \(error.code.rawValue, privacy: .public)")
            return MCPToolResult(text: "\(error.code.rawValue): \(error.message)", isError: true)
        } catch {
            let protocolError = ProtocolError(.internal, error.localizedDescription)
            Log.host.error("MCP tool \(name, privacy: .public) failed: \(protocolError.code.rawValue, privacy: .public)")
            return MCPToolResult(text: "\(protocolError.code.rawValue): \(protocolError.message)", isError: true)
        }
    }

    // MARK: - 6.1 to 6.3

    private func listDevices() async throws -> String {
        let local = await host.localMain()
        return try json(try await perform(.meshSnapshot, EmptyPayload(), on: local.id, as: MeshSnapshot.self))
    }

    private func listProjects() async throws -> String {
        struct MainProjects: Encodable {
            let id: UUID
            let name: String
            let online: Bool
            let projects: [ProjectSummary]?
            let error: String?
        }
        struct Result: Encodable { let mains: [MainProjects] }

        let mains = await orderedMains()
        let lists = await projectLists(of: mains)
        let entries = mains.enumerated().map { index, main -> MainProjects in
            guard main.online, let outcome = lists[index] else {
                return MainProjects(id: main.id, name: main.name, online: false, projects: nil, error: nil)
            }
            switch outcome {
            case .success(let projects):
                return MainProjects(id: main.id, name: main.name, online: true, projects: projects, error: nil)
            case .failure(let error):
                return MainProjects(id: main.id, name: main.name, online: false, projects: nil,
                                    error: "\(error.code.rawValue): \(error.message)")
            }
        }
        return try json(Result(mains: entries))
    }

    private func getProject(_ arguments: Arguments) async throws -> String {
        struct MainRef: Encodable { let id: UUID; let name: String }
        struct Result: Encodable {
            let main: MainRef
            let project: Project
            let taskCounts: [String: Int]
            let runs: [RunInfo]
        }

        let projectID = try arguments.project("project")
        let main = try await locate(projectID)
        let snapshot = try await perform(.projectsSnapshot, ProjectsSnapshotParams(projectID: projectID), on: main.id,
                                         as: ProjectsSnapshotResult.self)
        var counts: [String: Int] = ["todo": 0, "in_progress": 0, "review": 0, "done": 0, "broken": 0]
        for task in snapshot.tasks {
            let key = task.parseError == nil ? task.status.rawValue : "broken"
            counts[key, default: 0] += 1
        }
        return try json(Result(main: MainRef(id: main.id, name: main.name), project: snapshot.project,
                               taskCounts: counts, runs: snapshot.runs))
    }

    // MARK: - 6.4, 6.5

    private func createProject(_ arguments: Arguments) async throws -> String {
        let name = try arguments.requiredString("name", minLength: 1)
        let identifier = try arguments.project("identifier")
        let parent = try arguments.optionalProject("parent")
        let device = try arguments.optionalString("device")

        if let parent {
            let main = try await locate(parent)
            return try json(try await perform(.projectsCreate,
                                              ProjectsCreateParams(name: name, identifier: identifier, parentID: parent),
                                              on: main.id, as: ProjectSummary.self))
        }
        var target = await host.localMain()
        if let device {
            let mains = [await host.localMain()] + (await host.otherMains())
            let match = mains.first { UUID(uuidString: device) == $0.id }
                ?? mains.first { $0.name.caseInsensitiveCompare(device) == .orderedSame }
            guard let match else { throw ToolFailure.message("No Main named \"\(device)\".") }
            guard match.online else { throw ToolFailure.message("Main \"\(device)\" is not online.") }
            target = match
        }
        return try json(try await perform(.projectsCreate, ProjectsCreateParams(name: name, identifier: identifier),
                                          on: target.id, as: ProjectSummary.self))
    }

    /// No tool changes run configurations: an argument `runs` is ignored like any argument the schema does not list.
    private func updateProject(_ arguments: Arguments) async throws -> String {
        let projectID = try arguments.project("project")
        let name = try arguments.optionalString("name", minLength: 1)
        let description = try arguments.optionalString("description")
        let main = try await locate(projectID)
        let params = ProjectsUpdateParams(projectID: projectID,
                                          patch: ProjectPatch(name: name, description: description))
        return try json(try await perform(.projectsUpdate, params, on: main.id, as: Project.self))
    }

    // MARK: - 6.6 to 6.12

    private func listTasks(_ arguments: Arguments) async throws -> String {
        struct TaskLine: Encodable {
            let id: String
            let name: String?
            let status: TaskStatus?
            let created: Date?
            let updated: Date?
            let comments: Int?
            let parseError: String?
        }
        struct Result: Encodable { let project: String; let tasks: [TaskLine] }

        let projectID = try arguments.project("project")
        let status = try arguments.optionalEnum("status", TaskStatus.self)
        let main = try await locate(projectID)
        let snapshot = try await perform(.projectsSnapshot, ProjectsSnapshotParams(projectID: projectID), on: main.id,
                                         as: ProjectsSnapshotResult.self)
        let lines = snapshot.tasks
            .sorted { (TaskID($0.id)?.number ?? Int.max, $0.id) < (TaskID($1.id)?.number ?? Int.max, $1.id) }
            .compactMap { task -> TaskLine? in
                if let parseError = task.parseError {
                    guard status == nil else { return nil }
                    return TaskLine(id: task.id, name: nil, status: nil, created: nil, updated: nil, comments: nil,
                                    parseError: parseError)
                }
                if let status, task.status != status { return nil }
                return TaskLine(id: task.id, name: task.name, status: task.status, created: task.created,
                                updated: task.updated, comments: task.comments.count, parseError: nil)
            }
        return try json(Result(project: projectID, tasks: lines))
    }

    private func getTask(_ arguments: Arguments, context: MCPSessionContext) async throws -> String {
        struct Result: Encodable { let task: TaskItem; let attachmentsFolder: String? }

        let task = try arguments.task()
        if context.kind == .feedback, task.taskID != context.taskID?.uppercased() {
            throw ToolFailure.message("Forge sessions can only read their own feedback task.")
        }
        let main = try await locate(task.projectID)
        let snapshot = try await perform(.projectsSnapshot, ProjectsSnapshotParams(projectID: task.projectID),
                                         on: main.id, as: ProjectsSnapshotResult.self)
        guard let item = snapshot.tasks.first(where: { $0.id == task.taskID }) else {
            throw ToolFailure.protocolError(ProtocolError(.notFound, "Task \(task.taskID) does not exist."))
        }
        let folder = await host.localProjectRoot(task.projectID).map { root in
            root.appendingPathComponent(".hephaestus", isDirectory: true)
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent(task.taskID, isDirectory: true).path
        }
        return try json(Result(task: item, attachmentsFolder: folder))
    }

    private func createTask(_ arguments: Arguments) async throws -> String {
        let projectID = try arguments.project("project")
        let name = try arguments.requiredString("name", minLength: 1)
        let description = try arguments.optionalString("description")
        let status = try arguments.optionalEnum("status", TaskStatus.self)
        let main = try await locate(projectID)
        let params = TasksCreateParams(projectID: projectID, name: name, description: description, status: status)
        return try json(try await perform(.tasksCreate, params, on: main.id, as: TaskItem.self))
    }

    private func updateTask(_ arguments: Arguments) async throws -> String {
        let task = try arguments.task()
        let name = try arguments.optionalString("name", minLength: 1)
        let description = try arguments.optionalString("description")
        let status = try arguments.optionalEnum("status", TaskStatus.self)
        let main = try await locate(task.projectID)
        let params = TasksUpdateParams(projectID: task.projectID, taskID: task.taskID,
                                       patch: TaskPatch(name: name, description: description, status: status))
        return try json(try await perform(.tasksUpdate, params, on: main.id, as: TaskItem.self))
    }

    private func deleteTask(_ arguments: Arguments) async throws -> String {
        let task = try arguments.task()
        let main = try await locate(task.projectID)
        _ = try await perform(.tasksDelete, TasksDeleteParams(projectID: task.projectID, taskID: task.taskID),
                              on: main.id, as: EmptyPayload.self)
        return try json(["deleted": task.taskID])
    }

    private func commentTask(_ arguments: Arguments) async throws -> String {
        let task = try arguments.task()
        let body = try arguments.requiredString("body", minLength: 1)
        let paths = try arguments.optionalStrings("files") ?? []

        // Each path: an absolute path of a readable regular file of this Main; nothing is sent otherwise.
        var files: [(path: String, size: Int)] = []
        for path in paths {
            guard path.hasPrefix("/") else {
                throw ToolFailure.message("Cannot attach \(path): the path is not absolute.")
            }
            var info = stat()
            guard stat(path, &info) == 0 else {
                throw ToolFailure.message("Cannot attach \(path): \(String(cString: strerror(errno))).")
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw ToolFailure.message("Cannot attach \(path): it is not a regular file.")
            }
            guard access(path, R_OK) == 0 else {
                throw ToolFailure.message("Cannot attach \(path): \(String(cString: strerror(errno))).")
            }
            files.append((path, Int(info.st_size)))
        }

        let main = try await locate(task.projectID)
        var refs: [UploadRef] = []
        do {
            for file in files {
                refs.append(try await upload(file.path, size: file.size, projectID: task.projectID, on: main.id,
                                             begun: refs))
            }
        } catch let failure as UploadFailure {
            await cancelUploads(failure.begun, on: main.id)
            throw ToolFailure.message("Cannot attach \(failure.path): \(Self.withoutFinalPeriod(failure.reason)).")
        }
        let params = TasksAddCommentParams(projectID: task.projectID, taskID: task.taskID, body: body,
                                           attachments: refs, author: "Claude")
        do {
            return try json(try await perform(.tasksAddComment, params, on: main.id, as: TaskItem.self))
        } catch {
            await cancelUploads(refs, on: main.id)
            throw error
        }
    }

    private func startTaskSession(_ arguments: Arguments) async throws -> String {
        let task = try arguments.task()
        guard let mode = try arguments.optionalEnum("mode", SessionMode.self) else {
            throw ToolFailure.invalidArguments("mode is missing")
        }
        let instructions = try arguments.optionalString("instructions")
        if mode == .custom, (instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolFailure.message("Mode custom needs instructions.")
        }
        let main = try await locate(task.projectID)
        let params = SessionsStartParams(projectID: task.projectID, kind: .task, taskID: task.taskID, mode: mode,
                                         message: instructions)
        return try json(try await perform(.sessionsStart, params, on: main.id, as: SessionInfo.self))
    }

    // MARK: - 6.13 to 6.16

    private func listRuns(_ arguments: Arguments) async throws -> String {
        struct Result: Encodable { let configurations: [RunConfig]; let runs: [RunInfo] }

        let projectID = try arguments.project("project")
        let main = try await locate(projectID)
        let snapshot = try await perform(.projectsSnapshot, ProjectsSnapshotParams(projectID: projectID), on: main.id,
                                         as: ProjectsSnapshotResult.self)
        return try json(Result(configurations: snapshot.project.runs, runs: snapshot.runs))
    }

    private func startRun(_ arguments: Arguments) async throws -> String {
        let projectID = try arguments.project("project")
        let name = try arguments.requiredString("name", minLength: 1)
        let main = try await locate(projectID)
        return try json(try await perform(.runsStart, RunsStartParams(projectID: projectID, name: name), on: main.id,
                                          as: RunInfo.self))
    }

    private func stopRun(_ arguments: Arguments) async throws -> String {
        let projectID = try arguments.project("project")
        let runID = try arguments.runID()
        let main = try await locate(projectID)
        _ = try await perform(.runsStop, RunsStopParams(projectID: projectID, runID: runID), on: main.id,
                              as: EmptyPayload.self)
        return try json(["stopped": runID.uuidString])
    }

    private func getRunOutput(_ arguments: Arguments) async throws -> String {
        let projectID = try arguments.project("project")
        let runID = try arguments.runID()
        let main = try await locate(projectID)
        let output = try await perform(.runsOutput, RunsOutputParams(projectID: projectID, runID: runID), on: main.id,
                                       as: RunsOutputResult.self)
        guard !output.text.isEmpty else { return "(no output)" }
        let bytes = Array(output.text.utf8)
        let limit = 65_536
        guard bytes.count > limit else { return output.text }
        var tail = bytes[(bytes.count - limit)...]
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = tail[tail.index(after: newline)...]
        }
        return "[… earlier output omitted]\n" + String(decoding: tail, as: UTF8.self)
    }

    // MARK: - 6.17 to 6.19

    private func listWebTabs(_ arguments: Arguments) async throws -> String {
        let projectID = try arguments.project("project")
        let main = try await locate(projectID)
        let snapshot = try await perform(.projectsSnapshot, ProjectsSnapshotParams(projectID: projectID), on: main.id,
                                         as: ProjectsSnapshotResult.self)
        return try json(["tabs": snapshot.project.webTabs])
    }

    private func openWebTab(_ arguments: Arguments) async throws -> String {
        let projectID = try arguments.project("project")
        let url = try arguments.requiredString("url", minLength: 1)
        let title = try arguments.optionalString("title")
        let locked = try arguments.optionalBool("locked")
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parsed.host, !host.isEmpty
        else {
            throw ToolFailure.message("Use an absolute http or https URL.")
        }
        let main = try await locate(projectID)
        let params = TabsOpenParams(projectID: projectID, url: url, title: title, locked: locked)
        return try json(try await perform(.tabsOpen, params, on: main.id, as: WebTab.self))
    }

    private func search(_ arguments: Arguments) async throws -> String {
        let query = try arguments.requiredString("query", minLength: 1)
        let scopes = try arguments.optionalEnums("scopes", SearchScope.self)
        let params = SearchQueryParams(query: query, scopes: scopes, limit: 50)
        let mains = await orderedMains().filter(\.online)
        let host = self.host
        let results = await withTaskGroup(of: (Int, [SearchResult]?).self) { group in
            for (index, main) in mains.enumerated() {
                group.addTask {
                    let result = try? await Self.perform(host, .searchQuery, params, on: main.id,
                                                         as: SearchQueryResult.self)
                    return (index, result?.results)
                }
            }
            var collected: [Int: [SearchResult]] = [:]
            for await (index, results) in group {
                collected[index] = results
            }
            return collected
        }
        let merged = mains.indices.flatMap { results[$0] ?? [] }
        return try json(["results": merged])
    }

    // MARK: - 6.20 to 6.22

    private func listSkills() async throws -> String {
        let local = await host.localMain()
        let result = try await perform(.skillsList, EmptyPayload(), on: local.id, as: SkillsListResult.self)
        return try json(["skills": result.skills])
    }

    private func getSkill(_ arguments: Arguments) async throws -> String {
        struct Result: Encodable { let name: String; let content: String; let files: [SkillFile] }

        let name = try arguments.skillName()
        let local = await host.localMain()
        let files = try await perform(.skillsFiles, SkillsFilesParams(name: name), on: local.id,
                                      as: SkillsFilesResult.self)
        let content = try await perform(.skillsReadFile, SkillsReadFileParams(name: name, path: "SKILL.md"),
                                        on: local.id, as: SkillsReadFileResult.self)
        return try json(Result(name: name, content: String(decoding: content.data, as: UTF8.self),
                               files: files.files))
    }

    private func saveSkill(_ arguments: Arguments) async throws -> String {
        let name = try arguments.skillName()
        let content = try arguments.requiredString("content", minLength: 1)
        let data = Data(content.utf8)
        // 1. The SKILL.md validation; nothing is written when it fails.
        if let problem = SkillFrontMatter.problem(in: data, skillName: name) {
            throw ToolFailure.message(problem)
        }
        let local = await host.localMain()
        // 2. A new skill is created first.
        let existing = try await perform(.skillsList, EmptyPayload(), on: local.id, as: SkillsListResult.self)
        if !existing.skills.contains(where: { $0.name == name }) {
            let description = SkillFrontMatter.description(in: data) ?? ""
            _ = try await perform(.skillsCreate, SkillsCreateParams(name: name, description: description),
                                  on: local.id, as: SkillSummary.self)
        }
        // 3. SKILL.md.
        _ = try await perform(.skillsWriteFile, SkillsWriteFileParams(name: name, path: "SKILL.md", data: data),
                              on: local.id, as: EmptyPayload.self)
        // 4. Its summary.
        let skills = try await perform(.skillsList, EmptyPayload(), on: local.id, as: SkillsListResult.self)
        guard let summary = skills.skills.first(where: { $0.name == name }) else {
            throw ToolFailure.protocolError(ProtocolError(.notFound, "Skill \(name) does not exist."))
        }
        return try json(summary)
    }

    // MARK: - 6.23, 6.24

    private func forgePush(context: MCPSessionContext, docs: Bool) async throws -> String {
        do {
            if docs {
                return try await host.forgePushDocs(sessionID: context.sessionID)
            }
            return try await host.forgePushRegen(sessionID: context.sessionID)
        } catch let error as ProtocolError {
            throw ToolFailure.message(error.message)
        } catch {
            throw ToolFailure.message(error.localizedDescription)
        }
    }

    // MARK: - 7. Locating a project

    /// The Main hosting a project or sub project: this Main first, then the online other Mains, in parallel.
    private func locate(_ projectID: String) async throws -> MCPMain {
        let local = await host.localMain()
        if case .success(let projects)? = await projectLists(of: [local]).first ?? nil,
           Self.tree(projects, contains: projectID) {
            return local
        }
        let others = await host.otherMains().filter(\.online)
        let lists = await projectLists(of: others)
        for (index, main) in others.enumerated() {
            if case .success(let projects)? = lists[index], Self.tree(projects, contains: projectID) {
                return main
            }
        }
        throw ToolFailure.message("No online Main hosts project \(projectID).")
    }

    /// This Main, then the other Mains sorted by name (the order of list_projects).
    private func orderedMains() async -> [MCPMain] {
        let local = await host.localMain()
        let others = await host.otherMains()
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return [local] + others
    }

    /// `projects.list {}` on each online Main, in parallel; nil for an offline Main.
    private func projectLists(of mains: [MCPMain]) async -> [Result<[ProjectSummary], ProtocolError>?] {
        let host = self.host
        let outcomes = await withTaskGroup(of: (Int, Result<[ProjectSummary], ProtocolError>).self) { group in
            for (index, main) in mains.enumerated() where main.online {
                group.addTask {
                    do {
                        let result = try await Self.perform(host, .projectsList, EmptyPayload(), on: main.id,
                                                            as: ProjectsListResult.self)
                        return (index, .success(result.projects))
                    } catch {
                        return (index, .failure(Self.protocolError(error)))
                    }
                }
            }
            var collected: [Int: Result<[ProjectSummary], ProtocolError>] = [:]
            for await (index, outcome) in group {
                collected[index] = outcome
            }
            return collected
        }
        return mains.indices.map { outcomes[$0] }
    }

    private static func tree(_ projects: [ProjectSummary], contains projectID: String) -> Bool {
        projects.contains { $0.id == projectID || tree($0.children, contains: projectID) }
    }

    // MARK: - Uploads (6.11)

    private struct UploadFailure: Error {
        let path: String
        let reason: String
        let begun: [UploadRef]
    }

    /// Uploads one file to the Main hosting the task's project: uploads.begin, then its bytes in chunks of
    /// `MethodLimits.maxChunkSize`, one request at a time.
    private func upload(_ path: String, size: Int, projectID: String, on mainID: UUID,
                        begun: [UploadRef]) async throws -> UploadRef {
        let fileName = (path as NSString).lastPathComponent
        let uploadID: UUID
        do {
            uploadID = try await perform(.uploadsBegin,
                                         UploadsBeginParams(projectID: projectID, fileName: fileName, size: size),
                                         on: mainID, as: UploadsBeginResult.self).uploadID
        } catch {
            throw UploadFailure(path: path, reason: Self.reason(error), begun: begun)
        }
        let ref = UploadRef(uploadID: uploadID, fileName: fileName)
        let all = begun + [ref]
        guard size > 0 else { return ref }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw UploadFailure(path: path, reason: error.localizedDescription, begun: all)
        }
        defer { try? handle.close() }
        var offset = 0
        while offset < size {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: min(MethodLimits.maxChunkSize, size - offset)) ?? Data()
            } catch {
                throw UploadFailure(path: path, reason: error.localizedDescription, begun: all)
            }
            guard !chunk.isEmpty else {
                throw UploadFailure(path: path, reason: "the file changed while it was read", begun: all)
            }
            do {
                _ = try await perform(.uploadsChunk, UploadsChunkParams(uploadID: uploadID, offset: offset, data: chunk),
                                      on: mainID, as: EmptyPayload.self)
            } catch {
                throw UploadFailure(path: path, reason: Self.reason(error), begun: all)
            }
            offset += chunk.count
        }
        // A file that grew while it was read.
        if let extra = try? handle.read(upToCount: 1), !extra.isEmpty {
            throw UploadFailure(path: path, reason: "the file changed while it was read", begun: all)
        }
        return ref
    }

    /// uploads.cancel for each upload begun; errors ignored.
    private func cancelUploads(_ refs: [UploadRef], on mainID: UUID) async {
        for ref in refs {
            _ = try? await perform(.uploadsCancel, UploadsCancelParams(uploadID: ref.uploadID), on: mainID,
                                   as: EmptyPayload.self)
        }
    }

    // MARK: - Helpers

    private func perform<P: Encodable, R: Decodable>(_ method: RPCMethod, _ params: P, on deviceID: UUID,
                                                     as type: R.Type) async throws -> R {
        try await Self.perform(host, method, params, on: deviceID, as: type)
    }

    /// One protocol call; a failure throws `ToolFailure.protocolError`.
    private static func perform<P: Encodable, R: Decodable>(_ host: any MCPHost, _ method: RPCMethod, _ params: P,
                                                            on deviceID: UUID, as type: R.Type) async throws -> R {
        let result: Data
        do {
            result = try await host.perform(method.rawValue, params: try WireCoding.encodeJSON(params), on: deviceID)
        } catch {
            throw ToolFailure.protocolError(protocolError(error))
        }
        do {
            return try WireCoding.decodeJSON(type, from: result)
        } catch {
            throw ToolFailure.protocolError(ProtocolError(.internal, "Unexpected result of \(method.rawValue)."))
        }
    }

    /// The tool's result, JSON encoded compact with sorted keys, slashes not escaped, dates as on the wire.
    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try WireCoding.makeEncoder().encode(value), as: UTF8.self)
    }

    private static func protocolError(_ error: any Error) -> ProtocolError {
        if case ToolFailure.protocolError(let error)? = error as? ToolFailure {
            return error
        }
        return ProtocolError(error)
    }

    /// The reason of a failed upload request: `<code>: <message>`.
    private static func reason(_ error: any Error) -> String {
        let error = protocolError(error)
        return "\(error.code.rawValue): \(error.message)"
    }

    private static func withoutFinalPeriod(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }
}

/// Why a tool failed; its text is the result's text (section 8).
private enum ToolFailure: Error {
    /// An argument is missing, of the wrong type, or breaks a rule: `Invalid arguments: <what is wrong>.`
    case invalidArguments(String)
    /// A protocol call failed: `<code>: <message>`.
    case protocolError(ProtocolError)
    /// A tool-specific check failed: the message of section 6.
    case message(String)

    var text: String {
        switch self {
        case .invalidArguments(let what): return "Invalid arguments: \(what)."
        case .protocolError(let error): return "\(error.code.rawValue): \(error.message)"
        case .message(let text): return text
        }
    }
}

/// The `arguments` object of a tools/call, with the argument rules of section 6.
private struct Arguments {
    private let values: [String: Any]

    /// The arguments object (the dispatcher checked it is one); empty data is `{}`.
    init(_ data: Data) throws {
        guard !data.isEmpty else {
            values = [:]
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ToolFailure.invalidArguments("the arguments are not an object")
        }
        values = object
    }

    func requiredString(_ key: String, minLength: Int = 0) throws -> String {
        guard let value = try optionalString(key, minLength: minLength) else {
            throw ToolFailure.invalidArguments("\(key) is missing")
        }
        return value
    }

    func optionalString(_ key: String, minLength: Int = 0) throws -> String? {
        guard let raw = values[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else {
            throw ToolFailure.invalidArguments("\(key) must be a string")
        }
        guard value.count >= minLength else {
            throw ToolFailure.invalidArguments("\(key) must not be empty")
        }
        return value
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let raw = values[key], !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ToolFailure.invalidArguments("\(key) must be a boolean")
        }
        return number.boolValue
    }

    func optionalStrings(_ key: String) throws -> [String]? {
        guard let raw = values[key], !(raw is NSNull) else { return nil }
        guard let array = raw as? [Any], let strings = array as? [String], strings.count == array.count else {
            throw ToolFailure.invalidArguments("\(key) must be an array of strings")
        }
        return strings
    }

    func optionalEnum<T: RawRepresentable>(_ key: String, _ type: T.Type) throws -> T?
        where T.RawValue == String, T: CaseIterable {
        guard let text = try optionalString(key) else { return nil }
        guard let value = T(rawValue: text) else {
            let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolFailure.invalidArguments("\(key) must be one of \(allowed)")
        }
        return value
    }

    func optionalEnums<T: RawRepresentable>(_ key: String, _ type: T.Type) throws -> [T]?
        where T.RawValue == String, T: CaseIterable {
        guard let texts = try optionalStrings(key) else { return nil }
        return try texts.map { text in
            guard let value = T(rawValue: text) else {
                let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolFailure.invalidArguments("\(key) must hold values among \(allowed)")
            }
            return value
        }
    }

    /// A project argument: uppercased, then it must match ^[A-Z]{2,8}$.
    func project(_ key: String) throws -> String {
        guard let value = try optionalProject(key) else {
            throw ToolFailure.invalidArguments("\(key) is missing")
        }
        return value
    }

    func optionalProject(_ key: String) throws -> String? {
        guard let text = try optionalString(key) else { return nil }
        let value = text.uppercased()
        guard (2...8).contains(value.unicodeScalars.count),
              value.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) })
        else {
            throw ToolFailure.invalidArguments("\(key) is not a project identifier")
        }
        return value
    }

    /// The `task` argument: uppercased, then it must match ^[A-Z]{2,8}-[0-9]+$; its project is the part before `-`.
    func task() throws -> (taskID: String, projectID: String) {
        let value = try requiredString("task").uppercased()
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              (2...8).contains(parts[0].unicodeScalars.count),
              parts[0].unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }),
              !parts[1].isEmpty, parts[1].unicodeScalars.allSatisfy({ ("0"..."9").contains($0) })
        else {
            throw ToolFailure.invalidArguments("task is not a task id")
        }
        return (value, String(parts[0]))
    }

    /// The `run` argument: a run id.
    func runID() throws -> UUID {
        let value = try requiredString("run", minLength: 1)
        guard let id = UUID(uuidString: value) else {
            throw ToolFailure.invalidArguments("run is not a run id")
        }
        return id
    }

    /// The `name` of a skill: ^[a-z0-9-]{1,64}$.
    func skillName() throws -> String {
        let value = try requiredString("name")
        guard SkillName.isValid(value) else {
            throw ToolFailure.invalidArguments("name is not a skill name")
        }
        return value
    }
}
#endif
