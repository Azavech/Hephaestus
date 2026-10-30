import Foundation
import Synchronization

/// An in-process pair of channels: a frame sent on one end is yielded by the other end's `inbound`, in order, without
/// size checks (docs/protocol/envelope.md, "LoopbackChannel.swift"). `close()` on either end closes both. A Main's own
/// UI talks to its own host through a pair; tests use pairs to run peers without a network.
public final class LoopbackChannel: MessageChannel {
    /// A new pair: the workspace connects the client end, the host accepts the server end.
    public static func makePair() -> (client: LoopbackChannel, server: LoopbackChannel) {
        let (clientStream, clientContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let (serverStream, serverContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let pair = LoopbackPair(client: clientContinuation, server: serverContinuation)
        return (LoopbackChannel(pair: pair, side: .client, inbound: clientStream),
                LoopbackChannel(pair: pair, side: .server, inbound: serverStream))
    }

    public var state: ChannelState {
        pair.isOpen ? .open : .closed(reason: nil)
    }

    public var inbound: AsyncStream<Data> {
        stream
    }

    public func send(_ frame: Data) {
        pair.deliver(frame, from: side)
    }

    public func close() {
        pair.close()
    }

    // MARK: - Private

    private let pair: LoopbackPair
    private let side: LoopbackSide
    private let stream: AsyncStream<Data>

    private init(pair: LoopbackPair, side: LoopbackSide, inbound: AsyncStream<Data>) {
        self.pair = pair
        self.side = side
        self.stream = inbound
    }
}

private enum LoopbackSide {
    case client, server
}

/// The state both ends of a pair share, behind one lock.
private final class LoopbackPair: Sendable {
    private struct State {
        var open = true
        /// Yields to the client end's `inbound`.
        let client: AsyncStream<Data>.Continuation
        /// Yields to the server end's `inbound`.
        let server: AsyncStream<Data>.Continuation
    }

    private let state: Mutex<State>

    init(client: AsyncStream<Data>.Continuation, server: AsyncStream<Data>.Continuation) {
        state = Mutex(State(client: client, server: server))
    }

    var isOpen: Bool {
        state.withLock { $0.open }
    }

    /// Yields the frame to the other end, under the lock so that frames keep the order of the `send` calls; dropped
    /// once the pair is closed.
    func deliver(_ frame: Data, from side: LoopbackSide) {
        state.withLock { state in
            guard state.open else { return }
            switch side {
            case .client: state.server.yield(frame)
            case .server: state.client.yield(frame)
            }
        }
    }

    /// Closes both ends; each `inbound` finishes after yielding the frames already sent.
    func close() {
        state.withLock { state in
            guard state.open else { return }
            state.open = false
            state.client.finish()
            state.server.finish()
        }
    }
}
