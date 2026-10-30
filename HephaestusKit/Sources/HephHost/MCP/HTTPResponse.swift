#if os(macOS)
import Foundation

/// A response of the MCP server (docs/claude/mcp.md §3).
struct HTTPResponse: Sendable, Equatable {
    var status: Int
    var headers: [HTTPHeader]
    var body: Data

    init(status: Int, headers: [HTTPHeader] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A response with a JSON body: `Content-Type: application/json`.
    static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(status: status, headers: [HTTPHeader(name: "Content-Type", value: "application/json")], body: body)
    }

    /// Status line, headers (Content-Length added, Connection: close added when `close`), blank line, body.
    func serialized(close: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for header in headers {
            head += "\(header.name): \(header.value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        if close {
            head += "Connection: close\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    /// The reason phrase of a status code.
    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        default: return ""
        }
    }
}
#endif
