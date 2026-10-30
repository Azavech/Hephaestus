import HephClient
import HephCore
import SwiftUI

/// The task list (docs/ui/tasks.md, "Task list"): above it a filter field, the filter menu and the New Task button (in
/// the navigation bar in compact width); then the tasks in one section per status and a Broken section.
struct TaskListView: View {
    let store: ProjectStore
    @Bindable var state: TaskListState
    let isCompact: Bool
    /// Opens the New Task sheet.
    let onNewTask: () -> Void

    @Environment(WindowContext.self) private var context
    @State private var taskToDelete: TaskItem?

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            if isCompact {
                ToolbarItem(placement: .primaryAction) {
                    newTaskButton
                }
            }
        }
        .modifier(TaskDeleteConfirmation(task: $taskToDelete, store: store))
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $state.text)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            filterMenu
            if !isCompact {
                newTaskButton
            }
        }
    }

    /// Statuses shown (toggles) and Sort (picker); the symbol is filled when a setting differs from its default.
    private var filterMenu: some View {
        Menu {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Toggle(status.displayName, isOn: statusBinding(status))
            }
            Divider()
            Picker("Sort", selection: $state.sort) {
                ForEach(TaskListState.Sort.allCases, id: \.self) { sort in
                    Text(sort.title)
                        .tag(sort)
                }
            }
            .pickerStyle(.menu)
        } label: {
            Image(systemName: state.isDefault
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var newTaskButton: some View {
        Button(action: onNewTask) {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .disabled(!TasksScreen.isConnected(store))
    }

    private func statusBinding(_ status: TaskStatus) -> Binding<Bool> {
        Binding(
            get: { state.statuses.contains(status) },
            set: { isOn in
                if isOn {
                    state.statuses.insert(status)
                } else {
                    state.statuses.remove(status)
                }
            }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let sections = state.sections(of: store.tasks)
        if store.tasks.isEmpty {
            ContentUnavailableView {
                Text("No tasks yet")
            } actions: {
                Button("New Task", action: onNewTask)
                    .disabled(!TasksScreen.isConnected(store))
            }
        } else if sections.isEmpty {
            ContentUnavailableView {
                Text("No matching tasks")
            } actions: {
                Button("Clear Filter") {
                    state.reset()
                }
            }
        } else {
            List(selection: itemBinding) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.tasks) { task in
                            TaskRow(store: store, task: task) {
                                taskToDelete = task
                            }
                            .tag(task.id)
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
        }
    }

    /// `TaskStatusBadge` and the count; the Broken header is `exclamationmark.triangle`, "Broken" and the count.
    private func sectionHeader(_ section: TaskListSection) -> some View {
        HStack(spacing: 6) {
            switch section.kind {
            case .status(let status):
                TaskStatusBadge(status: status)
            case .broken:
                Label("Broken", systemImage: "exclamationmark.triangle")
            }
            Text("\(section.tasks.count)")
                .foregroundStyle(.secondary)
        }
    }

    /// Choosing a row sets `selection.item`.
    private var itemBinding: Binding<String?> {
        Binding(
            get: { context.selection.item },
            set: { context.selection.item = $0 }
        )
    }
}
