import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The text view of a message composer (docs/ui/sessions.md, "Message composer"): plain text in the body font, grows
/// from 1 to 8 lines then scrolls, placeholder in secondary color. Return inserts a line break; ⌘↩ calls `onSend`;
/// pasting files or images calls `onAttach` with them instead of pasting text.
struct ComposerTextView: View {
    @Binding var text: String
    let placeholder: String
    let focusOnAppear: Bool
    let onSend: () -> Void
    let onAttach: ([AttachmentInput]) -> Void

    var body: some View {
        ComposerTextRepresentable(text: $text, focusOnAppear: focusOnAppear, onSend: onSend, onAttach: onAttach)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.leading, ComposerTextMetrics.placeholderInsets.leading)
                        .padding(.top, ComposerTextMetrics.placeholderInsets.top)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(placeholder)
    }
}

/// The sizes the platform text views share.
enum ComposerTextMetrics {
    static let minimumLines: CGFloat = 1
    static let maximumLines: CGFloat = 8
    /// The space around the text inside the text view.
    static let insetWidth: CGFloat = 4
    static let insetHeight: CGFloat = 6
    /// The text container's default line fragment padding.
    static let lineFragmentPadding: CGFloat = 5

    /// Where the placeholder starts: the insets plus the line fragment padding.
    static var placeholderInsets: EdgeInsets {
        EdgeInsets(top: insetHeight, leading: insetWidth + lineFragmentPadding, bottom: insetHeight,
                   trailing: insetWidth + lineFragmentPadding)
    }

    /// The height of the view for a text height: clamped to 1–8 lines, plus the insets.
    static func viewHeight(textHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let clamped = min(max(textHeight, minimumLines * lineHeight), maximumLines * lineHeight)
        return ceil(clamped + 2 * insetHeight)
    }
}

#if os(macOS)

/// `NSTextView` in an `NSScrollView`: plain text, undo on, no automatic quote and dash substitution, body font,
/// transparent background.
private struct ComposerTextRepresentable: NSViewRepresentable {
    @Binding var text: String
    let focusOnAppear: Bool
    let onSend: () -> Void
    let onAttach: ([AttachmentInput]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = Coordinator.font
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: ComposerTextMetrics.insetWidth,
                                             height: ComposerTextMetrics.insetHeight)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = ComposerTextMetrics.lineFragmentPadding
        textView.string = text
        textView.delegate = context.coordinator
        textView.focusOnAppear = focusOnAppear
        textView.onSend = onSend
        textView.onAttach = onAttach

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        textView.onSend = onSend
        textView.onAttach = onAttach
        textView.isEditable = context.environment.isEnabled
        if textView.string != text {
            textView.string = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.frame.width
        let textWidth = max(width - 2 * ComposerTextMetrics.insetWidth, 1)
        let height = context.coordinator.textHeight(text, width: textWidth)
        return CGSize(width: width,
                      height: ComposerTextMetrics.viewHeight(textHeight: height,
                                                             lineHeight: context.coordinator.lineHeight))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.preferredFont(forTextStyle: .body)

        var text: Binding<String>
        /// Lays out the text at a given width to measure it, as the text view does.
        private let measureStorage = NSTextStorage()
        private let measureLayout = NSLayoutManager()
        private let measureContainer = NSTextContainer()

        init(text: Binding<String>) {
            self.text = text
            super.init()
            measureContainer.lineFragmentPadding = ComposerTextMetrics.lineFragmentPadding
            measureLayout.addTextContainer(measureContainer)
            measureStorage.addLayoutManager(measureLayout)
        }

        var lineHeight: CGFloat {
            measureLayout.defaultLineHeight(for: Self.font)
        }

        func textHeight(_ string: String, width: CGFloat) -> CGFloat {
            measureContainer.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            measureStorage.setAttributedString(NSAttributedString(string: string, attributes: [.font: Self.font]))
            measureLayout.ensureLayout(for: measureContainer)
            return measureLayout.usedRect(for: measureContainer).height
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
        }
    }
}

/// ⌘↩ sends; a paste of files or images attaches them.
private final class ComposerNSTextView: NSTextView {
    var focusOnAppear = false
    var onSend: (() -> Void)?
    var onAttach: (([AttachmentInput]) -> Void)?
    private var didFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, !didFocus, let window else { return }
        didFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && modifiers == .command {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let attachments = AttachmentPasteboard.attachments(from: .general) {
            onAttach?(attachments)
        } else {
            super.paste(sender)
        }
    }
}

#else

/// `UITextView` with the body font.
private struct ComposerTextRepresentable: UIViewRepresentable {
    @Binding var text: String
    let focusOnAppear: Bool
    let onSend: () -> Void
    let onAttach: ([AttachmentInput]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> ComposerUITextView {
        let textView = ComposerUITextView()
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: ComposerTextMetrics.insetHeight,
                                                   left: ComposerTextMetrics.insetWidth,
                                                   bottom: ComposerTextMetrics.insetHeight,
                                                   right: ComposerTextMetrics.insetWidth)
        textView.textContainer.lineFragmentPadding = ComposerTextMetrics.lineFragmentPadding
        textView.isScrollEnabled = true
        textView.text = text
        textView.delegate = context.coordinator
        textView.focusOnAppear = focusOnAppear
        textView.onSend = onSend
        textView.onAttach = onAttach
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: ComposerUITextView, context: Context) {
        context.coordinator.text = $text
        textView.onSend = onSend
        textView.onAttach = onAttach
        textView.isEditable = context.environment.isEnabled
        if textView.text != text {
            textView.text = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: ComposerUITextView, context: Context)
        -> CGSize? {
        let width = proposal.width ?? textView.bounds.width
        let fitting = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let textHeight = fitting.height - 2 * ComposerTextMetrics.insetHeight
        let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        return CGSize(width: width, height: ComposerTextMetrics.viewHeight(textHeight: textHeight,
                                                                           lineHeight: lineHeight))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            if text.wrappedValue != textView.text {
                text.wrappedValue = textView.text
            }
        }
    }
}

/// ⌘↩ sends; a paste of images attaches them; paste is allowed when the pasteboard has images or strings.
final class ComposerUITextView: UITextView {
    var focusOnAppear = false
    var onSend: (() -> Void)?
    var onAttach: (([AttachmentInput]) -> Void)?
    private var didFocus = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard focusOnAppear, !didFocus, window != nil else { return }
        didFocus = true
        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(sendCommand))
        send.wantsPriorityOverSystemBehavior = true
        return [send] + (super.keyCommands ?? [])
    }

    @objc private func sendCommand() {
        onSend?()
    }

    override func paste(_ sender: Any?) {
        if let attachments = AttachmentPasteboard.attachments(from: .general) {
            onAttach?(attachments)
        } else {
            super.paste(sender)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

#endif
