#if os(macOS)
import Foundation

/// The write queue of one project (docs/services/host.md §6.8): its operations run one at a time, in submission order;
/// one starts after the previous one ended, successfully or not.
actor ProjectWriteQueue {
    /// An operation is running.
    private var busy = false
    /// The operations waiting for their turn, in submission order.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
        } else {
            busy = true
        }
        defer { next() }
        return try await operation()
    }

    /// Hands the queue to the next waiting operation, or frees it.
    private func next() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
#endif
