import HephClient
import HephCore
import SwiftUI

/// Adds tickets to a bundle (docs/ui/tickets.md, "Add tickets sheet"): the project's tickets that are not broken and not in the
/// bundle, by ticket number, filtered by the text rule of the ticket filter; the chosen ones are added after the bundle's
/// tickets.
struct AddBundleTicketsSheet: View {
    let store: ProjectStore
    let bundle: BundleItem

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var chosen: Set<String> = []
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "Add Tickets to \(bundle.id)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $text)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Form {
                ForEach(shownTickets) { ticket in
                    ticketRow(ticket)
                }
            }
            .formStyle(.grouped)
            .disabled(isAdding)
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(action: add) {
                    if isAdding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
                .background {
                    // ⌘↩ adds too (docs/ui/tickets.md, "Keyboard shortcuts").
                    Button("Add", action: add)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canAdd)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 440)
        #endif
    }

    /// The tickets that are not broken and not in the bundle, in the order of `store.tickets` (by ticket number), filtered
    /// by the text.
    private var shownTickets: [TicketItem] {
        let inBundle = Set(bundle.tickets.map(\.ticketID))
        let candidates = store.tickets.filter { $0.parseError == nil && !inBundle.contains($0.id) }
        return TicketListState.tickets(candidates, matching: text)
    }

    /// The id (monospaced) and the name; a checkmark when chosen. Choosing the row toggles it.
    private func ticketRow(_ ticket: TicketItem) -> some View {
        Button {
            if chosen.contains(ticket.id) {
                chosen.remove(ticket.id)
            } else {
                chosen.insert(ticket.id)
            }
        } label: {
            HStack(spacing: 8) {
                Text(ticket.id)
                    .font(.body.monospaced())
                Text(ticket.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if chosen.contains(ticket.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A ticket is chosen, the Main is connected and no request is in flight.
    private var canAdd: Bool {
        !chosen.isEmpty && !isAdding && TicketsScreen.isConnected(store)
    }

    private func add() {
        guard canAdd else { return }
        let ticketIDs = BundleScreen.ticketIDs(of: store.bundle(bundle.id) ?? bundle, adding: Array(chosen))
        let projectID = store.projectID
        let bundleID = bundle.id
        isAdding = true
        errorMessage = nil
        Task {
            do {
                let connection = try TicketsScreen.connection(of: store, workspace: workspace)
                _ = try await connection.updateBundle(projectID: projectID, bundleID: bundleID,
                                                      patch: BundlePatch(ticketIDs: ticketIDs))
                isAdding = false
                dismiss()
            } catch is CancellationError {
                isAdding = false
            } catch {
                isAdding = false
                errorMessage = Banner.message(of: error)
            }
        }
    }
}
