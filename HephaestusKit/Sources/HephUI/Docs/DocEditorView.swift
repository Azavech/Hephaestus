import Foundation
import HephClient
import HephEditor
import SwiftUI

/// Edit mode of the Docs section: the Markdown editor and its live preview (docs/ui/docs.md, "Editor").
struct DocEditorView: View {
    let model: DocsSectionModel
    @Bindable var document: EditorDocument
    let store: ProjectStore
    let proxy: CodeEditorProxy
    /// Compact width shows the editor or the preview, as the Edit / Preview picker says.
    let isCompact: Bool
    let showsPreview: Bool

    var body: some View {
        Group {
            if isCompact {
                if showsPreview {
                    preview
                } else {
                    editor
                }
            } else {
                HStack(spacing: 0) {
                    editor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            model.previewText = document.text
        }
        .task(id: document.text) {
            // 300 ms after the last change of the text; each change restarts the delay.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.previewText = document.text
        }
    }

    private var editor: some View {
        CodeEditorView(
            text: Binding(get: { document.text }, set: { document.edit($0) }),
            language: .markdown,
            selection: $document.selection,
            proxy: proxy
        )
        .id(document.id)
    }

    private var preview: some View {
        DocReaderView(source: model.previewText, document: document, model: model, store: store,
                      appliesPendingAnchor: false)
    }
}
