import HephClient
import HephCore
import SwiftUI

/// The task list (docs/ui/tasks.md, "Task list"): above it a filter field, the filter menu and the New Task button (in
/// the navigation bar in compact width); then the Bundles section, the tasks in one section per status and a Broken
/// section. Several tasks can be selected ("Multi-selection"): ⌘-click and ⇧-click in regular width, the Select mode
/// with its bottom bar in compact width.
struct TaskListView: View {
    let store: ProjectStore
    @Bindable var state: TaskListState
    let isCompact: Bool
    /// Opens the New Task sheet.
    let onNewTask: () -> Void
    /// Opens the New Bundle sheet with these tasks.
    let onNewBundle: ([String]) -> Void

    @Environment(WindowContext.self) private var context
    @State private var taskToDelete: TaskItem?
    @State private var bundleToDelete: BundleItem?

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
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    selectButton
                }
                if state.isSelecting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        selectionActions
                    }
                }
                #endif
            }
        }
        #if os(iOS)
        .environment(\.editMode, editMode)
        #endif
        .modifier(TaskDeleteConfirmation(task: $taskToDelete, store: store))
        .modifier(BundleDeleteConfirmation(bundle: $bundleToDelete, store: store))
    }

    // MARK: - Compact selection

    #if os(iOS)
    /// The edit mode of the list: active in the Select mode.
    private var editMode: Binding<EditMode> {
        Binding(
            get: { state.isSelecting ? .active : .inactive },
            set: { state.isSelecting = $0.isEditing }
        )
    }

    /// "Select" turns on the edit mode, in which task rows show selection circles; "Done" turns it off and empties the
    /// selection.
    private var selectButton: some View {
        Button(state.isSelecting ? "Done" : "Select") {
            if state.isSelecting {
                state.isSelecting = false
                context.selection.item = state.select([], isBroken: isBroken)
            } else {
                state.isSelecting = true
            }
        }
    }

    /// The bottom bar of the Select mode: New Bundle and the Add to Bundle menu, enabled when a task is selected.
    @ViewBuilder
    private var selectionActions: some View {
        let taskIDs = state.selectedTaskIDs(in: store.tasks)
        Button("New Bundle") {
            onNewBundle(taskIDs)
        }
        .disabled(taskIDs.isEmpty || !TasksScreen.isConnected(store))
        Spacer()
        AddToBundleMenu(store: store, taskIDs: taskIDs)
    }
    #endif

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
        let bundles = state.shownBundles(of: store.bundles)
        if store.tasks.isEmpty {
            ContentUnavailableView {
                Text("No tasks yet")
            } actions: {
                Button("New Task", action: onNewTask)
                    .disabled(!TasksScreen.isConnected(store))
            }
        } else if sections.isEmpty && bundles.isEmpty {
            ContentUnavailableView {
                Text("No matching tasks")
            } actions: {
                Button("Clear Filter") {
                    state.reset()
                }
            }
        } else {
            List(selection: selectionBinding) {
                if !bundles.isEmpty {
                    Section {
                        ForEach(bundles) { bundle in
                            BundleRow(store: store, bundle: bundle) {
                                bundleToDelete = bundle
                            }
                            .tag(bundle.id)
                            .selectionDisabled(state.isSelecting)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Label("Bundles", systemImage: "square.stack.3d.up")
                            Text("\(bundles.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.tasks) { task in
                            TaskRow(store: store, task: task, bundleTaskIDs: bundleTaskIDs(for: task),
                                    onNewBundle: onNewBundle) {
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

    /// The tasks of New Bundle from Selection… and Add to Bundle of a row: the selected tasks, or this task when it is
    /// not selected.
    private func bundleTaskIDs(for task: TaskItem) -> [String] {
        guard state.selectedIDs.contains(task.id) else { return [task.id] }
        return state.selectedTaskIDs(in: store.tasks)
    }

    private func isBroken(_ id: String) -> Bool {
        store.task(id)?.parseError != nil
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

    /// The list's selection, `state.selectedIDs`. A change applies the rules of Multi-selection and sets
    /// `selection.item`: the id when one row is selected, else nil.
    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: { state.selectedIDs },
            set: { ids in
                let item = state.select(ids, isBroken: isBroken)
                if context.selection.item != item {
                    context.selection.item = item
                }
            }
        )
    }
}

/// The Add to Bundle menu (docs/ui/tasks.md, "Multi-selection"): the bundles in `draft` or `done` status; choosing one
/// calls `updateBundle` with its tasks, then the given tasks that are not in it, by task number. Without such a bundle
/// it holds the disabled item "No bundle to add to".
struct AddToBundleMenu: View {
    let store: ProjectStore
    /// The tasks to add.
    let taskIDs: [String]

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners

    var body: some View {
        let bundles = store.bundles.filter(BundleScreen.isEditable)
        Menu("Add to Bundle") {
            if bundles.isEmpty {
                Button("No bundle to add to") {}
                    .disabled(true)
            } else {
                ForEach(bundles) { bundle in
                    Button {
                        add(to: bundle)
                    } label: {
                        Text(verbatim: "\(bundle.name) (\(bundle.id))")
                    }
                }
            }
        }
        .disabled(taskIDs.isEmpty || !TasksScreen.isConnected(store))
    }

    private func add(to bundle: BundleItem) {
        let projectID = store.projectID
        let bundleID = bundle.id
        let taskIDs = BundleScreen.taskIDs(of: bundle, adding: taskIDs)
        Task {
            await banners.perform {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                _ = try await connection.updateBundle(projectID: projectID, bundleID: bundleID,
                                                      patch: BundlePatch(taskIDs: taskIDs))
            }
        }
    }
}
