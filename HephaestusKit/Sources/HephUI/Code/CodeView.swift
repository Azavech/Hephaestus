import Foundation
import HephClient
import HephCore
import HephEditor
import SwiftUI

/// The Code section of the project held by `store`. @MainActor; reads the Workspace, the SettingsStore, the window's
/// Selection and WindowBanners from the environment (docs/ui/code.md).
public struct CodeView: View {
    private let store: ProjectStore

    @Environment(Workspace.self) private var workspace
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(Selection.self) private var selection
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// The editor of this window, for its Find button.
    @State private var proxy = CodeEditorProxy()
    @State private var treeActions = FileTreeActions()
    /// Compact width: the paths of the pushed editors.
    @State private var stack: [String] = []

    public init(store: ProjectStore) {
        self.store = store
    }

    private var model: CodeSectionModel {
        CodeSectionModel.shared(store: store, workspace: workspace)
    }

    private var isCompact: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    /// `project.code`.
    private var code: String {
        store.project?.code ?? "."
    }

    private var projectName: String {
        store.project?.name ?? store.projectID
    }

    /// The name of the code folder; the project name when the code folder is the project root.
    private var folderName: String {
        let folder = ProjectPath.normalize(code)
        return folder.isEmpty ? projectName : ProjectPath.name(of: folder)
    }

    public var body: some View {
        let model = model
        layout(model)
            .fileTreeFlows(treeActions, tree: model.tree, handlers: handlers(model))
            .saveChangesDialog(model.questions)
            .onAppear {
                model.follow(settingsStore)
                model.setCodeFolder(code)
                open(item: selection.item, model: model, isAppearing: true)
            }
            .onChange(of: code) { _, code in
                model.setCodeFolder(code)
            }
            .onChange(of: selection.item) { _, item in
                open(item: item, model: model, isAppearing: false)
            }
            .onChange(of: model.activePath) { _, path in
                selection.item = path
            }
            .focusedSceneValue(\.saveDocumentAction, CodeDocumentActions.saveAction(model.activeDocument))
            .focusedSceneValue(\.closeTabAction, model.activeDocument.map { document in { model.close(document) } })
    }

    // MARK: - Layout

    @ViewBuilder
    private func layout(_ model: CodeSectionModel) -> some View {
        #if os(macOS)
        HSplitView {
            if model.isTreeVisible {
                treePane(model)
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 400)
            }
            editorArea(model)
        }
        .toolbar {
            regularToolbar(model)
        }
        #else
        if isCompact {
            NavigationStack(path: $stack) {
                treePane(model)
                    .navigationTitle(projectName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        compactTreeToolbar(model)
                    }
                    .navigationDestination(for: String.self) { path in
                        CodeEditorScreen(model: model, path: path, stack: $stack, projectName: projectName)
                    }
            }
        } else {
            HStack(spacing: 0) {
                if model.isTreeVisible {
                    treePane(model)
                        .frame(width: 260)
                    Divider()
                }
                editorArea(model)
            }
            .toolbar {
                regularToolbar(model)
            }
        }
        #endif
    }

    private func treePane(_ model: CodeSectionModel) -> some View {
        VStack(spacing: 0) {
            if !isCompact {
                FileTreeHeader(title: folderName, tree: model.tree, actions: treeActions, newFileTitle: "New File…",
                               includesShowHiddenFiles: true)
                Divider()
            }
            FileTreeView(
                tree: model.tree,
                actions: treeActions,
                newFileTitle: "New File…",
                selectedPath: isCompact ? nil : model.activePath,
                missingMessage: "The code folder “\(code)” was not found on \(model.files.mainName).",
                onOpenFile: { path in
                    model.open(path)
                    if isCompact {
                        push(path)
                    }
                }
            )
        }
    }

    private func editorArea(_ model: CodeSectionModel) -> some View {
        EditorPane(model: model, document: model.activeDocument, showsTabStrip: true, projectName: projectName,
                   proxy: proxy)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Show Files / Hide Files, Find (iPadOS), Save.
    @ToolbarContentBuilder
    private func regularToolbar(_ model: CodeSectionModel) -> some ToolbarContent {
        #if os(macOS)
        let placement = ToolbarItemPlacement.automatic
        #else
        let placement = ToolbarItemPlacement.topBarTrailing
        #endif
        ToolbarItemGroup(placement: placement) {
            Button {
                model.isTreeVisible.toggle()
            } label: {
                Label(model.isTreeVisible ? "Hide Files" : "Show Files", systemImage: "sidebar.left")
            }
            .help(model.isTreeVisible ? "Hide Files" : "Show Files")
            #if os(iOS)
            Button {
                proxy.showFind()
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            #endif
            Button {
                CodeDocumentActions.save(model.activeDocument)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save")
            .disabled(!CodeDocumentActions.canSave(model.activeDocument))
        }
    }

    #if os(iOS)
    /// The "+" and "…" menus of the tree header, and Open Files.
    @ToolbarContentBuilder
    private func compactTreeToolbar(_ model: CodeSectionModel) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            FileTreeAddMenu(tree: model.tree, actions: treeActions, newFileTitle: "New File…")
            FileTreeMoreMenu(tree: model.tree, includesShowHiddenFiles: true)
            if !model.documents.isEmpty {
                Menu {
                    ForEach(model.documents) { document in
                        Button {
                            model.activePath = document.path
                            push(document.path)
                        } label: {
                            OpenFileLabel(document: document, isActive: document.path == model.activePath)
                        }
                    }
                } label: {
                    Label("Open Files", systemImage: "doc.on.doc")
                }
            }
        }
    }
    #endif

    // MARK: - Tree flows

    private func handlers(_ model: CodeSectionModel) -> FileTreeActionHandlers {
        FileTreeActionHandlers(
            newFileMenuTitle: "New File…",
            newFileSheetTitle: "New File",
            newFileName: { $0 },
            didCreateFile: { path in
                model.open(path)
                if isCompact {
                    push(path)
                }
            },
            didRename: { oldPath, newPath in
                model.didRename(from: oldPath, to: newPath)
                stack = stack.map { ProjectPath.rebase($0, from: oldPath, to: newPath) }
            },
            didDelete: { path in
                model.didDelete(path)
            },
            hasDirtyDocument: { path in
                model.hasDirtyDocument(at: path)
            }
        )
    }

    // MARK: - Navigation and selection

    /// Opens the item of the selection: its path, then its `#L<line>`; compact width pushes the editor.
    private func open(item: String?, model: CodeSectionModel, isAppearing: Bool) {
        guard let item else {
            if isAppearing {
                selection.item = model.activePath
            }
            return
        }
        let (path, line) = ProjectPath.splitLineSuffix(item)
        guard !path.isEmpty else { return }
        var didOpen = false
        if path != model.activePath {
            model.open(path)
            didOpen = true
            let tree = model.tree
            Task {
                await tree.reveal(path)
            }
        }
        if let line {
            model.document(at: path)?.selectLine(line)
            selection.item = path
        }
        if isCompact && (didOpen || line != nil) {
            push(path)
        }
    }

    /// Pushes the editor of `path`, unless it is already the top of the stack.
    private func push(_ path: String) {
        if stack.last != path {
            stack.append(path)
        }
    }
}

/// Save of the toolbar, ⌘S and the compact editor screen.
@MainActor
enum CodeDocumentActions {
    /// The document is text, dirty, without a conflict banner, and its Main is connected.
    static func canSave(_ document: EditorDocument?) -> Bool {
        guard let document else { return false }
        return document.content == .text && document.isDirty && document.banner != .conflict
            && document.files.isConnected
    }

    static func save(_ document: EditorDocument?) {
        guard let document else { return }
        Task {
            await document.save()
        }
    }

    /// The `saveDocumentAction` of a document: published while its content is text.
    static func saveAction(_ document: EditorDocument?) -> (() -> Void)? {
        guard let document, document.content == .text else { return nil }
        return {
            save(document)
        }
    }
}

#if os(iOS)
/// An open document in an Open Files menu: a checkmark on the active one, "●" before dirty ones.
private struct OpenFileLabel: View {
    let document: EditorDocument
    let isActive: Bool

    var body: some View {
        let title = (document.isDirty ? "● " : "") + document.fileName
        if isActive {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// The editor of one document, pushed in compact width.
private struct CodeEditorScreen: View {
    let model: CodeSectionModel
    let path: String
    @Binding var stack: [String]
    let projectName: String

    /// The editor of this screen, for its Find button.
    @State private var proxy = CodeEditorProxy()

    var body: some View {
        let document = model.document(at: path)
        EditorPane(model: model, document: document, showsTabStrip: false, projectName: projectName, proxy: proxy)
            .navigationTitle(document.map { $0.fileName + ($0.isDirty ? " ●" : "") } ?? ProjectPath.name(of: path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        proxy.showFind()
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    Button {
                        CodeDocumentActions.save(document)
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!CodeDocumentActions.canSave(document))
                    Menu {
                        ForEach(model.documents) { other in
                            Button {
                                show(other)
                            } label: {
                                OpenFileLabel(document: other, isActive: other.path == path)
                            }
                        }
                        Divider()
                        Button("Close File") {
                            if let document {
                                model.close(document)
                            }
                        }
                    } label: {
                        Label("Open Files", systemImage: "doc.on.doc")
                    }
                }
            }
            .onAppear {
                if document != nil && model.activePath != path {
                    model.activePath = path
                }
            }
            .onChange(of: document == nil) { _, isClosed in
                if isClosed {
                    stack.removeAll { $0 == path }
                }
            }
    }

    /// Shows another open document in place of this one.
    private func show(_ document: EditorDocument) {
        model.activePath = document.path
        guard document.path != path else { return }
        if let index = stack.lastIndex(of: path) {
            stack[index] = document.path
        } else {
            stack.append(document.path)
        }
    }
}
#endif

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    CodeView(store: appModel.workspace.projectStore(mainDeviceID: studio, projectID: "HEPH"))
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, projectID: "HEPH", section: .code))
}
