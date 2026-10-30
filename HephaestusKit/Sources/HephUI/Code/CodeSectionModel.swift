import Foundation
import HephClient
import HephCore
import Observation

/// The state of the Code section of one project: tree, open tabs and active file, shared by every window showing it,
/// for the life of the process (docs/ui/code.md, "Section model").
@MainActor @Observable
final class CodeSectionModel {
    /// The models, by project identifier.
    private static var models: [String: CodeSectionModel] = [:]

    /// The model of `store.projectID`, created on first use; its files go to `store.mainDeviceID`.
    static func shared(store: ProjectStore, workspace: Workspace) -> CodeSectionModel {
        if let model = models[store.projectID] {
            model.files.mainDeviceID = store.mainDeviceID
            return model
        }
        let files = ProjectFiles(workspace: workspace, mainDeviceID: store.mainDeviceID, projectID: store.projectID)
        let model = CodeSectionModel(files: files, codeFolder: ProjectPath.normalize(store.project?.code ?? "."))
        models[store.projectID] = model
        return model
    }

    /// The project's file access.
    let files: ProjectFiles
    /// Filter `.all`, rooted at the code folder.
    let tree: FileTreeModel
    /// The open tabs, in tab order.
    private(set) var documents: [EditorDocument] = []
    /// Path of the active tab.
    var activePath: String?
    /// Regular width: the tree pane is shown.
    var isTreeVisible = true
    /// "Do you want to save the changes?" questions of closing tabs.
    let questions = SaveChangesQuestions()

    /// The setting `autosave`, given to every document.
    @ObservationIgnored private var autosave = true
    @ObservationIgnored private weak var settingsStore: SettingsStore?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?

    private init(files: ProjectFiles, codeFolder: String) {
        self.files = files
        tree = FileTreeModel(files: files, rootPath: codeFolder, filter: .all)
        tree.onError = { message in
            AppModel.shared.banners.post(Banner(style: .error, message: message))
        }
        let tree = tree
        Task {
            await tree.loadRoot()
        }
    }

    /// The document of the active tab.
    var activeDocument: EditorDocument? {
        activePath.flatMap { document(at: $0) }
    }

    func document(at path: String) -> EditorDocument? {
        documents.first { $0.path == path }
    }

    /// `tree.showHidden` and every document's `autosaveEnabled` follow the settings `showHiddenFiles` and `autosave`:
    /// set now and on each change.
    func follow(_ settingsStore: SettingsStore) {
        guard self.settingsStore !== settingsStore else { return }
        self.settingsStore = settingsStore
        apply(settingsStore.settings)
        settingsTask?.cancel()
        let changes = settingsStore.changes()
        settingsTask = Task { [weak self] in
            for await settings in changes {
                self?.apply(settings)
            }
        }
    }

    private func apply(_ settings: DeviceSettings) {
        if tree.showHidden != settings.showHiddenFiles {
            tree.showHidden = settings.showHiddenFiles
        }
        autosave = settings.autosave
        for document in documents where document.autosaveEnabled != settings.autosave {
            document.autosaveEnabled = settings.autosave
        }
    }

    /// When `project.code` changes, the tree takes the new root; open tabs stay.
    func setCodeFolder(_ code: String) {
        let root = ProjectPath.normalize(code)
        guard root != tree.rootPath else { return }
        let tree = tree
        Task {
            await tree.setRoot(root)
        }
    }

    // MARK: - Opening

    /// Activates the tab of `path`, or opens a new one after the active tab (at the end when none) and loads it.
    func open(_ path: String) {
        if document(at: path) != nil {
            activePath = path
            return
        }
        let document = EditorDocument(files: files, path: path)
        document.autosaveEnabled = autosave
        document.onError = { message in
            AppModel.shared.banners.post(Banner(style: .error, message: message))
        }
        // Deleted on the Main while not dirty, or closed from its "Deleted on the Main" banner: removed without a
        // question.
        document.onRemoved = { [weak self] document in
            self?.remove(document)
        }
        let index = activePath.flatMap { active in documents.firstIndex { $0.path == active } }.map { $0 + 1 }
            ?? documents.count
        documents.insert(document, at: index)
        activePath = path
        Task {
            await document.load()
        }
    }

    // MARK: - Closing

    /// Closes one tab with the rules of "Closing a tab".
    func close(_ document: EditorDocument) {
        Task {
            await closeTab(document)
        }
    }

    /// Closes every other tab, each with the same rules.
    func closeOthers(_ document: EditorDocument) {
        let others = documents.filter { $0 !== document }
        Task {
            for other in others {
                await closeTab(other)
            }
        }
    }

    /// Not dirty: removed. Dirty with autosave: saved, then removed once clean. Dirty without autosave: the question
    /// "Do you want to save the changes?". Returns whether the tab was removed.
    @discardableResult
    func closeTab(_ document: EditorDocument) async -> Bool {
        guard documents.contains(where: { $0 === document }) else { return true }
        guard document.isDirty else {
            remove(document)
            return true
        }
        if document.autosaveEnabled {
            return await saveThenRemove(document)
        }
        switch await questions.ask(fileName: document.fileName) {
        case .save:
            return await saveThenRemove(document)
        case .dontSave:
            remove(document)
            return true
        case .cancel:
            return false
        }
    }

    /// The tab stays when the document stays dirty (an error or a conflict).
    private func saveThenRemove(_ document: EditorDocument) async -> Bool {
        await DocumentSaving.saveAndWait(document)
        guard !document.isDirty else { return false }
        remove(document)
        return true
    }

    /// Removes a tab without saving and closes its document. When it was active, the tab on its right becomes active,
    /// else the one on its left, else none.
    func remove(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        let wasActive = document.path == activePath
        documents.remove(at: index)
        document.close()
        guard wasActive else { return }
        if index < documents.count {
            activePath = documents[index].path
        } else if index > 0 {
            activePath = documents[index - 1].path
        } else {
            activePath = nil
        }
    }

    // MARK: - Tree operations

    /// After a rename made from this device: the open documents at or inside the old path move to the new path, and
    /// so does the active path.
    func didRename(from oldPath: String, to newPath: String) {
        for document in documents where ProjectPath.isSameOrInside(document.path, oldPath) {
            document.moved(to: ProjectPath.rebase(document.path, from: oldPath, to: newPath))
        }
        if let activePath, ProjectPath.isSameOrInside(activePath, oldPath) {
            self.activePath = ProjectPath.rebase(activePath, from: oldPath, to: newPath)
        }
    }

    /// After a deletion: the open documents at or inside the path are closed without saving.
    func didDelete(_ path: String) {
        for document in documents where ProjectPath.isSameOrInside(document.path, path) {
            remove(document)
        }
    }

    /// Whether an open document at or inside the path is dirty.
    func hasDirtyDocument(at path: String) -> Bool {
        documents.contains { $0.isDirty && ProjectPath.isSameOrInside($0.path, path) }
    }
}

/// The answer to "Do you want to save the changes to “<name>”?".
enum SaveChangesAnswer {
    case save, dontSave, cancel
}

/// One question waiting for its answer.
@MainActor
final class SaveChangesQuestion: Identifiable {
    let id = UUID()
    let fileName: String
    private var continuation: CheckedContinuation<SaveChangesAnswer, Never>?

    init(fileName: String, continuation: CheckedContinuation<SaveChangesAnswer, Never>) {
        self.fileName = fileName
        self.continuation = continuation
    }

    fileprivate func resume(_ answer: SaveChangesAnswer) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

/// The "Do you want to save the changes?" questions of a section model; the dialog of every window showing the
/// section shows the first one, and any of them answers it.
@MainActor @Observable
final class SaveChangesQuestions {
    private(set) var pending: [SaveChangesQuestion] = []

    var current: SaveChangesQuestion? {
        pending.first
    }

    /// Asks and waits for the answer.
    func ask(fileName: String) async -> SaveChangesAnswer {
        await withCheckedContinuation { continuation in
            pending.append(SaveChangesQuestion(fileName: fileName, continuation: continuation))
        }
    }

    func answer(_ question: SaveChangesQuestion, with answer: SaveChangesAnswer) {
        guard let index = pending.firstIndex(where: { $0 === question }) else { return }
        pending.remove(at: index)
        question.resume(answer)
    }
}

/// Saving a document before it is closed or left.
@MainActor
enum DocumentSaving {
    /// `save()`, then waits until no save of the document runs: a save asked while another runs is run when it ends.
    static func saveAndWait(_ document: EditorDocument) async {
        await document.save()
        while document.isSaving {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = document.isSaving
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}
