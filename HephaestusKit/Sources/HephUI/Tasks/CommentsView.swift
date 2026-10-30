import HephClient
import HephCore
import SwiftUI

/// The Comments section of the task detail (docs/ui/tasks.md, "Comments"): a "Comments" header with the count, then
/// the comments, oldest first. The detail's scroll view follows a new comment when it is scrolled to the bottom.
struct CommentsView: View {
    let store: ProjectStore
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Comments")
                    .font(.headline)
                Text("\(task.comments.count)")
                    .foregroundStyle(.secondary)
            }
            ForEach(task.comments) { comment in
                CommentView(store: store, taskID: task.id, comment: comment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
