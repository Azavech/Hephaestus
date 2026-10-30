import SwiftUI

/// An ordered or unordered list: each item is its marker and the blocks of the item; items are 4 pt apart.
struct MarkdownListView: View {
    let list: MarkdownList
    let context: MarkdownRenderContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list.items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(index)
                    MarkdownBlocksView(blocks: list.items[index].blocks, isNested: true, context: context)
                }
            }
        }
    }

    /// A task box (it cannot be toggled), the number of an ordered item, or the bullet of the nesting depth.
    @ViewBuilder
    private func marker(_ index: Int) -> some View {
        if let isChecked = list.items[index].isChecked {
            column {
                if isChecked {
                    Image(systemName: "checkmark.square.fill")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "square")
                        .foregroundStyle(.secondary)
                }
            }
        } else if list.isOrdered {
            column {
                Text(verbatim: "\(list.startIndex + index).")
                    .monospacedDigit()
            }
        } else {
            column {
                Text(verbatim: bullet)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The marker column, trailing-aligned: 20 pt wide for an unordered list, at least 20 pt for an ordered one.
    @ViewBuilder
    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        if list.isOrdered {
            content().frame(minWidth: 20, alignment: .trailing)
        } else {
            content().frame(width: 20, alignment: .trailing)
        }
    }

    /// `•` at the top level, `◦` at depth 2, `▪` deeper.
    private var bullet: String {
        switch list.depth {
        case ...1: return "•"
        case 2: return "◦"
        default: return "▪"
        }
    }
}
