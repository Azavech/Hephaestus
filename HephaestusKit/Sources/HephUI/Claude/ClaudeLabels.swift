import HephClient
import HephCore
import SwiftUI

/// The titles of the session statuses, permission modes and session kinds; every view of the sessions uses them
/// (docs/ui/sessions.md, "Labels"). `SessionMode` titles are its `displayName`.
public enum ClaudeLabels {
    public static func title(_ status: SessionStatus) -> String {
        switch status {
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .waitingPermission: return "Waiting for permission"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    public static func title(_ mode: PermissionMode) -> String {
        switch mode {
        case .manual: return "Manual"
        case .acceptEdits: return "Accept Edits"
        case .auto: return "Auto"
        case .plan: return "Plan"
        case .bypassPermissions: return "Bypass Permissions"
        }
    }

    public static func title(_ kind: SessionKind) -> String {
        switch kind {
        case .project: return "Chat"
        case .task: return "Task"
        case .feedback: return "Feedback"
        case .regeneration: return "Regeneration"
        case .bundle: return "Bundle"
        }
    }

    /// The model aliases offered; any other model name can be typed, and an empty model means the default.
    static let modelAliases = ["opus", "sonnet", "haiku"]

    /// The five permission modes, in the order of the table.
    static let permissionModes: [PermissionMode] = [.manual, .acceptEdits, .auto, .plan, .bypassPermissions]

    /// A session has a live CLI process when its status is `idle`, `starting`, `running` or `waitingPermission`.
    static func hasLiveProcess(_ status: SessionStatus) -> Bool {
        switch status {
        case .idle, .starting, .running, .waitingPermission: return true
        case .stopped, .failed: return false
        }
    }

    /// The options menu and the session context menu offer Permission Mode for kinds other than `feedback` and
    /// `regeneration`.
    static func offersPermissionMode(_ kind: SessionKind) -> Bool {
        switch kind {
        case .project, .task, .bundle: return true
        case .feedback, .regeneration: return false
        }
    }
}

/// The indicator of a session status: green dot, small progress view, orange hand, gray dot or red octagon; the dots
/// are circles 8 pt wide and the accessibility label is the title (docs/ui/sessions.md, "Labels"). The session list and
/// the session tabs of a task use it.
struct SessionStatusIndicator: View {
    let status: SessionStatus

    var body: some View {
        indicator
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ClaudeLabels.title(status))
    }

    @ViewBuilder private var indicator: some View {
        switch status {
        case .idle:
            SessionStatusDot(color: .green)
        case .starting, .running:
            ProgressView()
                .controlSize(.small)
        case .waitingPermission:
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
        case .stopped:
            SessionStatusDot(color: .gray)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}

/// The colored dot of the session indicators and of the status line.
struct SessionStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

/// Names and connections shared by the views of the sessions.
enum ClaudeNames {
    /// The name of a Main: its connection's name, else its registry name, else "Main".
    @MainActor
    static func mainName(_ mainDeviceID: UUID, in workspace: Workspace) -> String {
        if let connection = workspace.connection(mainDeviceID) {
            return connection.name
        }
        return workspace.mesh?.devices.first { $0.id == mainDeviceID }?.name ?? "Main"
    }

    /// The name of a device in the mesh records, nil when unknown.
    @MainActor
    static func deviceName(_ deviceID: UUID?, in workspace: Workspace) -> String? {
        guard let deviceID else { return nil }
        if let record = workspace.mesh?.devices.first(where: { $0.id == deviceID }) {
            return record.name
        }
        return workspace.mains.first { $0.id == deviceID }?.name
    }

    /// The connection of the store's Main; throws `unavailable` "<Main name> is offline." without one.
    @MainActor
    static func connection(of store: ProjectStore, in workspace: Workspace) throws -> MainConnection {
        guard let connection = store.connection else {
            throw ProtocolError(.unavailable, "\(mainName(store.mainDeviceID, in: workspace)) is offline.")
        }
        return connection
    }
}
