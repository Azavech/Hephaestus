import HephCore
import SwiftUI

/// The scope chips of the search (docs/ui/search.md, "Scope bar"): All, then one chip per scope.
struct SearchScopeBar: View {
    @Binding private var scopes: Set<SearchScope>

    init(scopes: Binding<Set<SearchScope>>) {
        _scopes = scopes
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ChipToggle(title: "All", isOn: scopes.isEmpty) {
                    scopes = []
                }
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    ChipToggle(title: SearchResultsList.title(of: scope), isOn: scopes.contains(scope)) {
                        toggle(scope)
                    }
                }
            }
        }
    }

    /// Inserts or removes the scope; a set holding every scope becomes the empty set (All).
    private func toggle(_ scope: SearchScope) {
        var updated = scopes
        if updated.contains(scope) {
            updated.remove(scope)
        } else {
            updated.insert(scope)
        }
        scopes = updated.count == SearchScope.allCases.count ? [] : updated
    }
}
