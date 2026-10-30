import SwiftUI

/// The empty and error states of the screens (docs/ui/shell.md §12): a `ContentUnavailableView`.
public struct EmptyStateView<Actions: View>: View {
    private let symbol: String
    private let title: String
    private let message: String?
    private let actions: Actions

    public init(symbol: String, title: String, message: String? = nil,
                @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            actions
        }
    }
}
