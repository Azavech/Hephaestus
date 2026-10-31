#if os(macOS)
import Foundation
import HephCore

/// The table of section 6: the session kinds that list each tool and may call it.
enum MCPToolKinds {
    static func kinds(for toolName: String) -> Set<SessionKind> {
        switch toolName {
        // 6.1–6.6, 6.8, 6.10, 6.13, 6.16–6.22
        case "list_devices", "list_projects", "get_project",
             "create_project", "update_project", "list_tasks",
             "create_task", "delete_task", "list_runs",
             "get_run_output", "list_web_tabs", "open_web_tab",
             "search", "list_skills", "get_skill", "save_skill":
            return [.project, .task, .bundle]
        // 6.7, 6.9, 6.11, in a feedback session for its own task only
        case "get_task", "update_task", "comment_task":
            return [.project, .task, .bundle, .feedback]
        // 6.12, 6.14, 6.15
        case "start_task_session", "start_run", "stop_run":
            return [.project, .task]
        // 6.23
        case "forge_push_docs":
            return [.feedback, .bundle]
        // 6.24
        case "forge_push_regen":
            return [.regeneration]
        // 6.25–6.28
        case "get_bundle", "start_bundle_task", "update_bundle", "finish_bundle":
            return [.bundle]
        default:
            return []
        }
    }
}
#endif
