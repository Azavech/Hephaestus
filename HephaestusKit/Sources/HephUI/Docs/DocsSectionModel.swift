import Foundation
import HephClient
import HephCore
import Observation

/// The state of the Docs section of one project: tree, shown document, history, shared by every window showing it,
/// for the life of the process (docs/ui/docs.md, "Section model").
@MainActor @Observable
final class DocsSectionModel {
    /// The models, by project identifier.
    private static var models: [String: DocsSectionModel] = [:]

    /// The model of `store.projectID`, created on first use; its files go to `store.mainDeviceID`.
    static func shared(store: ProjectStore, workspace: Workspace) -> DocsSectionModel {
        if let model = models[store.projectID] {
            model.files.mainDeviceID = store.mainDeviceID
            return model
        }
        let files = ProjectFiles(workspace: workspace, mainDeviceID: store.mainDeviceID, projectID: store.projectID)
        let model = DocsSectionModel(files: files, docsRoot: docsRoot(of: store.project))
        models[store.projectID] = model
        return model
    }

    /// `ProjectPath.join(ProjectPath.normalize(project.code), ProjectPath.normalize(project.docs))`.
    static func docsRoot(of project: Project?) -> String {
        ProjectPath.join(ProjectPath.normalize(project?.code ?? "."), ProjectPath.normalize(project?.docs ?? "docs"))
    }

    /// The project's file access.
    let files: ProjectFiles
    /// Filter `.markdown`, rooted at the docs root.
    let tree: FileTreeModel
    /// The shown document, never shared with the Code section.
    private(set) var document: EditorDocument?
    /// Edit mode.
    var isEditing = false
    /// Paths for Back, most recent last.
    private(set) var backStack: [String] = []
    /// Paths for Forward, most recent last.
    private(set) var forwardStack: [String] = []
    /// Heading slug to scroll to once the document is rendered.
    var pendingAnchor: String?
    /// Source of the live preview.
    var previewText = ""
    /// Regular width: the tree pane is shown.
    var isTreeVisible = true
    /// "Do you want to save the changes?" questions of leaving a document.
    let questions = SaveChangesQuestions()

    /// The setting `autosave`, given to the shown document.
    @ObservationIgnored private var autosave = true
    @ObservationIgnored private weak var settingsStore: SettingsStore?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?

    private init(files: ProjectFiles, docsRoot: String) {
        self.files = files
        tree = FileTreeModel(files: files, rootPath: docsRoot, filter: .markdown)
        tree.onError = { message in
            AppModel.shared.banners.post(Banner(style: .error, message: message))
        }
        let tree = tree
        Task {
            await tree.loadRoot()
        }
    }

    /// The document's `autosaveEnabled` follows the setting `autosave`: set now and on each change.
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
        autosave = settings.autosave
        if let document, document.autosaveEnabled != settings.autosave {
            document.autosaveEnabled = settings.autosave
        }
    }

    /// When `code` or `docs` changes, the tree takes the new docs root.
    func setDocsRoot(_ root: String) {
        guard root != tree.rootPath else { return }
        let tree = tree
        Task {
            await tree.setRoot(root)
        }
    }

    // MARK: - Showing a document

    /// Shows a document (docs/ui/docs.md, "Showing a document"). Returns false when leaving the shown document was
    /// cancelled: nothing changed.
    @discardableResult
    func show(path: String, anchor: String?, recordHistory: Bool) async -> Bool {
        if let document, document.path == path {
            pendingAnchor = anchor
            return true
        }
        let previousPath = document?.path
        guard await leave() else { return false }
        if recordHistory, let previousPath {
            backStack.append(previousPath)
            forwardStack = []
        }
        replaceDocument(with: path, anchor: anchor)
        return true
    }

    /// Back: the last path of `backStack`, shown without recording; the shown path goes on `forwardStack`.
    func goBack() async {
        guard let target = backStack.last else { return }
        let currentPath = document?.path
        guard await leave() else { return }
        if let index = backStack.lastIndex(of: target) {
            backStack.remove(at: index)
        }
        if let currentPath {
            forwardStack.append(currentPath)
        }
        replaceDocument(with: target, anchor: nil)
    }

    /// Forward: the reverse of Back.
    func goForward() async {
        guard let target = forwardStack.last else { return }
        let currentPath = document?.path
        guard await leave() else { return }
        if let index = forwardStack.lastIndex(of: target) {
            forwardStack.remove(at: index)
        }
        if let currentPath {
            backStack.append(currentPath)
        }
        replaceDocument(with: target, anchor: nil)
    }

    /// ⌘W: leaves the shown document, then shows none.
    func closeDocument() async {
        guard document != nil, await leave() else { return }
        document = nil
        isEditing = false
    }

    /// Done: leaves edit mode; a dirty document is saved when autosave is on.
    func endEditing() {
        isEditing = false
        if let document, document.isDirty, document.autosaveEnabled {
            Task {
                await document.save()
            }
        }
    }

    /// The first of `README.md` and `index.md` (names compared ignoring case) among the docs root's entries.
    func defaultDocumentPath() -> String? {
        let entries = (tree.children(of: tree.rootPath) ?? []).filter { !$0.isDirectory }
        for name in ["README.md", "index.md"] {
            if let entry = entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return entry.path
            }
        }
        return nil
    }

    /// Leaving the shown document (docs/ui/docs.md, "Leaving a document"): not dirty, it goes on; dirty with autosave,
    /// it is saved and goes on once clean; dirty without autosave, the question decides. Going on closes it.
    private func leave() async -> Bool {
        guard let document else { return true }
        if document.isDirty {
            if document.autosaveEnabled {
                await DocumentSaving.saveAndWait(document)
                guard !document.isDirty else { return false }
            } else {
                switch await questions.ask(fileName: document.fileName) {
                case .save:
                    await DocumentSaving.saveAndWait(document)
                    guard !document.isDirty else { return false }
                case .dontSave:
                    break
                case .cancel:
                    return false
                }
            }
        }
        // Another action replaced the document meanwhile: this one does not go on.
        guard self.document === document else { return false }
        document.close()
        return true
    }

    /// A new document is created and loaded; reading mode; the anchor waits for the rendering; the tree reveals it.
    private func replaceDocument(with path: String, anchor: String?) {
        let document = EditorDocument(files: files, path: path)
        document.autosaveEnabled = autosave
        document.onError = { message in
            AppModel.shared.banners.post(Banner(style: .error, message: message))
        }
        // Deleted on the Main while not dirty, or closed from its "Deleted on the Main" banner.
        document.onRemoved = { [weak self] document in
            self?.closeWithoutSaving(document)
        }
        self.document = document
        isEditing = false
        pendingAnchor = anchor
        Task {
            await document.load()
        }
        let tree = tree
        Task {
            await tree.reveal(path)
        }
    }

    private func closeWithoutSaving(_ document: EditorDocument) {
        guard self.document === document else { return }
        document.close()
        self.document = nil
        isEditing = false
    }

    // MARK: - Tree operations

    /// After a rename made from this device: the shown document at or inside the old path moves, and so do the
    /// paths of the history.
    func didRename(from oldPath: String, to newPath: String) {
        if let document, ProjectPath.isSameOrInside(document.path, oldPath) {
            document.moved(to: ProjectPath.rebase(document.path, from: oldPath, to: newPath))
        }
        backStack = backStack.map { ProjectPath.rebase($0, from: oldPath, to: newPath) }
        forwardStack = forwardStack.map { ProjectPath.rebase($0, from: oldPath, to: newPath) }
    }

    /// After a deletion: the shown document at or inside the path is closed without saving.
    func didDelete(_ path: String) {
        if let document, ProjectPath.isSameOrInside(document.path, path) {
            closeWithoutSaving(document)
        }
    }

    /// Whether the shown document is at or inside the path and dirty.
    func hasDirtyDocument(at path: String) -> Bool {
        guard let document else { return false }
        return document.isDirty && ProjectPath.isSameOrInside(document.path, path)
    }
}
