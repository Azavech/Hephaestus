import Foundation
import HephClient
import Observation

/// The state of one window (docs/ui/shell.md §5.2). Menu commands reach it through the focused scene value
/// `windowContext`.
@MainActor @Observable
public final class WindowContext {
    /// Main, project, section and item shown by the window.
    public let selection: Selection
    /// The window's banners (§8.1).
    public let banners: WindowBanners
    /// The shell sheet presented by `MainShell`.
    public var sheet: ShellSheet?
    /// Regular width: the search palette is shown.
    public var isSearchPresented = false
    /// The window is compact; set from `horizontalSizeClass` by `RootView` when it creates the context and by
    /// `MainShell` (always false on macOS).
    public var isCompact = false

    public init(selection: Selection) {
        self.selection = selection
        banners = WindowBanners()
    }

    /// Shows a section; a change of section clears the item.
    public func select(_ section: SidebarSection) {
        guard section != selection.section else { return }
        selection.section = section
        selection.item = nil
    }

    /// Shows an item set from elsewhere (search, a link): Main, project, section and item, then closes search.
    public func navigate(mainDeviceID: UUID?, projectID: String?, section: SidebarSection, item: String?) {
        if let mainDeviceID, mainDeviceID != selection.mainDeviceID {
            selection.mainDeviceID = mainDeviceID
            selection.projectID = projectID
        } else if let projectID {
            selection.projectID = projectID
        }
        selection.section = section
        selection.item = item
        isSearchPresented = false
        if sheet == .search {
            sheet = nil
        }
    }

    /// Compact: the search sheet; regular: the search palette.
    public func openSearch() {
        if isCompact {
            sheet = .search
        } else if !isSearchPresented {
            isSearchPresented = true
        }
    }
}

/// The sheets presented by `MainShell` (§6.1).
public enum ShellSheet: Identifiable, Hashable {
    case pathPicker
    case newProject(mainDeviceID: UUID)
    case addExistingFolder(mainDeviceID: UUID)
    case search

    /// "pathPicker", "newProject-<uuid>", "addExistingFolder-<uuid>", "search".
    public var id: String {
        switch self {
        case .pathPicker:
            return "pathPicker"
        case .newProject(let mainDeviceID):
            return "newProject-\(mainDeviceID.uuidString)"
        case .addExistingFolder(let mainDeviceID):
            return "addExistingFolder-\(mainDeviceID.uuidString)"
        case .search:
            return "search"
        }
    }
}
