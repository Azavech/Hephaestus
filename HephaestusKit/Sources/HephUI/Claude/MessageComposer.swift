import HephClient
import HephCore
import SwiftUI

/// Uploads its attachments to `projectID` on the Main `mainDeviceID` as they are added (docs/ui/sessions.md,
/// "Message composer"). The composer of sessions and of task comments: the attachment tray, then the attach menu, the
/// text view, the Stop button (when given) and the Send button.
public struct MessageComposer: View {
    private let placeholder: String
    @Binding private var draft: ComposerDraft
    private let mainDeviceID: UUID
    private let projectID: String
    private let canSend: Bool
    private let focusOnAppear: Bool
    private let onStop: (() -> Void)?
    private let onSend: (ComposerDraft) async -> Bool

    @Environment(Workspace.self) private var workspace
    @State private var uploads = ComposerUploads()
    @State private var isSending = false

    /// An attachment uploaded more than this long before Send is uploaded again first: the Main deletes an upload
    /// that no request used for an hour.
    private static let uploadLifetime: TimeInterval = 55 * 60

    public init(placeholder: String, draft: Binding<ComposerDraft>, mainDeviceID: UUID, projectID: String,
                canSend: Bool, focusOnAppear: Bool = false, onStop: (() -> Void)? = nil,
                onSend: @escaping (ComposerDraft) async -> Bool) {
        self.placeholder = placeholder
        _draft = draft
        self.mainDeviceID = mainDeviceID
        self.projectID = projectID
        self.canSend = canSend
        self.focusOnAppear = focusOnAppear
        self.onStop = onStop
        self.onSend = onSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !draft.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(draft.attachments) { attachment in
                            ComposerAttachmentChip(
                                attachment: attachment,
                                onCancel: { remove(attachment.id) },
                                onRemove: { remove(attachment.id) },
                                onRetry: { retry(attachment.id) }
                            )
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
            HStack(alignment: .bottom, spacing: 8) {
                AttachmentPickerButton(onAdd: add)
                    .fixedSize()
                ComposerTextView(text: $draft.text, placeholder: placeholder, focusOnAppear: focusOnAppear,
                                 onSend: send, onAttach: add)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
                if let onStop {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                sendButton
            }
        }
        .attachmentDrop(onAdd: add)
        .onChange(of: draft.attachments) { oldAttachments, newAttachments in
            uploads.attachmentsChanged(from: oldAttachments, to: newAttachments, workspace: workspace,
                                       mainDeviceID: mainDeviceID)
        }
        .task(id: mainDeviceID) {
            for await event in workspace.events() {
                if case .connected(let connectedID) = event, connectedID == mainDeviceID {
                    markUploadsStale()
                }
            }
        }
        .onDisappear {
            let attachments = draft.attachments
            uploads.composerDisappeared(attachments, workspace: workspace, mainDeviceID: mainDeviceID)
            if !attachments.isEmpty {
                draft.attachments = []
            }
        }
    }

    @ViewBuilder private var sendButton: some View {
        let button = Button(action: send) {
            if isSending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
            } else {
                Label("Send", systemImage: "arrow.up.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSendEnabled ? Color.accentColor : Color.secondary)
        .disabled(!isSendEnabled)
        if isUploading {
            button.help("Waiting for uploads…")
        } else {
            button
        }
    }

    private var isUploading: Bool {
        draft.attachments.contains {
            if case .uploading = $0.state {
                return true
            }
            return false
        }
    }

    /// `canSend`, a non-empty trimmed text or attachments, every attachment uploaded, and no send in flight.
    private var isSendEnabled: Bool {
        let hasContent = !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.attachments.isEmpty
        return canSend && hasContent && draft.isUploaded && !isSending
    }

    // MARK: Attachments

    private func add(_ inputs: [AttachmentInput]) {
        for input in inputs {
            let attachment = AttachmentDraft(input: input)
            draft.attachments.append(attachment)
            startUpload(attachment)
        }
    }

    private func startUpload(_ attachment: AttachmentDraft) {
        uploads.start(attachment, draft: $draft, workspace: workspace, mainDeviceID: mainDeviceID,
                      projectID: projectID)
    }

    /// Cancel and Remove: the attachment leaves the draft; `attachmentsChanged` cancels its task, cancels its upload
    /// on the Main when it is uploaded, and discards its source.
    private func remove(_ id: UUID) {
        draft.attachments.removeAll { $0.id == id }
    }

    /// Retry: a new upload of the same source.
    private func retry(_ id: UUID) {
        guard let index = draft.attachments.firstIndex(where: { $0.id == id }) else { return }
        draft.attachments[index].state = .uploading(nil)
        startUpload(draft.attachments[index])
    }

    /// After a reconnection of the Main, which may have forgotten its uploads, the next Send uploads them again.
    private func markUploadsStale() {
        for index in draft.attachments.indices {
            if case .uploaded(let ref, _) = draft.attachments[index].state {
                draft.attachments[index].state = .uploaded(ref, at: .distantPast)
            }
        }
    }

    // MARK: Send

    private func send() {
        guard isSendEnabled else { return }
        isSending = true
        Task {
            await performSend()
            isSending = false
        }
    }

    /// Uploads again the attachments uploaded more than 55 minutes before, then calls `onSend` once every attachment
    /// is uploaded; `true` clears the draft (the Main used the uploads), `false` keeps it.
    private func performSend() async {
        let now = Date()
        var reuploads: [UUID] = []
        for index in draft.attachments.indices {
            if case .uploaded(_, let at) = draft.attachments[index].state,
               now.timeIntervalSince(at) > Self.uploadLifetime {
                draft.attachments[index].state = .uploading(nil)
                startUpload(draft.attachments[index])
                reuploads.append(draft.attachments[index].id)
            }
        }
        for id in reuploads {
            await uploads.wait(for: id)
        }
        guard draft.isUploaded else { return }
        let sent = draft
        guard await onSend(sent) else { return }
        uploads.markConsumed(sent.attachments.map(\.id))
        draft = ComposerDraft()
    }
}

/// The upload tasks of a composer's attachments.
@MainActor
final class ComposerUploads {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Attachments whose uploads a request used (Send succeeded): they leave the draft without cancelling anything.
    private var consumed: Set<UUID> = []
    /// Attachments already released.
    private var released: Set<UUID> = []

    /// Uploads the attachment's source at once; each progress report sets `uploading(progress)`. Success:
    /// `uploaded(ref, at: <now>)`; failure: `failed(<message>)`; without a connection: `failed("<Main name> is
    /// offline.")`. A cancelled task changes nothing.
    func start(_ attachment: AttachmentDraft, draft: Binding<ComposerDraft>, workspace: Workspace, mainDeviceID: UUID,
               projectID: String) {
        let id = attachment.id
        tasks[id]?.cancel()
        tasks[id] = nil
        guard let connection = workspace.connection(mainDeviceID) else {
            let name = ClaudeNames.mainName(mainDeviceID, in: workspace)
            Self.set(.failed("\(name) is offline."), of: id, in: draft)
            return
        }
        let fileName = attachment.fileName
        let source = attachment.source
        tasks[id] = Task { [weak self] in
            do {
                let ref = try await connection.upload(fileName: fileName, projectID: projectID, source: source) {
                    progress in
                    guard !Task.isCancelled else { return }
                    Self.set(.uploading(progress), of: id, in: draft)
                }
                if Task.isCancelled || !Self.contains(id, in: draft) {
                    // The attachment left the draft while its upload completed.
                    Self.cancelUpload(ref.uploadID, on: connection)
                } else {
                    Self.set(.uploaded(ref, at: Date()), of: id, in: draft)
                }
            } catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    Self.set(.failed(Banner.message(of: error)), of: id, in: draft)
                }
            }
            self?.finished(id)
        }
    }

    /// Waits until the upload of the attachment ends.
    func wait(for id: UUID) async {
        await tasks[id]?.value
    }

    /// The attachments sent with a successful request leave the draft without cancelling their uploads.
    func markConsumed(_ ids: [UUID]) {
        consumed.formUnion(ids)
    }

    /// Attachments that left the draft (Remove, Cancel, the caller replacing the draft, a successful send) are
    /// released.
    func attachmentsChanged(from oldAttachments: [AttachmentDraft], to newAttachments: [AttachmentDraft],
                            workspace: Workspace, mainDeviceID: UUID) {
        let remaining = Set(newAttachments.map(\.id))
        for attachment in oldAttachments where !remaining.contains(attachment.id) {
            release(attachment, workspace: workspace, mainDeviceID: mainDeviceID)
        }
    }

    /// When the composer disappears, every attachment is released.
    func composerDisappeared(_ attachments: [AttachmentDraft], workspace: Workspace, mainDeviceID: UUID) {
        for attachment in attachments {
            release(attachment, workspace: workspace, mainDeviceID: mainDeviceID)
        }
    }

    /// An attachment leaves the draft: its task is cancelled and, when it is uploaded and the upload was not used,
    /// `cancelUpload` is sent without waiting; its source is discarded.
    private func release(_ attachment: AttachmentDraft, workspace: Workspace, mainDeviceID: UUID) {
        let id = attachment.id
        tasks[id]?.cancel()
        tasks[id] = nil
        guard released.insert(id).inserted else { return }
        if !consumed.contains(id), let ref = attachment.uploadRef, let connection = workspace.connection(mainDeviceID) {
            Self.cancelUpload(ref.uploadID, on: connection)
        }
        AttachmentFiles.discard(attachment.source)
    }

    private func finished(_ id: UUID) {
        tasks[id] = nil
    }

    private static func cancelUpload(_ uploadID: UUID, on connection: MainConnection) {
        Task {
            try? await connection.cancelUpload(uploadID: uploadID)
        }
    }

    private static func contains(_ id: UUID, in draft: Binding<ComposerDraft>) -> Bool {
        draft.wrappedValue.attachments.contains { $0.id == id }
    }

    private static func set(_ state: AttachmentDraft.State, of id: UUID, in draft: Binding<ComposerDraft>) {
        guard let index = draft.wrappedValue.attachments.firstIndex(where: { $0.id == id }) else { return }
        draft.wrappedValue.attachments[index].state = state
    }
}

/// A chip of the attachment tray: thumbnail or `doc`, the name, then a line and buttons by state.
private struct ComposerAttachmentChip: View {
    let attachment: AttachmentDraft
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onRetry: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.fileName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160, alignment: .leading)
                stateLine
            }
            buttons
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
        .task(id: attachment.id) {
            await loadThumbnail()
        }
    }

    @ViewBuilder private var thumbnailView: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: displayScale)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "doc")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.08))
        }
    }

    @ViewBuilder private var stateLine: some View {
        switch attachment.state {
        case .uploading(let progress):
            HStack(spacing: 6) {
                ProgressView(value: progress?.fraction)
                    .frame(width: 120)
                if let progress {
                    Text("\(Self.bytes(progress.completed)) of \(Self.bytes(progress.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .uploaded:
            Text(Self.bytes(attachment.size))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Upload failed")
            }
            .font(.caption)
            .foregroundStyle(.red)
            .help(message)
            .accessibilityValue(message)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch attachment.state {
        case .uploading:
            chipButton("Cancel Upload", symbol: "xmark.circle.fill", action: onCancel)
        case .uploaded:
            chipButton("Remove", symbol: "xmark.circle.fill", action: onRemove)
        case .failed:
            chipButton("Retry Upload", symbol: "arrow.clockwise", action: onRetry)
            chipButton("Remove", symbol: "xmark.circle.fill", action: onRemove)
        }
    }

    private func chipButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(title)
    }

    /// Images: a thumbnail decoded from the source with `ImageDecoding`, off the main actor.
    private func loadThumbnail() async {
        guard attachment.isImage else { return }
        let source = attachment.source
        let maxPixelSize = Int((40 * displayScale).rounded(.up))
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            let data: Data?
            switch source {
            case .data(let bytes):
                data = bytes
            case .file(let url):
                data = try? Data(contentsOf: url, options: .mappedIfSafe)
            }
            guard let data else { return nil }
            return ImageDecoding.thumbnail(of: data, maxPixelSize: maxPixelSize)
        }.value
        thumbnail = image
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
