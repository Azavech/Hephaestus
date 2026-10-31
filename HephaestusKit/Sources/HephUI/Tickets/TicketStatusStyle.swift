import HephCore
import SwiftUI

/// The symbol and the tint of each ticket status, used everywhere a status is drawn: the Tickets screen and the Overview
/// counts (docs/ui/tickets.md, "Status style"). Titles are `TicketStatus.displayName`.
public enum TicketStatusStyle {
    public static func symbolName(_ status: TicketStatus) -> String {
        switch status {
        case .todo:
            return "circle"
        case .inProgress:
            return "circle.lefthalf.filled"
        case .review:
            return "eye.circle"
        case .done:
            return "checkmark.circle.fill"
        }
    }

    public static func tint(_ status: TicketStatus) -> Color {
        switch status {
        case .todo:
            return .gray
        case .inProgress:
            return .blue
        case .review:
            return .orange
        case .done:
            return .green
        }
    }
}

/// Capsule with the status symbol and `displayName`: symbol and title in the tint color, caption font, the tint at 15 %
/// opacity as background.
public struct TicketStatusBadge: View {
    private let status: TicketStatus

    public init(status: TicketStatus) {
        self.status = status
    }

    public var body: some View {
        let tint = TicketStatusStyle.tint(status)
        Label(status.displayName, systemImage: TicketStatusStyle.symbolName(status))
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}
