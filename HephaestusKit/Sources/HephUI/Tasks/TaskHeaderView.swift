import HephClient
import HephCore
import SwiftUI

/// The header of the task detail (docs/ui/tasks.md, "Header"): the id, the segment (regular width) and the actions
/// menu; the name field; the status menu and the dates.
struct TaskHeaderView: View {
    let store: ProjectStore
    let task: TaskItem
    @Binding var segment: TaskDetailSegment
    /// Regular width: the segment is trailing in the first row.
    let showsSegment: Bool
    /// Asks for the delete confirmation of the task.
    let onDelete: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    @State private var nameText = ""
    /// The name of the request in flight, so that one commit sends it once.
    @State private var sendingName: String?
    /// The status chosen in the menu until the stored status changes; nil when the request failed.
    @State private var chosenStatus: (base: TaskStatus, value: TaskStatus)?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(task.id)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if showsSegment {
                    TaskSegmentPicker(segment: $segment)
                }
                actionsMenu
            }
            nameField
            HStack(spacing: 10) {
                statusMenu
                dates
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            nameText = task.name
        }
        .onChange(of: task.name) { _, name in
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

    // MARK: - Actions

    private var actionsMenu: some View {
        Menu {
            Button("Copy ID") {
                TasksScreen.copy(task.id)
            }
            Button("Delete Task…", role: .destructive, action: onDelete)
                .disabled(!isConnected)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Name

    /// A plain text field; Return or focus loss commits, Escape reverts. While it has focus, incoming changes do not
    /// replace its text.
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
        nameText = store.task(task.id)?.name ?? task.name
    }

    /// Sends the trimmed name with `TaskPatch(name:)`. A name that is empty or holds a line break is not sent and the
    /// field reverts; an unchanged name sends nothing; a failure reverts the field.
    private func commitName() {
        let stored = store.task(task.id)?.name ?? task.name
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(where: { $0.isNewline }) else {
            nameText = stored
            return
        }
        nameText = name
        guard name != stored, name != sendingName else { return }
        sendingName = name
        let projectID = store.projectID
        let taskID = task.id
        Task {
            let succeeded = await banners.perform {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                _ = try await connection.updateTask(projectID: projectID, taskID: taskID, patch: TaskPatch(name: name))
            }
            if sendingName == name {
                sendingName = nil
            }
            if !succeeded {
                nameText = store.task(taskID)?.name ?? nameText
            }
        }
    }

    // MARK: - Status

    /// The status shown: the one chosen in the menu while the stored status has not changed since, else the stored one.
    private var displayedStatus: TaskStatus {
        if let chosenStatus, chosenStatus.base == task.status {
            return chosenStatus.value
        }
        return task.status
    }

    /// A menu labeled with the `TaskStatusBadge`; the four statuses, current checked. The badge shows the chosen status
    /// at once and returns to the stored status when the request fails.
    private var statusMenu: some View {
        Menu {
            Picker("Status", selection: Binding(get: { displayedStatus }, set: setStatus)) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Text(status.displayName)
                        .tag(status)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            TaskStatusBadge(status: displayedStatus)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isConnected)
    }

    private func setStatus(_ status: TaskStatus) {
        guard status != displayedStatus else { return }
        let base = task.status
        chosenStatus = (base: base, value: status)
        let projectID = store.projectID
        let taskID = task.id
        Task {
            let succeeded = await banners.perform {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                _ = try await connection.updateTask(projectID: projectID, taskID: taskID,
                                                    patch: TaskPatch(status: status))
            }
            if !succeeded, chosenStatus?.value == status {
                chosenStatus = nil
            }
        }
    }

    // MARK: - Dates

    /// "Created <date>" · "Updated <relative time>", refreshed every minute; the absolute date in the help tag.
    private var dates: some View {
        TimelineView(.everyMinute) { _ in
            HStack(spacing: 4) {
                Text(verbatim: "Created \(task.created.formatted(date: .abbreviated, time: .shortened))")
                Text(verbatim: "·")
                Text(verbatim: "Updated \(task.updated.formatted(.relative(presentation: .named)))")
                    .help(task.updated.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}
