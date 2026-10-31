import HephClient
import HephCore
import SwiftUI

/// The Comments section of the ticket detail (docs/ui/tickets.md, "Comments"): a "Comments" header with the count, then
/// the comments, oldest first. The detail's scroll view follows a new comment when it is scrolled to the bottom.
struct CommentsView: View {
    let store: ProjectStore
    let ticket: TicketItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Comments")
                    .font(.headline)
                Text("\(ticket.comments.count)")
                    .foregroundStyle(.secondary)
            }
            ForEach(ticket.comments) { comment in
                CommentView(store: store, ticketID: ticket.id, comment: comment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
