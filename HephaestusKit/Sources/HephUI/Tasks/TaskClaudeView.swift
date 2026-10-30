import HephClient
import HephCore
import SwiftUI

/// The Claude segment of a task (docs/ui/tasks.md, "Claude segment"): one tab per Claude session of the task, the
/// selected session's `SessionView`, and the new session sheet.
struct TaskClaudeView: View {
    let store: ProjectStore
    let task: TaskItem
    /// The selected tab, remembered per task by `TasksView`.
    @Binding var selectedSessionID: UUID?
    /// Switches the detail to the Claude segment after a session was started from the new session sheet.
    let onSessionStarted: () -> Void

    @State private var isNewSessionPresented = false

    /// The sessions of `store.sessions` with kind `task` and this task's id, in the store's order (by `created`).
    private var sessions: [SessionInfo] {
        store.sessions.filter { $0.kind == .task && $0.taskID == task.id }
    }

    var body: some View {
        let sessions = self.sessions
        Group {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Text("No Claude session for this task yet.")
                } actions: {
                    Button("New Session…") {
                        isNewSessionPresented = true
                    }
                    .disabled(!TasksScreen.isConnected(store))
                }
            } else {
                VStack(spacing: 0) {
                    tabStrip(sessions)
                    Divider()
                    if let sessionID = shownSessionID(in: sessions) {
                        SessionView(store: store, sessionID: sessionID, showsTaskLink: false)
                            .id(sessionID)
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .onAppear {
            selectDefaultIfNeeded(in: self.sessions)
        }
        .onChange(of: sessions.map(\.id)) { oldIDs, newIDs in
            followRemoval(oldIDs: oldIDs, newIDs: newIDs)
        }
        .sheet(isPresented: $isNewSessionPresented) {
            NewTaskSessionSheet(store: store, task: task) { session in
                selectedSessionID = session.id
                onSessionStarted()
            }
        }
    }

    // MARK: - Tabs

    /// A horizontal scroll of tabs, the selected one highlighted, then the `plus` button of the new session sheet.
    private func tabStrip(_ sessions: [SessionInfo]) -> some View {
        let shownID = shownSessionID(in: sessions)
        return HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(sessions) { session in
                        tab(session, isSelected: session.id == shownID)
                    }
                }
                .padding(.horizontal, 8)
            }
            Button {
                isNewSessionPresented = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(!TasksScreen.isConnected(store))
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
    }

    /// The status indicator and the title (one line, at most 200 pt wide); the context menu of the session.
    private func tab(_ session: SessionInfo, isSelected: Bool) -> some View {
        Button {
            selectedSessionID = session.id
        } label: {
            HStack(spacing: 6) {
                SessionStatusIndicator(status: session.status)
                TaskSessionTabTitleLayout(maxWidth: 200) {
                    Text(session.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(SessionContextMenu(store: store, session: session))
    }

    // MARK: - Selection

    /// The selected tab; by default the session with the latest `updated`.
    private func shownSessionID(in sessions: [SessionInfo]) -> UUID? {
        if let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) {
            return selectedSessionID
        }
        return Self.latestSession(in: sessions)
    }

    /// Records the default tab, so that a session started elsewhere adds a tab that is not selected.
    private func selectDefaultIfNeeded(in sessions: [SessionInfo]) {
        if let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) {
            return
        }
        selectedSessionID = Self.latestSession(in: sessions)
    }

    /// When the selected session is removed, the tab on its left is selected, or the first tab.
    private func followRemoval(oldIDs: [UUID], newIDs: [UUID]) {
        guard let selected = selectedSessionID else {
            selectDefaultIfNeeded(in: sessions)
            return
        }
        guard !newIDs.contains(selected) else { return }
        if let index = oldIDs.firstIndex(of: selected),
           let left = oldIDs[..<index].last(where: { newIDs.contains($0) }) {
            selectedSessionID = left
        } else {
            selectedSessionID = newIDs.first
        }
    }

    private static func latestSession(in sessions: [SessionInfo]) -> UUID? {
        sessions.max { $0.updated < $1.updated }?.id
    }
}

/// Gives its single subview its ideal width, at most `maxWidth`, so that a tab title in the horizontal scroll view
/// truncates beyond 200 pt.
private struct TaskSessionTabTitleLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(.unspecified)
        return subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, maxWidth), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
