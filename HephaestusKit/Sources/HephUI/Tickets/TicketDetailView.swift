import HephClient
import HephCore
import SwiftUI

/// The segments of the ticket detail.
enum TicketDetailSegment: Hashable, CaseIterable {
    case details
    case claude

    var title: String {
        switch self {
        case .details:
            return "Details"
        case .claude:
            return "Claude"
        }
    }
}

/// The segmented picker of the ticket detail: Details and Claude.
struct TicketSegmentPicker: View {
    @Binding var segment: TicketDetailSegment

    var body: some View {
        Picker("Segment", selection: $segment) {
            ForEach(TicketDetailSegment.allCases, id: \.self) { segment in
                Text(segment.title)
                    .tag(segment)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// One ticket (docs/ui/tickets.md, "Ticket detail"): the header, then the Details segment (description, comments and the
/// comment composer) or the Claude segment (the ticket's sessions). A broken ticket shows its parse error instead.
///
/// The view starts on the Details segment; `TicketsView` gives each ticket its own view, so selecting a ticket shows Details.
struct TicketDetailView: View {
    let store: ProjectStore
    let ticket: TicketItem
    let isCompact: Bool
    /// The selected session tab of this ticket, kept by `TicketsView`.
    @Binding var selectedSessionID: UUID?

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    @State private var segment: TicketDetailSegment = .details
    @State private var draft = ComposerDraft()
    @State private var ticketToDelete: TicketItem?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var isScrolledToBottom = true

    var body: some View {
        Group {
            if ticket.parseError != nil {
                brokenTicket
            } else if isCompact {
                compactContent
            } else {
                regularContent
            }
        }
        .modifier(TicketDeleteConfirmation(ticket: $ticketToDelete, store: store))
    }

    // MARK: - Layouts

    /// Regular width: the header stays above the segment's content; the segment is trailing in its first row.
    private var regularContent: some View {
        VStack(spacing: 0) {
            header(showsSegment: true)
                .padding(16)
            Divider()
            switch segment {
            case .details:
                details(includesHeader: false)
            case .claude:
                claude
            }
        }
    }

    /// Compact width: the segment is the navigation bar's principal item; the header scrolls with the Details content
    /// and the Claude segment hides it, with the ticket id as the navigation title.
    private var compactContent: some View {
        Group {
            switch segment {
            case .details:
                details(includesHeader: true)
            case .claude:
                claude
            }
        }
        .navigationTitle(segment == .claude ? ticket.id : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                TicketSegmentPicker(segment: $segment)
            }
        }
    }

    private func header(showsSegment: Bool) -> some View {
        TicketHeaderView(store: store, ticket: ticket, segment: $segment, showsSegment: showsSegment) {
            ticketToDelete = ticket
        }
    }

    // MARK: - Details segment

    /// A scroll view with the Description and Comments sections; the comment composer is pinned under it. When a
    /// comment arrives while the view is scrolled to the bottom, it scrolls to show it.
    private func details(includesHeader: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if includesHeader {
                    header(showsSegment: false)
                    Divider()
                }
                TicketDescriptionView(store: store, ticket: ticket)
                CommentsView(store: store, ticket: ticket)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
            return visibleBottom >= geometry.contentSize.height - 8
        } action: { _, isAtBottom in
            isScrolledToBottom = isAtBottom
        }
        .onChange(of: ticket.comments.count) { oldCount, newCount in
            if newCount > oldCount, isScrolledToBottom {
                withAnimation {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
    }

    /// The comment composer: `MessageComposer` without a Stop action.
    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            MessageComposer(
                placeholder: "Add a comment",
                draft: $draft,
                mainDeviceID: store.mainDeviceID,
                projectID: store.projectID,
                canSend: TicketsScreen.isConnected(store)
            ) { draft in
                await sendComment(draft)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    /// `addComment` with the trimmed text and the uploads; true clears the draft, false keeps it with its uploads.
    private func sendComment(_ draft: ComposerDraft) async -> Bool {
        let body = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploads = draft.uploads
        let projectID = store.projectID
        let ticketID = ticket.id
        return await banners.perform {
            let connection = try TicketsScreen.connection(of: store, workspace: workspace)
            _ = try await connection.addComment(projectID: projectID, ticketID: ticketID, body: body,
                                                attachments: uploads)
        }
    }

    // MARK: - Claude segment

    private var claude: some View {
        TicketClaudeView(store: store, ticket: ticket, selectedSessionID: $selectedSessionID) {
            segment = .claude
        }
    }

    // MARK: - Broken ticket

    /// The id, "This ticket file cannot be read.", the parse error, the file path and Delete Ticket…; no segment, no
    /// comments and no composer.
    private var brokenTicket: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(ticket.id)
                    .font(.title2.monospaced())
                    .textSelection(.enabled)
                Text("This ticket file cannot be read.")
                Text(verbatim: ticket.parseError ?? "")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text(verbatim: ".hephaestus/tickets/\(ticket.id).yml")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Delete Ticket…", role: .destructive) {
                    ticketToDelete = ticket
                }
                .disabled(!TicketsScreen.isConnected(store))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The confirmation of Delete a ticket (docs/ui/tickets.md, "Delete a ticket"), from the detail's actions menu, the row's
/// context menu and the broken-ticket detail. Delete calls `deleteTicket`; after success, `selection.item` is cleared when
/// it was this ticket. The ticket's sessions are kept.
struct TicketDeleteConfirmation: ViewModifier {
    @Binding var ticket: TicketItem?
    let store: ProjectStore

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Text(verbatim: "Delete \(ticket?.id ?? "")?"),
                isPresented: Binding(
                    get: { ticket != nil },
                    set: { isPresented in
                        if !isPresented {
                            ticket = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: ticket
            ) { ticket in
                Button("Delete", role: .destructive) {
                    delete(ticket)
                }
                Button("Cancel", role: .cancel) {}
            } message: { ticket in
                if ticket.parseError != nil {
                    Text(verbatim: "The file .hephaestus/tickets/\(ticket.id).yml is deleted. This cannot be undone.")
                } else {
                    Text(verbatim: "“\(ticket.name)” and its attachments are deleted. This cannot be undone.")
                }
            }
    }

    private func delete(_ ticket: TicketItem) {
        let projectID = store.projectID
        let ticketID = ticket.id
        Task {
            let succeeded = await banners.perform {
                let connection = try TicketsScreen.connection(of: store, workspace: workspace)
                try await connection.deleteTicket(projectID: projectID, ticketID: ticketID)
            }
            if succeeded, context.selection.item == ticketID {
                context.selection.item = nil
            }
        }
    }
}
