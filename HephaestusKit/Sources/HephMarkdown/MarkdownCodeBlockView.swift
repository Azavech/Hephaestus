import SwiftUI

/// A code block: its highlighted text in a monospaced font, lines not wrapped, in a horizontal scroll view.
struct MarkdownCodeBlockView: View {
    let text: AttributedString

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
