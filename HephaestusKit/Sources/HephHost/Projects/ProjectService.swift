#if os(macOS)
import Foundation
import HephCore

/// `projects.*` except `projects.migrate` (docs/services/host.md §7).
actor ProjectService: HostMethodHandler {
    private let host: HostService

    init(host: HostService) {
        self.host = host
    }

    /// projects.list (§7.1).
    func list() async -> [ProjectSummary] {
        await host.registry.summaries()
    }

    /// projects.snapshot (§7.2): served while the project is migrating.
    func snapshot(projectID: String) async throws -> ProjectsSnapshotResult {
        let project = try await host.registry.project(projectID)
        let tasks = try await host.tasks.list(projectID: projectID)
        let bundles = await host.bundles.list(projectID: projectID)
        let sessions = try await host.sessions.sessions(projectID: projectID)
            .sorted { $0.created < $1.created }
        let runs = await host.runs.list(projectID: projectID).reversed()
        return ProjectsSnapshotResult(project: project, tasks: tasks, bundles: bundles, sessions: sessions,
                                      runs: Array(runs))
    }

    /// projects.create (§7.3).
    func create(_ params: ProjectsCreateParams) async throws -> ProjectSummary {
        let host = self.host
        // 1. Name and identifier.
        let name = try Self.mapped { try ProjectFile.validatedName(params.name) }
        let identifier = try Self.mapped { try ProjectIdentifier.validated(params.identifier) }

        // 2. Folder.
        let rawFolder = params.folderName ?? name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard let folder = ProjectFile.normalizedRelativePath(rawFolder), folder != ".",
              folder.split(separator: "/").first != ".hephaestus"
        else {
            throw Self.invalidFolder
        }

        // 3. Base.
        let base: URL
        if let parentID = params.parentID {
            let parent = try await host.registry.hosted(parentID)
            try await host.registry.checkWritable(parentID)
            // The folder of the Forge source project is the public repository.
            let forge = await host.settings().forge
            if forge.enabled {
                let sourceTree = [forge.sourceProjectID] + (await host.registry.descendants(of: forge.sourceProjectID))
                if sourceTree.contains(parentID) {
                    throw ProtocolError(.badRequest,
                                        "The Forge source project is a public repository: create this project elsewhere.")
                }
            }
            base = parent.root
        } else {
            base = await host.settings().projectsFolderURL
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            } catch {
                throw ProtocolError(.internal, error.localizedDescription)
            }
        }

        // 4. Target: strictly inside the base, symlinks resolved.
        let target = base.appendingPathComponent(folder, isDirectory: true).standardizedFileURL
        guard let realBase = ClaudePathEncoding.canonicalPath(base.path) else { throw Self.invalidFolder }
        let resolved: URL
        do {
            resolved = try PathResolver(root: URL(fileURLWithPath: realBase, isDirectory: true)).resolve(folder)
        } catch {
            throw Self.invalidFolder
        }
        guard resolved.path != realBase else { throw Self.invalidFolder }
        let targetExisted: Bool
        switch Self.itemKind(resolved) {
        case .none:
            targetExisted = false
        case .directory:
            if Self.itemKind(ProjectFile.url(projectRoot: resolved)) != nil {
                throw ProtocolError(.conflict, "\(target.path) is already a project.")
            }
            targetExisted = true
        case .other:
            throw ProtocolError(.conflict, "\(target.path) already exists.")
        }

        // 5. Identifier available on this Main and on the connected Mains.
        try await host.registry.checkIdentifiersAvailable([identifier])

        // 6. project.yml, .hephaestus/tasks/ and the docs folder.
        do {
            try ProjectFile.create(ProjectFile(id: identifier, name: name, description: params.description),
                                   projectRoot: target)
        } catch {
            // `.invalid` is thrown before anything is written.
            if case DataError.invalid = error {} else {
                Self.undoCreate(target: target, targetExisted: targetExisted)
            }
            throw ProjectRegistry.protocolError(error)
        }

        // 7. Registration.
        do {
            if let parentID = params.parentID {
                try await host.registry.write(parentID) { parent in
                    let file: ProjectFile
                    do {
                        file = try ProjectFile.update(projectRoot: parent.root) { file in
                            file.subprojects.append(folder)
                        }
                    } catch {
                        throw ProjectRegistry.protocolError(error)
                    }
                    let modified = ProjectRegistry.modificationDate(of: ProjectFile.url(projectRoot: parent.root))
                    await host.registry.reloaded(parentID, file: file, modified: modified)
                }
            } else {
                _ = try await host.registry.register(root: target, parentID: nil)
            }
        } catch {
            Self.undoCreate(target: target, targetExisted: targetExisted)
            throw ProjectRegistry.protocolError(error)
        }

        // 8. The new project's summary.
        guard let summary = Self.find(identifier, in: await host.registry.summaries()) else {
            throw ProtocolError(.internal, "Project \(identifier) is not hosted on this Main.")
        }
        return summary
    }

    /// projects.import (§7.4).
    func importFolder(_ params: ProjectsImportParams) async throws -> ProjectSummary {
        // 1. The folder.
        let root = URL(fileURLWithPath: try Self.absolutePath(params.path), isDirectory: true).standardizedFileURL
        guard Self.itemKind(root) == .directory else {
            throw ProtocolError(.notFound, "No folder at \(root.path).")
        }

        // 2. No overlap with a registered project.
        let realPath = ClaudePathEncoding.canonicalPath(root.path) ?? root.path
        for project in await host.registry.all() {
            let other = project.realRoot.path
            if realPath == other || realPath.hasPrefix(other + "/") || other.hasPrefix(realPath + "/") {
                throw ProtocolError(.conflict, "\(root.path) overlaps project \(project.file.name).")
            }
        }

        // 3. Identifiers to check.
        let hasFile = Self.itemKind(ProjectFile.url(projectRoot: root)) != nil
        var identifiers: [String] = []
        var newFile: ProjectFile?
        if hasFile {
            let file: ProjectFile
            do {
                file = try ProjectFile.load(projectRoot: root)
            } catch {
                throw ProtocolError(.badRequest, ProjectRegistry.protocolError(error).message)
            }
            identifiers.append(file.id)
            for entry in file.subprojects {
                guard let normalized = ProjectFile.normalizedRelativePath(entry), normalized != "." else { continue }
                let subRoot = ProjectRegistry.subprojectRoot(of: root, entry: normalized)
                if let subFile = try? ProjectFile.load(projectRoot: subRoot) {
                    identifiers.append(subFile.id)
                }
            }
        } else {
            guard let rawName = params.name, let rawIdentifier = params.identifier else {
                throw ProtocolError(.badRequest, "A name and an identifier are required.")
            }
            let name = try Self.mapped { try ProjectFile.validatedName(rawName) }
            let identifier = try Self.mapped { try ProjectIdentifier.validated(rawIdentifier) }
            identifiers.append(identifier)
            newFile = ProjectFile(id: identifier, name: name, description: nil)
        }

        // 4. Identifiers available.
        try await host.registry.checkIdentifiersAvailable(identifiers)

        // 5. project.yml for a folder without one.
        if let newFile {
            do {
                try ProjectFile.create(newFile, projectRoot: root)
            } catch {
                throw ProjectRegistry.protocolError(error)
            }
        }

        // 6. Registration, with the listed sub projects.
        let project: HostedProject
        do {
            project = try await host.registry.register(root: root, parentID: nil)
        } catch {
            throw ProjectRegistry.protocolError(error)
        }

        // 7. Its summary.
        guard let summary = Self.find(project.id, in: await host.registry.summaries()) else {
            throw ProtocolError(.notFound, "Project \(project.id) is not hosted on this Main.")
        }
        return summary
    }

    /// projects.update (§7.5).
    func update(projectID: String, patch: ProjectPatch) async throws -> Project {
        let host = self.host
        try await host.registry.write(projectID) { project in
            let file: ProjectFile
            do {
                file = try ProjectFile.update(projectRoot: project.root) { file in
                    if let name = patch.name { file.name = name }
                    if let description = patch.description { file.description = description }
                    if let runs = patch.runs {
                        file.runs = runs.map { ProjectFile.RunEntry(name: $0.name, command: $0.command, cwd: $0.cwd) }
                    }
                    if let skills = patch.skills { file.skills = skills }
                    if let claude = patch.claude { file.claude = claude }
                }
            } catch {
                throw ProjectRegistry.protocolError(error)
            }
            let modified = ProjectRegistry.modificationDate(of: ProjectFile.url(projectRoot: project.root))
            await host.registry.reloaded(projectID, file: file, modified: modified)
        }
        return try await host.registry.project(projectID)
    }

    /// projects.remove (§7.6).
    func remove(projectID: String, moveToTrash: Bool) async throws {
        let host = self.host
        // 1.
        try await host.registry.checkWritable(projectID)
        let project = try await host.registry.hosted(projectID)

        // 2. The sessions and runs of the project and of its sub projects.
        let ids = [projectID] + (await host.registry.descendants(of: projectID))
        let sessions: SessionService = host.sessions
        let runs: RunService = host.runs
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await sessions.stopAll(projectID: id) }
                group.addTask { await runs.stopAll(projectID: id) }
            }
        }

        let appSupport = host.appSupport
        guard let parentID = project.parentID else {
            // 3. Top-level project.
            if moveToTrash {
                await host.watcher.unwatch(project.root)
                do {
                    try appSupport.trashItem(project.realRoot)
                } catch {
                    await host.watcher.watch(project.root)
                    throw Self.trashFailure(project.root.path, error)
                }
            }
            await host.registry.unregister(projectID, forget: true)
            return
        }

        // 4. Sub project: one update of the parent's project.yml.
        try await host.registry.write(parentID) { parent in
            let file: ProjectFile
            do {
                file = try ProjectFile.update(projectRoot: parent.root) { file in
                    file.subprojects.removeAll { entry in
                        guard let normalized = ProjectFile.normalizedRelativePath(entry) else { return false }
                        return ProjectRegistry.subprojectRoot(of: parent.root, entry: normalized).path
                            == project.root.path
                    }
                    if moveToTrash {
                        do {
                            try appSupport.trashItem(project.realRoot)
                        } catch {
                            throw Self.trashFailure(project.root.path, error)
                        }
                    }
                }
            } catch {
                throw ProjectRegistry.protocolError(error)
            }
            let modified = ProjectRegistry.modificationDate(of: ProjectFile.url(projectRoot: parent.root))
            await host.registry.reloaded(parentID, file: file, modified: modified)
        }
    }

    // MARK: - HostMethodHandler

    func handle(method: String, params: Data, context: RequestContext) async throws -> Data {
        do {
            switch RPCMethod(rawValue: method) {
            case .projectsList:
                _ = try Self.decode(EmptyPayload.self, params, method)
                return try WireCoding.encodeJSON(ProjectsListResult(projects: await list()))
            case .projectsSnapshot:
                let request = try Self.decode(ProjectsSnapshotParams.self, params, method)
                return try WireCoding.encodeJSON(try await snapshot(projectID: request.projectID))
            case .projectsCreate:
                let request = try Self.decode(ProjectsCreateParams.self, params, method)
                return try WireCoding.encodeJSON(try await create(request))
            case .projectsImport:
                let request = try Self.decode(ProjectsImportParams.self, params, method)
                return try WireCoding.encodeJSON(try await importFolder(request))
            case .projectsUpdate:
                let request = try Self.decode(ProjectsUpdateParams.self, params, method)
                // §7.5: runs.start runs their commands without a permission request, so no Claude session (an MCP
                // tool) defines one; refused before the write.
                if request.patch.runs != nil, context.author == Self.claude {
                    throw ProtocolError(.badRequest, "Run configurations are changed by the user in the app.")
                }
                return try WireCoding.encodeJSON(try await update(projectID: request.projectID, patch: request.patch))
            case .projectsRemove:
                let request = try Self.decode(ProjectsRemoveParams.self, params, method)
                try await remove(projectID: request.projectID, moveToTrash: request.moveToTrash)
                return try WireCoding.encodeJSON(EmptyPayload())
            default:
                throw ProtocolError(.badRequest, "Unknown method \(method).")
            }
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    // MARK: - Private

    private enum ItemKind {
        case directory, other
    }

    private static let invalidFolder = ProtocolError(.badRequest, "Invalid folder name.")
    /// The `context.author` of the MCP tools.
    private static let claude = "Claude"

    /// What exists at `url` (lstat: a dangling symbolic link exists); a symbolic link to a folder is a folder.
    private static func itemKind(_ url: URL) -> ItemKind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        var target = stat()
        if stat(url.path, &target) == 0, (target.st_mode & S_IFMT) == S_IFDIR {
            return .directory
        }
        return .other
    }

    /// `~` or a leading `~/` is the home folder; any other path must be absolute.
    private static func absolutePath(_ path: String) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home + "/" + path.dropFirst(2)
        }
        guard path.hasPrefix("/") else {
            throw ProtocolError(.badRequest, "The path must be absolute.")
        }
        return path
    }

    /// When step 6 or 7 of §7.3 fails: the target folder is removed when step 6 created it; in a folder that existed
    /// before, the project.yml written by step 6 is removed.
    private static func undoCreate(target: URL, targetExisted: Bool) {
        let item = targetExisted ? ProjectFile.url(projectRoot: target) : target
        do {
            try FileManager.default.removeItem(at: item)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Log.host.error("Could not remove \(item.path) after a failed creation: \(error.localizedDescription)")
        }
    }

    private static func trashFailure(_ path: String, _ error: any Error) -> ProtocolError {
        var reason = error.localizedDescription
        if reason.hasSuffix(".") {
            reason.removeLast()
        }
        return ProtocolError(.unavailable, "Could not move \(path) to the Trash: \(reason).")
    }

    /// Runs a validation; its DataError becomes badRequest.
    private static func mapped<T>(_ validation: () throws -> T) throws -> T {
        do {
            return try validation()
        } catch {
            throw ProjectRegistry.protocolError(error)
        }
    }

    private static func find(_ identifier: String, in tree: [ProjectSummary]) -> ProjectSummary? {
        for summary in tree {
            if summary.id == identifier { return summary }
            if let match = find(identifier, in: summary.children) { return match }
        }
        return nil
    }

    /// WireCoding decoding of the params; a failure is badRequest "Invalid params for <method>: <coding path>.".
    private static func decode<P: Decodable>(_ type: P.Type, _ params: Data, _ method: String) throws -> P {
        try InboundRequest(id: 1, method: method, params: params).decodeParams(type)
    }
}
#endif
