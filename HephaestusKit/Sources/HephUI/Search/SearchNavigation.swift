import Foundation
import HephClient
import HephCore

/// Opening a search result in a window (docs/ui/search.md, "Opening a result").
@MainActor
enum SearchNavigation {
    /// The arguments of WindowContext.navigate for a result; nil leaves the Main or the project unchanged.
    static func target(for result: SearchResult) -> (mainDeviceID: UUID?, projectID: String?,
                                                      section: SidebarSection, item: String?) {
        switch result.kind {
        case .projects:
            return (result.deviceID, result.projectID, .overview, nil)
        case .tickets, .comments:
            return (result.deviceID, result.projectID, .tickets, result.ticketID)
        case .docs:
            return (result.deviceID, result.projectID, .docs, fileItem(of: result))
        case .code:
            return (result.deviceID, result.projectID, .code, fileItem(of: result))
        case .skills:
            if let path = result.path, path != "SKILL.md" {
                return (result.deviceID, nil, .skills, "\(result.itemID)/\(path)")
            }
            return (result.deviceID, nil, .skills, result.itemID)
        case .webTabs:
            return (result.deviceID, result.projectID, .web, result.itemID)
        case .sessions:
            return (result.deviceID, result.projectID, .claude, result.itemID)
        case .devices:
            return (nil, nil, .devices, result.itemID)
        }
    }

    /// Navigates the window to the result, then closes the palette or dismisses the search sheet.
    static func open(_ result: SearchResult, in context: WindowContext) {
        let target = target(for: result)
        context.navigate(mainDeviceID: target.mainDeviceID, projectID: target.projectID, section: target.section,
                         item: target.item)
        context.isSearchPresented = false
        if context.sheet == .search {
            context.sheet = nil
        }
    }

    /// A `docs` or `code` item: the path, followed by `#L<line>` when the result has a line.
    private static func fileItem(of result: SearchResult) -> String {
        let path = result.path ?? result.itemID
        guard let line = result.line else { return path }
        return "\(path)#L\(line)"
    }
}
