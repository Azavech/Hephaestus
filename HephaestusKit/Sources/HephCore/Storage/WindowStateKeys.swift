import Foundation

/// The `@SceneStorage` keys under which each window keeps its selection (docs/data/app-storage.md, "Per-window state").
/// Values are strings: a UUID is stored as its `uuidString`, and an empty string stores `nil`.
public enum WindowStateKeys {
    public static let mainDeviceID = "selection.mainDeviceID"
    public static let projectID = "selection.projectID"
    public static let section = "selection.section"
    public static let item = "selection.item"
}
