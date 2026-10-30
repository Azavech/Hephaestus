import HephClient
import HephCore
import SwiftUI

/// A row of the task list (docs/ui/tasks.md, "Row"): the id and the indicators, then the name; a context menu with
/// Status, Copy ID and Delete… (a broken task: Copy ID and Delete… only).
struct TaskRow: View {
    let store: ProjectStore
    let task: TaskItem
    /// Asks for the delete confirmation of this task.
    let onDelete: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(task.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                indicators
                    .font(.caption)
            }
            if task.parseError != nil {
                Text("Invalid task file")
                    .foregroundStyle(.red)
            } else {
                Text(task.name)
                    .font(.body)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            contextMenuItems
        }
    }

    /// From the sessions of the task: `hand.raised.fill` when one waits for a permission, else `sparkles` when one is
    /// starting or running; then `bubble.left` and the comment count when the task has comments.
    @ViewBuilder
    private var indicators: some View {
        let sessions = store.sessions.filter { $0.taskID == task.id }
        if sessions.contains(where: { $0.status == .waitingPermission }) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
        } else if sessions.contains(where: { $0.status == .starting || $0.status == .running }) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
        }
        if !task.comments.isEmpty {
            HStack(spacing: 2) {
                Image(systemName: "bubble.left")
                Text("\(task.comments.count)")
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if task.parseError == nil {
            Picker("Status", selection: statusBinding) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Text(status.displayName)
                        .tag(status)
                }
            }
            .pickerStyle(.menu)
            .disabled(!TasksScreen.isConnected(store))
        }
        Button("Copy ID") {
            TasksScreen.copy(task.id)
        }
        Button("Delete…", role: .destructive, action: onDelete)
            .disabled(!TasksScreen.isConnected(store))
    }

    /// The current status checked; choosing another one sends `TaskPatch(status:)`.
    private var statusBinding: Binding<TaskStatus> {
        let projectID = store.projectID
        let taskID = task.id
        let current = task.status
        return Binding(
            get: { current },
            set: { status in
                guard status != current else { return }
                Task {
                    await banners.perform {
                        let connection = try TasksScreen.connection(of: store, workspace: workspace)
                        _ = try await connection.updateTask(projectID: projectID, taskID: taskID,
                                                            patch: TaskPatch(status: status))
                    }
                }
            }
        )
    }
}
