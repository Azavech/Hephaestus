#if os(macOS)
import Foundation
import HephCore
import Network
import os
import Security

/// The session a bearer token belongs to.
public struct MCPSessionContext: Sendable, Equatable {
    public var sessionID: UUID
    public var projectID: String
    public var kind: SessionKind
    public var ticketID: String?
    public var bundleID: String?

    public init(sessionID: UUID, projectID: String, kind: SessionKind, ticketID: String?, bundleID: String?) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.kind = kind
        self.ticketID = ticketID
        self.bundleID = bundleID
    }
}

/// The MCP server of this Main (docs/claude/mcp.md): Streamable HTTP, JSON-RPC 2.0 over `POST /mcp` on
/// `127.0.0.1:<port>`, JSON responses only. Each session process gets a bearer token that selects its context.
public actor MCPServer {
    private let dispatcher: MCPDispatcher
    /// The queue of the listener (Network.framework callbacks); each connection has its own.
    private let queue = DispatchQueue(label: "ca.azavech.hephaestus.mcp")
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var starting: Task<UInt16, Error>?
    private var tokens: [String: MCPSessionContext] = [:]
    private var connections: [UUID: MCPConnection] = [:]

    /// A connection with no byte received for this long is closed.
    private static let idleTimeout: Duration = .seconds(120)

    public init(host: any MCPHost) {
        dispatcher = MCPDispatcher(tools: MCPToolHandler(host: host))
    }

    // MARK: - Lifecycle

    /// Starts listening on 127.0.0.1 with a port chosen by the system and returns it; returns the port at once when
    /// already running.
    @discardableResult public func start() async throws -> UInt16 {
        if let boundPort, listener != nil {
            return boundPort
        }
        if let starting {
            return try await starting.value
        }
        let task = Task { try await self.openListener() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    public func stop() async {
        starting?.cancel()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        tokens.removeAll()
        Log.host.info("MCP server stopped")
    }

    public var port: UInt16? {
        listener == nil ? nil : boundPort
    }

    // MARK: - Tokens (§5)

    /// Registers a session process; returns its new bearer token.
    public func register(_ context: MCPSessionContext) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        tokens[token] = context
        return token
    }

    /// Forgets a token (process ended). Calls in progress complete.
    public func unregister(token: String) {
        tokens[token] = nil
    }

    /// The --mcp-config value (section 5). Call it after start().
    public func configJSON(token: String) -> String {
        let port = boundPort ?? 0
        return #"{"mcpServers":{"hephaestus":{"type":"http","url":"http://127.0.0.1:"#
            + String(port) + #"/mcp","headers":{"Authorization":"Bearer "# + token + #""}}}}"#
    }

    // MARK: - Listener

    private func openListener() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let port: UInt16 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                // Runs on the queue; the continuation is resumed once, by the first final state.
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    let first = { resumed.withLock { wasResumed -> Bool in
                        defer { wasResumed = true }
                        return !wasResumed
                    } }
                    switch state {
                    case .ready:
                        if first() {
                            continuation.resume(returning: listener?.port?.rawValue ?? 0)
                        }
                    case .failed(let error), .waiting(let error):
                        if first() {
                            listener?.cancel()
                            continuation.resume(throwing: error)
                        } else if case .failed = state, let self {
                            let description = error.debugDescription
                            Task { await self.listenerFailed(description) }
                        }
                    case .cancelled:
                        if first() {
                            continuation.resume(throwing: CancellationError())
                        }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    Task { await self.accept(connection) }
                }
                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
        }
        self.listener = listener
        boundPort = port
        Log.host.info("MCP server listening on 127.0.0.1:\(port, privacy: .public)")
        return port
    }

    /// The listener failed after it was ready: the next session start calls start() again.
    private func listenerFailed(_ description: String) {
        Log.host.error("The MCP server failed: \(description)")
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    // MARK: - Connections (§3)

    private func accept(_ connection: NWConnection) {
        guard listener != nil else {
            connection.cancel()
            return
        }
        let id = UUID()
        let served = MCPConnection(connection)
        connections[id] = served
        served.start()
        Task { await self.serve(served, id: id) }
    }

    private func connectionEnded(_ id: UUID) {
        connections[id] = nil
    }

    private func context(forToken token: String) -> MCPSessionContext? {
        tokens[token]
    }

    /// Serves one connection: the complete requests in order, one at a time, until it closes.
    private nonisolated func serve(_ connection: MCPConnection, id: UUID) async {
        var parser = HTTPRequestParser()
        reading: while true {
            guard let chunk = await receive(connection) else { break }
            parser.append(chunk)
            while true {
                let request: HTTPRequest?
                do {
                    request = try parser.nextRequest()
                } catch {
                    let status: Int
                    switch error as? HTTPParseError {
                    case .headersTooLarge?: status = 431
                    case .bodyTooLarge?: status = 413
                    default: status = 400
                    }
                    await connection.send(HTTPResponse(status: status).serialized(close: true))
                    break reading
                }
                guard let request else { break }
                let response = await respond(to: request)
                await connection.send(response.serialized(close: !request.keepAlive))
                if !request.keepAlive {
                    break reading
                }
            }
        }
        connection.cancel()
        await connectionEnded(id)
    }

    /// The next bytes, nil when the connection closed, failed, or received nothing for 120 s.
    private nonisolated func receive(_ connection: MCPConnection) async -> Data? {
        enum Received: Sendable {
            case data(Data)
            case closed
            case timedOut
        }
        let outcome = await withTaskGroup(of: Received.self) { group in
            group.addTask {
                guard let data = await connection.receive() else { return .closed }
                return .data(data)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: Self.idleTimeout)
                    return .timedOut
                } catch {
                    return .closed
                }
            }
            let first = await group.next() ?? .closed
            if case .timedOut = first {
                // Completes the pending receive.
                connection.cancel()
            }
            group.cancelAll()
            return first
        }
        if case .data(let data) = outcome {
            return data
        }
        return nil
    }

    /// The routing table of §3 for a parsed request.
    private nonisolated func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard request.path == "/mcp" else {
            return HTTPResponse(status: 404)
        }
        guard request.method == "POST" else {
            return HTTPResponse(status: 405, headers: [HTTPHeader(name: "Allow", value: "POST")])
        }
        guard let token = Self.bearerToken(request.header("Authorization")),
              let context = await context(forToken: token)
        else {
            return HTTPResponse(status: 401, headers: [HTTPHeader(name: "WWW-Authenticate", value: "Bearer")])
        }
        return await dispatcher.handle(body: request.body, context: context)
    }

    /// The token of an `Authorization: Bearer <token>` header.
    private static func bearerToken(_ value: String?) -> String? {
        guard let value, let space = value.firstIndex(of: " ") else { return nil }
        guard value[..<space].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
        let token = value[value.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

/// One accepted connection of the MCP server.
///
/// `@unchecked Sendable`: the NWConnection is only started, read, written and cancelled through its own methods, and
/// its callbacks run on the connection's own serial queue (`ca.azavech.hephaestus.mcp`).
private final class MCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ca.azavech.hephaestus.mcp")

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.start(queue: queue)
    }

    /// Up to 65,536 bytes; nil at the end of the stream or on an error.
    func receive() async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Sends the bytes and waits until they are processed (errors are ignored: the connection then ends).
    func send(_ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    func cancel() {
        connection.cancel()
    }
}
#endif
