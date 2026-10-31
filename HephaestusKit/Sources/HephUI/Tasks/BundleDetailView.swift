import HephClient
import HephCore
import SwiftUI

/// One bundle (docs/ui/tasks.md, "Bundle detail"): the header, the buttons that start, stop and open its work, a
/// caption by status, then its tasks in the bundle's order.
struct BundleDetailView: View {
    let store: ProjectStore
    let bundle: BundleItem

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    @State private var bundleToDelete: BundleItem?
    @State private var isAddTasksPresented = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                BundleHeaderView(store: store, bundle: bundle, onAddTasks: { isAddTasksPresented = true },
                                 onDelete: { bundleToDelete = bundle })
                buttons
                if let caption {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            tasks
        }
        .modifier(BundleDeleteConfirmation(bundle: $bundleToDelete, store: store))
        .sheet(isPresented: $isAddTasksPresented) {
            AddBundleTasksSheet(store: store, bundle: bundle)
        }
    }

    private var isConnected: Bool {
        TasksScreen.isConnected(store)
    }

    // MARK: - Buttons

    /// Work on Bundle in `draft`, Stop in `running` and `review`, Open Coordinator when the bundle has a coordinator.
    private var buttons: some View {
        HStack(spacing: 8) {
            switch bundle.status {
            case .draft:
                Button {
                    BundleScreen.start(bundle, store: store, workspace: workspace, banners: banners)
                } label: {
                    Label("Work on Bundle", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConnected)
            case .running, .review:
                Button {
                    BundleScreen.stop(bundle, store: store, workspace: workspace, banners: banners)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!isConnected)
            case .done:
                EmptyView()
            }
            if let coordinatorSessionID = bundle.coordinatorSessionID {
                Button("Open Coordinator") {
                    context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .claude,
                                     item: coordinatorSessionID.uuidString)
                }
            }
        }
    }

    private var caption: String? {
        switch bundle.status {
        case .draft:
            return nil
        case .running:
            return "Claude works on the tasks in parallel and reports in the coordinator's session."
        case .review:
            return "The coordinator waits for your agreement in its session."
        case .done:
            return "The work of this bundle was brought in."
        }
    }

    // MARK: - Tasks

    /// The tasks in the bundle's order. Choosing a row shows the task; in `draft` and `done` the rows can be reordered
    /// and removed.
    private var tasks: some View {
        let isEditable = BundleScreen.isEditable(bundle)
        return List(selection: taskSelection) {
            ForEach(bundle.tasks) { item in
                BundleTaskRow(store: store, item: item)
                    .tag(item.taskID)
                    .contextMenu {
                        if isEditable {
                            Button("Remove from Bundle") {
                                update(taskIDs: bundle.tasks.map(\.taskID).filter { $0 != item.taskID })
                            }
                            .disabled(bundle.tasks.count == 1 || !isConnected)
                        }
                    }
            }
            .onMove(perform: isEditable && isConnected ? move : nil)
        }
    }

    /// Choosing a row navigates to section `.tasks` with the task id; no row stays selected.
    private var taskSelection: Binding<String?> {
        Binding(
            get: { nil },
            set: { taskID in
                guard let taskID else { return }
                context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .tasks,
                                 item: taskID)
            }
        )
    }

    private func move(from source: IndexSet, to destination: Int) {
        var taskIDs = bundle.tasks.map(\.taskID)
        taskIDs.move(fromOffsets: source, toOffset: destination)
        update(taskIDs: taskIDs)
    }

    /// `updateBundle` with `BundlePatch(taskIDs:)`.
    private func update(taskIDs: [String]) {
        let projectID = store.projectID
        let bundleID = bundle.id
        Task {
            await banners.perform {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                _ = try await connection.updateBundle(projectID: projectID, bundleID: bundleID,
                                                      patch: BundlePatch(taskIDs: taskIDs))
            }
        }
    }
}

/// The header of the bundle detail: the id and the actions menu; the name field; the status badge and the dates.
private struct BundleHeaderView: View {
    let store: ProjectStore
    let bundle: BundleItem
    /// Opens the Add Tasks sheet.
    let onAddTasks: () -> Void
    /// Asks for the delete confirmation of the bundle.
    let onDelete: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    @State private var nameText = ""
    /// The name of the request in flight, so that one commit sends it once.
    @State private var sendingName: String?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(bundle.id)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                actionsMenu
            }
            nameField
            HStack(spacing: 10) {
                BundleStatusBadge(status: bundle.status)
                dates
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            nameText = bundle.name
        }
        .onChange(of: bundle.name) { _, name in
            if !isNameFocused {
                nameText = name
            }
        }
        .onChange(of: isNameFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                commitName()
            }
        }
        .onDisappear {
            commitName()
        }
    }

    private var isConnected: Bool {
        TasksScreen.isConnected(store)
    }

    /// Add Tasks… and Delete Bundle… in `draft` and `done`; Copy ID always.
    private var actionsMenu: some View {
        Menu {
            if BundleScreen.isEditable(bundle) {
                Button("Add Tasks…", action: onAddTasks)
                    .disabled(!isConnected)
            }
            Button("Copy ID") {
                TasksScreen.copy(bundle.id)
            }
            if BundleScreen.isEditable(bundle) {
                Button("Delete Bundle…", role: .destructive, action: onDelete)
                    .disabled(!isConnected)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A plain text field that commits like the task name: Return or focus loss commits, Escape reverts; while it has
    /// focus, incoming changes do not replace its text.
    private var nameField: some View {
        TextField("Name", text: $nameText)
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .focused($isNameFocused)
            .onSubmit(commitName)
            .onKeyPress(.escape) {
                revertName()
                return .handled
            }
            #if os(macOS)
            .onExitCommand(perform: revertName)
            #endif
            .disabled(!isConnected)
    }

    private func revertName() {
        nameText = store.bundle(bundle.id)?.name ?? bundle.name
    }

    /// Sends the trimmed name with `BundlePatch(name:)`. A name that is empty or holds a line break is not sent and the
    /// field reverts; an unchanged name sends nothing; a failure reverts the field.
    private func commitName() {
        let stored = store.bundle(bundle.id)?.name ?? bundle.name
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(where: { $0.isNewline }) else {
            nameText = stored
            return
        }
        nameText = name
        guard name != stored, name != sendingName else { return }
        sendingName = name
        let projectID = store.projectID
        let bundleID = bundle.id
        Task {
            let succeeded = await banners.perform {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                _ = try await connection.updateBundle(projectID: projectID, bundleID: bundleID,
                                                      patch: BundlePatch(name: name))
            }
            if sendingName == name {
                sendingName = nil
            }
            if !succeeded {
                nameText = store.bundle(bundleID)?.name ?? nameText
            }
        }
    }

    /// "Created <date>" · "Updated <relative time>", refreshed every minute; the absolute date in the help tag.
    private var dates: some View {
        TimelineView(.everyMinute) { _ in
            HStack(spacing: 4) {
                Text(verbatim: "Created \(bundle.created.formatted(date: .abbreviated, time: .shortened))")
                Text(verbatim: "·")
                Text(verbatim: "Updated \(bundle.updated.formatted(.relative(presentation: .named)))")
                    .help(bundle.updated.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// A task of the bundle: the id, the name ("Deleted task" for a deleted task), its status badge, and the indicator and
/// Open Session button of the session the bundle started for it.
private struct BundleTaskRow: View {
    let store: ProjectStore
    let item: BundleTask

    @Environment(WindowContext.self) private var context

    var body: some View {
        let task = store.task(item.taskID)
        HStack(spacing: 8) {
            Text(item.taskID)
                .font(.body.monospaced())
            if let task {
                Text(task.name)
                    .lineLimit(1)
            } else {
                Text("Deleted task")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let task {
                TaskStatusBadge(status: task.status)
            }
            if let session = item.sessionID.flatMap({ store.session($0) }) {
                SessionStatusIndicator(status: session.status)
                Button("Open Session") {
                    context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .claude,
                                     item: session.id.uuidString)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The confirmation of Delete Bundle… (docs/ui/tasks.md, "Bundle detail"), from the detail's actions menu and the
/// bundle row's context menu. Delete calls `deleteBundle`; after success, `selection.item` is cleared when it was this
/// bundle.
struct BundleDeleteConfirmation: ViewModifier {
    @Binding var bundle: BundleItem?
    let store: ProjectStore

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Text(verbatim: "Delete \(bundle?.id ?? "")?"),
                isPresented: Binding(
                    get: { bundle != nil },
                    set: { isPresented in
                        if !isPresented {
                            bundle = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: bundle
            ) { bundle in
                Button("Delete", role: .destructive) {
                    delete(bundle)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its worktrees are removed, and the branches whose work was brought in are deleted. "
                     + "Its tasks and sessions are kept.")
            }
    }

    private func delete(_ bundle: BundleItem) {
        let projectID = store.projectID
        let bundleID = bundle.id
        Task {
            let succeeded = await banners.perform {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                try await connection.deleteBundle(projectID: projectID, bundleID: bundleID)
            }
            if succeeded, context.selection.item == bundleID {
                context.selection.item = nil
            }
        }
    }
}

/// Helpers shared by the views of the bundles (docs/ui/tasks.md, "Bundles"). Requests run through `banners.perform`.
@MainActor
enum BundleScreen {
    /// The tasks can be changed and the bundle deleted: `draft` and `done`.
    static func isEditable(_ bundle: BundleItem) -> Bool {
        bundle.status == .draft || bundle.status == .done
    }

    /// The coordinator and the task sessions of the bundle, from `store.sessions`.
    static func sessions(of bundle: BundleItem, in store: ProjectStore) -> [SessionInfo] {
        store.sessions.filter { $0.bundleID == bundle.id || $0.id == bundle.coordinatorSessionID }
    }

    /// Work on Bundle: `startBundle`.
    static func start(_ bundle: BundleItem, store: ProjectStore, workspace: Workspace, banners: WindowBanners) {
        let projectID = store.projectID
        let bundleID = bundle.id
        Task {
            await banners.perform {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                _ = try await connection.startBundle(projectID: projectID, bundleID: bundleID)
            }
        }
    }

    /// Stop: `stopBundle`.
    static func stop(_ bundle: BundleItem, store: ProjectStore, workspace: Workspace, banners: WindowBanners) {
        let projectID = store.projectID
        let bundleID = bundle.id
        Task {
            await banners.perform {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                _ = try await connection.stopBundle(projectID: projectID, bundleID: bundleID)
            }
        }
    }

    /// The tasks of `bundle`, then the given tasks that are not in it, by task number.
    static func taskIDs(of bundle: BundleItem, adding taskIDs: [String]) -> [String] {
        let current = bundle.tasks.map(\.taskID)
        return current + TaskListState.sortedByNumber(taskIDs.filter { !current.contains($0) })
    }
}
