import Foundation
import HephCore
import Synchronization

/// A held subscription to a topic of a Main (docs/client/workspace.md, "Subscriptions"). The Workspace counts the
/// holders of each topic: the first one subscribes, the last `cancel()` unsubscribes.
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
    /// Holds `topic` on the Main `mainDeviceID`. The first holder sends `subscribe` when the connection is connected
    /// and awaits the answer; a failure is logged and the topic stays held. On every handshake the held topics are
    /// subscribed again.
    public func subscribe(_ topic: Topic, on mainDeviceID: UUID) async -> TopicSubscription {
        let subscription = TopicSubscription(workspace: self, mainDeviceID: mainDeviceID, topic: topic)
        let key = TopicKey(mainDeviceID: mainDeviceID, topic: topic)
        let holders = topicHolders[key, default: 0]
        topicHolders[key] = holders + 1
        if holders == 0, let connection = connection(mainDeviceID), connection.isConnected {
            do {
                try await connection.subscribeTopics([topic])
            } catch {
                let message = Workspace.message(of: error)
                Log.client.error("Could not subscribe to \(topic.rawValue, privacy: .public): \(message)")
            }
        }
        return subscription
    }

    /// One holder of the topic is gone; the last one sends `unsubscribe` when connected, without waiting.
    func releaseTopic(_ topic: Topic, on mainDeviceID: UUID) {
        let key = TopicKey(mainDeviceID: mainDeviceID, topic: topic)
        guard let holders = topicHolders[key] else { return }
        if holders > 1 {
            topicHolders[key] = holders - 1
            return
        }
        topicHolders[key] = nil
        guard let connection = connection(mainDeviceID), connection.isConnected else { return }
        Task {
            do {
                try await connection.unsubscribeTopics([topic])
            } catch {
                let message = Workspace.message(of: error)
                Log.client.error("Could not unsubscribe from \(topic.rawValue, privacy: .public): \(message)")
            }
        }
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
