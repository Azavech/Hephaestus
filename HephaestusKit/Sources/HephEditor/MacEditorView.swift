#if os(macOS)
import AppKit
import SwiftUI

/// The macOS editor: an `EditorNSTextView` (TextKit 1), document view of an `NSScrollView` built by hand, with a
/// `LineNumberRulerView`.
struct MacEditorView: NSViewRepresentable {
    let text: Binding<String>
    let language: EditorLanguage
    let isEditable: Bool
    let selection: Binding<NSRange>?
    let proxy: CodeEditorProxy?
    let onChange: (@MainActor (String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        private var parent: MacEditorView
        let textView: EditorNSTextView
        let scrollView: NSScrollView
        private let ruler: LineNumberRulerView
        private let controller: EditorController
        /// The last string written to the binding or accepted from it.
        private var lastText = ""
        /// True while SwiftUI updates the view: binding writes then wait for the next main-actor turn.
        private var isUpdating = false
        /// True while the whole text is replaced: the line index is rebuilt afterwards.
        private var isReplacingText = false
        private var isSelectionWriteScheduled = false

        init(_ parent: MacEditorView) {
            self.parent = parent
            let textView = EditorNSTextView(usingTextLayoutManager: false)
            let scrollView = NSScrollView()
            self.textView = textView
            self.scrollView = scrollView
            ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
            controller = EditorController(
                textStorage: textView.textStorage ?? NSTextStorage(), language: parent.language
            )
            super.init()
            controller.hasMarkedText = { [weak textView] in textView?.hasMarkedText() ?? false }
            configureTextView()
            configureScrollView()
            isUpdating = true
            textView.delegate = self
            textView.textStorage?.delegate = self
            setInitialText()
            parent.proxy?.register(textView)
            isUpdating = false
        }

        private func configureTextView() {
            let plain = EditorTheme.color(for: nil)
            textView.font = EditorTheme.font(for: nil)
            textView.defaultParagraphStyle = CodeEditorView.paragraphStyle
            textView.textColor = plain
            textView.insertionPointColor = plain
            textView.backgroundColor = EditorTheme.background
            textView.drawsBackground = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.usesRuler = false
            textView.isRulerVisible = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.isAutomaticTextCompletionEnabled = false
            textView.smartInsertDeleteEnabled = false
            textView.inlinePredictionType = .no
            textView.writingToolsBehavior = .none
            textView.allowsUndo = true
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.layoutManager?.allowsNonContiguousLayout = true
            textView.textContainerInset = NSSize(width: 4, height: 6)
            textView.isEditable = parent.isEditable
            textView.isSelectable = true
            textView.typingAttributes = CodeEditorView.baseAttributes
            textView.indentUnit = parent.language.indentUnit
        }

        private func configureScrollView() {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = true
            scrollView.backgroundColor = EditorTheme.background
            scrollView.documentView = textView
            ruler.clientView = textView
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            ruler.clipsToBounds = true
            ruler.updateThickness()
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                ruler, selector: #selector(LineNumberRulerView.clientViewDidChange(_:)),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                ruler, selector: #selector(LineNumberRulerView.clientViewDidChange(_:)),
                name: NSView.frameDidChangeNotification, object: textView
            )
        }

        /// The text the editor is created with: selected range from the binding, scrolled into view on the next
        /// main-actor turn, once SwiftUI has given the text view its size.
        private func setInitialText() {
            guard let storage = textView.textStorage else { return }
            setText(parent.text.wrappedValue, in: storage)
            guard let selection = parent.selection else { return }
            textView.setSelectedRange(CodeEditorView.clamp(selection.wrappedValue, toLength: storage.length))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.textView.scrollRangeToVisible(self.textView.selectedRange())
            }
        }

        func update(_ view: MacEditorView) {
            parent = view
            isUpdating = true
            defer { isUpdating = false }
            view.proxy?.register(textView)
            if view.text.wrappedValue != lastText {
                replaceText(with: view.text.wrappedValue)
            }
            if view.language != controller.language {
                textView.indentUnit = view.language.indentUnit
                controller.setLanguage(view.language)
            }
            if textView.isEditable != view.isEditable {
                textView.isEditable = view.isEditable
                textView.updateCurrentLine()
            }
            if let selection = view.selection, let storage = textView.textStorage {
                let range = CodeEditorView.clamp(selection.wrappedValue, toLength: storage.length)
                if range != textView.selectedRange() {
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                }
            }
        }

        func dismantle() {
            controller.stop()
            NotificationCenter.default.removeObserver(ruler)
        }

        // MARK: Text synchronization

        /// A text that came in through the binding replaces the text, keeping the selection and the scroll offset.
        private func replaceText(with newText: String) {
            guard let storage = textView.textStorage else { return }
            let selectedRange = textView.selectedRange()
            let scrollOrigin = scrollView.contentView.bounds.origin
            isReplacingText = true
            storage.setAttributedString(NSAttributedString(string: newText, attributes: CodeEditorView.baseAttributes))
            isReplacingText = false
            // The undo actions refer to the old text.
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(CodeEditorView.clamp(selectedRange, toLength: storage.length))
            restoreScrollOrigin(scrollOrigin)
            didSetText(newText, in: storage)
        }

        private func setText(_ newText: String, in storage: NSTextStorage) {
            isReplacingText = true
            storage.setAttributedString(NSAttributedString(string: newText, attributes: CodeEditorView.baseAttributes))
            isReplacingText = false
            didSetText(newText, in: storage)
        }

        private func didSetText(_ newText: String, in storage: NSTextStorage) {
            lastText = newText
            textView.lineIndex.rebuild(storage.mutableString)
            controller.textWasReplaced()
            ruler.updateThickness()
            ruler.needsDisplay = true
            textView.updateCurrentLine()
        }

        /// Scrolls back to `origin`, clamped to the content.
        private func restoreScrollOrigin(_ origin: NSPoint) {
            let clipView = scrollView.contentView
            let maximumY = max(0, textView.frame.height - clipView.bounds.height)
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: min(max(origin.y, 0), maximumY)))
            scrollView.reflectScrolledClipView(clipView)
        }

        func textDidChange(_ notification: Notification) {
            guard let storage = textView.textStorage else { return }
            let newText = storage.string
            lastText = newText
            parent.text.wrappedValue = newText
            parent.onChange?(newText)
            controller.textWasEdited()
            ruler.updateThickness()
            ruler.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Typed text never takes the color of the token next to it.
            textView.typingAttributes = CodeEditorView.baseAttributes
            textView.updateCurrentLine()
            ruler.needsDisplay = true
            guard parent.selection != nil else { return }
            if isUpdating {
                scheduleSelectionWrite()
            } else {
                writeSelection()
            }
        }

        /// Sets the binding to the text view's selection when they differ.
        private func writeSelection() {
            guard let selection = parent.selection else { return }
            let range = textView.selectedRange()
            if selection.wrappedValue != range {
                selection.wrappedValue = range
            }
        }

        /// A selection change during a SwiftUI update reaches the binding on the next main-actor turn.
        private func scheduleSelectionWrite() {
            guard !isSelectionWriteScheduled else { return }
            isSelectionWriteScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSelectionWriteScheduled = false
                self.writeSelection()
            }
        }

        nonisolated func textStorage(
            _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange, changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                controller.noteCharacterEdit(editedRange: editedRange, length: textStorage.length)
                guard !isReplacingText else { return }
                textView.lineIndex.update(
                    editedRange: editedRange, changeInLength: delta, string: textStorage.mutableString
                )
            }
        }
    }
}

/// The text view of the macOS editor. It declares no designated initializer: it is created with
/// `init(usingTextLayoutManager: false)` and runs on TextKit 1.
final class EditorNSTextView: NSTextView {
    /// The line starts of the text, kept by the coordinator.
    var lineIndex = LineIndex()
    /// What Tab inserts.
    var indentUnit = "    "
    /// The current-line rect last invalidated.
    private var currentLineRect: NSRect?

    /// Return inserts a line break followed by the indentation of the current line.
    override func insertNewline(_ sender: Any?) {
        guard isEditable, let storage = textStorage else {
            super.insertNewline(sender)
            return
        }
        let range = selectedRange()
        let indentation = CodeEditorView.indentation(
            of: storage.mutableString, at: range.location, lineIndex: lineIndex
        )
        insertText("\n" + indentation, replacementRange: range)
    }

    /// Tab inserts the language's indent unit.
    override func insertTab(_ sender: Any?) {
        guard isEditable else {
            super.insertTab(sender)
            return
        }
        insertText(indentUnit, replacementRange: selectedRange())
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lineRect = computeCurrentLineRect(), lineRect.intersects(rect) else { return }
        EditorTheme.currentLine.setFill()
        lineRect.intersection(rect).fill()
    }

    /// Invalidates the old and the new current-line rects.
    func updateCurrentLine() {
        let newRect = computeCurrentLineRect()
        if let currentLineRect { setNeedsDisplay(currentLineRect, avoidAdditionalLayout: true) }
        if let newRect { setNeedsDisplay(newRect, avoidAdditionalLayout: true) }
        currentLineRect = newRect
    }

    /// When editable with an empty selection: the union of the line fragment rects of the line holding the insertion
    /// point, or the extra line fragment rect for an empty last line, over the full width of the text view.
    private func computeCurrentLineRect() -> NSRect? {
        guard isEditable, let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let string = storage.mutableString
        let caret = min(selection.location, string.length)
        let lineRange = string.lineRange(for: NSRange(location: caret, length: 0))
        var rect = NSRect.null
        if lineRange.length == 0 {
            if string.length == 0 {
                layoutManager.ensureLayout(for: textContainer)
            } else {
                layoutManager.ensureLayout(forCharacterRange: NSRange(location: string.length - 1, length: 1))
            }
            rect = layoutManager.extraLineFragmentRect
        } else {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, _, _ in
                rect = rect.union(fragmentRect)
            }
        }
        guard !rect.isNull, rect.height > 0 else { return nil }
        return NSRect(x: 0, y: rect.minY + textContainerOrigin.y, width: bounds.width, height: rect.height)
    }
}
#endif
