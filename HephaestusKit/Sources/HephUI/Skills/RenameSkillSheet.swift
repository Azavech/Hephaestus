import HephClient
import HephCore
import SwiftUI

/// Renames a skill: a Name field prefilled with the current name, the rules of New Skill (unique among the other
/// skills, different from the current name), Cancel and Rename (docs/ui/skills.md, "Rename the skill"). Rename first
/// saves each open document of the skill that has unsaved changes; the Main also rewrites `name` in `SKILL.md`.
struct RenameSkillSheet: View {
    let mainDeviceID: UUID
    let currentName: String
    /// The names of the other skills of the list.
    let otherNames: Set<String>
    /// The screen whose open documents of the skill are saved before the rename.
    let screen: SkillsScreenModel
    /// Called with the new name just before `renameSkill(name:to:)` is sent.
    let onStart: (String) -> Void
    /// Called after a successful rename with the new name.
    let onRenamed: (String) -> Void
    /// Called when a rename that started failed.
    let onFailed: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isRenaming = false
    @State private var errorMessage: String?

    init(mainDeviceID: UUID, currentName: String, otherNames: Set<String>, screen: SkillsScreenModel,
         onStart: @escaping (String) -> Void, onRenamed: @escaping (String) -> Void,
         onFailed: @escaping () -> Void) {
        self.mainDeviceID = mainDeviceID
        self.currentName = currentName
        self.otherNames = otherNames
        self.screen = screen
        self.onStart = onStart
        self.onRenamed = onRenamed
        self.onFailed = onFailed
        _name = State(initialValue: currentName)
    }

    private var isValid: Bool {
        name != currentName && SkillNameRules.isAcceptable(name, existingNames: otherNames)
    }

    var body: some View {
        EditSheetLayout(confirmTitle: "Rename", isConfirmEnabled: isValid && !isRenaming, errorMessage: errorMessage,
                        onCancel: { dismiss() }, onConfirm: rename) {
            TextField("Name", text: SkillNameRules.lowercasing($name))
                .font(.body.monospaced())
                .autocorrectionDisabled()
            SkillNameRules.message(for: name, existingNames: otherNames)
        }
    }

    /// Saves the open documents of the skill that have unsaved changes, as ⌘S does (a failure shows its message and the
    /// skill is not renamed), then `renameSkill(name:to:)`. Success: the window selects the new name. Failure: the
    /// message shows.
    private func rename() {
        guard isValid, !isRenaming else { return }
        let oldName = currentName
        let newName = name
        let workspace = workspace
        let mainDeviceID = mainDeviceID
        let screen = screen
        isRenaming = true
        errorMessage = nil
        Task {
            do {
                try await screen.saveDocuments(ofSkill: oldName)
            } catch {
                isRenaming = false
                errorMessage = Banner.message(of: error)
                return
            }
            onStart(newName)
            do {
                let connection = try SkillNameRules.connection(mainDeviceID, in: workspace)
                let renamed = try await connection.renameSkill(name: oldName, to: newName)
                isRenaming = false
                dismiss()
                onRenamed(renamed.name)
            } catch {
                isRenaming = false
                errorMessage = Banner.message(of: error)
                onFailed()
            }
        }
    }
}
