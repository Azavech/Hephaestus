import HephClient
import SwiftUI

/// The sidebar (docs/ui/shell.md §6.2): the project sections of the selected project, then the workspace sections.
/// In compact width it is the root of the navigation stack and carries the shell toolbar.
struct SidebarView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context

    var body: some View {
        let hasProject = context.selection.projectID != nil
        List(selection: sectionBinding) {
            Section(projectName ?? "Project") {
                ForEach(SidebarSection.projectSections, id: \.self) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                        .disabled(!hasProject)
                        .selectionDisabled(!hasProject)
                }
            }
            Section("Workspace") {
                ForEach(SidebarSection.workspaceSections, id: \.self) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        #if os(iOS)
        .navigationTitle(context.isCompact ? projectName ?? "Hephaestus" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if context.isCompact {
                ShellToolbar(isCompact: true)
            }
        }
        #endif
    }

    /// The selected project's name; nil when no project is selected or it is not in its Main's tree.
    private var projectName: String? {
        guard let mainDeviceID = context.selection.mainDeviceID, let projectID = context.selection.projectID else {
            return nil
        }
        return workspace.summary(of: projectID, on: mainDeviceID)?.name
    }

    /// Reads `selection.section`; a section goes through `context.select(_:)`, nil (compact Back) clears it.
    private var sectionBinding: Binding<SidebarSection?> {
        Binding(
            get: { context.selection.section },
            set: { section in
                if let section {
                    context.select(section)
                } else {
                    context.selection.section = nil
                }
            }
        )
    }
}
