import HephClient
import HephCore
import SwiftUI

/// The header of a session: title, context, permission mode and model capsules, options menu (docs/ui/sessions.md,
/// "Header").
struct SessionHeaderView: View {
    let model: SessionModel
    let store: ProjectStore
    let showsTaskLink: Bool

    @Environment(WindowContext.self) private var context

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let info = model.info {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .font(.headline)
                        .lineLimit(1)
                    contextLine(info)
                }
                Spacer(minLength: 8)
                SessionHeaderCapsule(text: ClaudeLabels.title(info.permissionMode))
                SessionHeaderCapsule(text: info.model ?? "Default model")
                SessionOptionsMenu(model: model, info: info, isConnected: store.connection?.isConnected == true)
            } else {
                if store.phase != .loaded {
                    Text("Loading…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Task session "<task id> · <mode>", followed by " · <bundle id>" for a task session of a bundle; feedback
    /// "Feedback · <task id>"; regeneration "Regeneration"; bundle "Bundle · <bundle id>".
    @ViewBuilder private func contextLine(_ info: SessionInfo) -> some View {
        switch info.kind {
        case .project:
            EmptyView()
        case .task:
            HStack(spacing: 0) {
                if let taskID = info.taskID {
                    taskLink(taskID)
                }
                if let mode = info.mode {
                    Text(info.taskID == nil ? mode.displayName : " · \(mode.displayName)")
                }
                if let bundleID = info.bundleID {
                    Text(info.taskID == nil && info.mode == nil ? bundleID : " · \(bundleID)")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        case .feedback:
            HStack(spacing: 0) {
                Text(info.taskID == nil ? "Feedback" : "Feedback · ")
                if let taskID = info.taskID {
                    taskLink(taskID)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        case .regeneration:
            Text("Regeneration")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .bundle:
            Text(info.bundleID.map { "Bundle · \($0)" } ?? "Bundle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// The task id; with `showsTaskLink`, a link that shows the task.
    @ViewBuilder private func taskLink(_ taskID: String) -> some View {
        if showsTaskLink {
            Button(taskID) {
                context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .tasks,
                                 item: taskID)
            }
            #if os(macOS)
            .buttonStyle(.link)
            #else
            .buttonStyle(.borderless)
            #endif
        } else {
            Text(taskID)
        }
    }
}

/// A capsule of the header: the permission mode title, or the model.
private struct SessionHeaderCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
