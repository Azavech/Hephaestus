import HephClient
import HephCore
import SwiftUI

/// The Runs section of the project held by `store`. @MainActor; reads the Workspace, the window's WindowContext and
/// its WindowBanners from the environment (docs/ui/runs.md).
public struct RunsView: View {
    private let store: ProjectStore

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    /// The run chosen in the history (view state, not stored in the selection).
    @State private var selectedRunID: UUID?
    /// The configurations whose Run or Stop request is in flight.
    @State private var busyNames: Set<String> = []
    @State private var editorTarget: RunConfigurationEditorTarget?
    @State private var configurationToDelete: RunConfig?

    public init(store: ProjectStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if context.isCompact {
                NavigationStack {
                    list
                        .navigationDestination(item: compactItem) { name in
                            console(name: name)
                        }
                }
            } else {
                #if os(macOS)
                HSplitView {
                    list
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
                    console(name: context.selection.item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                #else
                HStack(spacing: 0) {
                    list
                        .frame(width: 320)
                    Divider()
                    console(name: context.selection.item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                #endif
            }
        }
        .sheet(item: $editorTarget) { target in
            RunConfigurationSheet(store: store, original: target.configuration) { originalName, saved in
                // An edited configuration that was selected stays selected under its new name.
                if let originalName, context.selection.item == originalName {
                    context.selection.item = saved.name
                }
            }
        }
        .confirmationDialog("Delete “\(configurationToDelete?.name ?? "")”?",
                            isPresented: isDeleteConfirmationPresented, titleVisibility: .visible,
                            presenting: configurationToDelete) { configuration in
            Button("Delete", role: .destructive) {
                delete(configuration)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Runs already started keep running.")
        }
    }

    // MARK: Data

    private var configurations: [RunConfig] {
        store.project?.runs ?? []
    }

    /// Newest `startedAt` first.
    private var history: [RunInfo] {
        store.runs.sorted { $0.startedAt > $1.startedAt }
    }

    private var isConnected: Bool {
        store.connection?.isConnected == true
    }

    private func isRunning(_ name: String) -> Bool {
        store.runs.contains { $0.name == name && $0.state == .running }
    }

    /// 1. the run `selectedRunID` when it is in `store.runs` and its name equals `selection.item`; 2. else the most
    /// recent run with that name; 3. else nothing.
    private func shownRun(name: String?) -> RunInfo? {
        guard let name else { return nil }
        if let selectedRunID, let run = store.run(selectedRunID), run.name == name {
            return run
        }
        return store.runs.filter { $0.name == name }.max { $0.startedAt < $1.startedAt }
    }

    // MARK: List

    private var list: some View {
        List(selection: listSelection) {
            Section {
                if configurations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No run configurations")
                            .foregroundStyle(.secondary)
                        Button("New Configuration…") {
                            editorTarget = .new
                        }
                        .disabled(!isConnected)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(configurations) { configuration in
                        configurationRow(configuration)
                            .tag(RunsListItem.configuration(configuration.name))
                    }
                }
            } header: {
                HStack {
                    Text("Configurations")
                    Spacer()
                    Button {
                        editorTarget = .new
                    } label: {
                        Label("New Configuration", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("New Configuration")
                    .disabled(!isConnected)
                }
            }
            Section("History") {
                if history.isEmpty {
                    Text("No runs yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history) { run in
                        RunHistoryRow(run: run)
                            .contextMenu {
                                if run.state == .running {
                                    Button("Stop") {
                                        stop(run.name)
                                    }
                                    .disabled(!isConnected)
                                }
                            }
                            .tag(RunsListItem.run(run.id))
                    }
                }
            }
        }
    }

    private func configurationRow(_ configuration: RunConfig) -> some View {
        let running = isRunning(configuration.name)
        return RunConfigurationRow(configuration: configuration, isRunning: running,
                                   isRequestInFlight: busyNames.contains(configuration.name),
                                   isConnected: isConnected,
                                   onRun: { run(configuration.name) },
                                   onStop: { stop(configuration.name) })
            .contextMenu {
                if running {
                    Button("Stop") {
                        stop(configuration.name)
                    }
                    .disabled(!isConnected || busyNames.contains(configuration.name))
                } else {
                    Button("Run") {
                        run(configuration.name)
                    }
                    .disabled(!isConnected || busyNames.contains(configuration.name))
                }
                Button("Edit…") {
                    editorTarget = .edit(configuration)
                }
                .disabled(!isConnected)
                Button("Delete…") {
                    configurationToDelete = configuration
                }
                .disabled(!isConnected)
            }
            #if os(macOS)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                // Opens Edit… while the Main is connected.
                if isConnected {
                    editorTarget = .edit(configuration)
                }
            })
            #endif
    }

    /// Choosing a configuration row selects its name; choosing a history row selects the run's name and the run.
    private var listSelection: Binding<RunsListItem?> {
        Binding(
            get: {
                guard let name = context.selection.item else { return nil }
                if let selectedRunID, let run = store.run(selectedRunID), run.name == name {
                    return .run(selectedRunID)
                }
                return .configuration(name)
            },
            set: { item in
                switch item {
                case .configuration(let name):
                    selectedRunID = nil
                    context.selection.item = name
                case .run(let id):
                    guard let run = store.run(id) else { return }
                    selectedRunID = id
                    context.selection.item = run.name
                case nil:
                    break
                }
            }
        )
    }

    /// Compact width: the console is pushed while `selection.item` is set; Back sets it and `selectedRunID` to nil.
    private var compactItem: Binding<String?> {
        Binding(
            get: { context.selection.item },
            set: { item in
                context.selection.item = item
                if item == nil {
                    selectedRunID = nil
                }
            }
        )
    }

    private func console(name: String?) -> some View {
        RunConsoleView(store: store, name: name, run: shownRun(name: name), busyNames: busyNames,
                       onRun: run, onStop: stop)
    }

    // MARK: Requests

    /// Run: `startRun(projectID:name:)`, then the returned run is selected.
    private func run(_ name: String) {
        guard !busyNames.contains(name) else { return }
        busyNames.insert(name)
        let store = store
        let workspace = workspace
        Task {
            await banners.perform {
                let connection = try ClaudeNames.connection(of: store, in: workspace)
                let run = try await connection.startRun(projectID: store.projectID, name: name)
                selectedRunID = run.id
                context.selection.item = name
            }
            busyNames.remove(name)
        }
    }

    /// Stop: `stopRun(projectID:runID:)` for every `running` run with that name.
    private func stop(_ name: String) {
        guard !busyNames.contains(name) else { return }
        let runIDs = store.runs.filter { $0.name == name && $0.state == .running }.map(\.id)
        guard !runIDs.isEmpty else { return }
        busyNames.insert(name)
        let store = store
        let workspace = workspace
        Task {
            await banners.perform {
                let connection = try ClaudeNames.connection(of: store, in: workspace)
                for runID in runIDs {
                    try await connection.stopRun(projectID: store.projectID, runID: runID)
                }
            }
            busyNames.remove(name)
        }
    }

    /// Delete: `ProjectPatch(runs:)` with the list without the configuration.
    private func delete(_ configuration: RunConfig) {
        let store = store
        let workspace = workspace
        Task {
            await banners.perform {
                let runs = (store.project?.runs ?? []).filter { $0.name != configuration.name }
                let connection = try ClaudeNames.connection(of: store, in: workspace)
                _ = try await connection.updateProject(projectID: store.projectID, patch: ProjectPatch(runs: runs))
            }
        }
    }

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(get: { configurationToDelete != nil }, set: { if !$0 { configurationToDelete = nil } })
    }
}

/// A row of the runs list.
private enum RunsListItem: Hashable {
    case configuration(String)
    case run(UUID)
}

/// The configuration editor: a new configuration or an edited one.
private enum RunConfigurationEditorTarget: Identifiable {
    case new
    case edit(RunConfig)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let configuration): return "edit-\(configuration.name)"
        }
    }

    var configuration: RunConfig? {
        switch self {
        case .new: return nil
        case .edit(let configuration): return configuration
        }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    RunsView(store: appModel.workspace.projectStore(mainDeviceID: studio, projectID: "HEPH"))
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, projectID: "HEPH", section: .runs))
}
