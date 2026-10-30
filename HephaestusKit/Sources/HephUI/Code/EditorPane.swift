import Foundation
import HephClient
import HephEditor
import SwiftUI

/// The editor area of the Code section: the tab strip (regular width), the banner of the document, then its content
/// (docs/ui/code.md, "Editor area").
struct EditorPane: View {
    let model: CodeSectionModel
    /// The document shown: the active one, or in compact width the one of the pushed editor.
    let document: EditorDocument?
    let showsTabStrip: Bool
    let projectName: String
    let proxy: CodeEditorProxy

    var body: some View {
        VStack(spacing: 0) {
            if showsTabStrip && !model.documents.isEmpty {
                EditorTabStrip(model: model, projectName: projectName)
                Divider()
            }
            if let document {
                DocumentBannerView(document: document)
                DocumentContentView(document: document, proxy: proxy)
            } else {
                VStack(spacing: 12) {
                    Text("No file open")
                        .foregroundStyle(.secondary)
                    if showsTabStrip && !model.isTreeVisible {
                        Button("Show Files") {
                            model.isTreeVisible = true
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The content of a document in the Code section: the code editor for text, the placeholders otherwise.
struct DocumentContentView: View {
    @Bindable var document: EditorDocument
    let proxy: CodeEditorProxy

    var body: some View {
        if document.content == .text {
            CodeEditorView(
                text: Binding(get: { document.text }, set: { document.edit($0) }),
                language: EditorLanguage(fileName: document.fileName),
                selection: $document.selection,
                proxy: proxy
            )
            .id(document.id)
        } else {
            DocumentPlaceholderView(document: document)
        }
    }
}

/// What a document whose content is not text shows (docs/ui/code.md, "Content"). Also used by the Docs section.
struct DocumentPlaceholderView: View {
    let document: EditorDocument

    var body: some View {
        switch document.content {
        case .loading, .text:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let data):
            ImageViewer(data: data, fileName: document.fileName)
        case .binary(let size):
            VStack(spacing: 4) {
                Text("Binary file")
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .tooLarge:
            let document = document
            LargeFileView(fileName: document.fileName) { progress in
                try await document.files.download(document.path, progress: progress)
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Text("Couldn't open “\(document.fileName)”")
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    let document = document
                    Task {
                        await document.load()
                    }
                }
                .disabled(!document.files.isConnected)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension View {
    /// Presents the first question of `questions`: "Do you want to save the changes to “<name>”?" with Save, Don't
    /// Save and Cancel.
    func saveChangesDialog(_ questions: SaveChangesQuestions) -> some View {
        modifier(SaveChangesDialog(questions: questions))
    }
}

private struct SaveChangesDialog: ViewModifier {
    let questions: SaveChangesQuestions

    func body(content: Content) -> some View {
        let question = questions.current
        content
            .confirmationDialog(
                "Do you want to save the changes to “\(question?.fileName ?? "")”?",
                isPresented: Binding {
                    questions.current != nil
                } set: { isPresented in
                    // Dismissed without a button: Cancel. A button answers first; this runs on the next turn.
                    guard !isPresented, let question else { return }
                    Task { @MainActor in
                        questions.answer(question, with: .cancel)
                    }
                },
                titleVisibility: .visible,
                presenting: question
            ) { question in
                Button("Save") {
                    questions.answer(question, with: .save)
                }
                Button("Don't Save", role: .destructive) {
                    questions.answer(question, with: .dontSave)
                }
                Button("Cancel", role: .cancel) {
                    questions.answer(question, with: .cancel)
                }
            }
    }
}
