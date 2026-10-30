import HephClient
import HephCore
import SwiftUI

/// The segments of the task detail.
enum TaskDetailSegment: Hashable, CaseIterable {
    case details
    case claude

    var title: String {
        switch self {
        case .details:
            return "Details"
        case .claude:
            return "Claude"
        }
    }
}

/// The segmented picker of the task detail: Details and Claude.
struct TaskSegmentPicker: View {
    @Binding var segment: TaskDetailSegment

    var body: some View {
        Picker("Segment", selection: $segment) {
            ForEach(TaskDetailSegment.allCases, id: \.self) { segment in
                Text(segment.title)
                    .tag(segment)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// One task (docs/ui/tasks.md, "Task detail"): the header, then the Details segment (description, comments and the
/// comment composer) or the Claude segment (the task's sessions). A broken task shows its parse error instead.
///
/// The view starts on the Details segment; `TasksView` gives each task its own view, so selecting a task shows Details.
struct TaskDetailView: View {
    let store: ProjectStore
    let task: TaskItem
    let isCompact: Bool
    /// The selected session tab of this task, kept by `TasksView`.
    @Binding var selectedSessionID: UUID?

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    @State private var segment: TaskDetailSegment = .details
    @State private var draft = ComposerDraft()
    @State private var taskToDelete: TaskItem?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var isScrolledToBottom = true

    var body: some View {
        Group {
            if task.parseError != nil {
                brokenTask
            } else if isCompact {
                compactContent
            } else {
                regularContent
            }
        }
        .modifier(TaskDeleteConfirmation(task: $taskToDelete, store: store))
    }

    // MARK: - Layouts

    /// Regular width: the header stays above the segment's content; the segment is trailing in its first row.
    private var regularContent: some View {
        VStack(spacing: 0) {
            header(showsSegment: true)
                .padding(16)
            Divider()
            switch segment {
            case .details:
                details(includesHeader: false)
            case .claude:
                claude
            }
        }
    }

    /// Compact width: the segment is the navigation bar's principal item; the header scrolls with the Details content
    /// and the Claude segment hides it, with the task id as the navigation title.
    private var compactContent: some View {
        Group {
            switch segment {
            case .details:
                details(includesHeader: true)
            case .claude:
                claude
            }
        }
        .navigationTitle(segment == .claude ? task.id : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                TaskSegmentPicker(segment: $segment)
            }
        }
    }

    private func header(showsSegment: Bool) -> some View {
        TaskHeaderView(store: store, task: task, segment: $segment, showsSegment: showsSegment) {
            taskToDelete = task
        }
    }

    // MARK: - Details segment

    /// A scroll view with the Description and Comments sections; the comment composer is pinned under it. When a
    /// comment arrives while the view is scrolled to the bottom, it scrolls to show it.
    private func details(includesHeader: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if includesHeader {
                    header(showsSegment: false)
                    Divider()
                }
                TaskDescriptionView(store: store, task: task)
                CommentsView(store: store, task: task)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
            return visibleBottom >= geometry.contentSize.height - 8
        } action: { _, isAtBottom in
            isScrolledToBottom = isAtBottom
        }
        .onChange(of: task.comments.count) { oldCount, newCount in
            if newCount > oldCount, isScrolledToBottom {
                withAnimation {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
    }

    /// The comment composer: `MessageComposer` without a Stop action.
    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            MessageComposer(
                placeholder: "Add a comment",
                draft: $draft,
                mainDeviceID: store.mainDeviceID,
                projectID: store.projectID,
                canSend: TasksScreen.isConnected(store)
            ) { draft in
                await sendComment(draft)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    /// `addComment` with the trimmed text and the uploads; true clears the draft, false keeps it with its uploads.
    private func sendComment(_ draft: ComposerDraft) async -> Bool {
        let body = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploads = draft.uploads
        let projectID = store.projectID
        let taskID = task.id
        return await banners.perform {
            let connection = try TasksScreen.connection(of: store, workspace: workspace)
            _ = try await connection.addComment(projectID: projectID, taskID: taskID, body: body,
                                                attachments: uploads)
        }
    }

    // MARK: - Claude segment

    private var claude: some View {
        TaskClaudeView(store: store, task: task, selectedSessionID: $selectedSessionID) {
            segment = .claude
        }
    }

    // MARK: - Broken task

    /// The id, "This task file cannot be read.", the parse error, the file path and Delete Task…; no segment, no
    /// comments and no composer.
    private var brokenTask: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(task.id)
                    .font(.title2.monospaced())
                    .textSelection(.enabled)
                Text("This task file cannot be read.")
                Text(verbatim: task.parseError ?? "")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text(verbatim: ".hephaestus/tasks/\(task.id).yml")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Delete Task…", role: .destructive) {
                    taskToDelete = task
                }
                .disabled(!TasksScreen.isConnected(store))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The confirmation of Delete a task (docs/ui/tasks.md, "Delete a task"), from the detail's actions menu, the row's
/// context menu and the broken-task detail. Delete calls `deleteTask`; after success, `selection.item` is cleared when
/// it was this task. The task's sessions are kept.
struct TaskDeleteConfirmation: ViewModifier {
    @Binding var task: TaskItem?
    let store: ProjectStore

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Text(verbatim: "Delete \(task?.id ?? "")?"),
                isPresented: Binding(
                    get: { task != nil },
                    set: { isPresented in
                        if !isPresented {
                            task = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: task
            ) { task in
                Button("Delete", role: .destructive) {
                    delete(task)
                }
                Button("Cancel", role: .cancel) {}
            } message: { task in
                if task.parseError != nil {
                    Text(verbatim: "The file .hephaestus/tasks/\(task.id).yml is deleted. This cannot be undone.")
                } else {
                    Text(verbatim: "“\(task.name)” and its attachments are deleted. This cannot be undone.")
                }
            }
    }

    private func delete(_ task: TaskItem) {
        let projectID = store.projectID
        let taskID = task.id
        Task {
            let succeeded = await banners.perform {
                let connection = try TasksScreen.connection(of: store, workspace: workspace)
                try await connection.deleteTask(projectID: projectID, taskID: taskID)
            }
            if succeeded, context.selection.item == taskID {
                context.selection.item = nil
            }
        }
    }
}
