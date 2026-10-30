import HephClient
import HephCore
import HephMarkdown
import SwiftUI

/// The rendering of one transcript item (docs/ui/sessions.md, "Transcript").
struct TranscriptRow: View {
    let item: TranscriptItem
    let model: SessionModel
    let store: ProjectStore

    var body: some View {
        switch item {
        case .user(let message):
            TranscriptUserMessage(message: message, store: store, sessionID: model.sessionID)
        case .assistant(let text):
            TranscriptAssistantText(text: text.text, store: store)
        case .thinking(let text):
            TranscriptDisclosure(symbol: "brain", title: "Thinking") {
                Text(text.text)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .tool(let tool):
            ToolUseRow(tool: tool, isSessionActive: isSessionActive, projectRoot: store.project?.rootPath)
        case .permission(let permission):
            PermissionCard(item: permission, model: model, projectRoot: store.project?.rootPath)
        case .turnEnd(let turnEnd):
            TranscriptTurnEnd(item: turnEnd)
        case .system(let text):
            Text(text.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        case .error(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(text.text)
                    .textSelection(.enabled)
            }
            .foregroundStyle(.red)
        case .streaming(let streaming):
            switch streaming.kind {
            case .text:
                TranscriptAssistantText(text: streaming.text, store: store)
            case .thinking:
                TranscriptDisclosure(symbol: "brain", title: "Thinking…") {
                    Text(streaming.text)
                        .foregroundStyle(.secondary)
                }
            case .toolInput:
                TranscriptDisclosure(symbol: "wrench.and.screwdriver", title: "Preparing a tool call…") {
                    Text(streaming.text)
                        .font(.callout.monospaced())
                }
            }
        }
    }

    /// Tool rows without a result show a progress view while the session is `running` or `waitingPermission`.
    private var isSessionActive: Bool {
        switch model.info?.status {
        case .running, .waitingPermission: return true
        default: return false
        }
    }
}

/// `.user`: a trailing bubble with the text and the attachments, and the caption "<device name> · <time>" under it.
private struct TranscriptUserMessage: View {
    let message: UserMessageItem
    let store: ProjectStore
    let sessionID: UUID

    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TranscriptBubbleLayout(fraction: 0.85) {
                VStack(alignment: .leading, spacing: 8) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .textSelection(.enabled)
                    }
                    if !message.attachments.isEmpty {
                        TranscriptFlowLayout(spacing: 8) {
                            ForEach(message.attachments) { attachment in
                                attachmentView(attachment)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.15)))
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// "<device name> · <time>", the device name omitted when unknown.
    private var caption: String {
        let time = message.at.formatted(date: .omitted, time: .shortened)
        guard let device = ClaudeNames.deviceName(message.deviceID, in: workspace) else { return time }
        return "\(device) · \(time)"
    }

    private func attachmentView(_ attachment: TaskAttachment) -> some View {
        let store = store
        let workspace = workspace
        let sessionID = sessionID
        return AttachmentView(
            fileName: attachment.file,
            mimeType: attachment.type,
            size: attachment.size,
            cacheKey: "\(store.projectID)/sessions/\(sessionID.uuidString)/\(attachment.file)",
            download: { progress in
                let connection = try ClaudeNames.connection(of: store, in: workspace)
                return try await connection.downloadSessionAttachment(projectID: store.projectID, sessionID: sessionID,
                                                                      fileName: attachment.file,
                                                                      size: attachment.size, progress: progress)
            }
        )
    }
}

/// `.assistant` and streamed text: leading, full width, Markdown with the link rules of the task descriptions: an
/// http(s) link opens a new web tab in the project, which the window then shows.
private struct TranscriptAssistantText: View {
    let text: String
    let store: ProjectStore

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    @Environment(\.openURL) private var openURL

    var body: some View {
        MarkdownView(text, linkHandler: openLink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openLink(_ target: MarkdownLinkTarget) {
        guard case .external(let url) = target else { return }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            openURL(url)
            return
        }
        let store = store
        let workspace = workspace
        let context = context
        Task {
            await banners.perform {
                let connection = try ClaudeNames.connection(of: store, in: workspace)
                let tab = try await connection.openTab(projectID: store.projectID, url: url.absoluteString,
                                                       title: nil, locked: nil)
                context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .web,
                                 item: tab.id.uuidString)
            }
        }
    }
}

/// `.turnEnd`: a centered caption between two hairlines; nothing for an interrupted turn.
private struct TranscriptTurnEnd: View {
    let item: TurnEndItem

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let caption = TranscriptTurnEndCaption.caption(item) {
            HStack(spacing: 8) {
                hairline
                Text(caption.text)
                    .font(.caption)
                    .foregroundStyle(caption.isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .layoutPriority(1)
                hairline
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1 / max(displayScale, 1))
    }
}

/// The captions of the `result` events (docs/ui/sessions.md, "Turn end captions").
enum TranscriptTurnEndCaption {
    /// nil: the row is not drawn (an interrupted turn).
    static func caption(_ item: TurnEndItem) -> (text: String, isError: Bool)? {
        if item.isError {
            if let reason = item.stopReason {
                return ("Failed: \(reason)", true)
            }
            return ("Failed", true)
        }
        guard let reason = item.stopReason else { return nil }
        if reason == "end_turn" {
            guard let milliseconds = item.durationMS else { return ("Done", false) }
            return ("Done in \(duration(milliseconds))", false)
        }
        guard let milliseconds = item.durationMS else { return ("Stopped (\(reason))", false) }
        return ("Stopped (\(reason)) after \(duration(milliseconds))", false)
    }

    /// `Duration.milliseconds(durationMS)` in hours, minutes and seconds, narrow.
    static func duration(_ milliseconds: Int) -> String {
        Duration.milliseconds(milliseconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}

/// A collapsed row with a symbol, a secondary title and a disclosure chevron; expanded, the content under it.
private struct TranscriptDisclosure<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: () -> Content

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                    Text(title)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Places its one subview at the trailing edge, at most `fraction` of the proposed width.
struct TranscriptBubbleLayout: Layout {
    let fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        guard let width = proposal.width, width.isFinite else {
            return subview.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        }
        let size = subview.sizeThatFits(ProposedViewSize(width: width * fraction, height: nil))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let maxWidth = bounds.width * fraction
        let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        subview.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                      proposal: ProposedViewSize(width: min(size.width, maxWidth), height: size.height))
    }
}

/// A wrapping flow: subviews left to right, on as many lines as needed.
struct TranscriptFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
