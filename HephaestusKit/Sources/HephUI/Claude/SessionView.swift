import HephClient
import HephCore
import SwiftUI

/// One session: header, transcript, status line and composer, top to bottom (docs/ui/sessions.md, "Session view").
/// The Claude section, the Claude segment of a task and every session shown through the selection use it.
public struct SessionView: View {
    private let store: ProjectStore
    private let sessionID: UUID
    private let showsTaskLink: Bool

    public init(store: ProjectStore, sessionID: UUID, showsTaskLink: Bool = true) {
        self.store = store
        self.sessionID = sessionID
        self.showsTaskLink = showsTaskLink
    }

    public var body: some View {
        // Each session gets its own model and draft: the view's state starts fresh when it shows another session.
        SessionContentView(store: store, sessionID: sessionID, showsTaskLink: showsTaskLink)
            .id(sessionID)
    }
}

/// The view of one session; it creates its `SessionModel` when it appears.
private struct SessionContentView: View {
    let store: ProjectStore
    let sessionID: UUID
    let showsTaskLink: Bool

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    @State private var model: SessionModel?
    @State private var draft = ComposerDraft()
    /// The item the transcript scrolls to (Review).
    @State private var scrollRequest: String?

    var body: some View {
        Group {
            if let model {
                if model.isRemoved {
                    Text("This session was deleted.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    session(model)
                }
            } else {
                Color.clear
            }
        }
        .onAppear {
            let model = model ?? SessionModel(workspace: workspace, store: store, sessionID: sessionID)
            self.model = model
            model.appear()
        }
        .onDisappear {
            model?.disappear()
        }
    }

    private func session(_ model: SessionModel) -> some View {
        let isLoading = model.info == nil && store.phase != .loaded
        return VStack(spacing: 0) {
            SessionHeaderView(model: model, store: store, showsTaskLink: showsTaskLink)
            Divider()
            TranscriptView(model: model, store: store, scrollRequest: $scrollRequest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SessionStatusLine(model: model, store: store) {
                review(model)
            }
            MessageComposer(placeholder: "Message Claude", draft: $draft, mainDeviceID: store.mainDeviceID,
                            projectID: store.projectID, canSend: canSend(model),
                            onStop: isTurnInProgress(model) ? { interrupt(model) } : nil,
                            onSend: { draft in await send(draft, model: model) })
                .padding(12)
                .disabled(isLoading)
        }
    }

    /// Send is possible when the Main is connected and `model.info` is known, whatever the status: a message sent
    /// during a turn is queued by the CLI.
    private func canSend(_ model: SessionModel) -> Bool {
        store.connection?.isConnected == true && model.info != nil
    }

    /// The Stop button shows while the status is `starting`, `running` or `waitingPermission`.
    private func isTurnInProgress(_ model: SessionModel) -> Bool {
        switch model.info?.status {
        case .starting, .running, .waitingPermission: return true
        default: return false
        }
    }

    private func send(_ draft: ComposerDraft, model: SessionModel) async -> Bool {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploads = draft.uploads
        return await banners.perform {
            try await model.send(text: text, attachments: uploads)
        }
    }

    /// Stop: the turn ends with an "Interrupted" caption and the process stays alive.
    private func interrupt(_ model: SessionModel) {
        Task {
            await banners.perform {
                try await model.interrupt()
            }
        }
    }

    /// Review scrolls to the first pending permission card.
    private func review(_ model: SessionModel) {
        let pending = Set(model.info?.pendingPermissions.map(\.requestID) ?? [])
        let card = model.items.first { item in
            if case .permission(let permission) = item {
                return permission.decision == nil && pending.contains(permission.requestID)
            }
            return false
        }
        if let card {
            scrollRequest = card.id
        } else if let requestID = model.info?.pendingPermissions.first?.requestID {
            scrollRequest = "permission:\(requestID)"
        }
    }
}
