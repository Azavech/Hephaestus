#if os(macOS)
import Foundation
import HephCore

/// The table of section 6: the session kinds that list each tool and may call it.
enum MCPToolKinds {
    static func kinds(for toolName: String) -> Set<SessionKind> {
        switch toolName {
        // 6.1–6.6, 6.8, 6.10, 6.12–6.22
        case "list_devices", "list_projects", "get_project",
             "create_project", "update_project", "list_tasks",
             "create_task", "delete_task",
             "start_task_session", "list_runs",
             "start_run", "stop_run", "get_run_output",
             "list_web_tabs", "open_web_tab", "search",
             "list_skills", "get_skill", "save_skill":
            return [.project, .task]
        // 6.7, 6.9, 6.11, in a feedback session for its own task only
        case "get_task", "update_task", "comment_task":
            return [.project, .task, .feedback]
        // 6.23
        case "forge_push_docs":
            return [.feedback]
        // 6.24
        case "forge_push_regen":
            return [.regeneration]
        default:
            return []
        }
    }
}
#endif
