#if os(macOS)
import Foundation
import HephCore

/// The permission requests of the session processes (docs/claude/cli.md §4): the requests waiting for an answer, the
/// ids each session's current process sent, and the answers written back to the CLI. `SessionService` owns one.
public struct PermissionBroker: Sendable {
    private struct SessionRequests: Sendable {
        /// Every request id received from the current process (the last one when it has ended).
        var received: Set<String> = []
        /// The requests waiting for an answer, oldest first.
        var pending: [PermissionRequest] = []
    }

    private var sessions: [UUID: SessionRequests] = [:]

    public init() {}

    /// A process of the session starts, or the session is deleted: forgets the request ids it received.
    public mutating func reset(sessionID: UUID) {
        sessions[sessionID] = nil
    }

    public mutating func add(sessionID: UUID, request: PermissionRequest) {
        var requests = sessions[sessionID] ?? SessionRequests()
        requests.received.insert(request.requestID)
        requests.pending.removeAll { $0.requestID == request.requestID }
        requests.pending.append(request)
        sessions[sessionID] = requests
    }

    /// The pending requests of the session, oldest first.
    public func pending(sessionID: UUID) -> [PermissionRequest] {
        sessions[sessionID]?.pending ?? []
    }

    /// Removes and returns a pending request. Throws ProtocolError notFound "No permission request <id>." when the id
    /// was not received since the last reset, conflict "This request is not pending." when it was answered or cancelled.
    public mutating func take(sessionID: UUID, requestID: String) throws -> PermissionRequest {
        guard var requests = sessions[sessionID], requests.received.contains(requestID) else {
            throw ProtocolError(.notFound, "No permission request \(requestID).")
        }
        guard let index = requests.pending.firstIndex(where: { $0.requestID == requestID }) else {
            throw ProtocolError(.conflict, "This request is not pending.")
        }
        let request = requests.pending.remove(at: index)
        sessions[sessionID] = requests
        return request
    }

    /// Removes and returns every pending request of the session (cancellation).
    public mutating func takeAll(sessionID: UUID) -> [PermissionRequest] {
        guard var requests = sessions[sessionID] else { return [] }
        let pending = requests.pending
        requests.pending.removeAll()
        sessions[sessionID] = requests
        return pending
    }

    /// The answer line of §4.2, without the trailing newline. `input` and `suggestions` are parsed back from their JSON
    /// text, so the original input object is sent back unchanged.
    public static func answer(to request: PermissionRequest, decision: PermissionDecision, message: String?,
                              deviceName: String) -> Data {
        let input = parse(request.input) ?? [String: Any]()
        var answer: [String: Any]
        switch decision {
        case .allow:
            answer = ["behavior": "allow", "updatedInput": input]
        case .allowAlways:
            answer = ["behavior": "allow", "updatedInput": input]
            let suggestions = parse(request.suggestions) as? [Any] ?? []
            let kept = suggestions.filter { suggestion in
                guard let type = (suggestion as? [String: Any])?["type"] as? String else { return false }
                return type == "addRules" || type == "addDirectories"
            }
            if !kept.isEmpty {
                answer["updatedPermissions"] = kept
            }
        case .deny:
            let text: String
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = message
            } else {
                text = "Denied from \(deviceName)"
            }
            answer = ["behavior": "deny", "message": text]
        }
        let line: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": request.requestID,
                "response": answer,
            ] as [String: Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
    }

    /// A JSON text parsed back to its value; nil when it is not JSON.
    private static func parse(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }
}
#endif
