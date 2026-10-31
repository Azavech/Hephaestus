import Foundation
import HephCore
import HephEditor
import Markdown

/// The block model of a Markdown source, built from its syntax tree: blocks, inline runs as `AttributedString`, image
/// references, the link table and the heading slugs.
struct MarkdownDocument {
    var blocks: [MarkdownBlock]
    /// The target of each active link, by the index its runs carry in their `heph-md-link:<index>` URL.
    var links: [MarkdownLinkTarget]

    static let empty = MarkdownDocument(blocks: [], links: [])

    /// Parses `source`: its front matter is left out, the body is parsed with smart punctuation disabled.
    @MainActor static func parse(_ source: String, basePath: String?) -> MarkdownDocument {
        let body = FrontMatter.body(of: source)
        let document = Document(parsing: String(body), options: [.disableSmartOpts])
        var builder = MarkdownDocumentBuilder(basePath: basePath)
        let blocks = builder.blocks(of: document.children, listDepth: 0)
        return MarkdownDocument(blocks: blocks, links: builder.links)
    }
}

enum MarkdownBlock {
    case heading(MarkdownHeading)
    /// A paragraph, or a text run of a paragraph split around its images.
    case paragraph(AttributedString)
    /// An image of a paragraph split around its images.
    case image(MarkdownImageReference)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    /// A code block, highlighted, or an HTML block.
    case code(MarkdownCodeBlock)
    case thematicBreak
    case table(MarkdownTable)

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }

    /// A table, an image or a thematic break: a run of its own when the selection reaches across blocks.
    var isOwnRun: Bool {
        switch self {
        case .table, .image, .thematicBreak: return true
        default: return false
        }
    }
}

struct MarkdownHeading {
    var level: Int
    var text: AttributedString
    var slug: String
}

struct MarkdownCodeBlock {
    /// The code highlighted for the block view.
    var text: AttributedString
    /// The code without its final line break.
    var code: String
    /// Nil for an HTML block, which is not highlighted.
    var language: EditorLanguage?
}

struct MarkdownImageReference {
    /// Nil when the source does not resolve or its target is not allowed: the failure view, nothing loaded.
    var target: MarkdownLinkTarget?
    var alt: String
    var source: String
    /// The index of the active link around the image, which makes it tappable.
    var linkIndex: Int?
}

struct MarkdownList {
    var isOrdered: Bool
    var startIndex: Int
    /// 1 for a top-level list.
    var depth: Int
    var items: [MarkdownListItem]
}

struct MarkdownListItem {
    /// Nil for an item that is not a task item.
    var isChecked: Bool?
    var blocks: [MarkdownBlock]
}

struct MarkdownTable {
    var columnCount: Int
    /// The alignment of each column.
    var alignments: [MarkdownColumnAlignment]
    var head: [MarkdownTableCell]
    var rows: [[MarkdownTableCell]]
}

enum MarkdownColumnAlignment {
    case leading, center, trailing
}

struct MarkdownTableCell {
    var text: AttributedString
    /// 0 for a cell covered by the one before it.
    var colspan: Int
    /// Covered by a cell of a row above (`rowspan == 0`): rendered empty.
    var isCoveredByRow: Bool

    static let empty = MarkdownTableCell(text: AttributedString(), colspan: 1, isCoveredByRow: false)
}

/// Converts the syntax tree to blocks; the inline conversion is in MarkdownInlines.swift.
@MainActor
struct MarkdownDocumentBuilder {
    let basePath: String?
    private(set) var links: [MarkdownLinkTarget] = []
    private var slugs = MarkdownSlug.Registry()

    init(basePath: String?) {
        self.basePath = basePath
    }

    mutating func blocks(of children: MarkupChildren, listDepth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for child in children {
            appendBlocks(of: child, listDepth: listDepth, to: &blocks)
        }
        return blocks
    }

    private mutating func appendBlocks(of markup: Markup, listDepth: Int, to blocks: inout [MarkdownBlock]) {
        switch markup {
        case let heading as Heading:
            let slug = slugs.unique(MarkdownSlug.slug(for: plainText(of: heading.children)))
            let text = inlineText(heading.children)
            blocks.append(.heading(MarkdownHeading(level: heading.level, text: text, slug: slug)))
        case let paragraph as Paragraph:
            blocks.append(contentsOf: paragraphBlocks(paragraph.children))
        case let quote as BlockQuote:
            blocks.append(.quote(self.blocks(of: quote.children, listDepth: listDepth)))
        case let list as UnorderedList:
            blocks.append(.list(makeList(list.listItems, isOrdered: false, startIndex: 1, depth: listDepth + 1)))
        case let list as OrderedList:
            let startIndex = Int(clamping: list.startIndex)
            let ordered = makeList(list.listItems, isOrdered: true, startIndex: startIndex, depth: listDepth + 1)
            blocks.append(.list(ordered))
        case let codeBlock as CodeBlock:
            let language = EditorLanguage(fenceInfo: codeBlock.language ?? "")
            let code = Self.removingFinalLineBreak(codeBlock.code)
            let text = SyntaxHighlighter.attributedString(code, language: language)
            blocks.append(.code(MarkdownCodeBlock(text: text, code: code, language: language)))
        case let html as HTMLBlock:
            let code = Self.removingFinalLineBreak(html.rawHTML)
            blocks.append(.code(MarkdownCodeBlock(text: AttributedString(code), code: code, language: nil)))
        case is ThematicBreak:
            blocks.append(.thematicBreak)
        case let table as Markdown.Table:
            blocks.append(.table(makeTable(table)))
        default:
            Log.markdown.debug("Skipped a \(String(describing: type(of: markup)), privacy: .public) block")
        }
    }

    private mutating func makeList(
        _ items: some Sequence<ListItem>, isOrdered: Bool, startIndex: Int, depth: Int
    ) -> MarkdownList {
        var listItems: [MarkdownListItem] = []
        for item in items {
            let isChecked = item.checkbox.map { $0 == .checked }
            let itemBlocks = blocks(of: item.children, listDepth: depth)
            listItems.append(MarkdownListItem(isChecked: isChecked, blocks: itemBlocks))
        }
        return MarkdownList(isOrdered: isOrdered, startIndex: startIndex, depth: depth, items: listItems)
    }

    private mutating func makeTable(_ table: Markdown.Table) -> MarkdownTable {
        let columnCount = table.maxColumnCount
        var alignments: [MarkdownColumnAlignment] = []
        for column in 0..<columnCount {
            let alignment = column < table.columnAlignments.count ? table.columnAlignments[column] : nil
            switch alignment {
            case .center?: alignments.append(.center)
            case .right?: alignments.append(.trailing)
            case .left?, nil: alignments.append(.leading)
            }
        }
        let head = makeRow(table.head.cells, columnCount: columnCount)
        var rows: [[MarkdownTableCell]] = []
        for row in table.body.rows {
            rows.append(makeRow(row.cells, columnCount: columnCount))
        }
        return MarkdownTable(columnCount: columnCount, alignments: alignments, head: head, rows: rows)
    }

    /// The cells of a row, completed with empty cells up to `columnCount`.
    private mutating func makeRow(
        _ cells: some Sequence<Markdown.Table.Cell>, columnCount: Int
    ) -> [MarkdownTableCell] {
        var row: [MarkdownTableCell] = []
        for cell in cells {
            row.append(MarkdownTableCell(
                text: inlineText(cell.children), colspan: Int(clamping: cell.colspan), isCoveredByRow: cell.rowspan == 0
            ))
        }
        while row.count < columnCount {
            row.append(.empty)
        }
        return row
    }

    /// The code of a block without its final line break.
    private static func removingFinalLineBreak(_ code: String) -> String {
        var scalars = code.unicodeScalars
        if scalars.last == "\n" {
            scalars.removeLast()
            if scalars.last == "\r" { scalars.removeLast() }
        }
        return String(scalars)
    }

    // MARK: Links

    /// The active target of a link destination or an image source: it resolves, and the target is allowed (any
    /// target with a base path; only `.external` without one).
    func allowedTarget(_ destination: String) -> MarkdownLinkTarget? {
        guard let target = MarkdownLinkTarget.resolve(destination, basePath: basePath ?? "") else { return nil }
        if basePath != nil { return target }
        if case .external = target { return target }
        return nil
    }

    /// Adds a target to the link table and returns its index.
    mutating func addLink(_ target: MarkdownLinkTarget) -> Int {
        links.append(target)
        return links.count - 1
    }
}
