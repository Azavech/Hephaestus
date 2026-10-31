import Foundation

/// The one-line summary, the symbol and the display name of a tool call (docs/ui/sessions.md, "Tool rows"). The tool
/// rows, the permission cards, the toolbar indicator and the permission banner use it.
enum ToolSummary {
    /// The longest summary, in characters, the ellipsis included.
    static let maximumLength = 200

    /// The summary of a call of `toolName` with the input JSON text `inputJSON`; empty when the input is not a JSON
    /// object or holds nothing to show. Paths under `<projectRoot>/` are shown relative to it.
    static func summary(toolName: String, inputJSON: String, projectRoot: String?) -> String {
        guard let data = inputJSON.data(using: .utf8),
              let input = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
                as? [String: Any]
        else { return "" }
        let summary = rawSummary(toolName: toolName, input: input, projectRoot: projectRoot)
        return cut(summary)
    }

    /// The SF Symbol of a tool.
    static func symbolName(toolName: String) -> String {
        switch toolName {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Write": return "square.and.pencil"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        default:
            if toolName.hasPrefix("mcp__hephaestus__") {
                return "hammer"
            }
            if toolName.hasPrefix("mcp__") {
                return "puzzlepiece.extension"
            }
            return "wrench.and.screwdriver"
        }
    }

    /// The server and the tool of a name `mcp__<server>__<tool>`; nil for any other name.
    static func mcpParts(of toolName: String) -> (server: String, tool: String)? {
        let prefix = "mcp__"
        guard toolName.hasPrefix(prefix) else { return nil }
        let rest = toolName.dropFirst(prefix.count)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[rest.startIndex..<separator.lowerBound])
        let tool = String(rest[separator.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    /// The name shown for a tool: `<tool>` for `mcp__<server>__<tool>`, any other name as it is.
    static func displayName(toolName: String) -> String {
        mcpParts(of: toolName)?.tool ?? toolName
    }

    /// A tool input pretty-printed with sorted keys; the text as it is when it is not JSON.
    static func prettyPrinted(inputJSON: String) -> String {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
              ),
              let text = String(data: pretty, encoding: .utf8)
        else { return inputJSON }
        return text
    }

    // MARK: Private

    private static func rawSummary(toolName: String, input: [String: Any], projectRoot: String?) -> String {
        func value(_ key: String) -> String? {
            guard let string = input[key] as? String else { return nil }
            return relative(string, key: key, projectRoot: projectRoot)
        }

        switch toolName {
        case "Bash":
            guard let command = input["command"] as? String else { return "" }
            return command.components(separatedBy: .newlines).first ?? ""
        case "Read", "Write", "Edit", "MultiEdit":
            return value("file_path") ?? ""
        case "NotebookEdit":
            return value("notebook_path") ?? ""
        case "Grep":
            guard let pattern = value("pattern") else { return "" }
            if let path = value("path") {
                return "\(pattern) in \(path)"
            }
            return pattern
        case "Glob":
            return value("pattern") ?? ""
        case "WebFetch":
            return value("url") ?? ""
        case "WebSearch":
            return value("query") ?? ""
        case "Task", "Agent":
            return value("description") ?? ""
        case "TodoWrite":
            guard let todos = input["todos"] as? [Any] else { return "" }
            return "\(todos.count) items"
        default:
            if toolName.hasPrefix("mcp__hephaestus__") {
                for key in ["ticket", "project", "name", "query", "url"] {
                    if let string = value(key) {
                        return string
                    }
                }
                return ""
            }
            for key in input.keys.sorted() {
                if let string = value(key) {
                    return string
                }
            }
            return ""
        }
    }

    /// `file_path`, `notebook_path` and `path` values under `<projectRoot>/` are shown relative to it.
    private static func relative(_ value: String, key: String, projectRoot: String?) -> String {
        guard ["file_path", "notebook_path", "path"].contains(key), let projectRoot, !projectRoot.isEmpty else {
            return value
        }
        let prefix = projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/"
        guard value.hasPrefix(prefix) else { return value }
        return String(value.dropFirst(prefix.count))
    }

    /// At most `maximumLength` characters, cut with "…".
    private static func cut(_ summary: String) -> String {
        guard summary.count > maximumLength else { return summary }
        return String(summary.prefix(maximumLength - 1)) + "…"
    }
}
