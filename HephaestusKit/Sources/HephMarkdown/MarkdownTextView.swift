#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// Shows one attributed string, selectable and not editable. It never scrolls: it takes the proposed width and the
/// height of its laid-out text. A click or tap on a link passes its URL to the environment's `openURL`.
@MainActor
struct MarkdownTextView {
    let text: NSAttributedString

    @MainActor
    final class Coordinator: NSObject {
        /// The last string set in the text storage.
        var text: NSAttributedString?
        var openURL: OpenURLAction?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
}

#if os(macOS)
extension MarkdownTextView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor]
        textView.delegate = context.coordinator
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        guard context.coordinator.text != text, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        storage.setAttributedString(text)
        context.coordinator.text = text
        textView.setSelectedRange(Self.clamped(selection, to: storage.length))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize? {
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return nil }
        let width = Self.width(proposal, current: textView.bounds.width)
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = layoutManager.usedRect(for: container).height
        return CGSize(width: width, height: ceil(height))
    }
}

extension MarkdownTextView.Coordinator: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url, let openURL else { return false }
        openURL(url)
        return true
    }
}
#else
extension MarkdownTextView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        guard context.coordinator.text != text else { return }
        let selection = textView.selectedRange
        textView.textStorage.setAttributedString(text)
        context.coordinator.text = text
        textView.selectedRange = Self.clamped(selection, to: textView.textStorage.length)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        let width = Self.width(proposal, current: textView.bounds.width)
        let size = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
}

extension MarkdownTextView.Coordinator: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case .link(let url) = textItem.content, let openURL else { return defaultAction }
        return UIAction { _ in openURL(url) }
    }
}
#endif

extension MarkdownTextView {
    /// The proposed width, or the text view's current width when the proposal has none.
    fileprivate static func width(_ proposal: ProposedViewSize, current: CGFloat) -> CGFloat {
        guard let width = proposal.width, width.isFinite else { return current }
        return width
    }

    /// `range` kept inside a text of `length` characters.
    fileprivate static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }
}
