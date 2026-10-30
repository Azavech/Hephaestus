import SwiftUI

/// A choice of the welcome screen (docs/ui/onboarding.md): symbol, title and text, then a progress indicator while
/// the choice runs.
struct OnboardingChoiceButton: View {
    private let symbol: String
    private let title: String
    private let text: String
    private let isBusy: Bool
    private let action: () -> Void

    init(symbol: String, title: String, text: String, isBusy: Bool, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.text = text
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36)
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.headline)
                    Text(text)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
