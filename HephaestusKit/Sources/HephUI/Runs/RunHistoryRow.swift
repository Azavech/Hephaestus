import HephClient
import HephCore
import SwiftUI

/// A row of the History section: the state badge, the name and the duration, then the relative start time and the
/// exit code (docs/ui/runs.md, "History").
struct RunHistoryRow: View {
    let run: RunInfo

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            RunStateBadge(state: run.state)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    RunDurationText(run: run)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                TimelineView(.everyMinute) { _ in
                    Text(secondLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The relative start time, then " · exit <exitCode>" when set.
    private var secondLine: String {
        let started = run.startedAt.formatted(.relative(presentation: .named))
        guard let exitCode = run.exitCode else { return started }
        return "\(started) · exit \(exitCode)"
    }
}

/// The badge of a run state: a small progress view, or a colored symbol.
struct RunStateBadge: View {
    let state: RunState

    var body: some View {
        badge
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.title(state))
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .stopped:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    static func title(_ state: RunState) -> String {
        switch state {
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

/// The duration of a run: `endedAt − startedAt`; while it runs, now − `startedAt`, refreshed every second.
struct RunDurationText: View {
    let run: RunInfo

    var body: some View {
        if run.state == .running || run.endedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(Self.format(timeline.date.timeIntervalSince(run.startedAt)))
            }
        } else {
            Text(Self.format((run.endedAt ?? run.startedAt).timeIntervalSince(run.startedAt)))
        }
    }

    /// `.time(pattern: .minuteSecond)` under one hour, `.time(pattern: .hourMinuteSecond)` from one hour.
    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(interval, 0)
        let duration = Duration.seconds(seconds)
        if seconds < 3600 {
            return duration.formatted(.time(pattern: .minuteSecond))
        }
        return duration.formatted(.time(pattern: .hourMinuteSecond))
    }
}
