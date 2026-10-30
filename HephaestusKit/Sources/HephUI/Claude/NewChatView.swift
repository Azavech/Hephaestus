import HephClient
import HephCore
import SwiftUI

/// A new project chat: its options, a short description and the composer whose Send starts the session
/// (docs/ui/sessions.md, "New chat").
struct NewChatView: View {
    let store: ProjectStore
    /// `isNewChatPresented` of the Claude section.
    @Binding var isPresented: Bool

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    @State private var draft = ComposerDraft()
    /// nil: Project Default.
    @State private var permissionMode: PermissionMode?
    /// nil: Project Default.
    @State private var model: String?
    @State private var isModelSheetPresented = false
    /// The session started by the last Send, until the composer has cleared the draft.
    @State private var startedSessionID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("New Chat")
                    .font(.headline)
                Spacer()
                optionsMenu
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            Text("Chat with Claude about \(projectName). Claude can plan, create and update tasks, edit code, start "
                 + "runs and more.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            MessageComposer(placeholder: "Message Claude", draft: $draft, mainDeviceID: store.mainDeviceID,
                            projectID: store.projectID, canSend: store.connection?.isConnected == true,
                            focusOnAppear: true, onSend: send)
                .padding(12)
        }
        .sheet(isPresented: $isModelSheetPresented) {
            SessionModelSheet { name in
                model = name
            }
        }
        .onChange(of: draft) { _, newDraft in
            // Success: the draft is cleared, the new chat closes, then the window selects the new session.
            guard let sessionID = startedSessionID, newDraft == ComposerDraft() else { return }
            startedSessionID = nil
            isPresented = false
            context.selection.item = sessionID.uuidString
        }
    }

    private var projectName: String {
        store.project?.name ?? workspace.summary(of: store.projectID, on: store.mainDeviceID)?.name ?? store.projectID
    }

    /// Only Permission Mode and Model, both starting at Project Default, which passes nil.
    private var optionsMenu: some View {
        Menu {
            SessionOptionMenus(
                permissionMode: permissionMode,
                model: model,
                permissionModeDefaultTitle: "Project Default",
                modelDefaultTitle: "Project Default",
                onPermissionMode: { permissionMode = $0 },
                onModel: { model = $0 },
                onOtherModel: { isModelSheetPresented = true }
            )
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Starts the session with the first message and its attachments. Success: the draft is cleared, the new chat
    /// closes, then the window selects the new session. A failure keeps the draft, with its uploads.
    private func send(_ draft: ComposerDraft) async -> Bool {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploads = draft.uploads
        let store = store
        let workspace = workspace
        let permissionMode = permissionMode
        let model = model
        var started: SessionInfo?
        let succeeded = await banners.perform {
            let connection = try ClaudeNames.connection(of: store, in: workspace)
            started = try await connection.startSession(projectID: store.projectID, kind: .project, taskID: nil,
                                                        mode: nil, title: nil, message: text.isEmpty ? nil : text,
                                                        attachments: uploads, permissionMode: permissionMode,
                                                        model: model)
        }
        if succeeded, let session = started {
            startedSessionID = session.id
        }
        return succeeded
    }
}
