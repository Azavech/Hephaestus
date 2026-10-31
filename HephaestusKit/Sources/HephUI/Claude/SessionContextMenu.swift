import HephClient
import HephCore
import SwiftUI

/// The context menu of the rows of the session list and of the session tabs of a task (docs/ui/sessions.md, "Session
/// context menu"). A row or a tab has no `SessionModel`, so the items call the request functions of `store.connection`
/// directly, through the window's banners.
///
/// It is a view modifier, so that the sheets and the confirmation it presents stay attached to the row or the tab:
/// `.modifier(SessionContextMenu(store: store, session: session))`, or `.sessionContextMenu(store:session:)`.
struct SessionContextMenu: ViewModifier {
    let store: ProjectStore
    let session: SessionInfo

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    @Environment(WindowContext.self) private var context
    @State private var isRenamePresented = false
    @State private var isModelSheetPresented = false
    @State private var isDeletePresented = false

    init(store: ProjectStore, session: SessionInfo) {
        self.store = store
        self.session = session
    }

    func body(content: Content) -> some View {
        // While the project's Main is not connected, every item is disabled: each sends a request or opens a sheet or
        // a confirmation dialog whose button sends one.
        let isDisabled = store.connection?.isConnected != true
        return content
            .contextMenu {
                Button("Rename…") { isRenamePresented = true }
                    .disabled(isDisabled)
                if ClaudeLabels.hasLiveProcess(session.status) {
                    Button("Stop Process") {
                        perform { connection in
                            try await connection.stopSession(projectID: store.projectID, sessionID: session.id)
                        }
                    }
                    .disabled(isDisabled)
                }
                Button("Delete Session…") { isDeletePresented = true }
                    .disabled(isDisabled)
                SessionOptionMenus(
                    permissionMode: session.permissionMode,
                    model: session.model,
                    permissionModeDefaultTitle: nil,
                    modelDefaultTitle: "Default",
                    allowsAllTools: session.allowsAllTools,
                    onPermissionMode: { mode in
                        guard let mode else { return }
                        update(SessionPatch(permissionMode: mode))
                    },
                    onAllowAllTools: { allows in
                        update(SessionPatch(allowsAllTools: allows))
                    },
                    onModel: { alias in
                        update(SessionPatch(model: alias ?? ""))
                    },
                    onOtherModel: { isModelSheetPresented = true }
                )
                .disabled(isDisabled)
            }
            .sheet(isPresented: $isRenamePresented) {
                SessionRenameSheet(title: session.title) { title in
                    update(SessionPatch(title: title))
                }
            }
            .sheet(isPresented: $isModelSheetPresented) {
                SessionModelSheet { name in
                    update(SessionPatch(model: name))
                }
            }
            .sessionDeleteConfirmation(isPresented: $isDeletePresented, title: session.title) {
                let sessionID = session.id
                perform { connection in
                    try await connection.deleteSession(projectID: store.projectID, sessionID: sessionID)
                    SessionActions.clearSelection(of: sessionID, in: context)
                }
            }
    }

    private func update(_ patch: SessionPatch) {
        let sessionID = session.id
        perform { connection in
            _ = try await connection.updateSession(projectID: store.projectID, sessionID: sessionID, patch: patch)
        }
    }

    private func perform(_ operation: @escaping @MainActor (MainConnection) async throws -> Void) {
        let store = store
        let workspace = workspace
        Task {
            await banners.perform {
                try await operation(try ClaudeNames.connection(of: store, in: workspace))
            }
        }
    }
}

extension View {
    /// Applies the session context menu, with its sheets and confirmation, to a row or a tab.
    func sessionContextMenu(store: ProjectStore, session: SessionInfo) -> some View {
        modifier(SessionContextMenu(store: store, session: session))
    }
}
