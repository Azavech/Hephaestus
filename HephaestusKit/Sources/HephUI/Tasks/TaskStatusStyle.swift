import HephCore
import SwiftUI

/// The symbol and the tint of each task status, used everywhere a status is drawn: the Tasks screen and the Overview
/// counts (docs/ui/tasks.md, "Status style"). Titles are `TaskStatus.displayName`.
public enum TaskStatusStyle {
    public static func symbolName(_ status: TaskStatus) -> String {
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

    public static func tint(_ status: TaskStatus) -> Color {
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
public struct TaskStatusBadge: View {
    private let status: TaskStatus

    public init(status: TaskStatus) {
        self.status = status
    }

    public var body: some View {
        let tint = TaskStatusStyle.tint(status)
        Label(status.displayName, systemImage: TaskStatusStyle.symbolName(status))
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
