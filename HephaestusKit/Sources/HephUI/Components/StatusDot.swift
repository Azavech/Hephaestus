import SwiftUI

/// A dot showing whether a device is online (docs/ui/shell.md §12).
public struct StatusDot: View {
    private let isOnline: Bool
    private let size: CGFloat

    public init(isOnline: Bool, size: CGFloat = 8) {
        self.isOnline = isOnline
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(isOnline ? Color.green : Color.gray.opacity(0.6))
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isOnline ? "Online" : "Offline")
    }
}
