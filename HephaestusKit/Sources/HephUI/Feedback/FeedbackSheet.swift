import Foundation
import HephClient
import HephCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The feedback sheet (docs/forge/feedback.md, "Sheet"). It gets its controller explicitly and does not rely on the
/// window's environment: the platform presents it outside the window's SwiftUI hierarchy.
struct FeedbackSheet: View {
    private let controller: FeedbackController
    @FocusState private var isCommentFocused: Bool

    init(controller: FeedbackController) {
        self.controller = controller
    }

    var body: some View {
        if let draft = controller.draft {
            content(draft)
        }
    }

    private func content(_ draft: FeedbackDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Feedback")
                .font(.headline)
            screenshotPreview(draft)
            commentEditor(draft)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(contextLines(draft.context), id: \.self) { line in
                    Text(line)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            forgeLine
            if isUploading(draft) {
                uploadRow(draft)
            }
            if let message = draft.errorMessage {
                errorBanner(message)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    controller.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(draft.isSending)
                Button {
                    controller.send()
                } label: {
                    if draft.isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.isSending || draft.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            isCommentFocused = true
        }
    }

    // MARK: - Parts

    private var previewHeight: CGFloat {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone ? 200 : 240
        #else
        return 240
        #endif
    }

    @ViewBuilder
    private func screenshotPreview(_ draft: FeedbackDraft) -> some View {
        if let image = draft.previewImage {
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 1)
                }
                .frame(maxWidth: .infinity)
        } else {
            Text("No screenshot")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: previewHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 1)
                }
        }
    }

    private func commentEditor(_ draft: FeedbackDraft) -> some View {
        TextEditor(text: Bindable(draft).comment)
            .focused($isCommentFocused)
            .frame(minHeight: 120)
            .overlay(alignment: .topLeading) {
                if draft.comment.isEmpty {
                    Text("Describe the problem or the change you want.")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5)
                        #if os(iOS)
                        .padding(.top, 8)
                        #endif
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var forgeLine: some View {
        let forge: ForgeModel? = controller.workspace?.forge
        if let hostID = forge?.forgeHostID {
            Text("Sent to the Forge on \(mainName(hostID)).")
                .font(.caption)
        } else {
            Text("No Forge online.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func uploadRow(_ draft: FeedbackDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Uploading the screenshot…")
                .font(.caption)
            if let progress = draft.uploadProgress {
                ProgressView(value: progress.fraction)
                Text(Self.bytes(progress.completed) + " of " + Self.bytes(progress.total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Values

    /// The screenshot uploads while the feedback is being sent and its last chunk has not been reported.
    private func isUploading(_ draft: FeedbackDraft) -> Bool {
        guard draft.isSending, draft.screenshot != nil else { return false }
        guard let progress = draft.uploadProgress else { return true }
        return progress.completed < progress.total
    }

    /// The device and app line, then, when the selection has a Main, the selection line.
    private func contextLines(_ context: FeedbackContext) -> [String] {
        var lines = ["\(context.deviceName) · Hephaestus \(context.appVersion) (\(context.build)) · docs "
            + String(context.docsHash.prefix(12))]
        let selection = context.selection
        if let mainDeviceID = selection.mainDeviceID {
            var parts = [mainName(mainDeviceID)]
            if let projectID = selection.projectID {
                parts.append(projectID)
            }
            if let section = selection.section {
                parts.append(section)
            }
            if let item = selection.item {
                parts.append(item)
            }
            lines.append(parts.joined(separator: " ▸ "))
        }
        return lines
    }

    /// The name of a Main: its connection's name, else its registry name, else its id's `uuidString`.
    private func mainName(_ id: UUID) -> String {
        let workspace = controller.workspace
        if let connection = workspace?.connection(id) {
            return connection.name
        }
        return workspace?.mesh?.devices.first { $0.id == id }?.name ?? id.uuidString
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
