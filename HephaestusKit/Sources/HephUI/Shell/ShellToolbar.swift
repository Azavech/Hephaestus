import SwiftUI

/// The toolbar of the shell (docs/ui/shell.md §9): attached to `DetailView` in regular width, to `SidebarView`, the
/// root of the navigation stack, in compact width.
struct ShellToolbar: ToolbarContent {
    let isCompact: Bool

    var body: some ToolbarContent {
        #if os(iOS)
        if isCompact {
            ToolbarItem(placement: .principal) {
                CompactPathButton()
            }
            ToolbarItem(placement: .topBarLeading) {
                PresenceIndicator()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                PermissionIndicator()
                SearchToolbarButton()
                FeedbackToolbarButton()
            }
        } else {
            regularItems
        }
        #else
        regularItems
        #endif
    }

    @ToolbarContentBuilder
    private var regularItems: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            PathBar()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            PermissionIndicator()
            PresenceIndicator()
            SearchToolbarButton()
            FeedbackToolbarButton()
        }
    }
}

/// The Search button of the toolbar.
private struct SearchToolbarButton: View {
    @Environment(WindowContext.self) private var context

    var body: some View {
        Button {
            context.openSearch()
        } label: {
            Label("Search", systemImage: "magnifyingglass")
        }
        .help("Search (⌘K)")
    }
}
