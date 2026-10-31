#if os(macOS)
import Foundation
import XCTest
@testable import HephCore
@testable import HephHost

/// The MCP server (docs/claude/mcp.md): HTTP parsing, routing over a real loopback connection, JSON-RPC and the tools
/// of each session kind.
final class MCPServerTests: XCTestCase {
    private let pingBody = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#

    // MARK: - HTTP parsing

    func testContentLength() throws {
        let request = Data(lengthRequest(pingBody).utf8)
        var parser = HTTPRequestParser()
        let split = request.count - 10
        parser.append(request.prefix(split))
        XCTAssertNil(try parser.nextRequest())
        parser.append(request.dropFirst(split))
        let parsed = try XCTUnwrap(try parser.nextRequest())
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.target, "/mcp")
        XCTAssertEqual(parsed.path, "/mcp")
        XCTAssertEqual(parsed.version, "HTTP/1.1")
        XCTAssertEqual(parsed.header("content-length"), String(pingBody.utf8.count))
        XCTAssertEqual(parsed.body, Data(pingBody.utf8))
        XCTAssertTrue(parsed.keepAlive)
        XCTAssertNil(try parser.nextRequest())
    }

    func testChunked() throws {
        let body = Array(pingBody.utf8)
        var text = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        text += String(16, radix: 16) + ";ext=1\r\n" + String(decoding: body[0..<16], as: UTF8.self) + "\r\n"
        text += String(body.count - 16, radix: 16) + "\r\n" + String(decoding: body[16...], as: UTF8.self) + "\r\n"
        text += "0\r\nX-Trailer: ignored\r\n\r\n"
        var parser = HTTPRequestParser()
        let data = Data(text.utf8)
        for byte in data {
            parser.append(Data([byte]))
        }
        let parsed = try XCTUnwrap(try parser.nextRequest())
        var reference = HTTPRequestParser()
        reference.append(Data(lengthRequest(pingBody).utf8))
        let expected = try XCTUnwrap(try reference.nextRequest())
        XCTAssertEqual(parsed.method, expected.method)
        XCTAssertEqual(parsed.path, expected.path)
        XCTAssertEqual(parsed.target, "/mcp?x=1")
        XCTAssertEqual(parsed.version, expected.version)
        XCTAssertEqual(parsed.body, expected.body)
        XCTAssertNil(try parser.nextRequest())
    }

    func testPipelined() throws {
        let first = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let second = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        var parser = HTTPRequestParser()
        parser.append(Data((lengthRequest(first) + lengthRequest(second)).utf8))
        XCTAssertEqual(try parser.nextRequest()?.body, Data(first.utf8))
        XCTAssertEqual(try parser.nextRequest()?.body, Data(second.utf8))
        XCTAssertNil(try parser.nextRequest())
    }

    func testLimits() throws {
        // A head of more than 64 KiB.
        var headers = HTTPRequestParser()
        headers.append(Data(("POST /mcp HTTP/1.1\r\nX-Padding: " + String(repeating: "a", count: 70_000)).utf8))
        XCTAssertThrowsError(try headers.nextRequest()) { XCTAssertEqual($0 as? HTTPParseError, .headersTooLarge) }
        // A declared body of more than 8 MiB.
        var declared = HTTPRequestParser()
        declared.append(Data("POST /mcp HTTP/1.1\r\nContent-Length: 8388609\r\n\r\n".utf8))
        XCTAssertThrowsError(try declared.nextRequest()) { XCTAssertEqual($0 as? HTTPParseError, .bodyTooLarge) }
        // An accumulated chunked body of more than 8 MiB.
        var chunked = HTTPRequestParser()
        chunked.append(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
        let chunk = Data(repeating: 0x61, count: 1_048_576)
        var thrown: HTTPParseError?
        for _ in 0..<9 where thrown == nil {
            chunked.append(Data("100000\r\n".utf8) + chunk + Data("\r\n".utf8))
            do {
                _ = try chunked.nextRequest()
            } catch {
                thrown = error as? HTTPParseError
            }
        }
        XCTAssertEqual(thrown, .bodyTooLarge)
        // Malformed request lines and framing.
        for head in ["POST /mcp\r\n\r\n", "POST  /mcp HTTP/1.1\r\n\r\n", "POST /mcp HTTP/2.0\r\n\r\n",
                     "POST /mcp HTTP/1.1\r\n folded: header\r\n\r\n", "POST /mcp HTTP/1.1\r\nNo colon\r\n\r\n",
                     "POST /mcp HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
                     "POST /mcp HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n"] {
            var parser = HTTPRequestParser()
            parser.append(Data(head.utf8))
            XCTAssertThrowsError(try parser.nextRequest(), head) { XCTAssertEqual($0 as? HTTPParseError, .malformed) }
        }
    }

    // MARK: - Routing

    func testRouting() async throws {
        let server = MCPServer(host: TestMCPHost())
        let port = try await server.start()
        addTeardownBlock { await server.stop() }
        let started = try await server.start()
        XCTAssertEqual(started, port)

        for method in ["GET", "DELETE"] {
            let response = try await exchange(port, "\(method) /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            XCTAssertEqual(response.status, 405)
            XCTAssertEqual(response.headers["allow"], "POST")
        }
        let missing = try await exchange(port, postRequest(pingBody, token: nil))
        XCTAssertEqual(missing.status, 401)
        XCTAssertEqual(missing.headers["www-authenticate"], "Bearer")
        let unknown = try await exchange(port, postRequest(pingBody, token: String(repeating: "0", count: 64)))
        XCTAssertEqual(unknown.status, 401)
        let other = try await exchange(port, "POST /other HTTP/1.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        XCTAssertEqual(other.status, 404)
        let malformed = try await exchange(port, "POST /mcp HTTP/9\r\n\r\n")
        XCTAssertEqual(malformed.status, 400)

        let token = await server.register(context(.project))
        XCTAssertEqual(token.count, 64)
        let ping = try await exchange(port, postRequest(pingBody, token: token))
        XCTAssertEqual(ping.status, 200)
        XCTAssertEqual(ping.headers["content-type"], "application/json")
        XCTAssertEqual(try object(ping.body)["result"] as? NSDictionary, [:] as NSDictionary)
        await server.unregister(token: token)
        let afterUnregister = try await exchange(port, postRequest(pingBody, token: token))
        XCTAssertEqual(afterUnregister.status, 401)

        let config = try object(Data(await server.configJSON(token: token).utf8))
        let entry = try XCTUnwrap((config["mcpServers"] as? NSDictionary)?["hephaestus"] as? NSDictionary)
        XCTAssertEqual(entry["type"] as? String, "http")
        XCTAssertEqual(entry["url"] as? String, "http://127.0.0.1:\(port)/mcp")
        XCTAssertEqual((entry["headers"] as? NSDictionary)?["Authorization"] as? String, "Bearer \(token)")
    }

    // MARK: - JSON-RPC

    func testInitialize() async throws {
        let dispatcher = MCPDispatcher(tools: MCPToolHandler(host: TestMCPHost()))
        for (requested, expected) in [("2025-11-25", "2025-11-25"), ("2099-01-01", "2025-11-25"),
                                      ("2024-11-05", "2024-11-05")] {
            let body = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"\#(requested)","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.309"}}}"#
            let response = await dispatcher.handle(body: Data(body.utf8), context: context(.project))
            XCTAssertEqual(response.status, 200)
            let reply = try object(response.body)
            XCTAssertEqual(reply["id"] as? Int, 0)
            let result = try XCTUnwrap(reply["result"] as? NSDictionary)
            XCTAssertEqual(result["protocolVersion"] as? String, expected)
            XCTAssertEqual(result["capabilities"] as? NSDictionary, ["tools": [String: Any]()] as NSDictionary)
            XCTAssertEqual((result["serverInfo"] as? NSDictionary)?["name"] as? String, "hephaestus")
        }
    }

    func testDiscoverFallsBack() async throws {
        let dispatcher = MCPDispatcher(tools: MCPToolHandler(host: TestMCPHost()))
        let response = await dispatcher.handle(body: Data(#"{"jsonrpc":"2.0","id":"a","method":"server/discover"}"#.utf8),
                                               context: context(.project))
        XCTAssertEqual(response.status, 200)
        let reply = try object(response.body)
        XCTAssertEqual(reply["id"] as? String, "a")
        XCTAssertEqual((reply["error"] as? NSDictionary)?["code"] as? Int, -32_601)
        XCTAssertEqual((reply["error"] as? NSDictionary)?["message"] as? String, "Method not found: server/discover")
    }

    func testNotifications() async throws {
        let dispatcher = MCPDispatcher(tools: MCPToolHandler(host: TestMCPHost()))
        let notification = await dispatcher.handle(
            body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), context: context(.project))
        XCTAssertEqual(notification.status, 202)
        XCTAssertTrue(notification.body.isEmpty)
        let clientResponse = await dispatcher.handle(body: Data(#"{"jsonrpc":"2.0","id":3,"result":{}}"#.utf8),
                                                     context: context(.project))
        XCTAssertEqual(clientResponse.status, 202)
        let ping = await dispatcher.handle(body: Data(pingBody.utf8), context: context(.project))
        XCTAssertEqual(ping.status, 200)
        let reply = try object(ping.body)
        XCTAssertEqual(reply["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(reply["id"] as? Int, 1)
        XCTAssertEqual(reply["result"] as? NSDictionary, [:] as NSDictionary)
    }

    func testToolsList() async throws {
        let dispatcher = MCPDispatcher(tools: MCPToolHandler(host: TestMCPHost()))
        let projectTools = ["list_devices", "list_projects", "get_project", "create_project", "update_project",
                            "list_tasks", "get_task", "create_task", "update_task", "delete_task", "comment_task",
                            "start_task_session", "list_runs", "start_run", "stop_run", "get_run_output",
                            "list_web_tabs", "open_web_tab", "search", "list_skills", "get_skill", "save_skill"]
        let bundleTools = projectTools.filter { !["start_task_session", "start_run", "stop_run"].contains($0) }
            + ["forge_push_docs", "get_bundle", "start_bundle_task", "update_bundle", "finish_bundle"]
        let feedbackTools = ["get_task", "update_task", "comment_task", "forge_push_docs"]
        let list = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        for (kind, expected) in [(SessionKind.project, projectTools), (.task, projectTools), (.bundle, bundleTools),
                                 (.feedback, feedbackTools), (.regeneration, ["forge_push_regen"])] {
            let response = await dispatcher.handle(body: Data(list.utf8), context: context(kind))
            XCTAssertEqual(response.status, 200)
            let tools = try XCTUnwrap((try object(response.body)["result"] as? NSDictionary)?["tools"] as? [NSDictionary])
            XCTAssertEqual(tools.map { $0["name"] as? String ?? "" }, expected, kind.rawValue)
            for tool in tools {
                XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
                XCTAssertEqual((tool["inputSchema"] as? NSDictionary)?["type"] as? String, "object")
            }
        }

        // start_run with the token of a feedback session: not one of its tools.
        let server = MCPServer(host: TestMCPHost())
        let port = try await server.start()
        addTeardownBlock { await server.stop() }
        let feedback = await server.register(context(.feedback, taskID: "HEPH-7"))
        let call = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"start_run","arguments":{"project":"HEPH","name":"Build"}}}"#
        let refused = try await exchange(port, postRequest(call, token: feedback))
        XCTAssertEqual(refused.status, 200)
        let error = try XCTUnwrap(try object(refused.body)["error"] as? NSDictionary)
        XCTAssertEqual(error["code"] as? Int, -32_602)
        XCTAssertEqual(error["message"] as? String, "Unknown tool: start_run")

        // get_task, update_task and comment_task of another task in a feedback session: a tool error.
        let calls = [
            (#"{"name":"get_task","arguments":{"task":"heph-8"}}"#,
             "Forge sessions can only read their own feedback task."),
            (#"{"name":"update_task","arguments":{"task":"heph-8","name":"Sidebar"}}"#,
             "Forge sessions can only change their own feedback task."),
            (#"{"name":"comment_task","arguments":{"task":"heph-8","body":"Done."}}"#,
             "Forge sessions can only change their own feedback task."),
        ]
        for (index, (params, expected)) in calls.enumerated() {
            let other = #"{"jsonrpc":"2.0","id":\#(5 + index),"method":"tools/call","params":\#(params)}"#
            let response = try await exchange(port, postRequest(other, token: feedback))
            XCTAssertEqual(response.status, 200)
            let result = try XCTUnwrap(try object(response.body)["result"] as? NSDictionary)
            XCTAssertEqual(result["isError"] as? Bool, true, params)
            let content = try XCTUnwrap(result["content"] as? [NSDictionary])
            XCTAssertEqual(content.first?["type"] as? String, "text")
            XCTAssertEqual(content.first?["text"] as? String, expected, params)
        }
    }

    func testJSONRPCErrors() async throws {
        let dispatcher = MCPDispatcher(tools: MCPToolHandler(host: TestMCPHost()))
        let cases: [(body: String, status: Int, code: Int)] = [
            ("not json", 400, -32_700),
            (#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, 400, -32_600),
            (#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, 400, -32_600),
            (#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, 400, -32_600),
            (#"{"jsonrpc":"2.0","id":1}"#, 400, -32_600),
            (#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#, 200, -32_601),
            (#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[1]}"#, 200, -32_602),
            (#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_tasks","arguments":[]}}"#, 200,
             -32_602),
        ]
        for testCase in cases {
            let response = await dispatcher.handle(body: Data(testCase.body.utf8), context: context(.project))
            XCTAssertEqual(response.status, testCase.status, testCase.body)
            let reply = try object(response.body)
            XCTAssertEqual((reply["error"] as? NSDictionary)?["code"] as? Int, testCase.code, testCase.body)
        }
        let parseError = try object(await dispatcher.handle(body: Data("not json".utf8), context: context(.project)).body)
        XCTAssertTrue(parseError["id"] is NSNull)
        XCTAssertEqual((parseError["error"] as? NSDictionary)?["message"] as? String, "Parse error")
        let batch = try object(await dispatcher.handle(body: Data("[]".utf8), context: context(.project)).body)
        XCTAssertEqual((batch["error"] as? NSDictionary)?["message"] as? String, "Batch requests are not supported")
    }

    // MARK: - Helpers

    private func context(_ kind: SessionKind, taskID: String? = nil) -> MCPSessionContext {
        MCPSessionContext(sessionID: UUID(), projectID: "HEPH", kind: kind,
                          taskID: taskID ?? (kind == .task ? "HEPH-1" : nil),
                          bundleID: kind == .bundle ? "HEPH-B1" : nil)
    }

    private func lengthRequest(_ body: String) -> String {
        "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
            + body
    }

    private func postRequest(_ body: String, token: String?) -> String {
        var head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nConnection: close\r\n"
        if let token {
            head += "Authorization: Bearer \(token)\r\n"
        }
        return head + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
    }

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private struct HTTPReply {
        var status: Int
        var headers: [String: String]   // lowercase names
        var body: Data
    }

    /// Sends one request over a new TCP connection to 127.0.0.1 and reads one response.
    private func exchange(_ port: UInt16, _ request: String) async throws -> HTTPReply {
        try await Task.detached { try Self.blockingExchange(port, Data(request.utf8)) }.value
    }

    private struct ExchangeError: Error {
        let reason: String
    }

    private static func blockingExchange(_ port: UInt16, _ request: Data) throws -> HTTPReply {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ExchangeError(reason: "socket") }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw ExchangeError(reason: "connect") }
        try request.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = send(descriptor, base + sent, buffer.count - sent, 0)
                guard count > 0 else { throw ExchangeError(reason: "send") }
                sent += count
            }
        }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let reply = parse(received) {
                return reply
            }
            let count = recv(descriptor, &chunk, chunk.count, 0)
            guard count > 0 else { throw ExchangeError(reason: "the connection closed before a response") }
            received.append(contentsOf: chunk[0..<count])
        }
    }

    /// A complete response, nil when more bytes are needed.
    private static func parse(_ data: Data) -> HTTPReply? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPReply(status: status, headers: headers, body: Data(body.prefix(length)))
    }
}

/// An MCPHost without other Mains or projects: tools that need none can run.
private struct TestMCPHost: MCPHost {
    let mainID = UUID()

    func localMain() async -> MCPMain {
        MCPMain(id: mainID, name: "Studio", online: true)
    }

    func otherMains() async -> [MCPMain] {
        []
    }

    func perform(_ method: String, params: Data, on deviceID: UUID) async throws -> Data {
        throw ProtocolError(.unavailable, "No method is served in this test.")
    }

    func localProjectRoot(_ projectID: String) async -> URL? {
        nil
    }

    func forgePushDocs(sessionID: UUID) async throws -> String {
        throw ProtocolError(.conflict, "Nothing to push: commit your change first.")
    }

    func forgePushRegen(sessionID: UUID) async throws -> String {
        throw ProtocolError(.conflict, "Nothing to push: commit your change first.")
    }

    func bundleTool(_ name: String, projectID: String, bundleID: String, arguments: Data) async throws -> String {
        throw ProtocolError(.notFound, "Bundle \(bundleID) does not exist.")
    }
}
#endif
