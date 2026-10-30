import CryptoKit
import Foundation
import HephCore
import Network
import Synchronization

/// A listener of mesh or pairing connections. NWListener and state confined to one serial queue.
///
/// `@unchecked Sendable`: the NWListener, the connections still in their handshake and the callbacks are touched
/// only on `queue` (`ca.azavech.hephaestus.listener`); the bound port is also kept behind a lock so that it can be
/// read from any thread.
public final class WebSocketListener: @unchecked Sendable {
    /// port 0: any free port (tests). host: the local address to bind (tests: "127.0.0.1"); nil: every interface.
    public init(port: Int, psk: SymmetricKey, identity: String, host: String? = nil) {
        requestedPort = port
        self.psk = psk
        self.identity = identity
        self.host = host
        queue.setSpecific(key: WebSocketListener.queueKey, value: ObjectIdentifier(self))
    }

    /// Starts listening and returns once ready. onChannel gets every connection that completed the TLS and WebSocket
    /// handshakes (a server WebSocketChannel, open); onHandshakeFailure is called for each failed TLS handshake.
    /// Throws CancellationError when the calling task is cancelled or stop() runs before the listener is ready.
    public func start(onChannel: @escaping @Sendable (WebSocketChannel) -> Void,
                      onHandshakeFailure: @escaping @Sendable () -> Void = {}) async throws {
        guard (0...65_535).contains(requestedPort), let port = NWEndpoint.Port(rawValue: UInt16(requestedPort)) else {
            throw MeshTransportError.listenerFailed("Invalid port \(requestedPort).")
        }
        try Task.checkCancellation()
        let localPort: NWEndpoint.Port = requestedPort == 0 ? .any : port
        let parameters = MeshParameters.make(psk: psk, identity: identity, listener: true)
        let listener: NWListener
        do {
            if let host {
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: localPort)
                listener = try NWListener(using: parameters)
            } else {
                listener = try NWListener(using: parameters, on: localPort)
            }
        } catch let error as NWError {
            throw failure(error)
        } catch {
            throw MeshTransportError.listenerFailed("Cannot listen on port \(requestedPort): \(error.localizedDescription).")
        }
        let attempt = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    self.begin(listener, attempt: attempt, continuation: continuation,
                               onChannel: onChannel, onHandshakeFailure: onHandshakeFailure)
                }
            }
        } onCancel: {
            queue.async { self.cancelStart(attempt: attempt) }
        }
    }

    /// The bound port once started; 0 before.
    public var port: Int {
        boundPort.withLock { $0 }
    }

    /// The Bonjour advertisement (NWListener.service); nil removes it. May be called before or after start.
    public func setService(_ service: NWListener.Service?) {
        queue.async {
            self.service = service
            self.listener?.service = service
        }
    }

    /// Cancels the listener, which is cancelled when this returns, and the connections still in their handshakes (one
    /// that completes afterwards is closed, never delivered). Channels already delivered stay open.
    public func stop() {
        onQueue {
            self.cancelListener()
            if let continuation = self.startContinuation {
                self.startContinuation = nil
                self.startAttempt = nil
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: - State

    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    private let requestedPort: Int
    private let psk: SymmetricKey
    private let identity: String
    private let host: String?
    private let queue = DispatchQueue(label: "ca.azavech.hephaestus.listener")
    private let boundPort = Mutex(0)

    // Confined to `queue`.
    private var listener: NWListener?
    private var service: NWListener.Service?
    private var onChannel: (@Sendable (WebSocketChannel) -> Void)?
    private var onHandshakeFailure: (@Sendable () -> Void)?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startAttempt: UUID?
    private var cancelledAttempts: Set<UUID> = []
    /// Accepted connections whose TLS and WebSocket handshakes are still running.
    private var pending: [ObjectIdentifier: WebSocketChannel] = [:]

    deinit {
        listener?.cancel()
        for channel in pending.values {
            channel.abortHandshake()
        }
    }

    /// Runs `work` on the queue and waits for it; inline when already on the queue.
    private func onQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: WebSocketListener.queueKey) == ObjectIdentifier(self) {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    // MARK: - Starting

    /// On the queue.
    private func begin(_ listener: NWListener, attempt: UUID, continuation: CheckedContinuation<Void, Error>,
                       onChannel: @escaping @Sendable (WebSocketChannel) -> Void,
                       onHandshakeFailure: @escaping @Sendable () -> Void) {
        if cancelledAttempts.remove(attempt) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        cancelListener()
        if let previous = startContinuation {
            previous.resume(throwing: CancellationError())
        }
        self.listener = listener
        self.onChannel = onChannel
        self.onHandshakeFailure = onHandshakeFailure
        startContinuation = continuation
        startAttempt = attempt
        if let service {
            listener.service = service
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener, self.listener === listener else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            self.listenerStateChanged(state)
        }
        listener.start(queue: queue)
    }

    /// On the queue: the calling task of `start` was cancelled.
    private func cancelStart(attempt: UUID) {
        if startAttempt == attempt, let continuation = startContinuation {
            startContinuation = nil
            startAttempt = nil
            cancelListener()
            continuation.resume(throwing: CancellationError())
        } else if startAttempt != attempt {
            // `begin` has not run yet: it resumes with CancellationError.
            cancelledAttempts.insert(attempt)
        }
    }

    /// On the queue.
    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                boundPort.withLock { $0 = Int(port.rawValue) }
            }
            if let continuation = startContinuation {
                startContinuation = nil
                startAttempt = nil
                Log.net.info("Listening on port \(self.port, privacy: .public)")
                continuation.resume()
            }
        case .failed(let error):
            listenerFailed(error)
        case .waiting(let error):
            if startContinuation != nil {
                listenerFailed(error)
            } else {
                Log.net.notice("The listener on port \(self.port, privacy: .public) is waiting: \(error.debugDescription)")
            }
        case .cancelled:
            if let continuation = startContinuation {
                startContinuation = nil
                startAttempt = nil
                continuation.resume(throwing: CancellationError())
            }
        default:
            break
        }
    }

    /// On the queue: after a failure the listener is cancelled.
    private func listenerFailed(_ error: NWError) {
        let failure = self.failure(error)
        cancelListener()
        if let continuation = startContinuation {
            startContinuation = nil
            startAttempt = nil
            continuation.resume(throwing: failure)
        } else {
            Log.net.error("The listener on port \(self.port, privacy: .public) failed: \(error.debugDescription)")
        }
    }

    /// On the queue: cancels the NWListener and the handshakes still running.
    private func cancelListener() {
        listener?.cancel()
        listener = nil
        for channel in pending.values {
            channel.abortHandshake()
        }
        pending.removeAll()
    }

    private func failure(_ error: NWError) -> MeshTransportError {
        if case .posix(.EADDRINUSE) = error {
            return .listenerFailed("Port \(requestedPort) is already in use.")
        }
        return .listenerFailed("Cannot listen on port \(requestedPort): \(error.debugDescription).")
    }

    // MARK: - Connections

    /// On the queue: a new connection; it becomes a server channel once its handshakes complete within 10 s.
    private func accept(_ connection: NWConnection) {
        let channel = WebSocketChannel(accepted: connection)
        let id = ObjectIdentifier(channel)
        pending[id] = channel
        channel.startAccepted(timeout: .seconds(10)) { [weak self] result in
            guard let self else {
                if case .success = result {
                    channel.close()
                }
                return
            }
            self.queue.async { self.handshakeFinished(channel, id: id, result: result) }
        }
    }

    /// On the queue.
    private func handshakeFinished(_ channel: WebSocketChannel, id: ObjectIdentifier,
                                   result: Result<Void, HandshakeFailure>) {
        guard pending.removeValue(forKey: id) != nil else {
            // The listener stopped during the handshake.
            if case .success = result {
                channel.close()
            }
            return
        }
        switch result {
        case .success:
            Log.net.info("Accepted a channel from \(channel.remoteDescription)")
            onChannel?(channel)
        case .failure(.authentication(let error)):
            Log.net.error("A TLS handshake on port \(self.port, privacy: .public) failed: \(error.debugDescription)")
            onHandshakeFailure?()
        case .failure(let failure):
            Log.net.debug("A connection on port \(self.port, privacy: .public) was dropped before it opened: \(failure.description)")
        }
    }
}
