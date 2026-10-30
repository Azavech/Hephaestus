import Foundation
import HephClient
import SwiftUI

/// One tab per open document, in a horizontal scroll view (docs/ui/code.md, "EditorTabStrip").
struct EditorTabStrip: View {
    let model: CodeSectionModel
    /// The name shown for the parent of a top-level file: the project's name.
    let projectName: String

    var body: some View {
        let documents = model.documents
        let names = documents.map(\.fileName)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(documents) { document in
                        EditorTab(
                            document: document,
                            isActive: document.path == model.activePath,
                            parentName: names.filter { $0 == document.fileName }.count > 1
                                ? parentName(of: document.path) : nil,
                            onSelect: { model.activePath = document.path },
                            onClose: { model.close(document) },
                            onCloseOthers: { model.closeOthers(document) }
                        )
                        .id(document.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onAppear {
                if let active = model.activeDocument {
                    proxy.scrollTo(active.id)
                }
            }
            .onChange(of: model.activePath) {
                if let active = model.activeDocument {
                    withAnimation {
                        proxy.scrollTo(active.id)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(height: 28)
        #else
        .frame(height: 36)
        #endif
    }

    private func parentName(of path: String) -> String {
        let parent = ProjectPath.parent(of: path)
        return parent.isEmpty ? projectName : ProjectPath.name(of: parent)
    }
}

/// One tab: the icon, the name, the parent folder when another open document has the same name, "●" when dirty,
/// and a close button.
private struct EditorTab: View {
    let document: EditorDocument
    let isActive: Bool
    let parentName: String?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void

    @State private var isHovered = false

    /// The file name, then " — <parent folder name>" in the secondary color.
    private var title: AttributedString {
        var title = AttributedString(document.fileName)
        if let parentName {
            var suffix = AttributedString(" — \(parentName)")
            suffix.foregroundColor = .secondary
            title += suffix
        }
        return title
    }

    /// Shown on macOS while the pointer is over the tab, always on iPadOS.
    private var showsCloseButton: Bool {
        #if os(macOS)
        return isHovered
        #else
        return true
        #endif
    }

    var body: some View {
        HStack(spacing: 4) {
            FileIcon.image(forFileName: document.fileName, isDirectory: false)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            if document.isDirty {
                Text("●")
                    .font(.caption)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Close")
            .opacity(showsCloseButton ? 1 : 0)
            .disabled(!showsCloseButton)
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 100, maxWidth: 220)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Close", action: onClose)
            Button("Close Other Tabs", action: onCloseOthers)
        }
        .padding(.vertical, 3)
    }
}
