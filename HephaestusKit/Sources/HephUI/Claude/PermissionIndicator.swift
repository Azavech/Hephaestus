import HephClient
import HephCore
import SwiftUI

/// The toolbar item of every window: the number of permission requests waiting for an answer, and the popover (a
/// sheet in compact width) that lists them (docs/ui/sessions.md, "Toolbar indicator").
public struct PermissionIndicator: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @State private var isListPresented = false

    public init() {}

    public var body: some View {
        let listed = workspace.sessionCenter.pendingPermissions
        let unlisted = PermissionWaiting.unlistedProjects(in: workspace)
        let count = listed.count + unlisted.reduce(0) { $0 + $1.count }
        if count > 0 {
            Button {
                isListPresented = true
            } label: {
                PermissionIndicatorBadge(count: count)
            }
            .accessibilityLabel("Waiting for Permission")
            .popover(isPresented: popoverBinding) {
                PermissionWaitingList(showsTitle: true, onClose: { isListPresented = false })
                    .frame(minWidth: 360, idealWidth: 420, maxHeight: 520)
            }
            .sheet(isPresented: sheetBinding) {
                NavigationStack {
                    PermissionWaitingList(showsTitle: false, onClose: { isListPresented = false })
                        .navigationTitle("Waiting for Permission")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                }
            }
        }
    }

    private var popoverBinding: Binding<Bool> {
        Binding(get: { isListPresented && !context.isCompact }, set: { isListPresented = $0 })
    }

    private var sheetBinding: Binding<Bool> {
        Binding(get: { isListPresented && context.isCompact }, set: { isListPresented = $0 })
    }
}

/// `hand.raised.fill` in orange with the count as a badge at its top trailing corner. The badge lies entirely inside
/// the toolbar item, so the toolbar never clips it: it overlays the symbol's padded frame, with no offset.
private struct PermissionIndicatorBadge: View {
    let count: Int

    var body: some View {
        Image(systemName: "hand.raised.fill")
            .foregroundStyle(.orange)
            .padding(.top, 6)
            .padding(.trailing, 6)
            .overlay(alignment: .topTrailing) {
                Text("\(count)")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Color.red))
                    .fixedSize()
            }
    }
}

/// Requests of a project that were pending when this device connected, in sessions whose `SessionInfo` this device
/// has not received since.
struct PermissionUnlistedProject: Identifiable, Equatable {
    let mainID: UUID
    let projectID: String
    let projectName: String
    let count: Int

    var id: String { "\(mainID.uuidString)/\(projectID)" }
}

/// The counts and the names of the toolbar indicator and the banner.
@MainActor
enum PermissionWaiting {
    /// For each project `P` (sub projects included) of the tree of each connected Main `M`, in path bar order of the
    /// Mains and tree order: `P.pendingPermissionCount` minus the listed requests of `M` and `P`, when positive.
    static func unlistedProjects(in workspace: Workspace) -> [PermissionUnlistedProject] {
        let listed = workspace.sessionCenter.pendingPermissions
        var rows: [PermissionUnlistedProject] = []
        for main in SelectionDefaults.orderedMains(workspace) {
            guard let connection = workspace.connection(main.id), connection.isConnected else { continue }
            var stack = Array(connection.projects.reversed())
            while let project = stack.popLast() {
                let listedCount = listed.filter { $0.mainID == main.id && $0.projectID == project.id }.count
                let count = project.pendingPermissionCount - listedCount
                if count > 0 {
                    rows.append(PermissionUnlistedProject(mainID: main.id, projectID: project.id,
                                                          projectName: project.name, count: count))
                }
                stack.append(contentsOf: project.children.reversed())
            }
        }
        return rows
    }

    /// The project's name in its Main's tree, else its identifier.
    static func projectName(_ pending: PendingPermission, in workspace: Workspace) -> String {
        workspace.summary(of: pending.projectID, on: pending.mainID)?.name ?? pending.projectID
    }

    /// The session's title in the project's store, else "Claude".
    static func sessionTitle(_ pending: PendingPermission, in workspace: Workspace) -> String {
        workspace.projectStore(mainDeviceID: pending.mainID, projectID: pending.projectID)
            .session(pending.sessionID)?.title ?? "Claude"
    }

    /// The summary of the request's tool call.
    static func summary(_ pending: PendingPermission, in workspace: Workspace) -> String {
        let projectRoot = workspace.summary(of: pending.projectID, on: pending.mainID)?.rootPath
        return ToolSummary.summary(toolName: pending.request.toolName, inputJSON: pending.request.input,
                                   projectRoot: projectRoot)
    }

    /// Show: the window shows the session and scrolls to the request's card.
    static func show(_ pending: PendingPermission, workspace: Workspace, context: WindowContext) {
        context.navigate(mainDeviceID: pending.mainID, projectID: pending.projectID, section: .claude,
                         item: pending.sessionID.uuidString)
        workspace.sessionCenter.reveal(mainID: pending.mainID, sessionID: pending.sessionID,
                                       requestID: pending.request.requestID)
    }
}

/// The content of the popover and of the sheet: one row per listed request, oldest first, then one row per project
/// with unlisted requests.
private struct PermissionWaitingList: View {
    /// The popover shows the title above the list; the sheet shows it as its navigation title.
    let showsTitle: Bool
    let onClose: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners

    var body: some View {
        let listed = workspace.sessionCenter.pendingPermissions
        let unlisted = PermissionWaiting.unlistedProjects(in: workspace)
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                Text("Waiting for Permission")
                    .font(.headline)
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 8)
            }
            List {
                ForEach(listed) { pending in
                    requestRow(pending)
                }
                ForEach(unlisted) { project in
                    projectRow(project)
                }
            }
        }
    }

    private func requestRow(_ pending: PendingPermission) -> some View {
        let summary = PermissionWaiting.summary(pending, in: workspace)
        let mainName = ClaudeNames.mainName(pending.mainID, in: workspace)
        let projectName = PermissionWaiting.projectName(pending, in: workspace)
        let sessionTitle = PermissionWaiting.sessionTitle(pending, in: workspace)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: ToolSummary.symbolName(toolName: pending.request.toolName))
                Text(ToolSummary.displayName(toolName: pending.request.toolName))
                    .bold()
                if !summary.isEmpty {
                    Text(summary)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Text("\(mainName) ▸ \(projectName) ▸ \(sessionTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                Button("Allow Once") {
                    respond(pending, decision: .allow)
                }
                Button("Deny") {
                    respond(pending, decision: .deny)
                }
                Spacer()
                Button("Show") {
                    onClose()
                    PermissionWaiting.show(pending, workspace: workspace, context: context)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func projectRow(_ project: PermissionUnlistedProject) -> some View {
        HStack(spacing: 8) {
            Text(project.count == 1
                 ? "1 request in \(project.projectName)"
                 : "\(project.count) requests in \(project.projectName)")
            Spacer()
            Button("Show") {
                onClose()
                context.navigate(mainDeviceID: project.mainID, projectID: project.projectID, section: .claude,
                                 item: nil)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private func respond(_ pending: PendingPermission, decision: PermissionDecision) {
        let center: SessionCenter = workspace.sessionCenter
        Task {
            await banners.perform {
                try await center.respond(to: pending, decision: decision, message: nil)
            }
        }
    }
}
