import HephClient
import HephCore
import SwiftUI

/// Creates a bundle from the given tickets (docs/ui/tickets.md, "New bundle sheet"): a name, then the tickets in ticket number
/// order, each removable while more than one remains.
struct NewBundleSheet: View {
    let store: ProjectStore
    /// Called with the created bundle once the sheet has dismissed itself; the caller empties the list's selection and
    /// selects the bundle.
    let onCreated: (BundleItem) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var ticketIDs: [String]
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(store: ProjectStore, ticketIDs: [String], onCreated: @escaping (BundleItem) -> Void) {
        self.store = store
        self.onCreated = onCreated
        _ticketIDs = State(initialValue: TicketListState.sortedByNumber(ticketIDs))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Bundle")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $name)
                        if nameHasLineBreak {
                            Text("Use a single line.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Section("Tickets") {
                    ForEach(ticketIDs, id: \.self) { ticketID in
                        ticketRow(ticketID)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
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
                Button(action: create) {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .background {
                    // ⌘↩ creates too (docs/ui/tickets.md, "Keyboard shortcuts").
                    Button("Create", action: create)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canCreate)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 400)
        #endif
    }

    /// The id (monospaced) and the name; a remove button while more than one ticket remains.
    private func ticketRow(_ ticketID: String) -> some View {
        HStack(spacing: 8) {
            Text(ticketID)
                .font(.body.monospaced())
            Text(store.ticket(ticketID)?.name ?? "")
                .lineLimit(1)
            Spacer(minLength: 4)
            if ticketIDs.count > 1 {
                Button {
                    ticketIDs.removeAll { $0 == ticketID }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameHasLineBreak: Bool {
        trimmedName.contains { $0.isNewline }
    }

    /// The name is valid, the Main is connected and no request is in flight.
    private var canCreate: Bool {
        !trimmedName.isEmpty && !nameHasLineBreak && !isCreating && TicketsScreen.isConnected(store)
    }

    private func create() {
        guard canCreate else { return }
        let name = trimmedName
        let ticketIDs = self.ticketIDs
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let connection = try TicketsScreen.connection(of: store, workspace: workspace)
                let bundle = try await connection.createBundle(projectID: store.projectID, name: name,
                                                               ticketIDs: ticketIDs)
                isCreating = false
                dismiss()
                onCreated(bundle)
            } catch is CancellationError {
                isCreating = false
            } catch {
                isCreating = false
                errorMessage = Banner.message(of: error)
            }
        }
    }
}
