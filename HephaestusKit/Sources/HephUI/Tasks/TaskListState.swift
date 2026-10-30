import Foundation
import HephCore
import Observation

/// A section of the task list: the tasks of one status, or the broken tasks (docs/ui/tasks.md, "Sections").
struct TaskListSection: Identifiable {
    enum Kind: Hashable {
        case status(TaskStatus)
        case broken
    }

    let kind: Kind
    let tasks: [TaskItem]

    var id: Kind { kind }
}

/// The filter and sort settings of the task list of one window (docs/ui/tasks.md, "Filter and sort"), in the state of
/// its `TasksView`: they are kept while the Tasks section of the same project is shown, and reset when the window shows
/// another section or selects another project (the shell gives every project its own `TasksView`).
@MainActor @Observable
final class TaskListState {
    enum Sort: Hashable, CaseIterable {
        case number
        case lastUpdated

        var title: String {
            switch self {
            case .number:
                return "Number"
            case .lastUpdated:
                return "Last Updated"
            }
        }
    }

    /// The statuses shown; broken tasks ignore it.
    var statuses: Set<TaskStatus> = Set(TaskStatus.allCases)
    var sort: Sort = .number
    /// The text of the search field.
    var text = ""

    /// Every setting has its default value.
    var isDefault: Bool {
        statuses == Set(TaskStatus.allCases) && sort == .number && text.isEmpty
    }

    /// Restores the defaults (Clear Filter).
    func reset() {
        statuses = Set(TaskStatus.allCases)
        sort = .number
        text = ""
    }

    /// The sections of `tasks` (in the order of `store.tasks`) after filtering and sorting: the statuses in
    /// `TaskStatus.allCases` order, then Broken; a section without task is left out. A broken task is only in Broken.
    func sections(of tasks: [TaskItem]) -> [TaskListSection] {
        let words = SearchQuery(text).words
        let shown = sorted(tasks.filter { matches($0, words: words) })
        var sections: [TaskListSection] = []
        for status in TaskStatus.allCases {
            let items = shown.filter { $0.parseError == nil && $0.status == status }
            if !items.isEmpty {
                sections.append(TaskListSection(kind: .status(status), tasks: items))
            }
        }
        let broken = shown.filter { $0.parseError != nil }
        if !broken.isEmpty {
            sections.append(TaskListSection(kind: .broken, tasks: broken))
        }
        return sections
    }

    /// Every word of the query occurs, case- and diacritic-insensitive, in the task's id, name or description; a broken
    /// task ignores the status filter and is matched on its id and parse error.
    private func matches(_ task: TaskItem, words: [String]) -> Bool {
        let fields: [String]
        if let parseError = task.parseError {
            fields = [task.id, parseError]
        } else {
            guard statuses.contains(task.status) else { return false }
            fields = [task.id, task.name, task.description]
        }
        return words.allSatisfy { word in
            fields.contains { SearchMatcher.contains(word, in: $0) }
        }
    }

    /// Number: the order of `store.tasks` (ascending task number). Last Updated: `updated` descending, ties by number
    /// descending.
    private func sorted(_ tasks: [TaskItem]) -> [TaskItem] {
        switch sort {
        case .number:
            return tasks
        case .lastUpdated:
            return tasks.sorted { lhs, rhs in
                if lhs.updated != rhs.updated {
                    return lhs.updated > rhs.updated
                }
                let lhsNumber = Self.number(of: lhs.id)
                let rhsNumber = Self.number(of: rhs.id)
                if lhsNumber != rhsNumber {
                    return lhsNumber > rhsNumber
                }
                return lhs.id > rhs.id
            }
        }
    }

    /// The integer after the last `-` of a task id; 0 when there is none.
    private static func number(of taskID: String) -> Int {
        guard let dash = taskID.lastIndex(of: "-") else { return 0 }
        return Int(taskID[taskID.index(after: dash)...]) ?? 0
    }
}
