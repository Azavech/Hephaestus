import Foundation
import HephClient
import HephCore
import SwiftUI

/// What the flows of a file tree do in one section: the Code section opens files in tabs, the Docs section shows
/// documents (docs/ui/code.md, "Flows"; docs/ui/docs.md, "Tree operations").
struct FileTreeActionHandlers {
    /// "New File…", or "New Document…" in the Docs section.
    var newFileMenuTitle: String
    /// The title of the New File sheet.
    var newFileSheetTitle: String
    /// The name the new file gets from the name typed.
    var newFileName: (String) -> String
    /// After a file was created, once its sheet is dismissed: its path.
    var didCreateFile: @MainActor (String) -> Void
    /// After a rename made from this device: the old path and the new path.
    var didRename: @MainActor (_ oldPath: String, _ newPath: String) -> Void
    /// After a deletion: the deleted path.
    var didDelete: @MainActor (String) -> Void
    /// Whether an open document at or inside the path is dirty.
    var hasDirtyDocument: @MainActor (String) -> Bool
}

/// The context menus and flows of a file tree (New File…, New Folder…, Rename…, Delete…) in one window
/// (docs/ui/code.md, "Context menus", "Flows").
@MainActor @Observable
final class FileTreeActions {
    /// The `FileNameSheet` shown.
    enum Sheet: Identifiable, Hashable {
        case newFile(folder: String)
        case newFolder(folder: String)
        case rename(path: String)

        var id: Self { self }
    }

    var sheet: Sheet? {
        didSet {
            if sheet != nil {
                presentation += 1
            }
        }
    }
    /// The path whose deletion is being confirmed.
    var deletion: String?
    /// Runs once the sheet is dismissed.
    @ObservationIgnored var afterSheet: (@MainActor () -> Void)?
    /// Changes each time `sheet` is set to a sheet: a commit that ends after its sheet was cancelled, or after another
    /// sheet was presented, leaves nothing to run at a later dismissal.
    @ObservationIgnored private(set) var presentation = 0

    init() {}
}

/// The items of a context menu or of the header's "+" menu.
struct FileTreeMenuItems: View {
    enum Target {
        /// The header's "+" menu and the empty area: the root.
        case root
        case folder(String)
        case file(String)
    }

    let target: Target
    let tree: FileTreeModel
    let actions: FileTreeActions
    let newFileTitle: String

    /// The folder New File… and New Folder… act on: the root, the folder itself, or the file's folder.
    private var folder: String {
        switch target {
        case .root:
            return tree.rootPath
        case .folder(let path):
            return path
        case .file(let path):
            return ProjectPath.parent(of: path)
        }
    }

    private var itemPath: String? {
        switch target {
        case .root:
            return nil
        case .folder(let path), .file(let path):
            return path
        }
    }

    var body: some View {
        Group {
            Button(newFileTitle) {
                actions.sheet = .newFile(folder: folder)
            }
            Button("New Folder…") {
                actions.sheet = .newFolder(folder: folder)
            }
            if let itemPath {
                Button("Rename…") {
                    actions.sheet = .rename(path: itemPath)
                }
                Button("Delete…", role: .destructive) {
                    actions.deletion = itemPath
                }
            }
        }
        .disabled(!tree.files.isConnected)
    }
}

extension View {
    /// Presents the sheets and the delete confirmation of a file tree.
    func fileTreeFlows(_ actions: FileTreeActions, tree: FileTreeModel,
                       handlers: FileTreeActionHandlers) -> some View {
        modifier(FileTreeFlows(actions: actions, tree: tree, handlers: handlers))
    }
}

/// New File…, New Folder… and Rename… in a `FileNameSheet`; Delete… after a confirmation.
private struct FileTreeFlows: ViewModifier {
    @Bindable var actions: FileTreeActions
    let tree: FileTreeModel
    let handlers: FileTreeActionHandlers

    @Environment(WindowBanners.self) private var banners

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.sheet, onDismiss: {
                let action = actions.afterSheet
                actions.afterSheet = nil
                action?()
            }, content: sheetContent)
            .confirmationDialog(deletionTitle, isPresented: isConfirmingDeletion, titleVisibility: .visible,
                                presenting: actions.deletion) { path in
                Button("Move to Trash", role: .destructive) {
                    delete(path)
                }
                Button("Cancel", role: .cancel) {}
            } message: { path in
                if handlers.hasDirtyDocument(path) {
                    Text("Unsaved changes in open files will be lost.")
                }
            }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: FileTreeActions.Sheet) -> some View {
        switch sheet {
        case .newFile(let folder):
            let presentation = actions.presentation
            FileNameSheet(title: handlers.newFileSheetTitle, actionTitle: "Create", initialName: "",
                          existingNames: names(in: folder)) { name in
                let entry = try await tree.createFile(named: handlers.newFileName(name), in: folder)
                // Nothing is opened when the sheet was cancelled before the creation ended.
                guard actions.sheet != nil, actions.presentation == presentation else { return }
                let didCreateFile = handlers.didCreateFile
                actions.afterSheet = { didCreateFile(entry.path) }
            }
        case .newFolder(let folder):
            FileNameSheet(title: "New Folder", actionTitle: "Create", initialName: "",
                          existingNames: names(in: folder)) { name in
                _ = try await tree.createFolder(named: name, in: folder)
            }
        case .rename(let path):
            let currentName = ProjectPath.name(of: path)
            let otherNames = names(in: ProjectPath.parent(of: path)).filter { $0 != currentName }
            FileNameSheet(title: "Rename", actionTitle: "Rename", initialName: currentName,
                          existingNames: otherNames) { name in
                guard name != currentName else { return }
                let newPath = try await tree.rename(path, to: name)
                handlers.didRename(path, newPath)
            }
        }
    }

    /// The names of the entries the tree shows in a folder.
    private func names(in folder: String) -> [String] {
        (tree.children(of: folder) ?? []).map(\.name)
    }

    private var deletionTitle: String {
        guard let path = actions.deletion else { return "" }
        return "Move “\(ProjectPath.name(of: path))” to the Trash on \(tree.files.mainName)?"
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding {
            actions.deletion != nil
        } set: { isPresented in
            if !isPresented {
                actions.deletion = nil
            }
        }
    }

    /// Move to Trash: `tree.delete(_:)`; on success the section closes the open documents at or inside the path.
    private func delete(_ path: String) {
        let tree = tree
        let didDelete = handlers.didDelete
        Task {
            await banners.perform {
                try await tree.delete(path)
                didDelete(path)
            }
        }
    }
}
