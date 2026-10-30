import HephClient
import HephCore
import SwiftUI

/// The sheet of Move to… (docs/ui/overview.md, "Move sheet"): moves a top-level project, sub projects included, to
/// another online Main. Active sessions and runs of the project are stopped first ("Stop and Move").
struct MoveProjectSheet: View {
    let store: ProjectStore
    /// Receives the migration id when `migrateProject` succeeded, before the sheet dismisses itself.
    let onMigrationStarted: (UUID) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var targetID: UUID?
    @State private var isMoving = false
    /// A `migrateProject` request is in flight: Cancel is disabled and the sheet cannot be dismissed, since cancelling
    /// the request only forgets it and the Main still starts the move.
    @State private var isRequestInFlight = false
    @State private var errorMessage: String?
    @State private var moveTask: Task<Void, Never>?

    var body: some View {
        let targets = self.targets
        let processes = activeProcessLines
        VStack(spacing: 0) {
            Text(verbatim: "Move “\(projectName)” to Another Main")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
            Form {
                Section {
                    if targets.isEmpty {
                        Text("No other Main is online.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(targets) { record in
                        targetRow(record, isSelected: record.id == selectedTargetID)
                    }
                }
                Section {
                    Text(verbatim: "The folder \(store.project?.rootPath ?? "") is copied to the projects folder of "
                         + "the chosen Main, verified, then moved to the Trash on "
                         + "\(OverviewScreen.mainName(store.mainDeviceID, workspace: workspace)). Sub projects move "
                         + "with it. .build, DerivedData and node_modules folders are not copied.")
                }
                if !processes.isEmpty {
                    Section {
                        ForEach(processes, id: \.self) { line in
                            Label {
                                Text(verbatim: line)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isMoving)
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    moveTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isRequestInFlight)
                Button(action: move) {
                    if isMoving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(processes.isEmpty ? "Move" : "Stop and Move")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canMove)
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 420)
        #endif
        .interactiveDismissDisabled(isRequestInFlight)
        .onDisappear {
            moveTask?.cancel()
        }
    }

    private var projectName: String {
        store.project?.name ?? store.projectID
    }

    // MARK: - Targets

    /// The Mains other than the project's Main that are online, in `mains` order.
    private var targets: [DeviceRecord] {
        workspace.mains.filter { record in
            record.id != store.mainDeviceID && workspace.presence[record.id]?.online == true
        }
    }

    /// The chosen target; the first one until another is chosen or while the chosen one is not listed.
    private var selectedTargetID: UUID? {
        let targets = self.targets
        if let targetID, targets.contains(where: { $0.id == targetID }) {
            return targetID
        }
        return targets.first?.id
    }

    /// A selectable row: `PlatformIcon` and the name.
    private func targetRow(_ record: DeviceRecord, isSelected: Bool) -> some View {
        Button {
            targetID = record.id
        } label: {
            HStack(spacing: 8) {
                PlatformIcon(platform: record.platform)
                Text(verbatim: record.name)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Active processes

    /// Sessions with a live CLI process (`starting`, `running`, `waitingPermission`, `idle`).
    private var activeSessions: [SessionInfo] {
        store.sessions.filter { session in
            switch session.status {
            case .starting, .running, .waitingPermission, .idle:
                return true
            case .stopped, .failed:
                return false
            }
        }
    }

    private var activeRuns: [RunInfo] {
        store.runs.filter { $0.state == .running }
    }

    /// "Claude: <session title>" and "Run: <run name>".
    private var activeProcessLines: [String] {
        activeSessions.map { "Claude: \($0.title)" } + activeRuns.map { "Run: \($0.name)" }
    }

    // MARK: - Move

    private var canMove: Bool {
        selectedTargetID != nil && !isMoving && (store.connection?.isConnected ?? false)
            && !(store.project?.migrating ?? false)
    }

    /// 1. Stops the listed sessions and runs, in parallel. 2. `migrateProject(projectID:to:)`, repeated every second, at
    /// most 15 times, while it answers `conflict` after processes were stopped. 3. Hands the migration id over and
    /// dismisses; a failure shows in red. During step 1 and between the repeats of step 2, Cancel and closing the sheet
    /// stop the move.
    private func move() {
        guard canMove, let targetID = selectedTargetID else { return }
        let projectID = store.projectID
        let sessionIDs = activeSessions.map(\.id)
        let runIDs = activeRuns.map(\.id)
        let mainDeviceID = store.mainDeviceID
        isMoving = true
        errorMessage = nil
        moveTask = Task {
            do {
                let connection = try OverviewScreen.connection(mainDeviceID, workspace: workspace)
                let stoppedProcesses = !sessionIDs.isEmpty || !runIDs.isEmpty
                if stoppedProcesses {
                    await withTaskGroup(of: Void.self) { group in
                        for sessionID in sessionIDs {
                            group.addTask { @MainActor in
                                do {
                                    try await connection.stopSession(projectID: projectID, sessionID: sessionID)
                                } catch {
                                    Log.ui.error("""
                                        Could not stop the session \(sessionID, privacy: .public) before a move: \
                                        \(Banner.message(of: error))
                                        """)
                                }
                            }
                        }
                        for runID in runIDs {
                            group.addTask { @MainActor in
                                do {
                                    try await connection.stopRun(projectID: projectID, runID: runID)
                                } catch {
                                    Log.ui.error("""
                                        Could not stop the run \(runID, privacy: .public) before a move: \
                                        \(Banner.message(of: error))
                                        """)
                                }
                            }
                        }
                    }
                }
                var repeats = 0
                while true {
                    do {
                        let migrationID = try await migrate(connection, projectID: projectID, to: targetID)
                        isMoving = false
                        onMigrationStarted(migrationID)
                        dismiss()
                        return
                    } catch let error as ProtocolError where error.code == .conflict && stoppedProcesses
                        && repeats < 15 {
                        repeats += 1
                        try await Task.sleep(for: .seconds(1))
                    }
                }
            } catch is CancellationError {
                isMoving = false
            } catch {
                isMoving = false
                errorMessage = Banner.message(of: error)
            }
        }
    }

    /// `migrateProject(projectID:to:)`, with `isRequestInFlight` set while the request runs.
    private func migrate(_ connection: MainConnection, projectID: String, to targetID: UUID) async throws -> UUID {
        isRequestInFlight = true
        defer { isRequestInFlight = false }
        return try await connection.migrateProject(projectID: projectID, to: targetID)
    }
}
