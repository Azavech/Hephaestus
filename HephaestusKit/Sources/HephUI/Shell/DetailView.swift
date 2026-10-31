import Foundation
import HephClient
import HephCore
import SwiftUI

/// The detail of a window (docs/ui/shell.md §6.3): the view of the selected section, or the first state that
/// applies. In regular width it carries the shell toolbar.
struct DetailView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context

    var body: some View {
        content
            .navigationTitle(windowTitle)
            #if os(macOS)
            .toolbar(removing: .title)
            // The toolbar keeps its material over the detail in every section and state; the content extends under
            // it (§9.2).
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbarBackground(.bar, for: .windowToolbar)
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !context.isCompact {
                    ShellToolbar(isCompact: false)
                }
            }
    }

    /// The selected project's name, else "Hephaestus".
    private var windowTitle: String {
        guard let mainDeviceID = context.selection.mainDeviceID, let projectID = context.selection.projectID,
              let summary = workspace.summary(of: projectID, on: mainDeviceID) else {
            return "Hephaestus"
        }
        return summary.name
    }

    @ViewBuilder
    private var content: some View {
        let selection = context.selection
        if let section = selection.section {
            if section.isProjectSection {
                if let mainDeviceID = selection.mainDeviceID {
                    projectSectionContent(section, mainDeviceID: mainDeviceID)
                } else {
                    noMainSelected
                }
            } else {
                switch section {
                case .skills:
                    if let mainDeviceID = selection.mainDeviceID {
                        SkillsView(mainDeviceID: mainDeviceID)
                    } else {
                        noMainSelected
                    }
                case .devices:
                    DevicesView()
                case .forge:
                    ForgeView()
                case .overview, .tickets, .code, .docs, .web, .claude:
                    EmptyView()
                }
            }
        } else {
            EmptyStateView(symbol: "sidebar.left", title: "Select a section")
        }
    }

    private var noMainSelected: some View {
        EmptyStateView(symbol: "desktopcomputer", title: "No Main selected", message: "Choose a Main in the path bar.")
    }

    /// The first row of the table of §6.3 that applies to a project section on the Main `mainDeviceID`.
    @ViewBuilder
    private func projectSectionContent(_ section: SidebarSection, mainDeviceID: UUID) -> some View {
        let connection = workspace.connection(mainDeviceID)
        let isConnected = connection?.isConnected == true
        let mainName = SelectionDefaults.mainName(mainDeviceID, workspace: workspace)
        let projectID = context.selection.projectID
        let store = projectID.flatMap { projectID in
            workspace.summary(of: projectID, on: mainDeviceID) == nil
                ? nil
                : workspace.projectStore(mainDeviceID: mainDeviceID, projectID: projectID)
        }
        if let projectID, let store, store.project != nil {
            sectionView(section, store: store)
                .id("\(mainDeviceID.uuidString)/\(projectID)")
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !isConnected {
                        OfflineBar(mainName: mainName, lastSeen: workspace.presence[mainDeviceID]?.lastSeen)
                    }
                }
        } else if !isConnected {
            TimelineView(.everyMinute) { timeline in
                EmptyStateView(
                    symbol: "desktopcomputer",
                    title: "\(mainName) is offline",
                    message: PresenceFormat.lastSeen(workspace.presence[mainDeviceID]?.lastSeen, now: timeline.date)
                        + ". Choose another Main in the path bar."
                )
            }
        } else if connection?.projectsLoaded != true {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let projectID {
            if let store {
                if case .failed(let message) = store.phase {
                    EmptyStateView(symbol: "exclamationmark.triangle", title: "Could not load \(projectID)",
                                   message: message) {
                        Button("Retry") {
                            Task {
                                await store.reload()
                            }
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                EmptyStateView(symbol: "questionmark.folder", title: "\(projectID) is not on \(mainName)")
            }
        } else {
            EmptyStateView(symbol: "folder", title: "No projects on \(mainName)",
                           message: "Create a project or add an existing folder.") {
                Button("New Project…") {
                    context.sheet = .newProject(mainDeviceID: mainDeviceID)
                }
                Button("Add Existing Folder…") {
                    context.sheet = .addExistingFolder(mainDeviceID: mainDeviceID)
                }
            }
        }
    }

    /// The view of a project section (§4).
    @ViewBuilder
    private func sectionView(_ section: SidebarSection, store: ProjectStore) -> some View {
        switch section {
        case .overview:
            OverviewView(store: store)
        case .tickets:
            TicketsView(store: store)
        case .code:
            CodeView(store: store)
        case .docs:
            DocsView(store: store)
        case .web:
            WebTabsView(store: store)
        case .claude:
            ClaudeView(store: store)
        case .devices, .skills, .forge:
            EmptyView()
        }
    }
}

/// The bar above a project section's view while its Main is not connected (§6.3, Offline bar).
private struct OfflineBar: View {
    let mainName: String
    let lastSeen: Date?

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            HStack(spacing: 6) {
                StatusDot(isOnline: false)
                Text("\(mainName) is offline — \(PresenceFormat.lastSeen(lastSeen, now: timeline.date)). "
                     + "Changes are disabled until it reconnects.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}
