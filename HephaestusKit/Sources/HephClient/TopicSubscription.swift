import Foundation
import HephCore
import Synchronization

/// A held subscription to a topic of a Main (docs/client/workspace.md, "Subscriptions"). The Workspace counts the
/// holders of each topic: the first one holds it, the last `cancel()` releases it.
@MainActor
public final class TopicSubscription {
    public let mainDeviceID: UUID
    public let topic: Topic

    /// True once cancelled; read by `deinit`, which is not isolated.
    private let isCancelled = Mutex(false)
    private weak var workspace: Workspace?
    /// Schedules the release on the main actor, for `deinit`.
    private let releaseLater: @Sendable () -> Void

    init(workspace: Workspace, mainDeviceID: UUID, topic: Topic) {
        self.workspace = workspace
        self.mainDeviceID = mainDeviceID
        self.topic = topic
        releaseLater = { [weak workspace] in
            Task { @MainActor in
                workspace?.releaseTopic(topic, on: mainDeviceID)
            }
        }
    }

    /// Releases the subscription; idempotent.
    public func cancel() {
        guard markCancelled() else { return }
        workspace?.releaseTopic(topic, on: mainDeviceID)
    }

    /// A subscription released without `cancel()` cancels itself.
    deinit {
        if markCancelled() {
            releaseLater()
        }
    }

    /// Sets the flag; true when it was not set.
    private nonisolated func markCancelled() -> Bool {
        isCancelled.withLock { cancelled in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
    }
}

extension Workspace {
    /// Holds `topic` on the Main `mainDeviceID`. The first holder queues `subscribe` and awaits its answer; a failure
    /// is logged and the topic stays held. On every handshake the held topics are subscribed again.
    public func subscribe(_ topic: Topic, on mainDeviceID: UUID) async -> TopicSubscription {
        let subscription = TopicSubscription(workspace: self, mainDeviceID: mainDeviceID, topic: topic)
        let key = TopicKey(mainDeviceID: mainDeviceID, topic: topic)
        let holders = topicHolders[key, default: 0]
        topicHolders[key] = holders + 1
        if holders == 0, let request = enqueueTopicRequest(subscribe: true, topic, on: mainDeviceID) {
            await request.value
        }
        return subscription
    }

    /// One holder of the topic is gone; the last one queues `unsubscribe`, without waiting.
    func releaseTopic(_ topic: Topic, on mainDeviceID: UUID) {
        let key = TopicKey(mainDeviceID: mainDeviceID, topic: topic)
        guard let holders = topicHolders[key] else { return }
        if holders > 1 {
            topicHolders[key] = holders - 1
            return
        }
        topicHolders[key] = nil
        enqueueTopicRequest(subscribe: false, topic, on: mainDeviceID)
    }

    /// Queues a `subscribe` or `unsubscribe` request behind the earlier ones of the Main: it is sent once the previous
    /// one has been answered, when the connection is connected on the same peer as when it was queued (a close drops
    /// it) and the request is still needed: `subscribe` while the topic is held, `unsubscribe` while it is not.
    @discardableResult
    private func enqueueTopicRequest(subscribe: Bool, _ topic: Topic, on mainDeviceID: UUID) -> Task<Void, Never>? {
        guard let connection = connection(mainDeviceID) else { return nil }
        let generation = connection.generation
        let key = TopicKey(mainDeviceID: mainDeviceID, topic: topic)
        let previous = topicQueues[mainDeviceID]
        let request = Task { [weak self, weak connection] in
            await previous?.value
            guard let self, let connection, connection.isConnected, connection.generation == generation,
                  (self.topicHolders[key] != nil) == subscribe else { return }
            do {
                if subscribe {
                    try await connection.subscribeTopics([topic])
                } else {
                    try await connection.unsubscribeTopics([topic])
                }
            } catch {
                let message = Workspace.message(of: error)
                if subscribe {
                    Log.client.error("Could not subscribe to \(topic.rawValue, privacy: .public): \(message)")
                } else {
                    Log.client.error("Could not unsubscribe from \(topic.rawValue, privacy: .public): \(message)")
                }
            }
        }
        topicQueues[mainDeviceID] = request
        return request
    }

    /// The topics held on a Main, for the re-subscription of the reconnect sequence.
    func heldTopics(on mainDeviceID: UUID) -> [Topic] {
        topicHolders.keys.filter { $0.mainDeviceID == mainDeviceID }.map(\.topic).sorted { $0.rawValue < $1.rawValue }
    }
}

/// A topic of a Main, counted by the Workspace.
struct TopicKey: Hashable {
    let mainDeviceID: UUID
    let topic: Topic
}
