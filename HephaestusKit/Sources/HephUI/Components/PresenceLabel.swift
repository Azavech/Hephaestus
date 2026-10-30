import Foundation
import SwiftUI

/// The online state of a device: a `StatusDot`, then "Online" or its last seen time (docs/ui/shell.md §12).
public struct PresenceLabel: View {
    private let isOnline: Bool
    private let lastSeen: Date?

    public init(isOnline: Bool, lastSeen: Date?) {
        self.isOnline = isOnline
        self.lastSeen = lastSeen
    }

    public var body: some View {
        TimelineView(.everyMinute) { timeline in
            HStack(spacing: 4) {
                StatusDot(isOnline: isOnline)
                Text(isOnline ? "Online" : PresenceFormat.lastSeen(lastSeen, now: timeline.date))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// The texts of presence.
public enum PresenceFormat {
    /// "Last seen " and the date relative to `now` ("Last seen 5 minutes ago"); nil: "Never seen online".
    public static func lastSeen(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Never seen online" }
        return "Last seen " + Date.AnchoredRelativeFormatStyle(anchor: date, presentation: .named).format(now)
    }
}
