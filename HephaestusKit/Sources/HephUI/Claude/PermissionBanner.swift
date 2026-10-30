import HephClient
import HephCore
import SwiftUI

extension View {
    /// The permission banner of a window, applied by the shell to every window's root view (docs/ui/sessions.md,
    /// "Banner"): while `sessionCenter.bannerPermission` is set and the window is active, a banner at the top center.
    public func permissionBanner() -> some View {
        modifier(PermissionBannerModifier())
    }
}

private struct PermissionBannerModifier: ViewModifier {
    @Environment(Workspace.self) private var workspace
    #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
    #else
    @Environment(\.scenePhase) private var scenePhase
    #endif

    /// macOS: the key window; iOS and iPadOS: the scene phase is `.active`.
    private var isWindowActive: Bool {
        #if os(macOS)
        appearsActive
        #else
        scenePhase == .active
        #endif
    }

    func body(content: Content) -> some View {
        let pending = isWindowActive ? workspace.sessionCenter.bannerPermission : nil
        content
            .overlay(alignment: .top) {
                if let pending {
                    PermissionBannerView(pending: pending)
                        .padding(.top, 12)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: pending?.id)
    }
}

/// The banner of one request: the request, Show and close. It goes away after 10 s, on close, on Show, or when the
/// request leaves `pendingPermissions`.
private struct PermissionBannerView: View {
    let pending: PendingPermission

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context

    /// How long the banner stays.
    private static let duration: Duration = .seconds(10)

    var body: some View {
        let projectName = PermissionWaiting.projectName(pending, in: workspace)
        let sessionTitle = PermissionWaiting.sessionTitle(pending, in: workspace)
        let summary = PermissionWaiting.summary(pending, in: workspace)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude wants to use \(ToolSummary.displayName(toolName: pending.request.toolName))")
                    .font(.headline)
                    .lineLimit(1)
                Text(summary.isEmpty
                     ? "\(projectName) ▸ \(sessionTitle)"
                     : "\(projectName) ▸ \(sessionTitle) · \(summary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button("Show") {
                let center: SessionCenter = workspace.sessionCenter
                PermissionWaiting.show(pending, workspace: workspace, context: context)
                center.dismissBanner()
            }
            Button {
                workspace.sessionCenter.dismissBanner()
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .task(id: pending.id) {
            do {
                try await Task.sleep(for: Self.duration)
            } catch {
                return
            }
            let center: SessionCenter = workspace.sessionCenter
            if center.bannerPermission?.id == pending.id {
                center.dismissBanner()
            }
        }
    }
}
