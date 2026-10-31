import HephClient
import HephCore
import SwiftUI

/// Starts a Claude session for a ticket (docs/ui/tickets.md, "New session sheet"): a mode, and instructions for Custom.
/// The Main titles the session, builds the first message and starts Claude at once.
struct NewTicketSessionSheet: View {
    let store: ProjectStore
    let ticket: TicketItem
    /// Called with the started session once the sheet has dismissed itself.
    let onStarted: (SessionInfo) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var mode: SessionMode = .implement
    @State private var instructions = ""
    @State private var isStarting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "New Claude Session for \(ticket.id)")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            Form {
                Section("Mode") {
                    ForEach(SessionMode.allCases, id: \.self) { mode in
                        modeRow(mode)
                    }
                }
                if mode == .custom {
                    Section("Instructions") {
                        TextEditor(text: $instructions)
                            .frame(minHeight: 100)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isStarting)
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
                Button(action: start) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Start")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
                .background {
                    // ⌘↩ starts too (docs/ui/tickets.md, "Keyboard shortcuts"), also from the instructions editor.
                    Button("Start", action: start)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canStart)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 440)
        #endif
    }

    /// A selectable row: the mode's `displayName` and its description, with a checkmark on the chosen one.
    private func modeRow(_ mode: SessionMode) -> some View {
        Button {
            self.mode = mode
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                    Text(Self.description(of: mode))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if self.mode == mode {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func description(of mode: SessionMode) -> String {
        switch mode {
        case .implement:
            return "Implement the ticket, keep the docs in sync, build and test, and comment a summary."
        case .debug:
            return "Find the root cause, explain it, and propose or apply a fix after your confirmation."
        case .review:
            return "Review the work done for the ticket and comment the findings."
        case .plan:
            return "Write a plan as a comment, without changing code."
        case .custom:
            return "Follow your instructions."
        }
    }

    private var trimmedInstructions: String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Custom needs instructions; the Main is connected and no request is in flight.
    private var canStart: Bool {
        !(mode == .custom && trimmedInstructions.isEmpty) && !isStarting && TicketsScreen.isConnected(store)
    }

    /// `startSession(projectID:kind: .ticket, ticketID:mode:title: nil, message:permissionMode: nil, model: nil)`; the
    /// message is the trimmed instructions for Custom, nil otherwise.
    private func start() {
        guard canStart else { return }
        let mode = self.mode
        let message: String? = mode == .custom ? trimmedInstructions : nil
        let projectID = store.projectID
        let ticketID = ticket.id
        isStarting = true
        errorMessage = nil
        Task {
            do {
                let connection = try TicketsScreen.connection(of: store, workspace: workspace)
                let session = try await connection.startSession(projectID: projectID, kind: .ticket, ticketID: ticketID,
                                                                mode: mode, title: nil, message: message,
                                                                permissionMode: nil, model: nil)
                isStarting = false
                dismiss()
                onStarted(session)
            } catch is CancellationError {
                isStarting = false
            } catch {
                isStarting = false
                errorMessage = Banner.message(of: error)
            }
        }
    }
}
