import HephClient
import HephCore
import SwiftUI

/// Creates a skill from a name and a description; the Main writes `SKILL.md` from its template (docs/ui/skills.md,
/// "New skill").
struct NewSkillSheet: View {
    let mainDeviceID: UUID
    /// The names of the skills of the list.
    let existingNames: Set<String>
    /// Called after a successful creation with the new skill's name.
    let onCreated: (String) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    /// The longest description, in characters after trimming.
    static let maximumDescriptionLength = 1024

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDescriptionTooLong: Bool {
        trimmedDescription.count > Self.maximumDescriptionLength
    }

    private var isValid: Bool {
        SkillNameRules.isAcceptable(name, existingNames: existingNames)
            && !trimmedDescription.isEmpty && !isDescriptionTooLong
    }

    var body: some View {
        EditSheetLayout(confirmTitle: "Create", isConfirmEnabled: isValid && !isCreating, errorMessage: errorMessage,
                        onCancel: { dismiss() }, onConfirm: create) {
            TextField("Name", text: SkillNameRules.lowercasing($name))
                .font(.body.monospaced())
                .autocorrectionDisabled()
            SkillNameRules.message(for: name, existingNames: existingNames)
            TextField("Description", text: $description, axis: .vertical)
                .lineLimit(1...4)
            if isDescriptionTooLong {
                Text("Use at most 1,024 characters.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// `createSkill(name:description:)` with the trimmed description. Success: the sheet dismisses itself. Failure:
    /// the message shows; the sheet stays open.
    private func create() {
        guard isValid, !isCreating else { return }
        let name = name
        let description = trimmedDescription
        let workspace = workspace
        let mainDeviceID = mainDeviceID
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let connection = try SkillNameRules.connection(mainDeviceID, in: workspace)
                _ = try await connection.createSkill(name: name, description: description)
                isCreating = false
                dismiss()
                onCreated(name)
            } catch {
                isCreating = false
                errorMessage = Banner.message(of: error)
            }
        }
    }
}

/// The rules and messages of skill names, shared by the New Skill and Rename sheets.
enum SkillNameRules {
    /// `SkillName.isValid` and not the name of another skill of the list.
    static func isAcceptable(_ name: String, existingNames: Set<String>) -> Bool {
        SkillName.isValid(name) && !existingNames.contains(name)
    }

    /// Under the name: the rule when it is broken, the existing skill, or how Claude sees a valid name.
    @ViewBuilder
    static func message(for name: String, existingNames: Set<String>) -> some View {
        if !name.isEmpty && !SkillName.isValid(name) {
            Text("Use lowercase letters, digits and hyphens (1 to 64 characters).")
                .font(.caption)
                .foregroundStyle(.red)
        } else if existingNames.contains(name) {
            Text("A skill named “\(name)” already exists.")
                .font(.caption)
                .foregroundStyle(.red)
        } else if SkillName.isValid(name) {
            Text("Claude sees it as hephaestus:\(name).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Letters `A`–`Z` are lowercased as they are typed.
    static func lowercasing(_ name: Binding<String>) -> Binding<String> {
        Binding(
            get: { name.wrappedValue },
            set: { typed in
                name.wrappedValue = String(String.UnicodeScalarView(typed.unicodeScalars.map { scalar in
                    ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
                }))
            }
        )
    }

    /// The connection of the Main whose library the screen shows.
    @MainActor
    static func connection(_ mainDeviceID: UUID, in workspace: Workspace) throws -> MainConnection {
        guard let connection = workspace.connection(mainDeviceID) else {
            throw ProtocolError(.unavailable, "\(ClaudeNames.mainName(mainDeviceID, in: workspace)) is offline.")
        }
        return connection
    }
}
