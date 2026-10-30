import HephCore
import SwiftUI

/// The symbol of a device's platform (docs/ui/shell.md §12).
public struct PlatformIcon: View {
    private let platform: DevicePlatform

    public init(platform: DevicePlatform) {
        self.platform = platform
    }

    public var body: some View {
        Image(systemName: symbolName)
    }

    private var symbolName: String {
        switch platform {
        case .macOS:
            return "desktopcomputer"
        case .iOS:
            return "iphone"
        case .iPadOS:
            return "ipad"
        }
    }
}
