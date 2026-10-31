import HephClient
import HephCore
import SwiftUI

/// Adds tasks to a bundle (docs/ui/tasks.md, "Add tasks sheet"): the project's tasks that are not broken and not in the
/// bundle, by task number, filtered by the text rule of the task filter; the chosen ones are added after the bundle's
/// tasks.
struct AddBundleTasksSheet: View {
    let store: ProjectStore
    let bundle: BundleItem

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var chosen: Set<String> = []
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "Add Tasks to \(bundle.id)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $text)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Form {
                ForEach(shownTasks) { task in
                    taskRow(task)
                }
            }
            .formStyle(.grouped)
            .disabled(isAdding)
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(action: add) {
                    if isAdding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
                .background {
                    // ⌘↩ adds too (docs/ui/tasks.md, "Keyboard shortcuts").
                    Button("Add", action: add)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canAdd)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 440)
        #endif
    }

    /// The tasks that are not broken and not in the bundle, in the order of `store.tasks` (by task number), filtered
    /// by the text.
    private var shownTasks: [TaskItem] {
        let inBundle = Set(bundle.tasks.map(\.taskID))
        let candidates = store.tasks.filter { $0.parseError == nil && !inBundle.contains($0.id) }
        return TaskListState.tasks(candidates, matching: text)
    }

    /// The id (monospaced) and the name; a checkmark when chosen. Choosing the row toggles it.
    private func taskRow(_ task: TaskItem) -> some View {
        Button {
            if chosen.contains(task.id) {
                chosen.remove(task.id)
            } else {
                chosen.insert(task.id)
            }
        } label: {
            HStack(spacing: 8) {
                Text(task.id)
                    .font(.body.monospaced())
                Text(task.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if chosen.contains(task.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A task is chosen, the Main is connected and no request is in flight.
    private var canAdd: Bool {
        !chosen.isEmpty && !isAdding && TasksScreen.isConnected(store)
    }

    private func add() {
        guard canAdd else { return }
        let taskIDs = BundleScreen.taskIDs(of: store.bundle(bundle.id) ?? bundle, adding: Array(chosen))
        let projectID = store.projectID
        let bundleID = bundle.id
        isAdding = true
        errorMessage = nil
        Task {
            do {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                _ = try await connection.updateBundle(projectID: projectID, bundleID: bundleID,
                                                      patch: BundlePatch(taskIDs: taskIDs))
                isAdding = false
                dismiss()
            } catch is CancellationError {
                isAdding = false
            } catch {
                isAdding = false
                errorMessage = Banner.message(of: error)
            }
        }
    }
}
