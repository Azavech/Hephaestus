import Foundation
import HephClient
import HephCore

/// The path bar order of the Mains and the defaults of a window's selection (docs/ui/shell.md §5.3, §7).
@MainActor
public enum SelectionDefaults {
    /// Path bar order: `workspace.mains` with this device first when it is a Main.
    public static func orderedMains(_ workspace: Workspace) -> [DeviceRecord] {
        var mains = workspace.mains
        if let index = mains.firstIndex(where: { $0.id == workspace.device.id }), index > 0 {
            let thisDevice = mains.remove(at: index)
            mains.insert(thisDevice, at: 0)
        }
        return mains
    }

    /// Fills the empty fields of `selection`; never replaces a field that is set.
    public static func apply(to selection: Selection, workspace: Workspace, isCompact: Bool) {
        // Rule 1: the first connected Main in path bar order, else the first Main.
        if selection.mainDeviceID == nil {
            let mains = orderedMains(workspace)
            if let main = mains.first(where: { isOnline($0.id, workspace: workspace) }) ?? mains.first {
                selection.mainDeviceID = main.id
            }
        }
        // Rule 2: the first top-level project by name of a connected Main whose projects are loaded.
        if let mainDeviceID = selection.mainDeviceID, selection.projectID == nil,
           let connection = workspace.connection(mainDeviceID), connection.isConnected, connection.projectsLoaded,
           let first = sortedByName(connection.projects).first {
            selection.projectID = first.id
        }
        // Rule 3: regular width shows a section.
        if !isCompact && selection.section == nil {
            selection.section = .overview
        }
    }

    // MARK: - Path helpers

    /// A Main is online in the path bar when this device's connection to it is connected.
    static func isOnline(_ mainDeviceID: UUID, workspace: Workspace) -> Bool {
        workspace.connection(mainDeviceID)?.isConnected == true
    }

    /// The name of a Main: its connection's name, else its registry name, else "Main".
    static func mainName(_ mainDeviceID: UUID, workspace: Workspace) -> String {
        if let connection = workspace.connection(mainDeviceID) {
            return connection.name
        }
        return workspace.mesh?.devices.first(where: { $0.id == mainDeviceID })?.name ?? "Main"
    }

    /// Projects sorted by name (`localizedStandardCompare`).
    nonisolated static func sortedByName(_ projects: [ProjectSummary]) -> [ProjectSummary] {
        projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
