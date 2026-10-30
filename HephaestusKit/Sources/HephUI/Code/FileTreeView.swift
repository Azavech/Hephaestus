import Foundation
import HephClient
import HephCore
import SwiftUI

/// The selection value of a tree row.
struct FileTreeItemID: Hashable {
    let path: String
    let isDirectory: Bool
}

/// The file tree of a section: a `List` of recursive `DisclosureGroup`s, or the state of the root listing
/// (docs/ui/code.md, "FileTreeView").
struct FileTreeView: View {
    let tree: FileTreeModel
    let actions: FileTreeActions
    /// "New File…", or "New Document…" in the Docs section.
    let newFileTitle: String
    /// The row shown as the list selection: the active file.
    let selectedPath: String?
    /// The text of the `missing` state.
    let missingMessage: String
    /// Choosing a file.
    let onOpenFile: (String) -> Void

    var body: some View {
        switch tree.rootState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            retryState(missingMessage)
        case .failed(let message):
            retryState(message)
        case .loaded:
            list
        }
    }

    private var list: some View {
        let entries = tree.children(of: tree.rootPath) ?? []
        return List(selection: selection) {
            ForEach(entries) { entry in
                FileTreeNode(entry: entry, tree: tree)
            }
        }
        .contextMenu(forSelectionType: FileTreeItemID.self) { items in
            FileTreeMenuItems(target: target(of: items.first), tree: tree, actions: actions,
                              newFileTitle: newFileTitle)
        }
        .overlay {
            if entries.isEmpty {
                Text("Empty folder")
                    .foregroundStyle(.secondary)
            }
        }
        #if os(iOS)
        .refreshable {
            await tree.refresh()
        }
        #endif
    }

    /// The row of `selectedPath` is selected; choosing a file opens it, choosing a folder toggles it. On iOS and
    /// iPadOS a disclosure row toggles by itself when it is tapped.
    private var selection: Binding<FileTreeItemID?> {
        Binding {
            selectedPath.map { FileTreeItemID(path: $0, isDirectory: false) }
        } set: { item in
            guard let item else { return }
            if item.isDirectory {
                #if os(macOS)
                tree.setExpanded(item.path, !tree.expanded.contains(item.path))
                #endif
            } else {
                onOpenFile(item.path)
            }
        }
    }

    private func target(of item: FileTreeItemID?) -> FileTreeMenuItems.Target {
        guard let item else { return .root }
        return item.isDirectory ? .folder(item.path) : .file(item.path)
    }

    private func retryState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task {
                    await tree.loadRoot()
                }
            }
            .disabled(!tree.files.isConnected)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A folder (a `DisclosureGroup` whose content is listed when it expands) or a file.
private struct FileTreeNode: View {
    let entry: FileEntry
    let tree: FileTreeModel

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: isExpanded) {
                if let children = tree.children(of: entry.path) {
                    ForEach(children) { child in
                        FileTreeNode(entry: child, tree: tree)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } label: {
                FileTreeRow(entry: entry)
            }
            .tag(FileTreeItemID(path: entry.path, isDirectory: true))
        } else {
            FileTreeRow(entry: entry)
                .tag(FileTreeItemID(path: entry.path, isDirectory: false))
        }
    }

    private var isExpanded: Binding<Bool> {
        Binding {
            tree.expanded.contains(entry.path)
        } set: { isExpanded in
            tree.setExpanded(entry.path, isExpanded)
        }
    }
}

/// The icon and the name; a hidden name is secondary.
private struct FileTreeRow: View {
    let entry: FileEntry

    var body: some View {
        Label {
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            FileIcon.image(forFileName: entry.name, isDirectory: entry.isDirectory)
        }
        .foregroundStyle(FileTreeModel.hiddenNames.contains(entry.name) ? .secondary : .primary)
    }
}

/// The header of the tree pane: the folder's name, the "+" menu and the "…" menu (docs/ui/code.md, "Header").
struct FileTreeHeader: View {
    let title: String
    let tree: FileTreeModel
    let actions: FileTreeActions
    let newFileTitle: String
    /// The Code section's "…" menu has Show Hidden Files; the Docs section's has Refresh only.
    let includesShowHiddenFiles: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            FileTreeAddMenu(tree: tree, actions: actions, newFileTitle: newFileTitle)
            FileTreeMoreMenu(tree: tree, includesShowHiddenFiles: includesShowHiddenFiles)
        }
        .padding(.horizontal, 10)
        #if os(macOS)
        .frame(height: 28)
        #else
        .frame(height: 36)
        #endif
    }
}

/// The "+" menu: New File… (New Document…) and New Folder…, acting on the root.
struct FileTreeAddMenu: View {
    let tree: FileTreeModel
    let actions: FileTreeActions
    let newFileTitle: String

    var body: some View {
        Menu {
            FileTreeMenuItems(target: .root, tree: tree, actions: actions, newFileTitle: newFileTitle)
        } label: {
            Label("New", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
    }
}

/// The "…" menu: Show Hidden Files (Code section) and Refresh.
struct FileTreeMoreMenu: View {
    let tree: FileTreeModel
    let includesShowHiddenFiles: Bool

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(WindowBanners.self) private var banners

    var body: some View {
        Menu {
            if includesShowHiddenFiles {
                Toggle("Show Hidden Files", isOn: showHiddenFiles)
            }
            Button("Refresh") {
                Task {
                    await tree.refresh()
                }
            }
            .disabled(!tree.files.isConnected)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
    }

    /// The setting `showHiddenFiles`, toggled with `settingsStore.update`; an error goes to the error banner.
    private var showHiddenFiles: Binding<Bool> {
        Binding {
            settingsStore.settings.showHiddenFiles
        } set: { _ in
            do {
                try settingsStore.update { $0.showHiddenFiles.toggle() }
            } catch {
                banners.showError(error)
            }
        }
    }
}
