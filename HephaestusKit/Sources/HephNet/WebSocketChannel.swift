import CryptoKit
import Foundation
import HephCore
import Network
import Synchronization

/// The TLS-PSK WebSocket MessageChannel. Its NWConnection and state are confined to one serial queue.
///
/// `@unchecked Sendable`: the NWConnection and the mutable state are touched only on `queue`
/// (`ca.azavech.hephaestus.websocket`, one per channel). The public `state` is also kept behind a lock, so that it can
/// be read from any thread and `close()` takes effect before it returns.
public final class WebSocketChannel: MessageChannel, @unchecked Sendable {
    // MessageChannel (protocol/envelope.md)

    public var state: ChannelState {
        publicState.withLock { $0 }
    }

    public var inbound: AsyncStream<Data> {
        stream
    }

    /// Returns at once. The frame is written on the channel's queue, after the frames of the earlier calls. A frame
    /// sent while closed is dropped; a frame larger than `WireCoding.maxFrameSize` is dropped and logged.
    public func send(_ frame: Data) {
        guard isOpen else { return }
        guard frame.count <= WireCoding.maxFrameSize else {
            Log.net.error("Dropped an outgoing frame of \(frame.count, privacy: .public) bytes: larger than the maximum frame size")
            return
        }
        queue.async { self.write(frame) }
    }

    /// Idempotent. When open: the state becomes `.closed(reason: nil)`, `inbound` finishes after the frames already
    /// received, a close frame is sent and the connection is cancelled when that send completes or after 1 s.
    public func close() {
        guard markClosed(reason: nil) else { return }
        Log.net.info("Closed the channel with \(self.remoteDescription)")
        queue.async { self.shutDown(sendingCloseFrame: true) }
    }

    public let isClient: Bool
    /// "<host>:<port>" of the other side, for logs and messages.
    public let remoteDescription: String

    /// wss://<host>:<port><path>, built with URLComponents; a host containing ":" (IPv6) is written in brackets.
    /// nil when the host is empty, the port is outside 0…65535, or the URL cannot be built.
    public static func url(host: String, port: Int, path: String) -> URL? {
        guard !host.isEmpty, (0...65_535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        components.path = path
        return components.url
    }

    /// Opens a client channel and returns once the WebSocket is open.
    public static func connect(url: URL, psk: SymmetricKey, identity: String,
                               timeout: Duration = .seconds(10)) async throws -> WebSocketChannel {
        try Task.checkCancellation()
        let connection = NWConnection(to: .url(url),
                                      using: MeshParameters.make(psk: psk, identity: identity, listener: false))
        let channel = WebSocketChannel(connection: connection, isClient: true, remoteDescription: describe(url))
        do {
            try await channel.openAsClient(timeout: timeout)
        } catch {
            Log.net.error("Cannot open a channel to \(channel.remoteDescription): \(String(describing: error))")
            throw error
        }
        Log.net.info("Opened a channel to \(channel.remoteDescription)")
        return channel
    }

    /// The mesh connection: the transport PSK of `credentials` and the identity "hephaestus".
    /// Throws MeshTransportError.invalidCredentials when MeshCrypto.transportKey returns nil.
    public static func connect(url: URL, credentials: MeshCredentials,
                               timeout: Duration = .seconds(10)) async throws -> WebSocketChannel {
        guard let key = MeshCrypto.transportKey(credentials) else {
            throw MeshTransportError.invalidCredentials
        }
        return try await connect(url: url, psk: key, identity: MeshConstants.transportIdentity, timeout: timeout)
    }

    // MARK: - Server side (WebSocketListener)

    /// A server channel for a connection the listener accepted; `startAccepted` starts it.
    convenience init(accepted connection: NWConnection) {
        self.init(connection: connection, isClient: false,
                  remoteDescription: WebSocketChannel.describe(connection.endpoint))
    }

    /// Starts an accepted connection on the channel's queue. `completion` runs once, on the channel's queue: success
    /// when the TLS and WebSocket handshakes completed (the channel is open), else the failure, after the connection
    /// was cancelled.
    func startAccepted(timeout: Duration,
                       completion: @escaping @Sendable (Result<Void, HandshakeFailure>) -> Void) {
        queue.async { self.startHandshake(timeout: timeout, completion: completion) }
    }

    /// Cancels a handshake still running (its completion gets `.cancelled`); does nothing once it finished.
    func abortHandshake() {
        queue.async { self.finishHandshake(.failure(.cancelled)) }
    }

    // MARK: - State

    private enum Phase {
        case idle         // created, not started
        case handshaking  // started, waiting for .ready
        case open         // receiving, keep-alive running
        case finished     // failed or closed; the connection is cancelled or being closed
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ca.azavech.hephaestus.websocket")
    private let publicState = Mutex(ChannelState.open)
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    // Confined to `queue`.
    private var phase = Phase.idle
    private var handshakeCompletion: (@Sendable (Result<Void, HandshakeFailure>) -> Void)?
    private var handshakeTimer: Task<Void, Never>?
    private var cancelRequested = false
    private var message = Data()
    private var messageOpcode: NWProtocolWebSocket.Opcode?
    private var lastInbound = ContinuousClock.now
    private var keepAlive: Task<Void, Never>?

    private init(connection: NWConnection, isClient: Bool, remoteDescription: String) {
        self.connection = connection
        self.isClient = isClient
        self.remoteDescription = remoteDescription
        (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    deinit {
        handshakeTimer?.cancel()
        keepAlive?.cancel()
        connection.cancel()
        continuation.finish()
    }

    private var isOpen: Bool {
        publicState.withLock { $0 == .open }
    }

    /// Sets `.closed(reason:)` and finishes `inbound` unless the channel is already closed; true when this call
    /// closed it.
    private func markClosed(reason: String?) -> Bool {
        let closed = publicState.withLock { state -> Bool in
            guard state == .open else { return false }
            state = .closed(reason: reason)
            return true
        }
        if closed {
            continuation.finish()
        }
        return closed
    }

    // MARK: - Opening

    /// The client side of `connect`: waits for `.ready`, a failure, the timeout or the cancellation of the calling
    /// task. In every failure case the connection is cancelled first.
    private func openAsClient(timeout: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    if self.cancelRequested {
                        self.phase = .finished
                        self.connection.cancel()
                        _ = self.markClosed(reason: "Cancelled.")
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.startHandshake(timeout: timeout) { result in
                        switch result {
                        case .success: continuation.resume()
                        case .failure(let failure): continuation.resume(throwing: failure.transportError)
                        }
                    }
                }
            }
        } onCancel: {
            queue.async {
                self.cancelRequested = true
                self.finishHandshake(.failure(.cancelled))
            }
        }
    }

    /// On the queue: starts the connection and the handshake timer.
    private func startHandshake(timeout: Duration,
                                completion: @escaping @Sendable (Result<Void, HandshakeFailure>) -> Void) {
        guard phase == .idle else { return }
        phase = .handshaking
        handshakeCompletion = completion
        connection.stateUpdateHandler = { [weak self] state in
            self?.connectionStateChanged(state)
        }
        connection.start(queue: queue)
        handshakeTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self else { return }
            self.queue.async { self.finishHandshake(.failure(.timedOut)) }
        }
    }

    /// On the queue: ends the handshake once. Success opens the channel; a failure cancels the connection first.
    private func finishHandshake(_ result: Result<Void, HandshakeFailure>) {
        guard phase == .handshaking, let completion = handshakeCompletion else { return }
        handshakeCompletion = nil
        handshakeTimer?.cancel()
        handshakeTimer = nil
        switch result {
        case .success:
            phase = .open
            lastInbound = .now
            receiveNext()
            startKeepAlive()
        case .failure(let failure):
            phase = .finished
            connection.cancel()
            _ = markClosed(reason: failure.description)
        }
        completion(result)
    }

    /// On the queue: every state change of the connection.
    private func connectionStateChanged(_ state: NWConnection.State) {
        switch phase {
        case .handshaking:
            switch state {
            case .ready:
                finishHandshake(.success(()))
            case .waiting(let error), .failed(let error):
                if case .tls = error {
                    finishHandshake(.failure(.authentication(error)))
                } else {
                    finishHandshake(.failure(.network(error)))
                }
            case .cancelled:
                finishHandshake(.failure(.cancelled))
            default:
                break
            }
        case .open:
            switch state {
            case .waiting(let error), .failed(let error):
                fail(reason: error.debugDescription)
            default:
                break
            }
        case .idle, .finished:
            break
        }
    }

    // MARK: - Receiving

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, context, isComplete, error in
            self?.received(content: content, context: context, isComplete: isComplete, error: error)
        }
    }

    /// On the queue: one received chunk. The chunks of a message are appended until one has `isComplete` true; the
    /// opcode comes from the WebSocket metadata every chunk carries.
    private func received(content: Data?, context: NWConnection.ContentContext?, isComplete: Bool, error: NWError?) {
        guard phase == .open else { return }
        let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata
        let hasData = !(content?.isEmpty ?? true)
        if hasData || metadata != nil {
            lastInbound = .now
        }
        if let error {
            fail(reason: error.debugDescription)
            return
        }
        guard hasData || metadata != nil else {
            // No data and no metadata: the end of the stream.
            fail(reason: "Closed by \(remoteDescription).")
            return
        }
        if metadata?.opcode == .close {
            fail(reason: "Closed by \(remoteDescription).")
            return
        }
        if let content {
            message.append(content)
        }
        if let opcode = metadata?.opcode {
            messageOpcode = opcode
        }
        if isComplete {
            let bytes = message
            let opcode = messageOpcode
            message = Data()
            messageOpcode = nil
            if opcode == .text {
                if isOpen {
                    continuation.yield(bytes)
                }
            } else if opcode == .binary {
                Log.net.debug("Ignored a received binary message of \(bytes.count, privacy: .public) bytes")
            }
        }
        receiveNext()
    }

    // MARK: - Sending

    /// On the queue: one text frame, after the frames of the earlier `send` calls.
    private func write(_ frame: Data) {
        guard phase == .open else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: frame, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            guard let error, let self else { return }
                            self.fail(reason: error.debugDescription)
                        })
    }

    // MARK: - Keep-alive

    /// Every `pingInterval` from the opening: the idle check, then a ping.
    private func startKeepAlive() {
        keepAlive = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: MeshConstants.pingInterval)
                } catch {
                    return
                }
                guard let self else { return }
                self.queue.async { self.keepAliveTick() }
            }
        }
    }

    /// On the queue.
    private func keepAliveTick() {
        guard phase == .open else { return }
        if ContinuousClock.now - lastInbound > MeshConstants.idleTimeout {
            fail(reason: "No data received for 30 s.")
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { [weak self] error in
            guard error == nil, let self, self.phase == .open else { return }
            self.lastInbound = .now
        }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    // MARK: - Closing

    /// On the queue: a failure or a close by the other side.
    private func fail(reason: String) {
        guard phase == .open else { return }
        if markClosed(reason: reason) {
            Log.net.info("The channel with \(self.remoteDescription) closed: \(reason)")
        }
        shutDown(sendingCloseFrame: false)
    }

    /// On the queue: stops the keep-alive and cancels the connection, after a close frame when `sendingCloseFrame`.
    private func shutDown(sendingCloseFrame: Bool) {
        switch phase {
        case .open:
            break
        case .idle:
            phase = .finished
            connection.cancel()
            return
        case .handshaking:
            finishHandshake(.failure(.cancelled))
            return
        case .finished:
            return
        }
        phase = .finished
        keepAlive?.cancel()
        keepAlive = nil
        message = Data()
        messageOpcode = nil
        let connection = self.connection
        guard sendingCloseFrame else {
            connection.cancel()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        let queue = self.queue
        Task {
            try? await Task.sleep(for: .seconds(1))
            queue.async { connection.cancel() }
        }
    }

    // MARK: - Descriptions

    private static func describe(_ url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? ""
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .url(let url):
            return describe(url)
        default:
            return "\(endpoint)"
        }
    }
}

/// Why opening a channel failed, before it was open.
enum HandshakeFailure: Error, CustomStringConvertible {
    /// `.waiting(.tls(_))` or `.failed(.tls(_))`: the key was refused.
    case authentication(NWError)
    /// Any other `.waiting(e)` or `.failed(e)`.
    case network(NWError)
    /// No `.ready` within the timeout.
    case timedOut
    /// Cancelled: the calling task, or the listener stopped.
    case cancelled

    /// The error `connect` throws.
    var transportError: Error {
        switch self {
        case .authentication: return MeshTransportError.authenticationFailed
        case .network(let error): return MeshTransportError.unreachable(error.debugDescription)
        case .timedOut: return MeshTransportError.timedOut
        case .cancelled: return CancellationError()
        }
    }

    var description: String {
        switch self {
        case .authentication(let error), .network(let error): return error.debugDescription
        case .timedOut: return "Timed out."
        case .cancelled: return "Cancelled."
        }
    }
}

/// The errors of the transport (docs/devices/mesh.md, "MeshTransportError").
public enum MeshTransportError: Error, Equatable, Sendable, LocalizedError {
    case authenticationFailed
    case unreachable(String)
    case timedOut
    case invalidCredentials
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed: return "The mesh key was refused."
        case .unreachable(let detail): return "Cannot connect: \(detail)"
        case .timedOut: return "The connection timed out."
        case .invalidCredentials: return "The mesh credentials are invalid."
        case .listenerFailed(let text): return text
        }
    }
}
