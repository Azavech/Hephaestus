import Foundation
import HephCore
import Observation

/// The sections of the sidebar (docs/client/workspace.md, "Selection").
public enum SidebarSection: String, Codable, CaseIterable, Sendable {
    /// Project sections, ⌘1–⌘7 in this order.
    case overview, tasks, code, docs, web, claude, runs
    /// Workspace sections.
    case devices, skills, forge

    /// True for the seven project sections.
    public var isProjectSection: Bool {
        switch self {
        case .overview, .tasks, .code, .docs, .web, .claude, .runs:
            return true
        case .devices, .skills, .forge:
            return false
        }
    }
}

/// What one window shows: Main, project, section and item. Setting a field changes nothing else; the Workspace
/// corrects the selections it made with `makeSelection()` by its selection rules.
@MainActor @Observable
public final class Selection {
    public var mainDeviceID: UUID?
    /// The selected project or sub project.
    public var projectID: String?
    /// nil: no section chosen (compact: the sidebar list is shown).
    public var section: SidebarSection?
    /// The item selected in the section.
    public var item: String?

    public init(mainDeviceID: UUID? = nil, projectID: String? = nil, section: SidebarSection? = nil,
                item: String? = nil) {
        self.mainDeviceID = mainDeviceID
        self.projectID = projectID
        self.section = section
        self.item = item
    }

    /// The four fields, the section as its raw value (docs/forge/feedback.md).
    public var feedbackSelection: FeedbackSelection {
        FeedbackSelection(mainDeviceID: mainDeviceID, projectID: projectID, section: section?.rawValue, item: item)
    }
}
