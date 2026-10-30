import SwiftUI

/// Help ▸ Send Feedback… (⇧⌘F) (docs/forge/feedback.md, "Entry points"); acts on the key window's controller.
public struct FeedbackCommands: Commands {
    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") {
                FeedbackController.forKeyWindow()?.begin()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}
