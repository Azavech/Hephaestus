import HephClient
import HephCore
import SwiftUI

/// A row of the Configurations section: the name, the command and the working directory, and a Run or Stop button
/// (docs/ui/runs.md, "Configurations").
struct RunConfigurationRow: View {
    let configuration: RunConfig
    /// A run with this name is `running`.
    let isRunning: Bool
    /// A Run or Stop request of this configuration is in flight.
    let isRequestInFlight: Bool
    /// The project's Main is connected.
    let isConnected: Bool
    let onRun: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(configuration.command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let cwd = configuration.cwd, cwd != "." {
                    Text("in \(cwd)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            RunStartStopButton(isRunning: isRunning, isRequestInFlight: isRequestInFlight,
                               isConnected: isConnected, onRun: onRun, onStop: onStop)
        }
        .padding(.vertical, 2)
    }
}

/// Run (`play.fill`) when no run of the configuration is running, else Stop (`stop.fill`, red); a small progress view
/// while the request runs.
struct RunStartStopButton: View {
    let isRunning: Bool
    let isRequestInFlight: Bool
    let isConnected: Bool
    let onRun: () -> Void
    let onStop: () -> Void

    var body: some View {
        if isRequestInFlight {
            ProgressView()
                .controlSize(.small)
        } else if isRunning {
            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Stop")
            .disabled(!isConnected)
        } else {
            Button(action: onRun) {
                Label("Run", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Run")
            .disabled(!isConnected)
        }
    }
}
