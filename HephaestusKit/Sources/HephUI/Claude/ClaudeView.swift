import HephClient
import HephCore
import SwiftUI

/// The project section Claude (⌘6): the sessions of the project and one session (docs/ui/sessions.md, "Claude
/// section"). While the section is shown, `selection.item` is the selected session id.
public struct ClaudeView: View {
    private let store: ProjectStore

    @Environment(WindowContext.self) private var context
    /// The new chat is shown; it becomes false when `selection.item` becomes non-nil.
    @State private var isNewChatPresented = false

    public init(store: ProjectStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if context.isCompact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .onChange(of: context.selection.item) { _, item in
            if item != nil {
                isNewChatPresented = false
            }
        }
    }

    private var selectedSessionID: UUID? {
        context.selection.item.flatMap(UUID.init(uuidString:))
    }

    // MARK: Layouts

    @ViewBuilder private var regularLayout: some View {
        #if os(macOS)
        HSplitView {
            sessionList
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
            sessionArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        HStack(spacing: 0) {
            sessionList
                .frame(width: 300)
            Divider()
            sessionArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
    }

    /// The session list is the root of a stack; a selected session, or the new chat, is pushed.
    private var compactLayout: some View {
        NavigationStack {
            sessionList
                .navigationDestination(item: compactSessionID) { sessionID in
                    SessionView(store: store, sessionID: sessionID)
                }
                .navigationDestination(isPresented: $isNewChatPresented) {
                    NewChatView(store: store, isPresented: $isNewChatPresented)
                }
        }
    }

    /// Reads `selection.item` as a UUID and writes its `uuidString`; Back writes nil.
    private var compactSessionID: Binding<UUID?> {
        Binding(
            get: { context.selection.item.flatMap(UUID.init(uuidString:)) },
            set: { context.selection.item = $0?.uuidString }
        )
    }

    private var sessionList: some View {
        SessionListView(store: store, isCompact: context.isCompact, onNewChat: newChat)
    }

    @ViewBuilder private var sessionArea: some View {
        if isNewChatPresented {
            NewChatView(store: store, isPresented: $isNewChatPresented)
        } else if let sessionID = selectedSessionID {
            SessionView(store: store, sessionID: sessionID)
                .id(sessionID)
        } else {
            Text("Select a session or start a new chat.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// New Chat clears `selection.item` and shows the new chat (compact: pushes it).
    private func newChat() {
        context.selection.item = nil
        isNewChatPresented = true
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    ClaudeView(store: appModel.workspace.projectStore(mainDeviceID: studio, projectID: "HEPH"))
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, projectID: "HEPH", section: .claude))
}
