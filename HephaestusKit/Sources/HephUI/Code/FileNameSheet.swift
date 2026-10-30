import Foundation
import HephCore
import SwiftUI

/// The sheet that asks for the name of a new file or folder, or a new name (docs/ui/code.md, "FileNameSheet").
struct FileNameSheet: View {
    let title: String
    let actionTitle: String
    let initialName: String
    /// The names of the other entries of the folder (not the item being renamed).
    let existingNames: [String]
    let onCommit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var name: String
    @State private var isCommitting = false
    @State private var errorMessage: String?
    /// The sheet was dismissed: a commit that still runs goes on, and its end changes nothing here.
    @State private var isDismissed = false
    @FocusState private var isFieldFocused: Bool

    init(title: String, actionTitle: String, initialName: String, existingNames: [String],
         onCommit: @escaping (String) async throws -> Void) {
        self.title = title
        self.actionTitle = actionTitle
        self.initialName = initialName
        self.existingNames = existingNames
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The validation line; nil for a valid name and for an empty one (the button is disabled).
    private var validationMessage: String? {
        let name = trimmedName
        if name.isEmpty {
            return nil
        }
        if name.contains("/") {
            return "A name can't contain “/”."
        }
        if name == "." || name == ".." {
            return "This name is reserved."
        }
        if existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "“\(name)” already exists in this folder."
        }
        return nil
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && validationMessage == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($isFieldFocused)
                .onSubmit(commit)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if isCommitting {
                    ProgressView()
                        .controlSize(.small)
                }
                // Enabled while the commit runs: the request goes on.
                Button("Cancel", role: .cancel) {
                    isDismissed = true
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isCommitting)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        .onAppear {
            isFieldFocused = true
        }
        .onDisappear {
            isDismissed = true
        }
        #if os(iOS)
        .presentationDetents(horizontalSizeClass == .compact ? [.medium] : [.large])
        #endif
    }

    /// Runs `onCommit` with the trimmed name: success dismisses the sheet, an error stays shown in red. After Cancel,
    /// the request goes on and its end, an error included, is not shown.
    private func commit() {
        guard isValid, !isCommitting else { return }
        let name = trimmedName
        isCommitting = true
        errorMessage = nil
        Task {
            do {
                try await onCommit(name)
                isCommitting = false
                if !isDismissed {
                    dismiss()
                }
            } catch {
                isCommitting = false
                if !isDismissed, !(error is CancellationError) {
                    errorMessage = Banner.message(of: error)
                }
            }
        }
    }
}
