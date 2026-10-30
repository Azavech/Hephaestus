import SwiftUI

/// A capsule button that shows an on or off state (docs/ui/shell.md §12).
public struct ChipToggle: View {
    private let title: String
    private let isOn: Bool
    private let action: () -> Void

    public init(title: String, isOn: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.quaternary),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
