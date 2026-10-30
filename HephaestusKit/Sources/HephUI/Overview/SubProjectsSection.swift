import HephClient
import HephCore
import SwiftUI

/// The Sub Projects section of the Overview (docs/ui/overview.md, "Sub projects"): one row per direct sub project, in
/// the order of `children`, then "New Sub Project…".
struct SubProjectsSection: View {
    let store: ProjectStore
    let project: Project
    let isNewSubProjectDisabled: Bool

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @State private var isNewSubProjectPresented = false

    var body: some View {
        let children = workspace.summary(of: store.projectID, on: store.mainDeviceID)?.children ?? []
        Section("Sub Projects") {
            if children.isEmpty {
                Text("No sub projects")
                    .foregroundStyle(.secondary)
            }
            ForEach(children) { child in
                row(child)
            }
            Button("New Sub Project…") {
                isNewSubProjectPresented = true
            }
            .disabled(isNewSubProjectDisabled)
            .sheet(isPresented: $isNewSubProjectPresented) {
                NewProjectSheet(mainDeviceID: store.mainDeviceID, parentID: store.projectID)
            }
        }
    }

    /// The name, the identifier (monospaced, secondary) and the folder relative to this project's root (secondary).
    /// Choosing the row selects the sub project in the window.
    private func row(_ child: ProjectSummary) -> some View {
        Button {
            context.navigate(mainDeviceID: nil, projectID: child.id, section: .overview, item: nil)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(child.name)
                    Text(child.id)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(relativeFolder(of: child))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The sub project's root relative to this project's `rootPath`; the absolute path when it is not inside it.
    private func relativeFolder(of child: ProjectSummary) -> String {
        let base = project.rootPath.hasSuffix("/") ? project.rootPath : project.rootPath + "/"
        guard child.rootPath.hasPrefix(base) else { return child.rootPath }
        return String(child.rootPath.dropFirst(base.count))
    }
}
