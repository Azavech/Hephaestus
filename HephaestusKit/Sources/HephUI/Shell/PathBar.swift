import Foundation
import HephClient
import HephCore
import SwiftUI

/// The path bar of a regular window: `{Main} ▸ {project} ▸ {sub project}`, like Xcode's jump bar
/// (docs/ui/shell.md §7).
struct PathBar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context

    var body: some View {
        let path = ShellPath(workspace: workspace, selection: context.selection)
        HStack(spacing: 4) {
            mainSegment(path)
            if let mainDeviceID = path.mainDeviceID {
                separator
                projectSegment(path, mainDeviceID: mainDeviceID)
                ForEach(path.subProjectSegments) { segment in
                    separator
                    subProjectSegment(segment, path: path)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Main segment (§7.1)

    private func mainSegment(_ path: ShellPath) -> some View {
        Menu {
            Picker("Main", selection: path.mainBinding) {
                ForEach(path.mains) { record in
                    MainMenuItem(name: record.name, isOnline: path.isOnline(record), lastSeen: path.lastSeen(record))
                        .tag(Optional(record.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            PathSegmentLabel(title: path.mainName ?? "No Main", isPlaceholder: path.mainDeviceID == nil) {
                StatusDot(isOnline: path.isMainOnline)
            }
        }
        .modifier(PathSegmentStyle())
    }

    // MARK: - Project segment (§7.2)

    private func projectSegment(_ path: ShellPath, mainDeviceID: UUID) -> some View {
        Menu {
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
                Button(path.unavailableText) {}
                    .disabled(true)
            }
            Divider()
            Button("New Project…") {
                context.sheet = .newProject(mainDeviceID: mainDeviceID)
            }
            .disabled(!path.projectsAvailable)
            Button("Add Existing Folder…") {
                context.sheet = .addExistingFolder(mainDeviceID: mainDeviceID)
            }
            .disabled(!path.projectsAvailable)
        } label: {
            PathSegmentLabel(title: path.topLevelProject?.name ?? "No Project",
                             isPlaceholder: path.topLevelProject == nil) {
                Image(systemName: "folder")
            }
        }
        .modifier(PathSegmentStyle())
    }

    // MARK: - Sub project segments (§7.3)

    private func subProjectSegment(_ segment: ShellPath.SubProjectSegment, path: ShellPath) -> some View {
        Menu {
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
        } label: {
            PathSegmentLabel(title: segment.selected?.name ?? "None", isPlaceholder: segment.selected == nil) {
                Image(systemName: "folder")
            }
        }
        .modifier(PathSegmentStyle())
    }
}

/// The Main and the project chain of a window's selection, as the path bar, the compact path button and the path
/// picker show them, and the choices they make (§7).
@MainActor
struct ShellPath {
    /// A segment after the project segment: a sub project of the chain, or the last "None" segment.
    struct SubProjectSegment: Identifiable {
        /// The project whose children the segment lists; "None" selects it.
        let parent: ProjectSummary
        /// The selected child; nil for the last segment, shown when the selected project has children.
        let selected: ProjectSummary?

        var id: String { parent.id }
        /// The children of `parent`, sorted by name.
        var options: [ProjectSummary] { SelectionDefaults.sortedByName(parent.children) }
        /// The id the segment's picker shows as chosen: the selected child, else `parent` ("None").
        var selectedID: String { selected?.id ?? parent.id }
    }

    let workspace: Workspace
    let selection: Selection
    /// The Mains in path bar order.
    let mains: [DeviceRecord]
    /// The summaries from the top-level project down to the selected project; empty when it is not in the tree.
    let chain: [ProjectSummary]

    init(workspace: Workspace, selection: Selection) {
        self.workspace = workspace
        self.selection = selection
        mains = SelectionDefaults.orderedMains(workspace)
        if let mainDeviceID = selection.mainDeviceID, let projectID = selection.projectID,
           let ids = workspace.projectPath(of: projectID, on: mainDeviceID) {
            chain = ids.compactMap { workspace.summary(of: $0, on: mainDeviceID) }
        } else {
            chain = []
        }
    }

    var mainDeviceID: UUID? { selection.mainDeviceID }

    /// The selected Main's connection.
    var connection: MainConnection? {
        mainDeviceID.flatMap { workspace.connection($0) }
    }

    /// The selected Main's name; nil when no Main is selected.
    var mainName: String? {
        mainDeviceID.map { SelectionDefaults.mainName($0, workspace: workspace) }
    }

    var isMainOnline: Bool { connection?.isConnected == true }

    /// The selected Main's connection is connected with its projects loaded.
    var projectsAvailable: Bool {
        guard let connection else { return false }
        return connection.isConnected && connection.projectsLoaded
    }

    /// The disabled item of the project menu when its projects are not available.
    var unavailableText: String {
        isMainOnline ? "Loading…" : "\(mainName ?? "Main") is offline"
    }

    /// The selected Main's top-level projects, sorted by name.
    var topLevelProjects: [ProjectSummary] {
        SelectionDefaults.sortedByName(connection?.projects ?? [])
    }

    /// The top-level project of the chain.
    var topLevelProject: ProjectSummary? { chain.first }

    /// The selected project or sub project.
    var selectedProject: ProjectSummary? { chain.last }

    /// One segment per sub project of the chain, then a "None" segment when the selected project has children.
    var subProjectSegments: [SubProjectSegment] {
        var segments: [SubProjectSegment] = []
        for index in chain.indices.dropFirst() {
            segments.append(SubProjectSegment(parent: chain[index - 1], selected: chain[index]))
        }
        if let last = chain.last, !last.children.isEmpty {
            segments.append(SubProjectSegment(parent: last, selected: nil))
        }
        return segments
    }

    func isOnline(_ record: DeviceRecord) -> Bool {
        SelectionDefaults.isOnline(record.id, workspace: workspace)
    }

    func lastSeen(_ record: DeviceRecord) -> Date? {
        workspace.presence[record.id]?.lastSeen
    }

    /// Choosing another Main selects it with no project and no item (§7.1).
    func chooseMain(_ mainDeviceID: UUID) {
        guard mainDeviceID != selection.mainDeviceID else { return }
        selection.mainDeviceID = mainDeviceID
        selection.projectID = nil
        selection.item = nil
    }

    /// Choosing another project or sub project selects it with no item; the section is kept (§7.2, §7.3).
    func chooseProject(_ projectID: String) {
        guard projectID != selection.projectID else { return }
        selection.projectID = projectID
        selection.item = nil
    }

    var mainBinding: Binding<UUID?> {
        Binding(
            get: { selection.mainDeviceID },
            set: { mainDeviceID in
                if let mainDeviceID {
                    chooseMain(mainDeviceID)
                }
            }
        )
    }

    var topLevelBinding: Binding<String?> {
        Binding(
            get: { chain.first?.id },
            set: { projectID in
                if let projectID {
                    chooseProject(projectID)
                }
            }
        )
    }

    func binding(for segment: SubProjectSegment) -> Binding<String> {
        Binding(
            get: { segment.selectedID },
            set: { projectID in
                chooseProject(projectID)
            }
        )
    }
}

/// A Main in the Main menu: menus draw symbols in one color, so the state is the symbol's shape (§7.1).
private struct MainMenuItem: View {
    let name: String
    let isOnline: Bool
    let lastSeen: Date?

    var body: some View {
        if isOnline {
            Label(name, systemImage: "circle.fill")
        } else {
            Label("\(name) — \(PresenceFormat.lastSeen(lastSeen))", systemImage: "circle")
        }
    }
}

/// The label of a segment: an icon and a one-line title, middle truncation, at most 220 pt wide.
private struct PathSegmentLabel<Icon: View>: View {
    let title: String
    let isPlaceholder: Bool
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
        }
    }
}

/// The style of a segment's menu.
private struct PathSegmentStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
