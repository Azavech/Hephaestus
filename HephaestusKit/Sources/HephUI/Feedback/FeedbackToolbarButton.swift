import SwiftUI

/// Toolbar item of every window; reads the window's FeedbackController from the environment
/// (docs/forge/feedback.md, "Entry points").
public struct FeedbackToolbarButton: View {
    @Environment(FeedbackController.self) private var controller: FeedbackController?

    public init() {}

    public var body: some View {
        Button {
            controller?.begin()
        } label: {
            Label("Send Feedback", systemImage: "exclamationmark.bubble")
        }
        .help("Send Feedback (⇧⌘F)")
    }
}
