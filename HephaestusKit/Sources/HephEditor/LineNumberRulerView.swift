#if os(macOS)
import AppKit

/// The line number gutter of the macOS editor: the vertical ruler of its scroll view, whose client view is the
/// `EditorNSTextView`.
final class LineNumberRulerView: NSRulerView {
    /// Sets `ruleThickness` to the gutter width of the client's line count.
    func updateThickness() {
        guard let textView = clientView as? EditorNSTextView else { return }
        let width = CodeEditorView.gutterWidth(lineCount: textView.lineIndex.lineCount)
        if ruleThickness != width {
            ruleThickness = width
        }
    }

    /// Redraws when the clip view scrolls and when the text view's frame changes.
    @objc func clientViewDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorTheme.background.setFill()
        rect.fill()
        EditorTheme.gutterSeparator.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        guard let textView = clientView as? EditorNSTextView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer, let storage = textView.textStorage else { return }
        let string = storage.mutableString
        let lineIndex = textView.lineIndex
        let origin = textView.textContainerOrigin
        let currentLine = lineIndex.lineNumber(at: textView.selectedRange().location)
        let visibleRect = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragmentGlyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            // Wrapped continuation fragments get no number.
            guard characterIndex == 0
                || (characterIndex <= string.length && string.character(at: characterIndex - 1) == 0x0A) else { return }
            let number = lineIndex.lineNumber(at: characterIndex)
            self.drawNumber(number, in: fragmentRect, of: textView, isCurrent: number == currentLine)
        }
        // The extra line fragment (empty text, or text ending with a line break).
        let extraRect = layoutManager.extraLineFragmentRect
        if layoutManager.extraLineFragmentTextContainer != nil, extraRect.height > 0 {
            let number = lineIndex.lineCount
            drawNumber(number, in: extraRect, of: textView, isCurrent: number == currentLine)
        }
    }

    /// Draws `number` right-aligned with 5 pt of right padding, vertically centered in a line fragment rect given in
    /// text container coordinates.
    private func drawNumber(_ number: Int, in fragmentRect: NSRect, of textView: EditorNSTextView, isCurrent: Bool) {
        let origin = textView.textContainerOrigin
        let rect = convert(fragmentRect.offsetBy(dx: origin.x, dy: origin.y), from: textView)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CodeEditorView.gutterFont,
            .foregroundColor: isCurrent ? EditorTheme.gutterCurrentText : EditorTheme.gutterText,
        ]
        let label = String(number) as NSString
        let size = label.size(withAttributes: attributes)
        let point = NSPoint(x: bounds.width - 5 - size.width, y: rect.minY + (rect.height - size.height) / 2)
        label.draw(at: point, withAttributes: attributes)
    }
}
#endif
