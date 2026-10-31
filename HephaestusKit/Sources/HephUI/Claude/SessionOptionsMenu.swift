import HephClient
import HephCore
import SwiftUI

/// The options menu of the session header, a button `ellipsis.circle` (docs/ui/sessions.md, "Options menu"). Its
/// requests go through the session's `SessionModel` and the window's banners. While the project's Main is not
/// connected (`isConnected` false), every item is disabled.
struct SessionOptionsMenu: View {
    let model: SessionModel
    let info: SessionInfo
    /// The project's Main is connected.
    let isConnected: Bool

    @Environment(WindowBanners.self) private var banners
    @Environment(WindowContext.self) private var context
    @State private var isRenamePresented = false
    @State private var isModelSheetPresented = false
    @State private var isDeletePresented = false

    var body: some View {
        Menu {
            Group {
                SessionOptionMenus(
                    permissionMode: info.permissionMode,
                    model: info.model,
                    permissionModeDefaultTitle: nil,
                    modelDefaultTitle: "Default",
                    allowsAllTools: info.allowsAllTools,
                    onPermissionMode: { mode in
                        guard let mode else { return }
                        perform { try await model.update(permissionMode: mode) }
                    },
                    onAllowAllTools: { allows in
                        perform { try await model.update(allowsAllTools: allows) }
                    },
                    onModel: { alias in
                        perform { try await model.update(model: alias ?? "") }
                    },
                    onOtherModel: { isModelSheetPresented = true }
                )
                Button("Rename…") { isRenamePresented = true }
                Button("Stop Process") {
                    perform { try await model.stop() }
                }
                .disabled(!ClaudeLabels.hasLiveProcess(info.status))
                Button("Delete Session…") { isDeletePresented = true }
            }
            .disabled(!isConnected)
            Divider()
            Button("Mode and model changes apply when Claude next starts.") {}
                .disabled(true)
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .sheet(isPresented: $isRenamePresented) {
            SessionRenameSheet(title: info.title) { title in
                perform { try await model.update(title: title) }
            }
        }
        .sheet(isPresented: $isModelSheetPresented) {
            SessionModelSheet { name in
                perform { try await model.update(model: name) }
            }
        }
        .sessionDeleteConfirmation(isPresented: $isDeletePresented, title: info.title) {
            let sessionID = model.sessionID
            perform {
                try await model.delete()
                SessionActions.clearSelection(of: sessionID, in: context)
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            await banners.perform(operation)
        }
    }
}

/// What the options menu and the context menu share.
enum SessionActions {
    /// After a deletion: the window whose `selection.item` is that session clears it.
    @MainActor
    static func clearSelection(of sessionID: UUID, in context: WindowContext) {
        if let item = context.selection.item, UUID(uuidString: item) == sessionID {
            context.selection.item = nil
        }
    }
}

/// The rename sheet: a Title field prefilled with the title, Cancel and Save. Save is disabled when the trimmed title
/// is empty or holds a line break; a title has no maximum length.
struct SessionRenameSheet: View {
    private let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    init(title: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _title = State(initialValue: title)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedTitle.isEmpty && !trimmedTitle.contains(where: \.isNewline)
    }

    var body: some View {
        EditSheetLayout(confirmTitle: "Save", isConfirmEnabled: isValid, errorMessage: nil,
                        onCancel: { dismiss() }, onConfirm: save) {
            TextField("Title", text: $title)
        }
    }

    private func save() {
        guard isValid else { return }
        onSave(trimmedTitle)
        dismiss()
    }
}

/// The Other… model sheet: a model text field (trimmed, required), Cancel and Set.
struct SessionModelSheet: View {
    private let onSet: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    init(onSet: @escaping (String) -> Void) {
        self.onSet = onSet
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        EditSheetLayout(confirmTitle: "Set", isConfirmEnabled: !trimmedName.isEmpty, errorMessage: nil,
                        onCancel: { dismiss() }, onConfirm: set) {
            TextField("Model", text: $name)
                .autocorrectionDisabled()
        }
    }

    private func set() {
        guard !trimmedName.isEmpty else { return }
        onSet(trimmedName)
        dismiss()
    }
}

extension View {
    /// The delete confirmation of a session: title "Delete “<title>”?", its message, Delete (destructive) and Cancel.
    func sessionDeleteConfirmation(isPresented: Binding<Bool>, title: String,
                                   onDelete: @escaping () -> Void) -> some View {
        confirmationDialog("Delete “\(title)”?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its transcript and the files attached to its messages are deleted. This cannot be undone.")
        }
    }
}

/// The layout of the sheets of the sessions, runs and skills screens: the fields in a form, then the error message
/// in red above the buttons, then Cancel (Escape) and the confirm button (default action, and ⌘↩).
struct EditSheetLayout<Fields: View>: View {
    let confirmTitle: String
    let isConfirmEnabled: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder let fields: () -> Fields

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                fields()
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isConfirmEnabled)
            }
            .background {
                // ⌘↩ confirms too, also while a multi-line field has the focus.
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!isConfirmEnabled)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 420)
        #endif
    }
}
