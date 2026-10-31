#if os(macOS)
import AppKit
#else
import UIKit
#endif
import HephEditor
import SwiftUI

/// Converts the blocks of a text run into one attributed string, for a selection that reaches across blocks. Every
/// block is one or more paragraphs joined by `\n`, and blocks are joined by `\n`; the space before a block is the
/// `paragraphSpacingBefore` of its first paragraph.
@MainActor
struct MarkdownFlowText {
    #if os(macOS)
    typealias PlatformFont = NSFont
    typealias PlatformColor = NSColor
    #else
    typealias PlatformFont = UIFont
    typealias PlatformColor = UIColor
    #endif

    /// The attributed string of the blocks of a text run.
    static func attributedString(of blocks: [MarkdownBlock]) -> NSAttributedString {
        var builder = MarkdownFlowText()
        builder.appendBlocks(blocks, layout: Layout(), firstSpacing: 0)
        return builder.output
    }

    /// The indent and the color of the blocks being converted.
    private struct Layout {
        var indent: CGFloat = 0
        var isSecondary = false
        /// Inside a list item or a quote: blocks 6 pt apart.
        var isNested = false
    }

    /// A list marker that the next paragraph starts with, and the indents of its item.
    private struct PendingMarker {
        var text: NSAttributedString
        /// The indent of the list.
        var outerIndent: CGFloat
        /// The indent of the item's text.
        var itemIndent: CGFloat
    }

    private let output = NSMutableAttributedString()
    private var pendingMarkers: [PendingMarker] = []

    // MARK: Blocks

    private mutating func appendBlocks(_ blocks: [MarkdownBlock], layout: Layout, firstSpacing: CGFloat) {
        for index in blocks.indices {
            let spacing: CGFloat
            if index == 0 {
                spacing = firstSpacing
            } else if layout.isNested {
                spacing = 6
            } else {
                spacing = blocks[index].isHeading ? 20 : 12
            }
            appendBlock(blocks[index], layout: layout, spacing: spacing)
        }
    }

    private mutating func appendBlock(_ block: MarkdownBlock, layout: Layout, spacing: CGFloat) {
        switch block {
        case .heading(let heading):
            let isSecondary = layout.isSecondary || heading.level == 6
            let font = Self.headingFont(level: heading.level)
            let text = Self.inlineText(heading.text, font: font, color: Self.color(isSecondary: isSecondary))
            appendParagraphs(text, indent: layout.indent, spacing: spacing)
        case .paragraph(let inlines):
            let font = PlatformFont.preferredFont(forTextStyle: .body)
            let text = Self.inlineText(inlines, font: font, color: Self.color(isSecondary: layout.isSecondary))
            appendParagraphs(text, indent: layout.indent, spacing: spacing)
        case .quote(let blocks):
            var quoteLayout = layout
            quoteLayout.indent += 12
            quoteLayout.isSecondary = true
            quoteLayout.isNested = true
            appendBlocks(blocks, layout: quoteLayout, firstSpacing: spacing)
        case .list(let list):
            appendList(list, layout: layout, spacing: spacing)
        case .code(let code):
            appendParagraphs(Self.codeText(code, layout: layout), indent: layout.indent + 12, spacing: spacing)
        case .image, .thematicBreak, .table:
            // Runs of their own; never part of a text run.
            break
        }
    }

    /// Each item is `\t<marker>\t` and its first block, indented 26 pt from the list (the 20 pt marker column and
    /// 6 pt); its other blocks are indented by the same amount. Items are 4 pt apart.
    private mutating func appendList(_ list: MarkdownList, layout: Layout, spacing: CGFloat) {
        for index in list.items.indices {
            let item = list.items[index]
            var itemLayout = layout
            itemLayout.indent = layout.indent + 26
            itemLayout.isNested = true
            pendingMarkers.append(PendingMarker(
                text: Self.marker(of: list, at: index),
                outerIndent: layout.indent,
                itemIndent: itemLayout.indent
            ))
            let itemSpacing = index == 0 ? spacing : 4
            if item.blocks.isEmpty {
                appendParagraphs(NSAttributedString(), indent: itemLayout.indent, spacing: itemSpacing)
            } else {
                appendBlocks(item.blocks, layout: itemLayout, firstSpacing: itemSpacing)
            }
        }
    }

    /// Appends the paragraphs of a block (its text split at `\n`): the first one has `spacing` before it, the others
    /// none; every paragraph is indented by `indent`. Pending list markers start the first paragraph, which then
    /// starts at the indent of the outermost list and gets the tab stops of the markers.
    private mutating func appendParagraphs(_ text: NSAttributedString, indent: CGFloat, spacing: CGFloat) {
        if output.length > 0 {
            var attributes = output.attributes(at: output.length - 1, effectiveRange: nil)
            attributes[.link] = nil
            output.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        let start = output.length
        let markers = pendingMarkers
        pendingMarkers = []
        for marker in markers {
            output.append(marker.text)
        }
        output.append(text)
        let blockRange = NSRange(location: start, length: output.length - start)

        let output = self.output
        let string = output.string as NSString
        var isFirst = true
        string.enumerateSubstrings(in: blockRange, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            if isFirst {
                style.paragraphSpacingBefore = spacing
                if let first = markers.first {
                    style.firstLineHeadIndent = first.outerIndent
                    var stops: [NSTextTab] = []
                    for marker in markers {
                        stops.append(NSTextTab(textAlignment: .right, location: marker.itemIndent - 6))
                        stops.append(NSTextTab(textAlignment: .left, location: marker.itemIndent))
                    }
                    style.tabStops = stops
                }
            }
            isFirst = false
            output.addAttribute(.paragraphStyle, value: style, range: enclosing)
        }
    }

    // MARK: Markers

    /// The bullet or number in the secondary color, or a task box: `☑` in the accent color, `☐` secondary.
    private static func marker(of list: MarkdownList, at index: Int) -> NSAttributedString {
        let body = PlatformFont.preferredFont(forTextStyle: .body)
        let marker: String
        var font = body
        var color = secondaryColor
        if let isChecked = list.items[index].isChecked {
            marker = isChecked ? "☑" : "☐"
            if isChecked { color = accentColor }
        } else if list.isOrdered {
            marker = "\(list.startIndex + index)."
            font = PlatformFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
        } else {
            switch list.depth {
            case ...1: marker = "•"
            case 2: marker = "◦"
            default: marker = "▪"
            }
        }
        return NSAttributedString(string: "\t\(marker)\t", attributes: [.font: font, .foregroundColor: color])
    }

    // MARK: Inlines

    /// The runs of inline text: `.emphasized` adds the italic trait, `.stronglyEmphasized` the bold trait, `.code`
    /// gives the monospaced system font at the size of `font`, `.strikethrough` a single strikethrough; inline code
    /// keeps a background, and links keep their `heph-md-link` URL.
    private static func inlineText(_ text: AttributedString, font: PlatformFont, color: PlatformColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            let intents = run.inlinePresentationIntent ?? []
            var runFont = font
            if intents.contains(.code) {
                runFont = PlatformFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            }
            runFont = withTraits(
                runFont,
                bold: intents.contains(.stronglyEmphasized) || isBold(font),
                italic: intents.contains(.emphasized)
            )
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if intents.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.swiftUI.backgroundColor != nil {
                attributes[.backgroundColor] = secondaryColor.withAlphaComponent(0.15)
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    /// A code or HTML block: one paragraph per line in the monospaced system font at the `.callout` size, colored by
    /// its tokens (none for HTML), on a background.
    private static func codeText(_ code: MarkdownCodeBlock, layout: Layout) -> NSAttributedString {
        let size = PlatformFont.preferredFont(forTextStyle: .callout).pointSize
        let text = NSMutableAttributedString(string: code.code, attributes: [
            .font: PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: color(isSecondary: layout.isSecondary),
            .backgroundColor: secondaryColor.withAlphaComponent(0.08),
        ])
        if let language = code.language {
            for token in SyntaxHighlighter.tokens(in: code.code, language: language) {
                text.addAttribute(.foregroundColor, value: EditorTheme.color(for: token.kind), range: token.range)
            }
        }
        return text
    }

    // MARK: Fonts and colors

    /// The font of a heading level, bold except at level 4.
    private static func headingFont(level: Int) -> PlatformFont {
        let style: PlatformFont.TextStyle
        switch level {
        case 1: style = .title1
        case 2: style = .title2
        case 3: style = .title3
        case 4: style = .headline
        default: style = .subheadline
        }
        let font = PlatformFont.preferredFont(forTextStyle: style)
        return level == 4 ? font : withTraits(font, bold: true, italic: false)
    }

    private static func isBold(_ font: PlatformFont) -> Bool {
        #if os(macOS)
        return font.fontDescriptor.symbolicTraits.contains(.bold)
        #else
        return font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    /// `font` with the bold and italic traits added when asked; the font itself when the system has no such face.
    private static func withTraits(_ font: PlatformFont, bold: Bool, italic: Bool) -> PlatformFont {
        guard bold || italic else { return font }
        #if os(macOS)
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    private static func color(isSecondary: Bool) -> PlatformColor {
        isSecondary ? secondaryColor : labelColor
    }

    #if os(macOS)
    private static var labelColor: PlatformColor { .labelColor }
    private static var secondaryColor: PlatformColor { .secondaryLabelColor }
    private static var accentColor: PlatformColor { .controlAccentColor }
    #else
    private static var labelColor: PlatformColor { .label }
    private static var secondaryColor: PlatformColor { .secondaryLabel }
    private static var accentColor: PlatformColor { .tintColor }
    #endif
}
