#if os(macOS)
import Foundation
import HephCore

/// The table of section 6: the session kinds that list each tool and may call it.
enum MCPToolKinds {
    static func kinds(for toolName: String) -> Set<SessionKind> {
        switch toolName {
        // 6.1–6.6, 6.8, 6.10, 6.13–6.18
        case "list_devices", "list_projects", "get_project",
             "create_project", "update_project", "list_tickets",
             "create_ticket", "delete_ticket", "list_web_tabs",
             "open_web_tab", "search", "list_skills",
             "get_skill", "save_skill":
            return [.project, .ticket, .bundle]
        // 6.7, 6.9, 6.11, in a feedback session for its own ticket only
        case "get_ticket", "update_ticket", "comment_ticket":
            return [.project, .ticket, .bundle, .feedback]
        // 6.12
        case "start_ticket_session":
            return [.project, .ticket]
        // 6.19
        case "forge_push_docs":
            return [.ticket, .bundle]
        // 6.20
        case "forge_push_regen":
            return [.regeneration]
        // 6.21–6.24
        case "get_bundle", "start_bundle_ticket", "update_bundle", "finish_bundle":
            return [.bundle]
        // 6.25
        case "rename_session":
            return [.project, .ticket, .bundle, .feedback, .regeneration]
        // 6.26
        case "close_session":
            return [.project, .ticket, .bundle, .feedback]
        default:
            return []
        }
    }
}
#endif
