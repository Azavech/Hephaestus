import HephClient
import HephCore
import Observation
import SwiftUI

extension View {
    /// Applied once to the root view of every window: migration progress sheets.
    public func migrationProgressPresenter() -> some View {
        modifier(MigrationProgressPresenter())
    }
}

/// The action that presents the progress sheet of a migration in this window. The presenter puts it in the
/// environment; `OverviewView` calls it when the move sheet has been dismissed after `migrateProject` succeeded.
struct PresentMigrationProgressAction {
    let action: @MainActor (UUID) -> Void

    @MainActor
    func callAsFunction(_ migrationID: UUID) {
        action(migrationID)
    }
}

extension EnvironmentValues {
    @Entry var presentMigrationProgress: PresentMigrationProgressAction = PresentMigrationProgressAction(action: { _ in })
}

/// The presenter of a window (docs/ui/overview.md, "Presentation in every window"): it iterates `workspace.events()` for
/// the life of the window, keeps the latest `MigrationProgressPayload` per migration, and owns the window's progress
/// sheet and its set of hidden migrations. It never changes the selection.
private struct MigrationProgressPresenter: ViewModifier {
    @Environment(Workspace.self) private var workspace: Workspace?
    @Environment(WindowContext.self) private var context: WindowContext?
    @State private var model = MigrationProgressPresenterModel()

    func body(content: Content) -> some View {
        content
            .environment(\.presentMigrationProgress, PresentMigrationProgressAction { [model] migrationID in
                model.present(migrationID)
            })
            .sheet(item: presentedItem) { item in
                MigrationProgressSheet(migrationID: item.id, model: model) {
                    model.close()
                }
            }
            .task {
                guard let workspace else { return }
                model.attach(workspace: workspace, context: context)
                for await event in workspace.events() {
                    if case .event(_, .migrationProgress(let payload)) = event {
                        model.record(payload)
                    }
                }
            }
            .onChange(of: context?.selection.mainDeviceID) {
                model.update()
            }
            .onChange(of: context?.selection.projectID) {
                model.update()
            }
            .onChange(of: workspace?.topologyRevision) {
                model.update()
            }
    }

    /// The presented migration; set to nil when the sheet is dismissed (Hide, Done, Close or a swipe).
    private var presentedItem: Binding<MigrationSheetItem?> {
        Binding(
            get: { model.presented.map(MigrationSheetItem.init) },
            set: { item in
                if item == nil {
                    model.close()
                }
            }
        )
    }
}

/// The identity of the presented progress sheet.
private struct MigrationSheetItem: Identifiable {
    let id: UUID
}

/// The state of the presenter of one window.
@MainActor @Observable
final class MigrationProgressPresenterModel {
    /// The project the window showed when `OverviewView` handed a migration over.
    private struct HandedOver {
        let mainDeviceID: UUID?
        let projectID: String?
    }

    /// The latest payload of each migration.
    private(set) var payloads: [UUID: MigrationProgressPayload] = [:]
    /// The migration whose sheet is presented.
    private(set) var presented: UUID?
    /// The last known name of each migration's project: it leaves the tree of the source and appears in the tree of the
    /// destination.
    private var projectNames: [UUID: String] = [:]
    /// Migration ids in the order this window learned of them: the earliest qualifying one is presented.
    private var order: [UUID] = []
    private var handedOver: [UUID: HandedOver] = [:]
    private var hidden: Set<UUID> = []
    private weak var workspace: Workspace?
    private weak var context: WindowContext?

    func attach(workspace: Workspace, context: WindowContext?) {
        self.workspace = workspace
        self.context = context
    }

    /// A `migration.progress` payload.
    func record(_ payload: MigrationProgressPayload) {
        payloads[payload.migrationID] = payload
        remember(payload.migrationID)
        update()
    }

    /// `presentMigrationProgress`: `OverviewView` handed the migration over in this window.
    func present(_ migrationID: UUID) {
        if handedOver[migrationID] == nil {
            handedOver[migrationID] = HandedOver(mainDeviceID: context?.selection.mainDeviceID,
                                                 projectID: context?.selection.projectID)
        }
        remember(migrationID)
        update()
    }

    /// Hide, Done and Close: the migration is hidden in this window; the next qualifying one, if any, is presented.
    func close() {
        guard let migrationID = presented else { return }
        hidden.insert(migrationID)
        presented = nil
        Task { @MainActor [weak self] in
            self?.update()
        }
    }

    /// Presents the earliest qualifying migration when no sheet is presented. A presented sheet stays until the user
    /// closes it, also after its migration reached `completed` or `failed`.
    func update() {
        for migrationID in order {
            refreshProjectName(of: migrationID)
        }
        guard presented == nil else { return }
        presented = order.first(where: qualifies)
    }

    /// Handed over in this window, or in progress (neither `completed` nor `failed`) while the window shows its
    /// project or one of its sub projects; never when hidden.
    private func qualifies(_ migrationID: UUID) -> Bool {
        guard !hidden.contains(migrationID) else { return false }
        if handedOver[migrationID] != nil {
            return true
        }
        guard let payload = payloads[migrationID], payload.state != .completed, payload.state != .failed,
              let workspace, let selection = context?.selection,
              let mainDeviceID = selection.mainDeviceID, let projectID = selection.projectID
        else { return false }
        return workspace.projectPath(of: projectID, on: mainDeviceID)?.first == payload.projectID
    }

    private func remember(_ migrationID: UUID) {
        if !order.contains(migrationID) {
            order.append(migrationID)
        }
        refreshProjectName(of: migrationID)
    }

    private func refreshProjectName(of migrationID: UUID) {
        guard let workspace else { return }
        let name: String?
        if let payload = payloads[migrationID] {
            name = workspace.summary(of: payload.projectID, on: payload.fromDeviceID)?.name
                ?? workspace.summary(of: payload.projectID, on: payload.toDeviceID)?.name
        } else if let handed = handedOver[migrationID], let mainDeviceID = handed.mainDeviceID,
                  let projectID = handed.projectID {
            name = workspace.summary(of: projectID, on: mainDeviceID)?.name
        } else {
            name = nil
        }
        if let name, projectNames[migrationID] != name {
            projectNames[migrationID] = name
        }
    }

    // MARK: - Texts of the sheet

    /// The project's name; its identifier while the name is unknown.
    func projectName(of migrationID: UUID) -> String {
        projectNames[migrationID]
            ?? payloads[migrationID]?.projectID
            ?? handedOver[migrationID]?.projectID
            ?? ""
    }

    /// The name of a Main, from `workspace.mains`.
    func mainName(_ deviceID: UUID) -> String {
        guard let workspace else { return "Main" }
        return OverviewScreen.mainName(deviceID, workspace: workspace)
    }
}
