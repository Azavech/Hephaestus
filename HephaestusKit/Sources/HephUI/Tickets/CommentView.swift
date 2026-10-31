import HephClient
import HephCore
import HephMarkdown
import SwiftUI

/// One comment of a ticket (docs/ui/tickets.md, "Rendering", "Editing and deleting"): the author, the time, the body, the
/// attachments, and the actions menu with Edit (comments of devices only) and Delete….
struct CommentView: View {
    let store: ProjectStore
    let ticketID: String
    let comment: TicketComment

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var isSaving = false
    @State private var isDeletePresented = false
    @FocusState private var isEditorFocused: Bool

    /// A comment made through the MCP tools: it can be deleted, not edited.
    private var isByClaude: Bool {
        comment.author == "Claude"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                author
                time
                Spacer(minLength: 8)
                actionsMenu
            }
            if isEditing {
                editor
            } else {
                MarkdownView(comment.body, linkHandler: { target in
                    TicketsScreen.openLink(target, store: store, workspace: workspace, context: context,
                                         banners: banners, openURL: openURL)
                })
            }
            if !comment.attachments.isEmpty {
                attachments
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            menuItems
        }
        .confirmationDialog("Delete this comment?", isPresented: $isDeletePresented, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its attached files are deleted too. This cannot be undone.")
        }
    }

    // MARK: - Header

    /// `sparkles` and "Claude" for Claude's comments, else `person.crop.circle` and the author.
    @ViewBuilder
    private var author: some View {
        if isByClaude {
            Label("Claude", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
        } else {
            Label {
                Text(comment.author)
            } icon: {
                Image(systemName: "person.crop.circle")
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    /// The relative creation time (absolute in the help tag); "· edited" when edited (the edit date in its help tag).
    private var time: some View {
        TimelineView(.everyMinute) { _ in
            HStack(spacing: 4) {
                Text(verbatim: comment.created.formatted(.relative(presentation: .named)))
                    .help(comment.created.formatted(date: .abbreviated, time: .shortened))
                if let edited = comment.edited {
                    Text("· edited")
                        .help(edited.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The `ellipsis` menu; on macOS it shows while the pointer is over the comment.
    private var actionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        #if os(macOS)
        .opacity(isHovering ? 1 : 0)
        #endif
    }

    @ViewBuilder
    private var menuItems: some View {
        if !isByClaude {
            Button("Edit", action: beginEditing)
                .disabled(isEditing)
        }
        Button("Delete…", role: .destructive) {
            isDeletePresented = true
        }
        .disabled(!TicketsScreen.isConnected(store))
    }

    // MARK: - Attachments

    /// Under the body in a wrapping flow: an image thumbnail for an `image/` type, else an attachment chip; both
    /// download the file into the attachment cache.
    private var attachments: some View {
        let workspace = self.workspace
        let store = self.store
        let projectID = store.projectID
        let ticketID = self.ticketID
        return CommentAttachmentFlow(spacing: 8) {
            ForEach(comment.attachments) { attachment in
                let fileName = attachment.file
                let size = attachment.size
                AttachmentView(
                    fileName: fileName,
                    mimeType: attachment.type,
                    size: size,
                    cacheKey: "\(projectID)/\(ticketID)/\(fileName)"
                ) { progress in
                    let connection = try TicketsScreen.connection(of: store, workspace: workspace)
                    return try await connection.downloadAttachment(projectID: projectID, ticketID: ticketID,
                                                                   fileName: fileName, size: size,
                                                                   progress: progress)
                }
            }
        }
    }

    // MARK: - Editing and deleting

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $editText)
                .font(.body.monospaced())
                .frame(minHeight: 80)
                .focused($isEditorFocused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    save()
                    return .handled
                }
                .onKeyPress(.escape) {
                    cancelEditing()
                    return .handled
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancelEditing)
                Button("Save", action: save)
                    .disabled(!canSave)
            }
        }
    }

    /// Disabled when the trimmed text is empty and the comment has no attachment, while saving, or offline.
    private var canSave: Bool {
        let isEmpty = editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !(isEmpty && comment.attachments.isEmpty) && !isSaving && TicketsScreen.isConnected(store)
    }

    private func beginEditing() {
        guard !isByClaude else { return }
        editText = comment.body
        isEditing = true
        isEditorFocused = true
    }

    private func cancelEditing() {
        isEditing = false
    }

    /// `updateComment` with the editor text; the comment keeps its author and attachments.
    private func save() {
        guard canSave else { return }
        let body = editText
        let projectID = store.projectID
        let ticketID = self.ticketID
        let commentID = comment.id
        isSaving = true
        Task {
            let succeeded = await banners.perform {
                let connection = try TicketsScreen.connection(of: store, workspace: workspace)
                _ = try await connection.updateComment(projectID: projectID, ticketID: ticketID, commentID: commentID,
                                                       body: body)
            }
            isSaving = false
            if succeeded {
                isEditing = false
            }
        }
    }

    private func delete() {
        let projectID = store.projectID
        let ticketID = self.ticketID
        let commentID = comment.id
        Task {
            await banners.perform {
                let connection = try TicketsScreen.connection(of: store, workspace: workspace)
                _ = try await connection.deleteComment(projectID: projectID, ticketID: ticketID, commentID: commentID)
            }
        }
    }
}

/// The wrapping flow of a comment's attachments: left to right, then on the next row when the width is full.
private struct CommentAttachmentFlow: Layout {
    var spacing: CGFloat

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> [Row] {
        let maxWidth = width ?? .infinity
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            if !row.items.isEmpty, row.width + spacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index: index, size: size))
        }
        if !row.items.isEmpty {
            rows.append(row)
        }
        return rows
    }
}
