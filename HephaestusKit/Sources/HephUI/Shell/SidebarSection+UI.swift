import HephClient
import SwiftUI

/// The presentation of the sidebar sections (docs/ui/shell.md §4).
extension SidebarSection {
    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .tasks: return "Tasks"
        case .code: return "Code"
        case .docs: return "Docs"
        case .web: return "Web"
        case .claude: return "Claude"
        case .runs: return "Runs"
        case .devices: return "Devices"
        case .skills: return "Skills"
        case .forge: return "Forge"
        }
    }

    public var symbolName: String {
        switch self {
        case .overview: return "info.circle"
        case .tasks: return "checklist"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .docs: return "book.closed"
        case .web: return "globe"
        case .claude: return "bubble.left.and.bubble.right"
        case .runs: return "play.rectangle"
        case .devices: return "laptopcomputer.and.iphone"
        case .skills: return "wand.and.stars"
        case .forge: return "hammer"
        }
    }

    /// "1"…"7" for the project sections (⌘1–⌘7), else nil.
    public var shortcutKey: KeyEquivalent? {
        switch self {
        case .overview: return "1"
        case .tasks: return "2"
        case .code: return "3"
        case .docs: return "4"
        case .web: return "5"
        case .claude: return "6"
        case .runs: return "7"
        case .devices, .skills, .forge: return nil
        }
    }

    /// The seven project sections, in sidebar order.
    public static var projectSections: [SidebarSection] {
        allCases.filter(\.isProjectSection)
    }

    /// Devices, Skills and Forge.
    public static var workspaceSections: [SidebarSection] {
        allCases.filter { !$0.isProjectSection }
    }
}
