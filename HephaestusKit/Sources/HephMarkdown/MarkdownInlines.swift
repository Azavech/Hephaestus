import Foundation
import Markdown
import SwiftUI

/// The inlines of a paragraph, a heading or a table cell become one `AttributedString` shown by a `SwiftUI.Text`.
extension MarkdownDocumentBuilder {
    /// The inlines of a heading or a table cell; an image renders as its alt text.
    mutating func inlineText(_ children: MarkupChildren) -> AttributedString {
        var output = InlineOutput(splitsImages: false)
        appendInlines(children, style: InlineStyle(), to: &output)
        return output.text
    }

    /// The blocks of a paragraph: one text without images; otherwise, in source order, its text runs and its images,
    /// text runs made only of white space dropped.
    mutating func paragraphBlocks(_ children: MarkupChildren) -> [MarkdownBlock] {
        var output = InlineOutput(splitsImages: true)
        appendInlines(children, style: InlineStyle(), to: &output)
        guard output.hasImages else { return [.paragraph(output.text)] }
        output.flushText()
        return output.blocks.filter { block in
            guard case .paragraph(let text) = block else { return true }
            return !text.characters.allSatisfy(\.isWhitespace)
        }
    }

    /// The text of inline children without markup, code spans included: heading slugs and image alt texts.
    func plainText(of children: MarkupChildren) -> String {
        var text = ""
        for child in children {
            switch child {
            case let node as Markdown.Text: text += node.string
            case let code as InlineCode: text += code.code
            case is SoftBreak: text += " "
            case is LineBreak: text += "\n"
            case is InlineHTML: continue
            default: text += plainText(of: child.children)
            }
        }
        return text
    }

    private mutating func appendInlines(_ children: MarkupChildren, style: InlineStyle, to output: inout InlineOutput) {
        for child in children {
            appendInline(child, style: style, to: &output)
        }
    }

    private mutating func appendInline(_ markup: Markup, style: InlineStyle, to output: inout InlineOutput) {
        switch markup {
        case let text as Markdown.Text:
            if style.isInsideLink {
                output.append(Self.run(text.string, style: style))
            } else {
                appendAutolinked(text.string, style: style, to: &output)
            }
        case let emphasis as Emphasis:
            appendInlines(emphasis.children, style: style.adding(.emphasized), to: &output)
        case let strong as Strong:
            appendInlines(strong.children, style: style.adding(.stronglyEmphasized), to: &output)
        case let strikethrough as Strikethrough:
            appendInlines(strikethrough.children, style: style.adding(.strikethrough), to: &output)
        case let code as InlineCode:
            output.append(Self.codeRun(code.code, style: style))
        case let html as InlineHTML:
            output.append(Self.codeRun(html.rawHTML, style: style))
        case let link as Markdown.Link:
            var linkStyle = style
            linkStyle.isInsideLink = true
            if let target = allowedTarget(link.destination ?? "") {
                linkStyle.linkIndex = addLink(target)
            }
            appendInlines(link.children, style: linkStyle, to: &output)
        case let image as Markdown.Image:
            let alt = plainText(of: image.children)
            if output.splitsImages {
                let source = image.source ?? ""
                output.appendImage(MarkdownImageReference(
                    target: allowedTarget(source), alt: alt, source: source, linkIndex: style.linkIndex
                ))
            } else {
                output.append(Self.run(alt, style: style))
            }
        case is SoftBreak:
            output.append(Self.run(" ", style: style))
        case is LineBreak:
            output.append(Self.run("\n", style: style))
        default:
            // InlineAttributes and any other node: its children.
            appendInlines(markup.children, style: style, to: &output)
        }
    }

    /// A text outside links: its bare URLs become `.external` links.
    private mutating func appendAutolinked(_ string: String, style: InlineStyle, to output: inout InlineOutput) {
        let scalars = Array(string.unicodeScalars)
        var position = 0
        for range in Autolinker.urlRanges(in: scalars) {
            if range.lowerBound > position {
                output.append(Self.run(Self.string(scalars[position..<range.lowerBound]), style: style))
            }
            let urlString = Self.string(scalars[range])
            var urlStyle = style
            if let url = URL(string: urlString) {
                urlStyle.linkIndex = addLink(.external(url))
            }
            output.append(Self.run(urlString, style: urlStyle))
            position = range.upperBound
        }
        if position < scalars.count {
            output.append(Self.run(Self.string(scalars[position...]), style: style))
        }
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// A run with the presentation intents and the link of `style`.
    private static func run(_ string: String, style: InlineStyle) -> AttributedString {
        var run = AttributedString(string)
        if !style.intents.isEmpty {
            run.inlinePresentationIntent = style.intents
        }
        if let index = style.linkIndex, let url = URL(string: "heph-md-link:\(index)") {
            run.link = url
        }
        return run
    }

    /// A code span or inline HTML: monospaced, on a light background.
    private static func codeRun(_ string: String, style: InlineStyle) -> AttributedString {
        var run = run(string, style: style.adding(.code))
        run.swiftUI.backgroundColor = Color.secondary.opacity(0.15)
        return run
    }
}

/// The attributes inherited by nested inline nodes.
struct InlineStyle {
    /// The union of the presentation intents of the enclosing nodes.
    var intents: InlinePresentationIntent = []
    /// The link table index of the enclosing active link.
    var linkIndex: Int?
    /// Inside a `Link` node, active or not: no autolinks.
    var isInsideLink = false

    func adding(_ intent: InlinePresentationIntent) -> InlineStyle {
        var style = self
        style.intents.formUnion(intent)
        return style
    }
}

/// The text being built, and, for a paragraph split around its images, the blocks already complete.
struct InlineOutput {
    let splitsImages: Bool
    var text = AttributedString()
    var blocks: [MarkdownBlock] = []
    var hasImages = false

    init(splitsImages: Bool) {
        self.splitsImages = splitsImages
    }

    mutating func append(_ run: AttributedString) {
        text.append(run)
    }

    mutating func appendImage(_ image: MarkdownImageReference) {
        flushText()
        blocks.append(.image(image))
        hasImages = true
    }

    mutating func flushText() {
        guard !text.characters.isEmpty else { return }
        blocks.append(.paragraph(text))
        text = AttributedString()
    }
}
