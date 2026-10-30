import Foundation
import HephCore
import Observation

/// What a file tree shows.
public enum FileTreeFilter: Sendable {
    case all, markdown
}

/// The state of the root listing of a file tree.
public enum FileTreeRootState: Equatable, Sendable {
    case loading, loaded, missing, failed(String)
}

/// A lazily loaded tree of a project folder, kept current from `files.changed` (docs/ui/code.md, "FileTreeModel").
@MainActor @Observable
public final class FileTreeModel {
    /// Exact names left out unless `showHidden` (always left out by the `.markdown` filter).
    public static let hiddenNames: Set<String> = [".git", ".hephaestus", ".build", "DerivedData", "node_modules",
                                                  ".DS_Store"]

    public let files: ProjectFiles
    public let filter: FileTreeFilter
    public private(set) var rootPath: String
    public private(set) var rootState: FileTreeRootState = .loading
    public private(set) var expanded: Set<String> = []
    /// Default false.
    public var showHidden = false
    @ObservationIgnored public var onError: (@MainActor (String) -> Void)?

    /// The raw entries of each loaded folder, in the order of `files.list`.
    private var loaded: [String: [FileEntry]] = [:]
    /// The listings running, by folder.
    private var loading: [String: Int] = [:]
    /// The last listing started for each folder: an older answer is not applied.
    @ObservationIgnored private var listingTokens: [String: Int] = [:]
    @ObservationIgnored private var nextToken = 0
    @ObservationIgnored private var changesTask: Task<Void, Never>?

    public init(files: ProjectFiles, rootPath: String, filter: FileTreeFilter) {
        self.files = files
        self.rootPath = rootPath
        self.filter = filter
        let changes = files.changes()
        changesTask = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                await self.apply(change)
            }
        }
    }

    /// nil for a folder not loaded, else its entries filtered.
    public func children(of folderPath: String) -> [FileEntry]? {
        guard let entries = loaded[folderPath] else { return nil }
        switch filter {
        case .all:
            return showHidden ? entries : entries.filter { !Self.hiddenNames.contains($0.name) }
        case .markdown:
            return entries.filter { entry in
                guard !Self.hiddenNames.contains(entry.name) else { return false }
                if entry.isDirectory {
                    return true
                }
                let fileExtension = (entry.name as NSString).pathExtension.lowercased()
                return fileExtension == "md" || fileExtension == "markdown"
            }
        }
    }

    /// True while a listing of that folder runs.
    public func isLoading(_ folderPath: String) -> Bool {
        loading[folderPath, default: 0] > 0
    }

    /// Expanding adds the folder to `expanded` and lists it when it is not loaded; collapsing keeps its entries.
    public func setExpanded(_ folderPath: String, _ isExpanded: Bool) {
        if isExpanded {
            expanded.insert(folderPath)
            if loaded[folderPath] == nil, !isLoading(folderPath) {
                Task {
                    await list(folderPath)
                }
            }
        } else {
            expanded.remove(folderPath)
        }
    }

    /// Lists the root.
    public func loadRoot() async {
        if loaded[rootPath] == nil {
            rootState = .loading
        }
        await list(rootPath)
    }

    /// Forgets every loaded folder and `expanded`, then lists the new root.
    public func setRoot(_ rootPath: String) async {
        self.rootPath = rootPath
        loaded = [:]
        expanded = []
        listingTokens = [:]
        rootState = .loading
        await loadRoot()
    }

    /// Lists the root and every loaded folder again.
    public func refresh() async {
        var folders = Set(loaded.keys)
        folders.insert(rootPath)
        await listAll(folders)
    }

    /// Expands, and loads when needed, every ancestor folder of `path` below `rootPath`, top down.
    public func reveal(_ path: String) async {
        let path = ProjectPath.normalize(path)
        guard ProjectPath.isSameOrInside(path, rootPath), path != rootPath else { return }
        var ancestors: [String] = []
        var folder = ProjectPath.parent(of: path)
        while folder != rootPath, ProjectPath.isSameOrInside(folder, rootPath), !folder.isEmpty {
            ancestors.insert(folder, at: 0)
            folder = ProjectPath.parent(of: folder)
        }
        for ancestor in ancestors {
            expanded.insert(ancestor)
            if loaded[ancestor] == nil {
                await list(ancestor)
            }
        }
    }

    /// `files.create` of a new empty file; the folder is listed again and, when it is not the root, expanded.
    public func createFile(named name: String, in folderPath: String) async throws -> FileEntry {
        try await create(name: name, in: folderPath, isDirectory: false)
    }

    /// `files.create` of a new folder; the folder is listed again and, when it is not the root, expanded.
    public func createFolder(named name: String, in folderPath: String) async throws -> FileEntry {
        try await create(name: name, in: folderPath, isDirectory: true)
    }

    /// `files.rename` within the item's folder; the folder is listed again and the expanded folders at or inside the
    /// old path are rebased onto the new path. Returns the new path.
    public func rename(_ path: String, to newName: String) async throws -> String {
        let parent = ProjectPath.parent(of: path)
        let newPath = ProjectPath.join(parent, newName)
        try await files.rename(from: path, to: newPath)
        let rebased = expanded.filter { ProjectPath.isSameOrInside($0, path) }
        expanded.subtract(rebased)
        let moved = Set(rebased.map { ProjectPath.rebase($0, from: path, to: newPath) })
        expanded.formUnion(moved)
        drop(path)
        await list(parent)
        for folder in moved.sorted() where loaded[folder] == nil {
            await list(folder)
        }
        return newPath
    }

    /// `files.delete` (the Main moves the item to its Trash); the item and its descendants are dropped and its
    /// folder is listed again.
    public func delete(_ path: String) async throws {
        try await files.delete(path)
        drop(path)
        expanded = expanded.filter { !ProjectPath.isSameOrInside($0, path) }
        await list(ProjectPath.parent(of: path))
    }

    /// Ends the task that consumes the changes.
    public func stop() {
        changesTask?.cancel()
        changesTask = nil
    }

    // MARK: - Private

    private func create(name: String, in folderPath: String, isDirectory: Bool) async throws -> FileEntry {
        let entry = try await files.create(ProjectPath.join(folderPath, name), isDirectory: isDirectory)
        await list(folderPath)
        if folderPath != rootPath {
            expanded.insert(folderPath)
        }
        return entry
    }

    /// `.paths`: for each path inside the root, its parent and the path itself are listed again when loaded.
    /// `.reconnected`: `refresh()`.
    private func apply(_ change: ProjectFileChange) async {
        switch change {
        case .paths(let paths):
            var folders = Set<String>()
            for path in paths where ProjectPath.isSameOrInside(path, rootPath) {
                for folder in [ProjectPath.parent(of: path), ProjectPath.normalize(path)] where loaded[folder] != nil {
                    folders.insert(folder)
                }
            }
            await listAll(folders)
        case .reconnected:
            await refresh()
        }
    }

    private func listAll(_ folders: Set<String>) async {
        await withTaskGroup(of: Void.self) { group in
            for folder in folders {
                group.addTask { @MainActor in
                    await self.list(folder)
                }
            }
        }
    }

    /// Lists a folder: its entries are stored, or the error is handled, whatever started the listing: the root's state;
    /// for another folder, `notFound` drops it with its descendants and is not reported, any other error removes it
    /// from `expanded` and is reported.
    private func list(_ folderPath: String) async {
        nextToken += 1
        let token = nextToken
        listingTokens[folderPath] = token
        loading[folderPath, default: 0] += 1
        defer {
            let count = loading[folderPath, default: 1] - 1
            loading[folderPath] = count > 0 ? count : nil
        }
        do {
            let entries = try await files.list(folderPath)
            guard listingTokens[folderPath] == token else { return }
            loaded[folderPath] = entries
            if folderPath == rootPath {
                rootState = .loaded
            }
        } catch {
            guard listingTokens[folderPath] == token, !(error is CancellationError) else { return }
            let notFound = (error as? ProtocolError)?.code == .notFound
            if folderPath == rootPath {
                rootState = notFound ? .missing : .failed(Workspace.message(of: error))
            } else if notFound {
                drop(folderPath)
                expanded = expanded.filter { !ProjectPath.isSameOrInside($0, folderPath) }
            } else {
                expanded.remove(folderPath)
                onError?("Could not list \(folderPath): \(Workspace.message(of: error))")
            }
        }
    }

    /// Forgets the loaded entries of a folder and of its descendants.
    private func drop(_ path: String) {
        for folder in loaded.keys where ProjectPath.isSameOrInside(folder, path) {
            loaded[folder] = nil
        }
    }
}
