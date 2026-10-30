#if os(iOS)
import UIKit

/// The line number gutter of the iOS and iPadOS editor: a subview of the text view, pinned to its visible area by
/// `EditorUITextView.layoutSubviews()`.
final class LineNumberGutterView: UIView {
    weak var textView: EditorUITextView?

    override func draw(_ rect: CGRect) {
        EditorTheme.background.setFill()
        UIRectFill(bounds)
        EditorTheme.gutterSeparator.setFill()
        UIRectFill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height))

        guard let textView else { return }
        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        let string = textView.textStorage.mutableString
        let lineIndex = textView.lineIndex
        let inset = textView.textContainerInset
        let offset = textView.contentOffset
        let currentLine = lineIndex.lineNumber(at: textView.selectedRange.location)
        // The visible rect in text container coordinates.
        let visibleRect = CGRect(
            x: 0, y: offset.y - inset.top, width: textContainer.size.width, height: textView.bounds.height
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, fragmentGlyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            // Wrapped continuation fragments get no number.
            guard characterIndex == 0
                || (characterIndex <= string.length && string.character(at: characterIndex - 1) == 0x0A) else { return }
            let number = lineIndex.lineNumber(at: characterIndex)
            self.drawNumber(
                number, fragmentRect: fragmentRect, inset: inset, offset: offset, isCurrent: number == currentLine
            )
        }
        // The extra line fragment (empty text, or text ending with a line break).
        let extraRect = layoutManager.extraLineFragmentRect
        if layoutManager.extraLineFragmentTextContainer != nil, extraRect.height > 0 {
            let number = lineIndex.lineCount
            drawNumber(number, fragmentRect: extraRect, inset: inset, offset: offset, isCurrent: number == currentLine)
        }
    }

    /// Draws `number` right-aligned with 5 pt of right padding, vertically centered in the fragment; a fragment's y in
    /// gutter coordinates is `fragment.minY + textContainerInset.top − contentOffset.y`.
    private func drawNumber(
        _ number: Int, fragmentRect: CGRect, inset: UIEdgeInsets, offset: CGPoint, isCurrent: Bool
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CodeEditorView.gutterFont,
            .foregroundColor: isCurrent ? EditorTheme.gutterCurrentText : EditorTheme.gutterText,
        ]
        let label = String(number) as NSString
        let size = label.size(withAttributes: attributes)
        let y = fragmentRect.minY + inset.top - offset.y
        let point = CGPoint(x: bounds.width - 5 - size.width, y: y + (fragmentRect.height - size.height) / 2)
        label.draw(at: point, withAttributes: attributes)
    }
}
#endif
