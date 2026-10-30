import HephClient
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One tool call of a transcript, collapsed by default; clicking the row toggles it (docs/ui/sessions.md, "Tool rows").
struct ToolUseRow: View {
    let tool: ToolItem
    /// The session is `running` or `waitingPermission`.
    let isSessionActive: Bool
    let projectRoot: String?

    /// A longer result is shown cut there.
    static let resultDisplayLimit = 20_000

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                header
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                details
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: ToolSummary.symbolName(toolName: tool.name))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            name
            let summary = ToolSummary.summary(toolName: tool.name, inputJSON: tool.input, projectRoot: projectRoot)
            if !summary.isEmpty {
                Text(summary)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            state
        }
    }

    @ViewBuilder private var name: some View {
        if tool.name.isEmpty {
            Text("Tool result")
                .bold()
        } else if let parts = ToolSummary.mcpParts(of: tool.name) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(parts.tool)
                    .bold()
                Text(parts.server)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(tool.name)
                .bold()
        }
    }

    @ViewBuilder private var state: some View {
        if let result = tool.result {
            if result.isError {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        } else if isSessionActive {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            TranscriptMonospacedBox(text: ToolSummary.prettyPrinted(inputJSON: tool.input), maxHeight: 240,
                                    isError: false)
            Text("Result")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if let result = tool.result {
                let count = result.text.count
                if count > Self.resultDisplayLimit {
                    TranscriptMonospacedBox(text: String(result.text.prefix(Self.resultDisplayLimit)), maxHeight: 300,
                                            isError: result.isError)
                    HStack(spacing: 12) {
                        Text("… \(count - Self.resultDisplayLimit) more characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Copy Full Result") {
                            TranscriptPasteboard.copy(result.text)
                        }
                        .controlSize(.small)
                    }
                } else {
                    TranscriptMonospacedBox(text: result.text, maxHeight: 300, isError: result.isError)
                }
            } else {
                Text("No result")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 26)
    }
}

/// Monospaced text in a box that grows with its content up to `maxHeight`, then scrolls.
struct TranscriptMonospacedBox: View {
    let text: String
    let maxHeight: CGFloat
    let isError: Bool

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.callout.monospaced())
                .foregroundStyle(isError ? Color.red : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))
    }
}

/// Copies text to the general pasteboard.
enum TranscriptPasteboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
