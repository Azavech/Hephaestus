import HephClient
import HephCore
import SwiftUI

/// Creates or edits one run configuration of the project (docs/ui/runs.md, "Configuration editor"). Save sends the
/// whole new list with `updateProject(projectID:patch:)`.
struct RunConfigurationSheet: View {
    let store: ProjectStore
    /// The configuration edited; nil for a new one.
    let original: RunConfig?
    /// Called after a successful save with the original name and the saved configuration.
    let onSaved: (_ originalName: String?, _ saved: RunConfig) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var workingDirectory: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(store: ProjectStore, original: RunConfig?, onSaved: @escaping (String?, RunConfig) -> Void) {
        self.store = store
        self.original = original
        self.onSaved = onSaved
        _name = State(initialValue: original?.name ?? "")
        _command = State(initialValue: original?.command ?? "")
        _workingDirectory = State(initialValue: original?.cwd ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedWorkingDirectory: String {
        workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameHasLineBreak: Bool {
        trimmedName.contains(where: \.isNewline)
    }

    /// Unique in the project, ignoring case and the edited configuration itself.
    private var isNameTaken: Bool {
        let others = (store.project?.runs ?? []).filter { $0.name != original?.name }
        return others.contains { $0.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame }
    }

    private var isWorkingDirectoryValid: Bool {
        Self.isValidWorkingDirectory(trimmedWorkingDirectory)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !nameHasLineBreak && !isNameTaken
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isWorkingDirectoryValid
    }

    var body: some View {
        EditSheetLayout(confirmTitle: "Save",
                        isConfirmEnabled: isValid && !isSaving && store.connection?.isConnected == true,
                        errorMessage: errorMessage, onCancel: { dismiss() }, onConfirm: save) {
            Section {
                TextField("Name", text: $name)
                if nameHasLineBreak {
                    fieldMessage("Use a single line.")
                } else if isNameTaken {
                    fieldMessage("A configuration named “\(trimmedName)” already exists.")
                }
                TextField("Command", text: $command, axis: .vertical)
                    .lineLimit(1...6)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                TextField("Working directory", text: $workingDirectory, prompt: Text("."))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                if !isWorkingDirectoryValid {
                    fieldMessage("The working directory must be inside the project.")
                }
            } footer: {
                Text("The command runs with /bin/zsh -lc on \(ClaudeNames.mainName(store.mainDeviceID, in: workspace)), "
                     + "with your login environment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fieldMessage(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
    }

    /// The new list from the current `store.project?.runs`: a new configuration is appended; an edited one replaces
    /// the configuration that has its original name, or is appended when that name is no longer listed. The name and
    /// the working directory are saved trimmed (`cwd` is nil when the field is empty after trimming), the command as
    /// typed.
    private func save() {
        guard isValid, !isSaving else { return }
        let saved = RunConfig(name: trimmedName, command: command,
                              cwd: trimmedWorkingDirectory.isEmpty ? nil : trimmedWorkingDirectory)
        var runs = store.project?.runs ?? []
        if let original, let index = runs.firstIndex(where: { $0.name == original.name }) {
            runs[index] = saved
        } else {
            runs.append(saved)
        }
        let originalName = original?.name
        let store = store
        let workspace = workspace
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let connection = try ClaudeNames.connection(of: store, in: workspace)
                _ = try await connection.updateProject(projectID: store.projectID, patch: ProjectPatch(runs: runs))
                isSaving = false
                onSaved(originalName, saved)
                dismiss()
            } catch {
                isSaving = false
                errorMessage = Banner.message(of: error)
            }
        }
    }

    /// Relative to the project root: no leading `/`, no empty, `.` or `..` component; `.` alone and empty are
    /// accepted.
    static func isValidWorkingDirectory(_ path: String) -> Bool {
        if path.isEmpty || path == "." {
            return true
        }
        if path.hasPrefix("/") {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}
