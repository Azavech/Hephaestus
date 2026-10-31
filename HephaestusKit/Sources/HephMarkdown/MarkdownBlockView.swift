import SwiftUI

/// The blocks of a document, a quote or a list item. In a document, blocks are 12 pt apart and a heading 20 pt from
/// the block before it; inside a list item or a quote, blocks are 6 pt apart.
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    /// Inside a list item or a quote.
    let isNested: Bool
    let context: MarkdownRenderContext

    var body: some View {
        if isNested {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(blocks.indices, id: \.self) { index in
                    MarkdownBlockView(block: blocks[index], context: context)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks.indices, id: \.self) { index in
                    MarkdownBlockView(block: blocks[index], context: context)
                        .padding(.top, spacing(before: index))
                }
            }
        }
    }

    private func spacing(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return blocks[index].isHeading ? 20 : 12
    }
}

/// The blocks of a document grouped into runs, for a selection that reaches across blocks: each table, image and
/// thematic break is a run of its own, shown by its block view; every maximal sequence of other blocks is one text
/// view. Runs are spaced like blocks.
struct MarkdownRunsView: View {
    let blocks: [MarkdownBlock]
    let context: MarkdownRenderContext

    var body: some View {
        let runs = Self.runs(of: blocks)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(runs.indices, id: \.self) { index in
                run(runs[index])
                    .padding(.top, spacing(before: runs[index], isFirst: index == 0))
            }
        }
    }

    @ViewBuilder
    private func run(_ run: Range<Int>) -> some View {
        let first = blocks[run.lowerBound]
        if first.isOwnRun {
            MarkdownBlockView(block: first, context: context)
        } else {
            MarkdownTextRunView(blocks: Array(blocks[run]))
        }
    }

    private func spacing(before run: Range<Int>, isFirst: Bool) -> CGFloat {
        guard !isFirst else { return 0 }
        return blocks[run.lowerBound].isHeading ? 20 : 12
    }

    /// The index ranges of the runs, in order.
    static func runs(of blocks: [MarkdownBlock]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in blocks.indices {
            if blocks[index].isOwnRun {
                if let textStart = start {
                    runs.append(textStart..<index)
                    start = nil
                }
                runs.append(index..<(index + 1))
            } else if start == nil {
                start = index
            }
        }
        if let textStart = start {
            runs.append(textStart..<blocks.count)
        }
        return runs
    }
}

/// A text run: one selectable text view of the blocks' attributed string, built again when the Dynamic Type size or
/// the color scheme changes.
struct MarkdownTextRunView: View {
    let blocks: [MarkdownBlock]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Reading both values makes a change of either one build the string again.
        let _ = (dynamicTypeSize, colorScheme)
        MarkdownTextView(text: MarkdownFlowText.attributedString(of: blocks))
    }
}

/// One block.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let context: MarkdownRenderContext

    var body: some View {
        switch block {
        case .heading(let heading):
            MarkdownHeadingView(heading: heading)
        case .paragraph(let text):
            Text(text)
                .font(.body)
        case .image(let image):
            MarkdownImageView(image: image, context: context)
        case .quote(let blocks):
            MarkdownBlocksView(blocks: blocks, isNested: true, context: context)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 3)
                }
        case .list(let list):
            MarkdownListView(list: list, context: context)
        case .code(let code):
            MarkdownCodeBlockView(text: code.text)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        case .table(let table):
            MarkdownTableView(table: table)
        }
    }
}

/// A heading: its font by level; levels 1 and 2 are followed by a divider, 6 pt below.
struct MarkdownHeadingView: View {
    let heading: MarkdownHeading

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if heading.level == 6 {
                title.foregroundStyle(.secondary)
            } else {
                title
            }
            if heading.level <= 2 {
                Divider()
            }
        }
        .id(MarkdownAnchor(slug: heading.slug))
    }

    private var title: some View {
        Text(heading.text)
            .font(font)
            .bold(isBold)
            .accessibilityAddTraits(.isHeader)
    }

    private var font: Font {
        switch heading.level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        default: return .subheadline
        }
    }

    private var isBold: Bool {
        heading.level != 4
    }
}
