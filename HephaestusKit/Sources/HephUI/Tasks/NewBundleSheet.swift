import HephClient
import HephCore
import SwiftUI

/// Creates a bundle from the given tasks (docs/ui/tasks.md, "New bundle sheet"): a name, then the tasks in task number
/// order, each removable while more than one remains.
struct NewBundleSheet: View {
    let store: ProjectStore
    /// Called with the created bundle once the sheet has dismissed itself; the caller empties the list's selection and
    /// selects the bundle.
    let onCreated: (BundleItem) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var taskIDs: [String]
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(store: ProjectStore, taskIDs: [String], onCreated: @escaping (BundleItem) -> Void) {
        self.store = store
        self.onCreated = onCreated
        _taskIDs = State(initialValue: TaskListState.sortedByNumber(taskIDs))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Bundle")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $name)
                        if nameHasLineBreak {
                            Text("Use a single line.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Section("Tasks") {
                    ForEach(taskIDs, id: \.self) { taskID in
                        taskRow(taskID)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
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
                Button(action: create) {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .background {
                    // ⌘↩ creates too (docs/ui/tasks.md, "Keyboard shortcuts").
                    Button("Create", action: create)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canCreate)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 400)
        #endif
    }

    /// The id (monospaced) and the name; a remove button while more than one task remains.
    private func taskRow(_ taskID: String) -> some View {
        HStack(spacing: 8) {
            Text(taskID)
                .font(.body.monospaced())
            Text(store.task(taskID)?.name ?? "")
                .lineLimit(1)
            Spacer(minLength: 4)
            if taskIDs.count > 1 {
                Button {
                    taskIDs.removeAll { $0 == taskID }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameHasLineBreak: Bool {
        trimmedName.contains { $0.isNewline }
    }

    /// The name is valid, the Main is connected and no request is in flight.
    private var canCreate: Bool {
        !trimmedName.isEmpty && !nameHasLineBreak && !isCreating && TasksScreen.isConnected(store)
    }

    private func create() {
        guard canCreate else { return }
        let name = trimmedName
        let taskIDs = self.taskIDs
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                let bundle = try await connection.createBundle(projectID: store.projectID, name: name,
                                                               taskIDs: taskIDs)
                isCreating = false
                dismiss()
                onCreated(bundle)
            } catch is CancellationError {
                isCreating = false
            } catch {
                isCreating = false
                errorMessage = Banner.message(of: error)
            }
        }
    }
}
