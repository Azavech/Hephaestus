import HephClient
import HephCore
import SwiftUI

/// The sessions of the project in groups: Chats, Tasks, Bundles, Forge (docs/ui/sessions.md, "Session list"). A group
/// without sessions is hidden; inside a group, by `updated` descending.
struct SessionListView: View {
    let store: ProjectStore
    /// The window is compact: the New Chat button sits in the navigation bar instead of the list header.
    let isCompact: Bool
    /// New Chat: clears `selection.item` and shows the new chat.
    let onNewChat: () -> Void

    @Environment(WindowContext.self) private var context

    var body: some View {
        let groups = SessionListGroup.groups(of: store.sessions)
        Group {
            if store.sessions.isEmpty {
                VStack(spacing: 12) {
                    Text("No sessions yet")
                        .foregroundStyle(.secondary)
                    Button("New Chat", action: onNewChat)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selectedSessionID) {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.sessions) { session in
                                SessionListRow(session: session, group: group.kind)
                                    .sessionContextMenu(store: store, session: session)
                                    .tag(session.id)
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isCompact {
                HStack {
                    Spacer()
                    newChatButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .toolbar {
            if isCompact {
                ToolbarItem(placement: .primaryAction) {
                    newChatButton
                }
            }
        }
    }

    private var newChatButton: some View {
        Button(action: onNewChat) {
            Label("New Chat", systemImage: "square.and.pencil")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("New Chat")
    }

    /// The selected session: `selection.item` read as a UUID; choosing a row writes its `uuidString`.
    private var selectedSessionID: Binding<UUID?> {
        Binding(
            get: { context.selection.item.flatMap(UUID.init(uuidString:)) },
            set: { id in
                guard let id else { return }
                context.selection.item = id.uuidString
            }
        )
    }
}

/// A group of the session list.
private struct SessionListGroup: Identifiable {
    enum Kind {
        case chats, tasks, bundles, forge
    }

    let kind: Kind
    let sessions: [SessionInfo]

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .chats: return "Chats"
        case .tasks: return "Tasks"
        case .bundles: return "Bundles"
        case .forge: return "Forge"
        }
    }

    /// Chats: kind `project`; Tasks: kind `task`; Bundles: kind `bundle`; Forge: kinds `feedback` and `regeneration`.
    static func groups(of sessions: [SessionInfo]) -> [SessionListGroup] {
        let sorted = sessions.sorted { $0.updated > $1.updated }
        let groups = [
            SessionListGroup(kind: .chats, sessions: sorted.filter { $0.kind == .project }),
            SessionListGroup(kind: .tasks, sessions: sorted.filter { $0.kind == .task }),
            SessionListGroup(kind: .bundles, sessions: sorted.filter { $0.kind == .bundle }),
            SessionListGroup(kind: .forge,
                             sessions: sorted.filter { $0.kind == .feedback || $0.kind == .regeneration }),
        ]
        return groups.filter { !$0.sessions.isEmpty }
    }
}

/// A row: the title and the status indicator, then the group's caption.
private struct SessionListRow: View {
    let session: SessionInfo
    let group: SessionListGroup.Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(session.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                SessionStatusIndicator(status: session.status)
            }
            TimelineView(.everyMinute) { _ in
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// Chats: relative `updated`; Tasks: "<task id> · <mode> · <relative updated>"; Bundles: "<bundle id> · <relative
    /// updated>"; Forge: "<kind title> · <task id when set> · <relative updated>".
    private var caption: String {
        let updated = session.updated.formatted(.relative(presentation: .named))
        switch group {
        case .chats:
            return updated
        case .tasks:
            return ([session.taskID, session.mode?.displayName].compactMap { $0 } + [updated])
                .joined(separator: " · ")
        case .bundles:
            return ([session.bundleID].compactMap { $0 } + [updated]).joined(separator: " · ")
        case .forge:
            return ([ClaudeLabels.title(session.kind), session.taskID].compactMap { $0 } + [updated])
                .joined(separator: " · ")
        }
    }
}
