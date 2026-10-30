import HephClient
import SwiftUI

/// The path bar of a compact window, in the navigation bar of the sidebar list (docs/ui/shell.md §7.4): it opens
/// the path picker.
struct CompactPathButton: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context

    var body: some View {
        let path = ShellPath(workspace: workspace, selection: context.selection)
        Button {
            context.sheet = .pathPicker
        } label: {
            HStack(spacing: 4) {
                VStack(spacing: 0) {
                    Text(path.selectedProject?.name ?? "Choose a Project")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        StatusDot(isOnline: path.isMainOnline, size: 6)
                        Text(path.mainName ?? "No Main")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
    }
}
