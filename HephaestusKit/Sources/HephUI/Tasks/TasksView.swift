import HephClient
import HephCore
import HephMarkdown
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Tasks section of the project held by `store` (docs/ui/tasks.md): the task list and the selected task.
///
/// | Width class     | Layout                                                                  |
/// |-----------------|-------------------------------------------------------------------------|
/// | regular, macOS  | `HSplitView`: task list (min 260, ideal 320, max 480 pt), task detail   |
/// | regular, iPadOS | `HStack(spacing: 0)`: task list (320 pt), `Divider`, task detail        |
/// | compact         | `NavigationStack` rooted at the task list; the detail is pushed         |
public struct TasksView: View {
    private let store: ProjectStore

    @Environment(WindowContext.self) private var context
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var listState = TaskListState()
    /// The selected session tab of each task, remembered while this view exists.
    @State private var selectedSessions: [String: UUID] = [:]
    @State private var isNewTaskPresented = false

    public init(store: ProjectStore) {
        self.store = store
    }

    public var body: some View {
        let newTaskAction: (() -> Void)? = TasksScreen.isConnected(store) ? { isNewTaskPresented = true } : nil
        layout
            .sheet(isPresented: $isNewTaskPresented) {
                NewTaskSheet(store: store) { task in
                    context.selection.item = task.id
                }
            }
            .focusedSceneValue(\.newTaskAction, newTaskAction)
    }

    private var isCompact: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        if isCompact {
            NavigationStack {
                list
                    .navigationDestination(item: itemBinding) { taskID in
                        TaskDetailDestination(store: store, taskID: taskID, isCompact: true,
                                              selectedSessions: $selectedSessions)
                    }
            }
        } else {
            HStack(spacing: 0) {
                list
                    .frame(width: 320)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #endif
    }

    private var list: some View {
        TaskListView(store: store, state: listState, isCompact: isCompact) {
            isNewTaskPresented = true
        }
    }

    /// The detail area of regular width.
    @ViewBuilder
    private var detail: some View {
        if let taskID = context.selection.item {
            TaskDetailDestination(store: store, taskID: taskID, isCompact: false, selectedSessions: $selectedSessions)
        } else {
            ContentUnavailableView {
                Text("Select a task")
            }
        }
    }

    /// `selection.item`, the selected task id. In compact width the pushed detail follows it; Back sets it to nil.
    private var itemBinding: Binding<String?> {
        Binding(
            get: { context.selection.item },
            set: { context.selection.item = $0 }
        )
    }
}

/// The detail of the task `taskID`, or "<ID> was deleted." when the store has no such task.
private struct TaskDetailDestination: View {
    let store: ProjectStore
    let taskID: String
    let isCompact: Bool
    @Binding var selectedSessions: [String: UUID]

    var body: some View {
        if let task = store.task(taskID) {
            TaskDetailView(
                store: store,
                task: task,
                isCompact: isCompact,
                selectedSessionID: Binding(
                    get: { selectedSessions[taskID] },
                    set: { selectedSessions[taskID] = $0 }
                )
            )
            .id(taskID)
        } else {
            ContentUnavailableView {
                Text(verbatim: "\(taskID) was deleted.")
            }
        }
    }
}

/// Published by TasksView with .focusedSceneValue; bound to File ▸ New Task (⌘N) by the shell's commands.
public struct NewTaskActionKey: FocusedValueKey {
    public typealias Value = () -> Void
}

extension FocusedValues {
    public var newTaskAction: (() -> Void)? {
        get { self[NewTaskActionKey.self] }
        set { self[NewTaskActionKey.self] = newValue }
    }
}

/// Helpers shared by the views of the Tasks screen.
@MainActor
enum TasksScreen {
    /// The project's Main is connected: the controls that send requests are enabled.
    static func isConnected(_ store: ProjectStore) -> Bool {
        store.connection?.isConnected ?? false
    }

    /// The connection of the project's Main; without one, the offline error of the request API.
    static func connection(of store: ProjectStore, workspace: Workspace) throws -> MainConnection {
        if let connection = store.connection {
            return connection
        }
        let name = workspace.mains.first { $0.id == store.mainDeviceID }?.name ?? "Main"
        throw ProtocolError(.unavailable, "\(name) is offline.")
    }

    /// Copy ID.
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// The link rules of task descriptions and comments: an http(s) link opens a new web tab in the project, then the
    /// window shows that tab; a link with another scheme (for example `mailto:`) opens with the environment's
    /// `openURL`.
    static func openLink(_ target: MarkdownLinkTarget, store: ProjectStore, workspace: Workspace,
                         context: WindowContext, banners: WindowBanners, openURL: OpenURLAction) {
        guard case .external(let url) = target else { return }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            openURL(url)
            return
        }
        let mainDeviceID = store.mainDeviceID
        let projectID = store.projectID
        Task {
            await banners.perform {
                let connection = try connection(of: store, workspace: workspace)
                let tab = try await connection.openTab(projectID: projectID, url: url.absoluteString, title: nil,
                                                       locked: nil)
                context.navigate(mainDeviceID: mainDeviceID, projectID: projectID, section: .web,
                                 item: tab.id.uuidString)
            }
        }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    TasksView(store: appModel.workspace.projectStore(mainDeviceID: studio, projectID: "HEPH"))
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, projectID: "HEPH", section: .tasks))
}
