#if os(macOS)
import Foundation
import HephCore
import HephNet

/// Event delivery to the connections of the host (docs/services/host.md §5): broadcast events go to every
/// authenticated connection, subscriber events to the connections subscribed to their topic.
public actor EventHub {
    /// The authenticated connections, by connection id.
    private var peers: [UUID: RPCPeer] = [:]
    /// The topics each connection subscribed to.
    private var subscriptions: [UUID: Set<Topic>] = [:]

    init(host: HostService) {}

    /// The connection passed hello: from now on it receives broadcast events.
    func add(_ connectionID: UUID, peer: RPCPeer) {
        peers[connectionID] = peer
    }

    /// The connection closed; drops its subscriptions.
    func remove(_ connectionID: UUID) {
        peers[connectionID] = nil
        subscriptions[connectionID] = nil
    }

    /// stop(): closes every connection and forgets it.
    func closeAll() {
        let closing = peers.values
        peers.removeAll()
        subscriptions.removeAll()
        for peer in closing {
            peer.close()
        }
    }

    func subscribe(_ connectionID: UUID, _ topics: [Topic]) {
        guard peers[connectionID] != nil else { return }
        subscriptions[connectionID, default: []].formUnion(topics)
    }

    func unsubscribe(_ connectionID: UUID, _ topics: [Topic]) {
        guard var current = subscriptions[connectionID] else { return }
        current.subtract(topics)
        subscriptions[connectionID] = current.isEmpty ? nil : current
    }

    /// An event whose `topic` is nil: sent to every authenticated connection.
    public func broadcast(_ event: ServerEvent) {
        guard event.topic == nil else {
            Log.host.error("Event \(event.name.rawValue, privacy: .public) has a topic: it is not broadcast")
            return
        }
        send(event, to: Array(peers.values))
    }

    /// An event with a topic: sent to the connections subscribed to `event.topic`.
    public func publish(_ event: ServerEvent) {
        guard let topic = event.topic else {
            Log.host.error("Event \(event.name.rawValue, privacy: .public) has no topic: it is not published")
            return
        }
        let targets = subscriptions.compactMap { connectionID, topics in
            topics.contains(topic) ? peers[connectionID] : nil
        }
        send(event, to: targets)
    }

    /// Encodes the event once and queues its frame on each target; never waits for a client.
    private func send(_ event: ServerEvent, to targets: [RPCPeer]) {
        guard !targets.isEmpty, let frame = encode(event) else { return }
        Log.host.debug("Event \(event.name.rawValue, privacy: .public) to \(targets.count, privacy: .public) connections")
        for peer in targets {
            peer.emit(frame: frame)
        }
    }

    /// The event's frame, encoded once; nil (logged) when it does not encode.
    private func encode(_ event: ServerEvent) -> Data? {
        do {
            return try event.encodeFrame()
        } catch {
            Log.host.error("Dropped the event \(event.name.rawValue, privacy: .public): it does not encode")
            return nil
        }
    }
}
#endif
