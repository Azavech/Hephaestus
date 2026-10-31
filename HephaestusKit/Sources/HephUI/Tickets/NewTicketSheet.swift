import HephClient
import HephCore
import SwiftUI

/// Creates a ticket in the project of `store` (docs/ui/tickets.md, "New ticket"). Opened by the New Ticket buttons and by ⌘N.
struct NewTicketSheet: View {
    let store: ProjectStore
    /// Called with the created ticket once the sheet has dismissed itself; the caller selects it.
    let onCreated: (TicketItem) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var status: TicketStatus = .todo
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
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
                Section("Description") {
                    TextEditor(text: $description)
                        .font(.body.monospaced())
                        .frame(minHeight: 120)
                }
                Section {
                    Picker("Status", selection: $status) {
                        ForEach(TicketStatus.allCases, id: \.self) { status in
                            TicketStatusBadge(status: status)
                                .tag(status)
                        }
                    }
                    .pickerStyle(.inline)
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
                    // ⌘↩ creates too (docs/ui/tickets.md, "Keyboard shortcuts"), also from the description editor.
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
        .frame(minWidth: 460, idealWidth: 520, minHeight: 460)
        #endif
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
        // nil when empty after trimming, else the text as typed.
        let isDescriptionEmpty = self.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let description: String? = isDescriptionEmpty ? nil : self.description
        let status = self.status
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let connection = try TicketsScreen.connection(of: store, workspace: workspace)
                let ticket = try await connection.createTicket(projectID: store.projectID, name: name,
                                                           description: description, status: status)
                isCreating = false
                dismiss()
                onCreated(ticket)
            } catch is CancellationError {
                isCreating = false
            } catch {
                isCreating = false
                errorMessage = Banner.message(of: error)
            }
        }
    }
}
