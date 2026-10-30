#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Lets a screen trigger editor actions that have no other entry point (the Find button on iOS).
@MainActor public final class CodeEditorProxy {
    #if os(macOS)
    private weak var textView: NSTextView?
    #else
    private weak var textView: UITextView?
    #endif

    public init() {}

    #if os(macOS)
    /// Registers the text view of the editor that was given this proxy (weak reference).
    func register(_ textView: NSTextView) {
        self.textView = textView
    }
    #else
    /// Registers the text view of the editor that was given this proxy (weak reference).
    func register(_ textView: UITextView) {
        self.textView = textView
    }
    #endif

    /// Shows the find interface of the registered editor; does nothing when no editor is registered.
    public func showFind() {
        guard let textView else { return }
        #if os(macOS)
        textView.window?.makeFirstResponder(textView)
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(sender)
        #else
        textView.findInteraction?.presentFindNavigator(showingReplace: false)
        #endif
    }
}
