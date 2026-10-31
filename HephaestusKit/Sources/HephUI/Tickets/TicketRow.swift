import HephClient
import HephCore
import SwiftUI

/// A row of the ticket list (docs/ui/tickets.md, "Row"): the id and the indicators, then the name; a context menu with
/// Status, New Bundle from Selection…, Add to Bundle, Copy ID and Delete… (a broken ticket: Copy ID and Delete… only).
struct TicketRow: View {
    let store: ProjectStore
    let ticket: TicketItem
    /// The tickets of New Bundle from Selection… and Add to Bundle: the selected tickets, or this ticket when it is not
    /// selected.
    let bundleTicketIDs: [String]
    /// Opens the New Bundle sheet with these tickets.
    let onNewBundle: ([String]) -> Void
    /// Asks for the delete confirmation of this ticket.
    let onDelete: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(ticket.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                indicators
                    .font(.caption)
            }
            if ticket.parseError != nil {
                Text("Invalid ticket file")
                    .foregroundStyle(.red)
            } else {
                Text(ticket.name)
                    .font(.body)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            contextMenuItems
        }
    }

    /// From the sessions of the ticket: `hand.raised.fill` when one waits for a permission, else `sparkles` when one is
    /// starting or running; then `bubble.left` and the comment count when the ticket has comments.
    @ViewBuilder
    private var indicators: some View {
        let sessions = store.sessions.filter { $0.ticketID == ticket.id }
        if sessions.contains(where: { $0.status == .waitingPermission }) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
        } else if sessions.contains(where: { $0.status == .starting || $0.status == .running }) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
        }
        if !ticket.comments.isEmpty {
            HStack(spacing: 2) {
                Image(systemName: "bubble.left")
                Text("\(ticket.comments.count)")
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if ticket.parseError == nil {
            Picker("Status", selection: statusBinding) {
                ForEach(TicketStatus.allCases, id: \.self) { status in
                    Text(status.displayName)
                        .tag(status)
                }
            }
            .pickerStyle(.menu)
            .disabled(!TicketsScreen.isConnected(store))
            Button("New Bundle from Selection…") {
                onNewBundle(bundleTicketIDs)
            }
            .disabled(bundleTicketIDs.isEmpty || !TicketsScreen.isConnected(store))
            AddToBundleMenu(store: store, ticketIDs: bundleTicketIDs)
        }
        Button("Copy ID") {
            TicketsScreen.copy(ticket.id)
        }
        Button("Delete…", role: .destructive, action: onDelete)
            .disabled(!TicketsScreen.isConnected(store))
    }

    /// The current status checked; choosing another one sends `TicketPatch(status:)`.
    private var statusBinding: Binding<TicketStatus> {
        let projectID = store.projectID
        let ticketID = ticket.id
        let current = ticket.status
        return Binding(
            get: { current },
            set: { status in
                guard status != current else { return }
                Task {
                    await banners.perform {
                        let connection = try TicketsScreen.connection(of: store, workspace: workspace)
                        _ = try await connection.updateTicket(projectID: projectID, ticketID: ticketID,
                                                            patch: TicketPatch(status: status))
                    }
                }
            }
        )
    }
}
