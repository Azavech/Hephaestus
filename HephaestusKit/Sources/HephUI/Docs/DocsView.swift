import Foundation
import HephClient
import HephCore
import HephEditor
import SwiftUI

/// The Docs section of the project held by `store`. @MainActor; reads the Workspace, the SettingsStore, the window's
/// Selection, WindowContext and WindowBanners from the environment (docs/ui/docs.md).
public struct DocsView: View {
    private let store: ProjectStore

    @Environment(Workspace.self) private var workspace
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(Selection.self) private var selection
    @Environment(WindowBanners.self) private var banners
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var treeActions = FileTreeActions()
    /// Compact width: the document pane is pushed.
    @State private var isDocumentPushed = false
    /// Compact width, editing: the Preview segment of the Edit / Preview picker is chosen.
    @State private var showsPreview = false
    /// The section appeared with no document and no selection item: the default document is shown once the docs
    /// root is listed.
    @State private var wantsDefaultDocument = false

    public init(store: ProjectStore) {
        self.store = store
    }

    private var model: DocsSectionModel {
        DocsSectionModel.shared(store: store, workspace: workspace)
    }

    private var isCompact: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    private var docsRoot: String {
        DocsSectionModel.docsRoot(of: store.project)
    }

    private var projectName: String {
        store.project?.name ?? store.projectID
    }

    /// The docs folder's name; the project name when the docs root is the project root.
    private var folderName: String {
        docsRoot.isEmpty ? projectName : ProjectPath.name(of: docsRoot)
    }

    public var body: some View {
        let model = model
        content(model)
            .fileTreeFlows(treeActions, tree: model.tree, handlers: handlers(model))
            .saveChangesDialog(model.questions)
            .onAppear {
                model.follow(settingsStore)
                model.setDocsRoot(docsRoot)
                if let item = selection.item {
                    open(item: item, model: model)
                } else if let document = model.document {
                    selection.item = document.path
                } else {
                    wantsDefaultDocument = true
                    showDefaultDocumentIfWanted(model)
                }
            }
            .onChange(of: docsRoot) { _, root in
                model.setDocsRoot(root)
            }
            .onChange(of: selection.item) { _, item in
                open(item: item, model: model)
            }
            .onChange(of: model.document?.path) { _, path in
                selection.item = path
            }
            .onChange(of: model.tree.rootState) {
                showDefaultDocumentIfWanted(model)
            }
            .focusedSceneValue(\.saveDocumentAction, CodeDocumentActions.saveAction(model.document))
            .focusedSceneValue(\.closeTabAction, model.document == nil ? nil : {
                Task {
                    await model.closeDocument()
                }
            })
    }

    @ViewBuilder
    private func content(_ model: DocsSectionModel) -> some View {
        if model.tree.rootState == .missing {
            EmptyStateView(symbol: "folder.badge.questionmark", title: "This project has no docs folder.",
                           message: docsRoot) {
                Button("Create Docs Folder") {
                    createDocsFolder(model)
                }
                .disabled(!model.files.isConnected)
            }
        } else {
            layout(model)
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func layout(_ model: DocsSectionModel) -> some View {
        #if os(macOS)
        HSplitView {
            if model.isTreeVisible {
                treePane(model)
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 400)
            }
            documentPane(model, isCompact: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        if isCompact {
            NavigationStack {
                treePane(model)
                    .navigationTitle(projectName)
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(isPresented: $isDocumentPushed) {
                        documentPane(model, isCompact: true)
                    }
            }
        } else {
            HStack(spacing: 0) {
                if model.isTreeVisible {
                    treePane(model)
                        .frame(width: 260)
                    Divider()
                }
                documentPane(model, isCompact: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #endif
    }

    private func treePane(_ model: DocsSectionModel) -> some View {
        VStack(spacing: 0) {
            FileTreeHeader(title: folderName, tree: model.tree, actions: treeActions, newFileTitle: "New Document…",
                           includesShowHiddenFiles: false)
            Divider()
            FileTreeView(
                tree: model.tree,
                actions: treeActions,
                newFileTitle: "New Document…",
                selectedPath: isCompact ? nil : model.document?.path,
                missingMessage: "This project has no docs folder.",
                onOpenFile: { path in
                    let isCompact = isCompact
                    Task {
                        if await model.show(path: path, anchor: nil, recordHistory: true), isCompact {
                            isDocumentPushed = true
                        }
                    }
                }
            )
        }
    }

    private func documentPane(_ model: DocsSectionModel, isCompact: Bool) -> some View {
        DocsDocumentPane(model: model, store: store, isCompact: isCompact, showsPreview: $showsPreview)
    }

    // MARK: - Tree operations

    private func handlers(_ model: DocsSectionModel) -> FileTreeActionHandlers {
        FileTreeActionHandlers(
            newFileMenuTitle: "New Document…",
            newFileSheetTitle: "New Document",
            newFileName: { name in
                let lowercased = name.lowercased()
                return lowercased.hasSuffix(".md") || lowercased.hasSuffix(".markdown") ? name : name + ".md"
            },
            didCreateFile: { path in
                let isCompact = isCompact
                Task {
                    if await model.show(path: path, anchor: nil, recordHistory: true) {
                        model.isEditing = true
                        showsPreview = false
                        if isCompact {
                            isDocumentPushed = true
                        }
                    }
                }
            },
            didRename: { oldPath, newPath in
                model.didRename(from: oldPath, to: newPath)
            },
            didDelete: { path in
                model.didDelete(path)
            },
            hasDirtyDocument: { path in
                model.hasDirtyDocument(at: path)
            }
        )
    }

    /// Create Docs Folder: `files.create` of the docs root, then the root is listed again.
    private func createDocsFolder(_ model: DocsSectionModel) {
        let root = docsRoot
        Task {
            await banners.perform {
                _ = try await model.files.create(root, isDirectory: true)
                await model.tree.loadRoot()
            }
        }
    }

    // MARK: - Navigation and selection

    /// Shows the item's document; with `#L<line>`, edits it with the line selected; compact width pushes the pane.
    private func open(item: String?, model: DocsSectionModel) {
        guard let item else { return }
        let (path, line) = ProjectPath.splitLineSuffix(item)
        guard !path.isEmpty else { return }
        let isCompact = isCompact
        Task {
            var didShow = false
            if path != model.document?.path {
                guard await model.show(path: path, anchor: nil, recordHistory: true) else {
                    // Leaving the shown document was cancelled.
                    selection.item = model.document?.path
                    return
                }
                didShow = true
            }
            if let line, let document = model.document, document.path == path {
                model.isEditing = true
                showsPreview = false
                document.selectLine(line)
                selection.item = path
            }
            if isCompact && (didShow || line != nil) {
                isDocumentPushed = true
            }
        }
    }

    /// The first of `README.md` and `index.md` of the docs root, shown without recording once the root is listed.
    private func showDefaultDocumentIfWanted(_ model: DocsSectionModel) {
        guard wantsDefaultDocument, model.tree.rootState == .loaded else { return }
        wantsDefaultDocument = false
        guard model.document == nil, selection.item == nil, let path = model.defaultDocumentPath() else { return }
        Task {
            await model.show(path: path, anchor: nil, recordHistory: false)
        }
    }
}

/// The document pane: the banner, then the reader, the editor or the content placeholders, with its toolbar
/// (docs/ui/docs.md, "Layout").
private struct DocsDocumentPane: View {
    let model: DocsSectionModel
    let store: ProjectStore
    let isCompact: Bool
    @Binding var showsPreview: Bool

    /// The editor of this pane, for its Find button.
    @State private var proxy = CodeEditorProxy()

    var body: some View {
        let document = model.document
        #if os(iOS)
        if isCompact {
            content(document)
                .navigationTitle(document.map { $0.fileName + ($0.isDirty ? " ●" : "") } ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    compactToolbar(document)
                }
        } else {
            content(document)
                .toolbar {
                    regularToolbar(document)
                }
        }
        #else
        content(document)
            .toolbar {
                regularToolbar(document)
            }
        #endif
    }

    @ViewBuilder
    private func content(_ document: EditorDocument?) -> some View {
        if let document {
            VStack(spacing: 0) {
                DocumentBannerView(document: document)
                if document.content == .text {
                    if model.isEditing {
                        DocEditorView(model: model, document: document, store: store, proxy: proxy,
                                      isCompact: isCompact, showsPreview: showsPreview)
                    } else {
                        DocReaderView(source: document.text, document: document, model: model, store: store,
                                      appliesPendingAnchor: true)
                    }
                } else {
                    DocumentPlaceholderView(document: document)
                }
            }
        } else {
            Text("Select a document")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func regularToolbar(_ document: EditorDocument?) -> some ToolbarContent {
        #if os(macOS)
        let placement = ToolbarItemPlacement.automatic
        #else
        let placement = ToolbarItemPlacement.topBarTrailing
        #endif
        ToolbarItemGroup(placement: .navigation) {
            backButton
            forwardButton
        }
        ToolbarItemGroup(placement: placement) {
            if document?.content == .text {
                editButton
            }
            if model.isEditing {
                saveButton(document)
                #if os(iOS)
                findButton
                #endif
            }
            Button {
                model.isTreeVisible.toggle()
            } label: {
                Label(model.isTreeVisible ? "Hide Files" : "Show Files", systemImage: "sidebar.left")
            }
            .help(model.isTreeVisible ? "Hide Files" : "Show Files")
        }
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private func compactToolbar(_ document: EditorDocument?) -> some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            backButton
            Spacer()
            forwardButton
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if document?.content == .text {
                editButton
            }
            if model.isEditing {
                saveButton(document)
                findButton
            }
        }
        if model.isEditing && document?.content == .text {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $showsPreview) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var findButton: some View {
        Button {
            proxy.showFind()
        } label: {
            Label("Find", systemImage: "magnifyingglass")
        }
    }
    #endif

    private var backButton: some View {
        Button {
            Task {
                await model.goBack()
            }
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .help("Back")
        .disabled(model.backStack.isEmpty)
    }

    private var forwardButton: some View {
        Button {
            Task {
                await model.goForward()
            }
        } label: {
            Label("Forward", systemImage: "chevron.right")
        }
        .help("Forward")
        .disabled(model.forwardStack.isEmpty)
    }

    /// Edit while reading, Done while editing.
    @ViewBuilder
    private var editButton: some View {
        if model.isEditing {
            Button("Done") {
                model.endEditing()
            }
        } else {
            Button {
                showsPreview = false
                model.isEditing = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .help("Edit")
        }
    }

    private func saveButton(_ document: EditorDocument?) -> some View {
        Button {
            CodeDocumentActions.save(document)
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .help("Save")
        .disabled(!CodeDocumentActions.canSave(document))
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    DocsView(store: appModel.workspace.projectStore(mainDeviceID: studio, projectID: "HEPH"))
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, projectID: "HEPH", section: .docs))
}
