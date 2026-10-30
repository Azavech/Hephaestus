#if os(macOS)
import Foundation
import HephCore

/// JSON-RPC 2.0 and the MCP methods of an authenticated `POST /mcp` (docs/claude/mcp.md §4).
struct MCPDispatcher: Sendable {
    private let tools: MCPToolHandler

    /// The protocol versions echoed by `initialize`; any other gets the first.
    private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    init(tools: MCPToolHandler) {
        self.tools = tools
    }

    /// Handles one authenticated POST /mcp body for the token's session.
    func handle(body: Data, context: MCPSessionContext) async -> HTTPResponse {
        guard let parsed = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            return Self.error(400, id: nil, code: -32_700, message: "Parse error")
        }
        if parsed is [Any] {
            return Self.error(400, id: nil, code: -32_600, message: "Batch requests are not supported")
        }
        guard let request = parsed as? [String: Any], request["jsonrpc"] as? String == "2.0" else {
            return Self.error(400, id: nil, code: -32_600, message: "Invalid Request")
        }
        let id = request["id"]
        if let id, !Self.isStringOrNumber(id) {
            return Self.error(400, id: nil, code: -32_600, message: "Invalid Request")
        }
        // A response from the client.
        if request["method"] == nil, request["result"] != nil || request["error"] != nil {
            return HTTPResponse(status: 202)
        }
        guard let method = request["method"] as? String else {
            return Self.error(400, id: id, code: -32_600, message: "Invalid Request")
        }
        // A notification: ignored.
        guard let id else {
            return HTTPResponse(status: 202)
        }
        let params: [String: Any]
        if let raw = request["params"] {
            guard let object = raw as? [String: Any] else {
                return Self.error(200, id: id, code: -32_602, message: "Invalid params")
            }
            params = object
        } else {
            params = [:]
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let result: [String: Any] = [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "hephaestus", "version": appVersion],
            ]
            guard let data = Self.serialize(result) else { return Self.internalError(id: id) }
            return Self.result(id: id, data)
        case "ping":
            return Self.result(id: id, Data("{}".utf8))
        case "tools/list":
            return Self.result(id: id, Self.toolList(for: context.kind))
        case "tools/call":
            guard let name = params["name"] as? String,
                  MCPTools.tools(for: context.kind).contains(where: { $0.name == name })
            else {
                return Self.error(200, id: id, code: -32_602,
                                  message: "Unknown tool: \(params["name"] as? String ?? "")")
            }
            let arguments: Data
            if let raw = params["arguments"] {
                guard let object = raw as? [String: Any] else {
                    return Self.error(200, id: id, code: -32_602, message: "Invalid params")
                }
                guard let data = Self.serialize(object) else { return Self.internalError(id: id) }
                arguments = data
            } else {
                arguments = Data("{}".utf8)
            }
            let outcome = await tools.call(name: name, arguments: arguments, context: context)
            let result: [String: Any] = [
                "content": [["type": "text", "text": outcome.text]],
                "isError": outcome.isError,
            ]
            guard let data = Self.serialize(result) else { return Self.internalError(id: id) }
            return Self.result(id: id, data)
        default:
            return Self.error(200, id: id, code: -32_601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Responses

    /// `{"tools":[…]}`: the tools of the session's kind in catalog order, each schema as written in the catalog.
    private static func toolList(for kind: SessionKind) -> Data {
        var data = Data(#"{"tools":["#.utf8)
        for (index, tool) in MCPTools.tools(for: kind).enumerated() {
            if index > 0 {
                data.append(UInt8(ascii: ","))
            }
            data.append(Data(#"{"name":"#.utf8))
            data.append(jsonValue(tool.name))
            data.append(Data(#","description":"#.utf8))
            data.append(jsonValue(tool.description))
            data.append(Data(#","inputSchema":"#.utf8))
            data.append(Data(tool.inputSchema.utf8))
            data.append(UInt8(ascii: "}"))
        }
        data.append(Data("]}".utf8))
        return data
    }

    /// `{"jsonrpc":"2.0","id":<id>,"result":<result>}`, HTTP 200.
    private static func result(id: Any, _ result: Data) -> HTTPResponse {
        var body = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        body.append(jsonValue(id))
        body.append(Data(#","result":"#.utf8))
        body.append(result)
        body.append(UInt8(ascii: "}"))
        return HTTPResponse.json(200, body)
    }

    /// `{"jsonrpc":"2.0","id":<id or null>,"error":{"code":<code>,"message":"<text>"}}`.
    private static func error(_ status: Int, id: Any?, code: Int, message: String) -> HTTPResponse {
        var body = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        body.append(jsonValue(id ?? NSNull()))
        body.append(Data(#","error":{"code":"#.utf8))
        body.append(Data(String(code).utf8))
        body.append(Data(#","message":"#.utf8))
        body.append(jsonValue(message))
        body.append(Data("}}".utf8))
        return HTTPResponse.json(status, body)
    }

    // MARK: - JSON

    /// A JSON value (a string, a number, null) as compact JSON text; the id is echoed as received.
    private static func jsonValue(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            ?? Data("null".utf8)
    }

    /// Compact JSON text of an object; nil when it cannot be serialized.
    private static func serialize(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// An unexpected failure while handling: `-32603`, `Internal error`.
    private static func internalError(id: Any) -> HTTPResponse {
        Log.host.error("An MCP request failed unexpectedly")
        return error(200, id: id, code: -32_603, message: "Internal error")
    }

    /// A JSON string or number; booleans and null are neither.
    private static func isStringOrNumber(_ value: Any) -> Bool {
        if value is String {
            return true
        }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) != CFBooleanGetTypeID()
        }
        return false
    }
}
#endif
