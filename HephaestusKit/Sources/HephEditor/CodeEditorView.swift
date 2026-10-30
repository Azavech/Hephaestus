import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A code editor for one text: line numbers, current-line highlight, auto-indent, find, syntax highlighting.
public struct CodeEditorView: View {
    private let text: Binding<String>
    private let language: EditorLanguage
    private let isEditable: Bool
    private let selection: Binding<NSRange>?
    private let proxy: CodeEditorProxy?
    private let onChange: (@MainActor (String) -> Void)?

    /// - Parameters:
    ///   - text: Set to the full new text after every user edit. A value that comes in from outside replaces the text
    ///     and is never written back.
    ///   - isEditable: When false, the text can be selected and copied, not changed.
    ///   - selection: Selected when the editor is created and whenever it takes a value from outside; set after every
    ///     selection change.
    ///   - proxy: Gets the editor's text view registered.
    ///   - onChange: Called with the new text after every user edit.
    public init(
        text: Binding<String>,
        language: EditorLanguage,
        isEditable: Bool = true,
        selection: Binding<NSRange>? = nil,
        proxy: CodeEditorProxy? = nil,
        onChange: (@MainActor (String) -> Void)? = nil
    ) {
        self.text = text
        self.language = language
        self.isEditable = isEditable
        self.selection = selection
        self.proxy = proxy
        self.onChange = onChange
    }

    public var body: some View {
        #if os(macOS)
        MacEditorView(
            text: text, language: language, isEditable: isEditable, selection: selection, proxy: proxy,
            onChange: onChange
        )
        #else
        IOSEditorView(
            text: text, language: language, isEditable: isEditable, selection: selection, proxy: proxy,
            onChange: onChange
        )
        #endif
    }
}

/// What both platforms' text views share.
extension CodeEditorView {
    /// The font, the plain color and the paragraph style: the attributes of text set through the binding, and the
    /// typing attributes after every selection change.
    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: EditorTheme.font(for: nil),
        .foregroundColor: EditorTheme.color(for: nil),
        .paragraphStyle: paragraphStyle,
    ]

    /// No tab stops; the default tab interval is 4 × the advance of a space in the font.
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: EditorTheme.font(for: nil)]).width
        style.defaultTabInterval = 4 * spaceWidth
        return style
    }()

    /// `range` clamped to a text of `length` UTF-16 units.
    static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let rangeLength = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: rangeLength)
    }

    /// The indentation of the line holding `location`: its leading spaces and tabs, from the line start up to
    /// `location`.
    static func indentation(of string: NSString, at location: Int, lineIndex: LineIndex) -> String {
        let lineNumber = lineIndex.lineNumber(at: location)
        let lineStarts = lineIndex.lineStarts
        let lineStart = lineNumber - 1 < lineStarts.count ? min(lineStarts[lineNumber - 1], location) : location
        var end = lineStart
        while end < location, end < string.length {
            let unit = string.character(at: end)
            guard unit == 0x20 || unit == 0x09 else { break }
            end += 1
        }
        return string.substring(with: NSRange(location: lineStart, length: end - lineStart))
    }

    /// The width of the line number gutter: `max(3, digits of lineCount)` × the advance of `"8"` + 10 pt.
    static func gutterWidth(lineCount: Int) -> CGFloat {
        CGFloat(max(3, String(lineCount).count)) * digitWidth + 10
    }

    /// `monospacedDigitSystemFont(ofSize: 11, weight: .regular)`.
    static let gutterFont = EditorTheme.PlatformFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private static let digitWidth = ("8" as NSString).size(withAttributes: [.font: gutterFont]).width
}
