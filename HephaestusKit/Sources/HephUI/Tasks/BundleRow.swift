import HephClient
import HephCore
import SwiftUI

/// A row of the Bundles section of the task list (docs/ui/tasks.md, "Bundle row"): the id, the activity indicators and
/// the status badge, then the name and the count of done tasks; a context menu with Work on Bundle or Stop, Copy ID and
/// Delete….
struct BundleRow: View {
    let store: ProjectStore
    let bundle: BundleItem
    /// Asks for the delete confirmation of this bundle.
    let onDelete: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(bundle.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                indicators
                    .font(.caption)
                BundleStatusBadge(status: bundle.status)
            }
            Text(bundle.name)
                .font(.body)
                .lineLimit(2)
            Text(verbatim: "\(doneCount) of \(bundle.tasks.count) done")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            contextMenuItems
        }
    }

    /// The tasks of the bundle whose status is `done`.
    private var doneCount: Int {
        bundle.tasks.filter { store.task($0.taskID)?.status == .done }.count
    }

    /// From the coordinator and the task sessions of the bundle: `sparkles` when one is starting or running,
    /// `hand.raised.fill` when one waits for a permission.
    @ViewBuilder
    private var indicators: some View {
        let sessions = BundleScreen.sessions(of: bundle, in: store)
        if sessions.contains(where: { $0.status == .starting || $0.status == .running }) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
        }
        if sessions.contains(where: { $0.status == .waitingPermission }) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        let isConnected = TasksScreen.isConnected(store)
        switch bundle.status {
        case .draft:
            Button("Work on Bundle") {
                BundleScreen.start(bundle, store: store, workspace: workspace, banners: banners)
            }
            .disabled(!isConnected)
        case .running, .review:
            Button("Stop") {
                BundleScreen.stop(bundle, store: store, workspace: workspace, banners: banners)
            }
            .disabled(!isConnected)
        case .done:
            EmptyView()
        }
        Button("Copy ID") {
            TasksScreen.copy(bundle.id)
        }
        if BundleScreen.isEditable(bundle) {
            Button("Delete…", role: .destructive, action: onDelete)
                .disabled(!isConnected)
        }
    }
}

/// The same capsule as `TaskStatusBadge` for a bundle status (docs/ui/tasks.md, "Status style").
///
/// | `BundleStatus` | Symbol                  | Tint   |
/// |----------------|-------------------------|--------|
/// | `draft`        | `square.dashed`         | gray   |
/// | `running`      | `sparkles`              | blue   |
/// | `review`       | `eye.circle`            | orange |
/// | `done`         | `checkmark.circle.fill` | green  |
public struct BundleStatusBadge: View {
    private let status: BundleStatus

    public init(status: BundleStatus) {
        self.status = status
    }

    public var body: some View {
        let tint = self.tint
        Label(status.displayName, systemImage: symbolName)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .fixedSize()
    }

    private var symbolName: String {
        switch status {
        case .draft:
            return "square.dashed"
        case .running:
            return "sparkles"
        case .review:
            return "eye.circle"
        case .done:
            return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .draft:
            return .gray
        case .running:
            return .blue
        case .review:
            return .orange
        case .done:
            return .green
        }
    }
}
