import HephClient
import HephCore
import SwiftUI

/// The console of the chosen run: a header, then the output filling the rest (docs/ui/runs.md, "Console").
struct RunConsoleView: View {
    let store: ProjectStore
    /// `selection.item`: the name of the selected run configuration.
    let name: String?
    /// The run shown (docs/ui/runs.md, "Selection").
    let run: RunInfo?
    /// The configurations whose Run or Stop request is in flight.
    let busyNames: Set<String>
    let onRun: (String) -> Void
    let onStop: (String) -> Void

    var body: some View {
        if let run {
            RunOutputPane(store: store, run: run, busyNames: busyNames, onRun: onRun, onStop: onStop)
                .id(run.id)
        } else if let name, store.project?.runs.contains(where: { $0.name == name }) == true {
            VStack(spacing: 12) {
                Text("“\(name)” has not run yet.")
                    .foregroundStyle(.secondary)
                if busyNames.contains(name) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Run") {
                        onRun(name)
                    }
                    .disabled(store.connection?.isConnected != true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a run configuration")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The header and the output of one run; it creates the run's `RunOutputModel` when it appears.
private struct RunOutputPane: View {
    let store: ProjectStore
    let run: RunInfo
    let busyNames: Set<String>
    let onRun: (String) -> Void
    let onStop: (String) -> Void

    @Environment(Workspace.self) private var workspace
    @State private var model: RunOutputModel?
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            output
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            let model = model ?? RunOutputModel(workspace: workspace, mainID: store.mainDeviceID,
                                                projectID: store.projectID, runID: run.id)
            self.model = model
            model.appear()
        }
        .onDisappear {
            model?.disappear()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(run.name)
                        .font(.headline)
                        .lineLimit(1)
                    RunStateBadge(state: run.state)
                    Text(stateTitle)
                        .foregroundStyle(.secondary)
                }
                Text(run.command)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                HStack(spacing: 0) {
                    Text("Started \(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · ")
                    RunDurationText(run: run)
                        .monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            buttons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The state title, then " · exit <exitCode>" when set.
    private var stateTitle: String {
        let title = RunStateBadge.title(run.state)
        guard let exitCode = run.exitCode else { return title }
        return "\(title) · exit \(exitCode)"
    }

    private var isConnected: Bool {
        store.connection?.isConnected == true
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            if busyNames.contains(run.name) {
                ProgressView()
                    .controlSize(.small)
            } else if run.state == .running {
                Button("Stop") {
                    onStop(run.name)
                }
                .disabled(!isConnected)
            } else if canRunAgain {
                Button("Run Again") {
                    onRun(run.name)
                }
                .disabled(!isConnected)
            }
            Group {
                Toggle(isOn: $autoScroll) {
                    Label("Auto-scroll", systemImage: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help("Auto-scroll")
                Button {
                    if let model {
                        TranscriptPasteboard.copy(model.text)
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy")
                Button {
                    model?.clear()
                } label: {
                    Label("Clear", systemImage: "eraser")
                }
                .help("Clear")
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
    }

    /// A configuration with that name exists and none of its runs is running.
    private var canRunAgain: Bool {
        guard store.project?.runs.contains(where: { $0.name == run.name }) == true else { return false }
        return !store.runs.contains { $0.name == run.name && $0.state == .running }
    }

    // MARK: Output

    @ViewBuilder private var output: some View {
        if let model {
            switch model.phase {
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task {
                            await model.reload()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                ConsoleTextView(model: model, autoScroll: autoScroll)
                    .overlay {
                        ProgressView()
                    }
            case .idle, .loaded:
                ConsoleTextView(model: model, autoScroll: autoScroll)
            }
        } else {
            Color.clear
        }
    }
}
