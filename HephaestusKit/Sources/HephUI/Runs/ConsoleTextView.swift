import HephClient
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The output of a run in the platform text view: read-only, selectable, monospaced 12 pt, wrapping, 8 pt insets
/// (docs/ui/runs.md, "Console text view"). When `model.generation` differs from the last applied one the whole text
/// is replaced; otherwise the text after the last applied UTF-16 length is appended. Then, with auto-scroll on, the
/// view scrolls to the end.
struct ConsoleTextView: View {
    let model: RunOutputModel
    let autoScroll: Bool

    var body: some View {
        ConsoleTextRepresentable(text: model.text, generation: model.generation, autoScroll: autoScroll)
    }
}

/// What both platforms apply.
private enum ConsoleText {
    static let fontSize: CGFloat = 12
    static let inset: CGFloat = 8
}

/// The text applied last to a text view.
@MainActor
private final class ConsoleTextState {
    var generation: Int?
    /// The UTF-16 length of the text applied.
    var length = 0

    /// The change to apply for a new text: a replacement, an appended tail, or nothing.
    enum Change {
        case replace(String)
        case append(String)
        case none
    }

    func change(for text: String, generation: Int) -> Change {
        let newLength = text.utf16.count
        if self.generation != generation || newLength < length {
            self.generation = generation
            length = newLength
            return .replace(text)
        }
        guard newLength > length else { return .none }
        let tail = (text as NSString).substring(from: length)
        length = newLength
        return .append(tail)
    }
}

#if os(macOS)

private struct ConsoleTextRepresentable: NSViewRepresentable {
    let text: String
    let generation: Int
    let autoScroll: Bool

    func makeCoordinator() -> ConsoleTextState {
        ConsoleTextState()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = Self.font
            textView.textColor = .textColor
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: ConsoleText.inset, height: ConsoleText.inset)
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        switch context.coordinator.change(for: text, generation: generation) {
        case .replace(let text):
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        case .append(let tail):
            storage.append(NSAttributedString(string: tail, attributes: Self.attributes))
        case .none:
            break
        }
        if autoScroll {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: ConsoleText.fontSize, weight: .regular)

    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }
}

#else

private struct ConsoleTextRepresentable: UIViewRepresentable {
    let text: String
    let generation: Int
    let autoScroll: Bool

    func makeCoordinator() -> ConsoleTextState {
        ConsoleTextState()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = Self.font
        textView.textColor = .label
        textView.backgroundColor = .systemBackground
        textView.textContainerInset = UIEdgeInsets(top: ConsoleText.inset, left: ConsoleText.inset,
                                                   bottom: ConsoleText.inset, right: ConsoleText.inset)
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.alwaysBounceVertical = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        switch context.coordinator.change(for: text, generation: generation) {
        case .replace(let text):
            textView.textStorage.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        case .append(let tail):
            textView.textStorage.append(NSAttributedString(string: tail, attributes: Self.attributes))
        case .none:
            break
        }
        if autoScroll {
            let length = textView.textStorage.length
            if length > 0 {
                textView.scrollRangeToVisible(NSRange(location: length - 1, length: 1))
            }
        }
    }

    private static let font = UIFont.monospacedSystemFont(ofSize: ConsoleText.fontSize, weight: .regular)

    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor.label]
    }
}

#endif
