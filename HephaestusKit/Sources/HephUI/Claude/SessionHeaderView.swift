import HephClient
import HephCore
import SwiftUI

/// The header of a session: title, context, permission mode, model and All Tools Allowed capsules, options menu
/// (docs/ui/sessions.md, "Header").
struct SessionHeaderView: View {
    let model: SessionModel
    let store: ProjectStore
    let showsTicketLink: Bool

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
                if info.allowsAllTools {
                    SessionHeaderCapsule(text: "All Tools Allowed")
                }
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

    /// Ticket session "<ticket id> · <mode>", followed by " · <bundle id>" for a ticket session of a bundle; feedback
    /// "Feedback · <ticket id>"; regeneration "Regeneration"; bundle "Bundle · <bundle id>".
    @ViewBuilder private func contextLine(_ info: SessionInfo) -> some View {
        switch info.kind {
        case .project:
            EmptyView()
        case .ticket:
            HStack(spacing: 0) {
                if let ticketID = info.ticketID {
                    ticketLink(ticketID)
                }
                if let mode = info.mode {
                    Text(info.ticketID == nil ? mode.displayName : " · \(mode.displayName)")
                }
                if let bundleID = info.bundleID {
                    Text(info.ticketID == nil && info.mode == nil ? bundleID : " · \(bundleID)")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        case .feedback:
            HStack(spacing: 0) {
                Text(info.ticketID == nil ? "Feedback" : "Feedback · ")
                if let ticketID = info.ticketID {
                    ticketLink(ticketID)
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

    /// The ticket id; with `showsTicketLink`, a link that shows the ticket.
    @ViewBuilder private func ticketLink(_ ticketID: String) -> some View {
        if showsTicketLink {
            Button(ticketID) {
                context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .tickets,
                                 item: ticketID)
            }
            #if os(macOS)
            .buttonStyle(.link)
            #else
            .buttonStyle(.borderless)
            #endif
        } else {
            Text(ticketID)
        }
    }
}

/// A capsule of the header: the permission mode title, the model, or All Tools Allowed.
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
