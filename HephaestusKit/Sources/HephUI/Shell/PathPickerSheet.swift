import HephClient
import SwiftUI

/// The Main and project picker of a compact window (docs/ui/shell.md §7.4). Choices apply at once with the rules of
/// the path bar.
struct PathPickerSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let path = ShellPath(workspace: workspace, selection: context.selection)
        NavigationStack {
            Form {
                Section("Main") {
                    Picker("Main", selection: path.mainBinding) {
                        ForEach(path.mains) { record in
                            HStack {
                                Text(record.name)
                                Spacer()
                                PresenceLabel(isOnline: path.isOnline(record), lastSeen: path.lastSeen(record))
                            }
                            .tag(Optional(record.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let mainDeviceID = path.mainDeviceID {
                    projectSection(path, mainDeviceID: mainDeviceID)
                    ForEach(path.subProjectSegments) { segment in
                        Section("Sub Project") {
                            Picker("Sub Project", selection: path.binding(for: segment)) {
                                Text("None")
                                    .tag(segment.parent.id)
                                ForEach(segment.options) { child in
                                    Text("\(child.name) — \(child.id)")
                                        .tag(child.id)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                }
            }
            .navigationTitle("Main and Project")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func projectSection(_ path: ShellPath, mainDeviceID: UUID) -> some View {
        Section("Project") {
            if path.projectsAvailable {
                Picker("Project", selection: path.topLevelBinding) {
                    ForEach(path.topLevelProjects) { project in
                        Text("\(project.name) — \(project.id)")
                            .tag(Optional(project.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } else {
                Text(path.unavailableText)
                    .foregroundStyle(.secondary)
            }
            Button("New Project…") {
                context.sheet = .newProject(mainDeviceID: mainDeviceID)
            }
            .disabled(!path.projectsAvailable)
            Button("Add Existing Folder…") {
                context.sheet = .addExistingFolder(mainDeviceID: mainDeviceID)
            }
            .disabled(!path.projectsAvailable)
        }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    PathPickerSheet()
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
