#if os(macOS)
import Foundation
import HephCore

/// A finished content block of an `assistant` line (docs/claude/cli.md §3.3).
public enum AssistantBlock: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: String)        // input: JSON text
}

/// The fields of a `system`/`init` line.
public struct InitInfo: Sendable, Equatable {
    public var version: String?          // claude_code_version
    public var model: String?            // model
    public var permissionMode: String?   // permissionMode
    public var toolCount: Int            // number of tools
    public var hephaestusStatus: String? // status of the mcp_servers item named "hephaestus"

    public init(version: String?, model: String?, permissionMode: String?, toolCount: Int,
                hephaestusStatus: String?) {
        self.version = version
        self.model = model
        self.permissionMode = permissionMode
        self.toolCount = toolCount
        self.hephaestusStatus = hephaestusStatus
    }
}

/// The fields of a `result` line.
public struct ResultInfo: Sendable, Equatable {
    public var isError: Bool             // is_error, false when absent
    public var subtype: String?          // subtype
    public var durationMS: Int           // duration_ms, 0 when absent
    public var costUSD: Double           // total_cost_usd, 0 when absent
    public var stopReason: String?       // stop_reason (null → nil)
    public var errorText: String?        // see the field rules of §3.3

    public init(isError: Bool, subtype: String?, durationMS: Int, costUSD: Double, stopReason: String?,
                errorText: String?) {
        self.isError = isError
        self.subtype = subtype
        self.durationMS = durationMS
        self.costUSD = costUSD
        self.stopReason = stopReason
        self.errorText = errorText
    }
}

/// A message of the CLI's standard output, as `SessionService` handles it.
public enum CLIMessage: Sendable, Equatable {
    case controlResponse(requestID: String, error: String?)     // error nil: success
    case permissionRequest(PermissionRequest)
    case unsupportedControlRequest(requestID: String)
    case controlCancel(requestID: String)
    case initialized(InitInfo)
    case statusLine(String)                                      // live status line text
    case turnActivity                                            // system status, message_start
    case delta(messageID: String, index: Int, kind: SessionDeltaKind, text: String)
    case block(messageID: String, index: Int, block: AssistantBlock)
    case toolResult(toolUseID: String, text: String, isError: Bool)
    case result(ResultInfo)
}

/// Turns the stream-json lines of the CLI's standard output into `CLIMessage` values (docs/claude/cli.md §3.3). One
/// parser reads the lines of one process, in order: it keeps the id of the last `message_start` and the number of
/// blocks parsed per message.
public struct StreamJSONParser: Sendable {
    /// The `id` of the last `message_start`.
    private var lastMessageID: String?
    /// The number of blocks already parsed for each `message.id`; cleared after each `result`.
    private var blockCounts: [String: Int] = [:]

    public init() {}

    public mutating func parse(_ line: String) -> [CLIMessage] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = object["type"] as? String
        else {
            Log.host.error("Ignored a line of the Claude CLI that is not a JSON object with a type")
            return []
        }
        switch type {
        case "stream_event", "assistant", "user":
            // Sub-agent traffic.
            if object["parent_tool_use_id"] is String {
                return []
            }
        default:
            break
        }
        switch type {
        case "control_response": return controlResponse(object)
        case "control_request": return controlRequest(object)
        case "control_cancel_request":
            guard let requestID = object["request_id"] as? String else { return [] }
            return [.controlCancel(requestID: requestID)]
        case "system": return system(object)
        case "stream_event": return streamEvent(object)
        case "assistant": return assistant(object)
        case "user": return user(object)
        case "result": return [result(object)]
        default: return []
        }
    }

    // MARK: - Line types

    private func controlResponse(_ object: [String: Any]) -> [CLIMessage] {
        guard let response = object["response"] as? [String: Any],
              let requestID = response["request_id"] as? String
        else { return [] }
        if response["subtype"] as? String == "success" {
            return [.controlResponse(requestID: requestID, error: nil)]
        }
        let error = response["error"] as? String ?? response["subtype"] as? String ?? ""
        return [.controlResponse(requestID: requestID, error: error)]
    }

    private func controlRequest(_ object: [String: Any]) -> [CLIMessage] {
        guard let requestID = object["request_id"] as? String else { return [] }
        // Another subtype, or a can_use_tool whose tool_name is empty or not a string: refused.
        guard let request = object["request"] as? [String: Any],
              request["subtype"] as? String == "can_use_tool",
              let toolName = request["tool_name"] as? String, !toolName.isEmpty
        else {
            return [.unsupportedControlRequest(requestID: requestID)]
        }
        let permission = PermissionRequest(
            requestID: requestID,
            toolName: toolName,
            input: Self.compactJSON(request["input"] ?? [String: Any]()),
            description: request["description"] as? String,
            suggestions: request["permission_suggestions"].map { Self.compactJSON($0) } ?? "[]",
            blockedPath: request["blocked_path"] as? String
        )
        return [.permissionRequest(permission)]
    }

    private func system(_ object: [String: Any]) -> [CLIMessage] {
        switch object["subtype"] as? String {
        case "init":
            let servers = object["mcp_servers"] as? [[String: Any]] ?? []
            let hephaestus = servers.first { $0["name"] as? String == "hephaestus" }
            return [.initialized(InitInfo(version: object["claude_code_version"] as? String,
                                          model: object["model"] as? String,
                                          permissionMode: object["permissionMode"] as? String,
                                          toolCount: (object["tools"] as? [Any])?.count ?? 0,
                                          hephaestusStatus: hephaestus?["status"] as? String))]
        case "status":
            guard let status = object["status"] as? String, let first = status.first else {
                return [.turnActivity]
            }
            return [.turnActivity, .statusLine(first.uppercased() + status.dropFirst() + "…")]
        case "thinking_tokens":
            guard let tokens = Self.integer(object["estimated_tokens"]) else { return [] }
            return [.statusLine("Thinking… (~\(tokens) tokens)")]
        case "task_summary":
            guard let detail = object["detail"] as? String, !detail.isEmpty else { return [] }
            return [.statusLine(detail)]
        case "post_turn_summary":
            guard let detail = object["status_detail"] as? String, !detail.isEmpty else { return [] }
            return [.statusLine(detail)]
        default:
            return []
        }
    }

    private mutating func streamEvent(_ object: [String: Any]) -> [CLIMessage] {
        guard let event = object["event"] as? [String: Any] else { return [] }
        switch event["type"] as? String {
        case "message_start":
            if let message = event["message"] as? [String: Any], let id = message["id"] as? String {
                lastMessageID = id
            }
            return [.turnActivity]
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            let kind: SessionDeltaKind
            let text: String?
            switch delta["type"] as? String {
            case "text_delta":
                kind = .text
                text = delta["text"] as? String
            case "thinking_delta":
                kind = .thinking
                text = delta["thinking"] as? String
            case "input_json_delta":
                kind = .toolInput
                text = delta["partial_json"] as? String
            default:
                return []
            }
            guard let text, !text.isEmpty else { return [] }
            let messageID = object["api_message_id"] as? String ?? lastMessageID ?? ""
            return [.delta(messageID: messageID, index: Self.integer(event["index"]) ?? 0, kind: kind, text: text)]
        default:
            return []
        }
    }

    private mutating func assistant(_ object: [String: Any]) -> [CLIMessage] {
        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return [] }
        let messageID = message["id"] as? String ?? lastMessageID ?? ""
        var messages: [CLIMessage] = []
        for block in blocks {
            let index = blockCounts[messageID, default: 0]
            blockCounts[messageID] = index + 1
            switch block["type"] as? String {
            case "text":
                messages.append(.block(messageID: messageID, index: index,
                                       block: .text(block["text"] as? String ?? "")))
            case "thinking":
                messages.append(.block(messageID: messageID, index: index,
                                       block: .thinking(block["thinking"] as? String ?? "")))
            case "tool_use":
                messages.append(.block(messageID: messageID, index: index,
                                       block: .toolUse(id: block["id"] as? String ?? "",
                                                       name: block["name"] as? String ?? "",
                                                       input: Self.compactJSON(block["input"] ?? [String: Any]()))))
            default:
                break
            }
        }
        return messages
    }

    private func user(_ object: [String: Any]) -> [CLIMessage] {
        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return [] }
        return blocks.compactMap { block -> CLIMessage? in
            guard block["type"] as? String == "tool_result" else { return nil }
            let text: String
            if let content = block["content"] as? String {
                text = content
            } else if let items = block["content"] as? [[String: Any]] {
                text = items.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
            } else {
                text = ""
            }
            return .toolResult(toolUseID: block["tool_use_id"] as? String ?? "", text: text,
                               isError: block["is_error"] as? Bool ?? false)
        }
    }

    private mutating func result(_ object: [String: Any]) -> CLIMessage {
        blockCounts.removeAll()
        let isError = object["is_error"] as? Bool ?? false
        let subtype = object["subtype"] as? String
        let errors = (object["errors"] as? [Any] ?? []).compactMap { $0 as? String }
        let errorText: String?
        if !errors.isEmpty {
            errorText = errors.joined(separator: "\n")
        } else if isError, let text = object["result"] as? String, !text.isEmpty {
            errorText = text
        } else if isError {
            errorText = "Claude ended the turn with an error (\(subtype ?? ""))."
        } else {
            errorText = nil
        }
        return .result(ResultInfo(isError: isError,
                                  subtype: subtype,
                                  durationMS: Self.integer(object["duration_ms"]) ?? 0,
                                  costUSD: (object["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0,
                                  stopReason: object["stop_reason"] as? String,
                                  errorText: errorText))
    }

    // MARK: - Helpers

    /// A JSON value written back as compact JSON text, keys sorted, slashes not escaped (tool inputs, suggestions).
    static func compactJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys, .withoutEscapingSlashes,
                                                               .fragmentsAllowed])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// An integer JSON number; booleans are not numbers here.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}
#endif
