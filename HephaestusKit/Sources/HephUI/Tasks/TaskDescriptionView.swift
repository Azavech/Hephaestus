import HephClient
import HephCore
import HephMarkdown
import SwiftUI

/// The Description section of the task detail (docs/ui/tasks.md, "Description"): the rendered Markdown with an Edit
/// button, or an editor with Cancel and Save.
struct TaskDescriptionView: View {
    let store: ProjectStore
    let task: TaskItem

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    @Environment(\.openURL) private var openURL
    @State private var isEditing = false
    /// The editor text.
    @State private var text = ""
    /// The stored description at the start of the edit, or the one taken with Use Theirs.
    @State private var base = ""
    @State private var isSaving = false
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Description")
                    .font(.headline)
                Spacer()
                if !isEditing && !isEmpty {
                    Button("Edit", action: beginEditing)
                }
            }
            if isEditing {
                editor
            } else if isEmpty {
                Text("No description")
                    .foregroundStyle(.secondary)
                Button("Add Description", action: beginEditing)
            } else {
                MarkdownView(task.description, linkHandler: { target in
                    TasksScreen.openLink(target, store: store, workspace: workspace, context: context,
                                         banners: banners, openURL: openURL)
                })
            }
        }
    }

    private var isEmpty: Bool {
        task.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Edit mode

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if task.description != base {
                HStack(spacing: 8) {
                    Text("The description was changed on another device.")
                        .font(.callout)
                    Spacer(minLength: 8)
                    Button("Use Theirs") {
                        text = task.description
                        base = task.description
                    }
                }
            }
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 160)
                .focused($isEditorFocused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    save()
                    return .handled
                }
                .onKeyPress(.escape) {
                    cancel()
                    return .handled
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save", action: save)
                    .disabled(isSaving || !TasksScreen.isConnected(store))
            }
        }
    }

    private func beginEditing() {
        text = task.description
        base = task.description
        isEditing = true
        isEditorFocused = true
    }

    private func cancel() {
        isEditing = false
    }

    /// Sends the editor text with `TaskPatch(description:)` (an empty text as ""). Success: view mode; failure: the
    /// error banner, and edit mode stays.
    private func save() {
        guard !isSaving, TasksScreen.isConnected(store) else { return }
        let description = text
        let projectID = store.projectID
        let taskID = task.id
        isSaving = true
        Task {
            let succeeded = await banners.perform {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                _ = try await connection.updateTask(projectID: projectID, taskID: taskID,
                                                    patch: TaskPatch(description: description))
            }
            isSaving = false
            if succeeded {
                isEditing = false
            }
        }
    }
}
