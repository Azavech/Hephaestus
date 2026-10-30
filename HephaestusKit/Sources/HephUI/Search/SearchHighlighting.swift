import Foundation
import SwiftUI

/// The highlighting of the query words in a result's title and snippet (docs/ui/search.md, "Highlighting").
enum SearchHighlighting {
    /// The text with each range bold on the accent color at 25 % opacity.
    static func attributed(_ text: String, ranges: [Range<String.Index>]) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges {
            guard let attributedRange = Range(range, in: attributed) else { continue }
            attributed[attributedRange].inlinePresentationIntent = .stronglyEmphasized
            attributed[attributedRange].swiftUI.backgroundColor = Color.accentColor.opacity(0.25)
        }
        return attributed
    }
}
