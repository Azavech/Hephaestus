import Foundation
import HephCore

/// One side of a connection: it sends requests and events, serves the requests it receives with its request handler,
/// and delivers the events it receives (docs/protocol/envelope.md, "RPCPeer.swift").
///
/// Usage: the owner creates the peer on an open channel, sets the request handler, starts `run()` (in a task, or
/// awaited by the code that serves the connection), consumes `events` if it uses events, then sends requests.
public actor RPCPeer {
    /// Returns the UTF-8 JSON of the result object (WireCoding.encodeJSON(result)).
    public typealias RequestHandler = @Sendable (InboundRequest) async throws -> Data

    public static let defaultTimeout: Duration = .seconds(30)

    public nonisolated let channel: any MessageChannel
    /// The events received, in arrival order; finishes when the connection has closed.
    public nonisolated let events: AsyncStream<InboundEvent>

    public init(channel: any MessageChannel, requestTimeout: Duration = RPCPeer.defaultTimeout) {
        self.channel = channel
        self.requestTimeout = requestTimeout
        (events, eventsContinuation) = AsyncStream.makeStream(of: InboundEvent.self, bufferingPolicy: .unbounded)
    }

    public func setRequestHandler(_ handler: @escaping RequestHandler) {
        requestHandler = handler
    }

    /// Reads the channel until it closes. Returns after every pending request has failed and `events` finished.
    public func run() async {
        guard !running else { return }
        running = true
        for await frame in channel.inbound {
            receive(frame)
        }
        closed = true
        // The inbound stream also ends when the task running `run()` is cancelled: the channel closes too.
        channel.close()
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timer.cancel()
            request.continuation.resume(throwing: ProtocolError(.unavailable, "Not connected."))
        }
        eventsContinuation.finish()
    }

    public var isClosed: Bool {
        closed || channel.state != .open
    }

    /// `timeout` nil: the peer's request timeout.
    public func request<R: Decodable & Sendable>(
        _ method: String, _ params: some Encodable & Sendable, as resultType: R.Type = R.self,
        timeout: Duration? = nil
    ) async throws -> R {
        guard !isClosed else {
            throw ProtocolError(.unavailable, "Not connected.")
        }
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        let frame: Data
        do {
            frame = try WireCoding.encodeRequest(id: id, method: method, params: params)
        } catch {
            throw ProtocolError(error)
        }
        guard frame.count <= WireCoding.maxFrameSize else {
            throw ProtocolError(.tooLarge, "The request is larger than 48 MiB.")
        }
        let body = try await send(frame, id: id, method: method, timeout: timeout ?? requestTimeout)
        return try await RPCPeer.decodeResult(R.self, from: body, method: method)
    }

    public func request<R: Decodable & Sendable>(
        _ method: RPCMethod, _ params: some Encodable & Sendable, as resultType: R.Type = R.self,
        timeout: Duration? = nil
    ) async throws -> R {
        try await request(method.rawValue, params, as: resultType, timeout: timeout)
    }

    public nonisolated func emit(_ event: ServerEvent) {
        let frame: Data
        do {
            frame = try event.encodeFrame()
        } catch {
            Log.net.error("Dropped the event \(event.name.rawValue, privacy: .public): it does not encode")
            return
        }
        sendEvent(frame, name: event.name.rawValue)
    }

    public nonisolated func emit(_ name: String, _ params: some Encodable & Sendable) {
        let frame: Data
        do {
            frame = try WireCoding.encodeEvent(name: name, params: params)
        } catch {
            Log.net.error("Dropped the event \(name, privacy: .public): it does not encode")
            return
        }
        sendEvent(frame, name: name)
    }

    /// Sends an event frame encoded beforehand (`ServerEvent.encodeFrame()` or `WireCoding.encodeEvent`); it is
    /// logged with its size only.
    public nonisolated func emit(frame: Data) {
        sendEvent(frame, name: nil)
    }

    /// Closes the channel; `run()` then ends.
    public nonisolated func close() {
        channel.close()
    }

    /// Sends an event frame, or drops it when it is larger than the maximum frame size. `name`: the event's name,
    /// logged with the frame; nil for a frame a caller passes to `emit(frame:)`, logged with its size only.
    private nonisolated func sendEvent(_ frame: Data, name: String?) {
        guard frame.count <= WireCoding.maxFrameSize else {
            if let name {
                Log.net.error("Dropped the event \(name, privacy: .public) of \(frame.count, privacy: .public) bytes: larger than the maximum frame size")
            } else {
                Log.net.error("Dropped an event of \(frame.count, privacy: .public) bytes: larger than the maximum frame size")
            }
            return
        }
        if let name {
            Log.net.debug("Sent event \(name, privacy: .public) (\(frame.count, privacy: .public) bytes)")
        } else {
            Log.net.debug("Sent an event of \(frame.count, privacy: .public) bytes")
        }
        channel.send(frame)
    }

    // MARK: - State

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timer: Task<Void, Never>
    }

    private let requestTimeout: Duration
    private let eventsContinuation: AsyncStream<InboundEvent>.Continuation
    private var requestHandler: RequestHandler?
    private var running = false
    private var closed = false
    private var nextID = 0
    private var pending: [Int: PendingRequest] = [:]

    // MARK: - Receiving

    private func receive(_ frame: Data) {
        let parsed: ParsedFrame
        do {
            parsed = try WireCoding.parseFrame(frame)
        } catch {
            Log.net.error("Ignored a malformed frame of \(frame.count, privacy: .public) bytes")
            return
        }
        switch parsed.kind {
        case .request:
            guard let id = parsed.id, let method = parsed.method else { return }
            Log.net.debug("Received request \(method, privacy: .public) #\(id, privacy: .public) (\(frame.count, privacy: .public) bytes)")
            let request = InboundRequest(id: id, method: method, params: parsed.body)
            let handler = requestHandler
            let channel = self.channel
            Task {
                await RPCPeer.serve(request, handler: handler, channel: channel)
            }
        case .response:
            guard let id = parsed.id else { return }
            guard let request = pending.removeValue(forKey: id) else {
                Log.net.debug("Ignored response #\(id, privacy: .public) (\(frame.count, privacy: .public) bytes): no pending request")
                return
            }
            Log.net.debug("Received response #\(id, privacy: .public) (\(frame.count, privacy: .public) bytes)")
            request.timer.cancel()
            if let error = parsed.error {
                request.continuation.resume(throwing: error)
            } else {
                request.continuation.resume(returning: parsed.body)
            }
        case .event:
            guard let name = parsed.event else { return }
            Log.net.debug("Received event \(name, privacy: .public) (\(frame.count, privacy: .public) bytes)")
            eventsContinuation.yield(InboundEvent(name: name, params: parsed.body))
        }
    }

    /// Runs the request handler and sends its response; an error becomes an error response.
    private static func serve(_ request: InboundRequest, handler: RequestHandler?, channel: any MessageChannel) async {
        var frame: Data
        do {
            guard let handler else {
                throw ProtocolError(.badRequest, "Unknown method \(request.method).")
            }
            let result = try await handler(request)
            frame = WireCoding.encodeResponse(id: request.id, resultJSON: result)
            if frame.count > WireCoding.maxFrameSize {
                frame = try WireCoding.encodeError(id: request.id,
                                                   error: ProtocolError(.tooLarge, "The response is larger than 48 MiB."))
            }
        } catch {
            let protocolError = ProtocolError(error)
            if protocolError.code == .internal {
                Log.net.error("Request \(request.method, privacy: .public) #\(request.id, privacy: .public) failed: \(protocolError.message)")
            }
            do {
                frame = try WireCoding.encodeError(id: request.id, error: protocolError)
            } catch {
                Log.net.error("Dropped the error response #\(request.id, privacy: .public): it does not encode")
                return
            }
        }
        Log.net.debug("Sent response #\(request.id, privacy: .public) (\(frame.count, privacy: .public) bytes)")
        channel.send(frame)
    }

    // MARK: - Requests

    /// Registers the request as pending, sends it and waits for its response body.
    private func send(_ frame: Data, id: Int, method: String, timeout: Duration) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.expire(id)
                }
                pending[id] = PendingRequest(continuation: continuation, timer: timer)
                Log.net.debug("Sent request \(method, privacy: .public) #\(id, privacy: .public) (\(frame.count, privacy: .public) bytes)")
                channel.send(frame)
            }
        } onCancel: {
            Task { await self.forget(id) }
        }
    }

    /// No response within the timeout: the request is forgotten.
    private func expire(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: ProtocolError(.unavailable, "The device did not answer in time."))
    }

    /// The calling task was cancelled: the request is forgotten.
    private func forget(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    /// Decodes a success response's body, off the actor.
    private static func decodeResult<R: Decodable & Sendable>(_ type: R.Type, from body: Data,
                                                              method: String) async throws -> R {
        do {
            return try WireCoding.decodeJSON(type, from: body)
        } catch {
            throw ProtocolError(.internal, "Invalid response to \(method).")
        }
    }
}
