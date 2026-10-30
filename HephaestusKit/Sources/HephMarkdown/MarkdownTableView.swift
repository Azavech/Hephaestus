import SwiftUI

/// A table: the head row, then the body rows, in a horizontally scrolling grid.
struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.head.indices, id: \.self) { column in
                        let cell = table.head[column]
                        if cell.colspan > 0 {
                            cellView(cell, column: column, isHead: true)
                                .gridColumnAlignment(horizontalAlignment(column))
                        }
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            let cell = table.rows[row][column]
                            if cell.colspan > 0 {
                                cellView(cell, column: column, isHead: false)
                            }
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Its inlines as a `Text`, 6 pt vertical and 10 pt horizontal padding, a 1 pt border; a covered cell is empty.
    private func cellView(_ cell: MarkdownTableCell, column: Int, isHead: Bool) -> some View {
        Text(cell.isCoveredByRow ? AttributedString() : cell.text)
            .bold(isHead)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(
                horizontal: horizontalAlignment(column), vertical: .center
            ))
            .background(isHead ? Color.secondary.opacity(0.08) : Color.clear)
            .overlay {
                Rectangle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            }
            .gridCellColumns(max(cell.colspan, 1))
    }

    /// `.left` or none: leading; `.center`: center; `.right`: trailing.
    private func horizontalAlignment(_ column: Int) -> HorizontalAlignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
