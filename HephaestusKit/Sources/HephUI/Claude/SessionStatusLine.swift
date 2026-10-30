import HephClient
import HephCore
import SwiftUI

/// The line between the transcript and the composer: the Main's connection and the session's status, one line high;
/// the failed details expand it (docs/ui/sessions.md, "Status line").
struct SessionStatusLine: View {
    let model: SessionModel
    let store: ProjectStore
    /// Review: scrolls to the first pending permission card.
    let onReview: () -> Void

    @Environment(Workspace.self) private var workspace
    @State private var isDetailsExpanded = false
    @State private var detailsHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var detailsLineHeight: CGFloat = Self.baseLineHeight

    /// The line height of the monospaced body font, at the default size.
    #if os(macOS)
    private static let baseLineHeight: CGFloat = 16
    #else
    private static let baseLineHeight: CGFloat = 22
    #endif
    /// The failure details show at most this many lines, then scroll.
    private static let maximumDetailLines: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                line
            }
            .lineLimit(1)
            if isDetailsExpanded, store.connection?.isConnected == true, let info = model.info,
               info.status == .failed, let error = info.error {
                ScrollView {
                    Text(error)
                        .font(.body.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            detailsHeight = height
                        }
                }
                .frame(height: min(max(detailsHeight, 1), detailsLineHeight * Self.maximumDetailLines))
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var line: some View {
        if store.connection?.isConnected != true {
            SessionStatusDot(color: .gray)
            Text("\(ClaudeNames.mainName(store.mainDeviceID, in: workspace)) is offline")
        } else if let info = model.info {
            switch info.status {
            case .idle:
                SessionStatusDot(color: .green)
                Text("Idle")
            case .starting:
                ProgressView()
                    .controlSize(.small)
                Text("Starting Claude…")
            case .running:
                ProgressView()
                    .controlSize(.small)
                if let statusLine = info.statusLine {
                    Text("Running — \(statusLine)")
                        .truncationMode(.tail)
                } else {
                    Text("Running")
                }
            case .waitingPermission:
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("Waiting for permission")
                Button("Review", action: onReview)
                    .buttonStyle(.borderless)
            case .stopped:
                SessionStatusDot(color: .gray)
                Text("Stopped. Sending a message restarts Claude.")
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text("Failed")
                if info.error != nil {
                    Button {
                        isDetailsExpanded.toggle()
                    } label: {
                        HStack(spacing: 2) {
                            Text("Details")
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .rotationEffect(.degrees(isDetailsExpanded ? 90 : 0))
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}
