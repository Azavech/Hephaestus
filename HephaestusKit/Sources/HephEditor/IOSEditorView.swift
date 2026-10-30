#if os(iOS)
import SwiftUI
import UIKit

/// The iOS and iPadOS editor: an `EditorUITextView` (TextKit 1) with a `LineNumberGutterView`.
struct IOSEditorView: UIViewRepresentable {
    let text: Binding<String>
    let language: EditorLanguage
    let isEditable: Bool
    let selection: Binding<NSRange>?
    let proxy: CodeEditorProxy?
    let onChange: (@MainActor (String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> EditorUITextView {
        context.coordinator.textView
    }

    func updateUIView(_ textView: EditorUITextView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ textView: EditorUITextView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, NSTextStorageDelegate {
        private var parent: IOSEditorView
        let textView: EditorUITextView
        private let controller: EditorController
        /// The last string written to the binding or accepted from it.
        private var lastText = ""
        /// True while SwiftUI updates the view: binding writes then wait for the next main-actor turn.
        private var isUpdating = false
        /// True while the whole text is replaced: the line index is rebuilt afterwards.
        private var isReplacingText = false
        private var isSelectionWriteScheduled = false

        init(_ parent: IOSEditorView) {
            self.parent = parent
            let textView = EditorUITextView(usingTextLayoutManager: false)
            self.textView = textView
            controller = EditorController(textStorage: textView.textStorage, language: parent.language)
            super.init()
            controller.hasMarkedText = { [weak textView] in textView?.markedTextRange != nil }
            configureTextView()
            isUpdating = true
            textView.delegate = self
            textView.textStorage.delegate = self
            setInitialText()
            parent.proxy?.register(textView)
            isUpdating = false
        }

        private func configureTextView() {
            let plain = EditorTheme.color(for: nil)
            textView.font = EditorTheme.font(for: nil)
            textView.textColor = plain
            textView.tintColor = plain
            textView.backgroundColor = EditorTheme.background
            textView.allowsEditingTextAttributes = false
            textView.autocorrectionType = .no
            textView.autocapitalizationType = .none
            textView.spellCheckingType = .no
            textView.smartQuotesType = .no
            textView.smartDashesType = .no
            textView.smartInsertDeleteType = .no
            textView.inlinePredictionType = .no
            textView.writingToolsBehavior = .none
            textView.dataDetectorTypes = []
            textView.isFindInteractionEnabled = true
            textView.alwaysBounceVertical = true
            textView.keyboardDismissMode = .interactive
            textView.isEditable = parent.isEditable
            textView.isSelectable = true
            textView.typingAttributes = CodeEditorView.baseAttributes
            textView.indentUnit = parent.language.indentUnit

            textView.currentLineView.backgroundColor = EditorTheme.currentLine
            textView.insertSubview(textView.currentLineView, at: 0)
            textView.gutter.textView = textView
            textView.gutter.isUserInteractionEnabled = false
            textView.gutter.contentMode = .redraw
            textView.addSubview(textView.gutter)
            let gutterWidth = CodeEditorView.gutterWidth(lineCount: textView.lineIndex.lineCount)
            textView.gutterWidth = gutterWidth
            textView.textContainerInset = UIEdgeInsets(top: 6, left: gutterWidth + 4, bottom: 6, right: 4)
        }

        /// The text the editor is created with: selected range from the binding, scrolled into view on the next
        /// main-actor turn, once SwiftUI has given the text view its size.
        private func setInitialText() {
            setText(parent.text.wrappedValue)
            guard let selection = parent.selection else { return }
            textView.selectedRange = CodeEditorView.clamp(selection.wrappedValue, toLength: textView.textStorage.length)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.textView.scrollRangeToVisible(self.textView.selectedRange)
            }
        }

        func update(_ view: IOSEditorView) {
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
            if let selection = view.selection {
                let range = CodeEditorView.clamp(selection.wrappedValue, toLength: textView.textStorage.length)
                if range != textView.selectedRange {
                    textView.selectedRange = range
                    textView.scrollRangeToVisible(range)
                }
            }
        }

        func dismantle() {
            controller.stop()
        }

        // MARK: Text synchronization

        /// A text that came in through the binding replaces the text, keeping the selection and the scroll offset.
        private func replaceText(with newText: String) {
            let selectedRange = textView.selectedRange
            let contentOffset = textView.contentOffset
            isReplacingText = true
            textView.textStorage.setAttributedString(
                NSAttributedString(string: newText, attributes: CodeEditorView.baseAttributes)
            )
            isReplacingText = false
            // The undo actions refer to the old text.
            textView.undoManager?.removeAllActions()
            textView.selectedRange = CodeEditorView.clamp(selectedRange, toLength: textView.textStorage.length)
            restoreContentOffset(contentOffset)
            didSetText(newText)
        }

        private func setText(_ newText: String) {
            isReplacingText = true
            textView.textStorage.setAttributedString(
                NSAttributedString(string: newText, attributes: CodeEditorView.baseAttributes)
            )
            isReplacingText = false
            didSetText(newText)
        }

        private func didSetText(_ newText: String) {
            lastText = newText
            textView.lineIndex.rebuild(textView.textStorage.mutableString)
            controller.textWasReplaced()
            textView.lineIndexDidChange()
        }

        /// Scrolls back to `offset`, clamped to the content.
        private func restoreContentOffset(_ offset: CGPoint) {
            let insets = textView.adjustedContentInset
            let minimumY = -insets.top
            let maximumY = max(minimumY, textView.contentSize.height + insets.bottom - textView.bounds.height)
            textView.contentOffset = CGPoint(x: offset.x, y: min(max(offset.y, minimumY), maximumY))
        }

        func textViewDidChange(_ textView: UITextView) {
            let newText = self.textView.textStorage.string
            lastText = newText
            parent.text.wrappedValue = newText
            parent.onChange?(newText)
            controller.textWasEdited()
            self.textView.lineIndexDidChange()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Typed text never takes the color of the token next to it.
            self.textView.typingAttributes = CodeEditorView.baseAttributes
            self.textView.updateCurrentLine()
            self.textView.gutter.setNeedsDisplay()
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
            let range = textView.selectedRange
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
            _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
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

/// The text view of the iOS and iPadOS editor. It declares no designated initializer: it is created with
/// `init(usingTextLayoutManager: false)` and runs on TextKit 1.
final class EditorUITextView: UITextView {
    /// The line number gutter, pinned to the visible area.
    let gutter = LineNumberGutterView()
    /// The current-line highlight, behind the text.
    let currentLineView = UIView()
    /// The line starts of the text, kept by the coordinator.
    var lineIndex = LineIndex()
    /// What Tab inserts.
    var indentUnit = "    "
    var gutterWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: gutterWidth, height: bounds.height)
        bringSubviewToFront(gutter)
        gutter.setNeedsDisplay()
        updateCurrentLine()
    }

    /// Return inserts a line break followed by the indentation of the current line; Tab inserts the indent unit.
    override func insertText(_ text: String) {
        if text == "\n" {
            let indentation = CodeEditorView.indentation(
                of: textStorage.mutableString, at: selectedRange.location, lineIndex: lineIndex
            )
            super.insertText("\n" + indentation)
        } else if text == "\t" {
            super.insertText(indentUnit)
        } else {
            super.insertText(text)
        }
    }

    /// After a text change: the gutter width (and the left inset with it), the gutter and the current line.
    func lineIndexDidChange() {
        let width = CodeEditorView.gutterWidth(lineCount: lineIndex.lineCount)
        if width != gutterWidth {
            gutterWidth = width
            textContainerInset.left = width + 4
            setNeedsLayout()
        }
        gutter.setNeedsDisplay()
        updateCurrentLine()
    }

    /// Places the current-line view on the line holding the insertion point, or hides it.
    func updateCurrentLine() {
        guard let rect = currentLineRect() else {
            currentLineView.isHidden = true
            return
        }
        currentLineView.isHidden = false
        currentLineView.frame = rect
    }

    /// When editable with an empty selection: the union of the line fragment rects of the line holding the insertion
    /// point, or the extra line fragment rect for an empty last line, over the full width of the text view.
    private func currentLineRect() -> CGRect? {
        let selection = selectedRange
        guard isEditable, selection.length == 0 else { return nil }
        let string = textStorage.mutableString
        let caret = min(selection.location, string.length)
        let lineRange = string.lineRange(for: NSRange(location: caret, length: 0))
        var rect = CGRect.null
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
        return CGRect(x: 0, y: rect.minY + textContainerInset.top, width: bounds.width, height: rect.height)
    }
}
#endif
