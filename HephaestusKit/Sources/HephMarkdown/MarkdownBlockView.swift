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
        case .code(let text):
            MarkdownCodeBlockView(text: text)
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
