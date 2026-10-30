import HephClient
import HephCore
import SwiftUI

/// The Claude section of the Overview (docs/ui/overview.md, "Claude defaults"): the project's permission mode and model,
/// sent together as `ClaudeDefaults(model:permissionMode:)`, which replaces the whole `claude` block. A nil field means
/// the Main's default setting; an empty model is sent as nil.
struct OverviewClaudeSection: View {
    let store: ProjectStore
    let project: Project
    let isDisabled: Bool

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    @State private var modelText = ""
    /// The defaults sent, shown until the stored block changes; nil when the request failed.
    @State private var sent: (base: ClaudeDefaults, value: ClaudeDefaults)?

    var body: some View {
        Section("Claude") {
            LabeledContent("Permission Mode") {
                PermissionModePicker(selection: permissionModeBinding, defaultLabel: "Main Default")
            }
            LabeledContent("Model") {
                ClaudeModelField(model: $modelText, placeholder: "Main Default", onCommit: commitModel)
            }
            .onAppear {
                modelText = project.claude.model ?? ""
            }
            .onChange(of: project.claude.model) { oldModel, newModel in
                // An incoming change does not replace text being edited.
                if modelText == (oldModel ?? "") {
                    modelText = newModel ?? ""
                }
            }
        }
        .disabled(isDisabled)
    }

    /// The defaults shown: the ones sent while the stored block has not changed since, else the stored ones.
    private var displayed: ClaudeDefaults {
        if let sent, sent.base == project.claude {
            return sent.value
        }
        return project.claude
    }

    /// A picker change sends the new mode with the current model.
    private var permissionModeBinding: Binding<PermissionMode?> {
        Binding(
            get: { displayed.permissionMode },
            set: { mode in
                send(ClaudeDefaults(model: displayed.model, permissionMode: mode))
            }
        )
    }

    /// Return, focus loss or a menu choice: sends the trimmed model (nil when empty) with the current mode.
    private func commitModel() {
        let text = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        modelText = text
        send(ClaudeDefaults(model: text.isEmpty ? nil : text, permissionMode: displayed.permissionMode))
    }

    /// `ProjectPatch(claude:)`. A value equal to the shown one sends nothing; a failure returns the field and the picker
    /// to the stored values.
    private func send(_ defaults: ClaudeDefaults) {
        guard defaults != displayed else { return }
        sent = (base: project.claude, value: defaults)
        let projectID = store.projectID
        Task {
            let succeeded = await banners.perform {
                let connection = try OverviewScreen.connection(store.mainDeviceID, workspace: workspace)
                _ = try await connection.updateProject(projectID: projectID, patch: ProjectPatch(claude: defaults))
            }
            if !succeeded, sent?.value == defaults {
                sent = nil
                modelText = store.project?.claude.model ?? ""
            }
        }
    }
}
