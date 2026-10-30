import HephClient
import HephCore
import SwiftUI

/// New File… of a skill: a Path field; Create writes an empty file at that path (docs/ui/skills.md, "Add a file").
struct NewSkillFileSheet: View {
    let mainDeviceID: UUID
    let skillName: String
    /// The paths of the files of the skill.
    let existingPaths: Set<String>
    /// Called after a successful creation with the new file's path.
    let onCreated: (String) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var isValid: Bool {
        Self.isValidPath(path) && !existingPaths.contains(path)
    }

    var body: some View {
        EditSheetLayout(confirmTitle: "Create", isConfirmEnabled: isValid && !isCreating, errorMessage: errorMessage,
                        onCancel: { dismiss() }, onConfirm: create) {
            TextField("Path", text: $path, prompt: Text("references/notes.md"))
                .font(.body.monospaced())
                .autocorrectionDisabled()
        }
    }

    /// `writeSkillFile(name:path:data:)` with empty data.
    private func create() {
        guard isValid, !isCreating else { return }
        let path = path
        let skillName = skillName
        let workspace = workspace
        let mainDeviceID = mainDeviceID
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let connection = try SkillNameRules.connection(mainDeviceID, in: workspace)
                try await connection.writeSkillFile(name: skillName, path: path, data: Data())
                isCreating = false
                dismiss()
                onCreated(path)
            } catch {
                isCreating = false
                errorMessage = Banner.message(of: error)
            }
        }
    }

    /// A relative `/`-separated path: no leading `/`, no empty, `.` or `..` component.
    static func isValidPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}
