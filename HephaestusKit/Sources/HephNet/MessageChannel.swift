import Foundation

/// The state of a message channel.
public enum ChannelState: Sendable, Equatable {
    case open
    case closed(reason: String?)   // nil: closed by this side
}

/// One connection carrying JSON envelopes, one per text frame (docs/protocol/envelope.md, "MessageChannel.swift").
///
/// A conformer is created open by its transport (connect or accept) and never reopens. `inbound` returns the same
/// stream on every access: the bytes of each received text frame in arrival order, finished after the channel closes
/// once the frames received before closing have been yielded; one consumer, unbounded buffer. `send` enqueues one
/// text frame and returns at once; frames leave in the order of the `send` calls; a frame sent after the channel
/// closed is dropped. `close()` is idempotent: it sets `state` to `.closed(reason: nil)` unless already closed, closes
/// the transport and finishes `inbound`. A transport failure or a close by the other side sets `.closed(reason:)`
/// with a description of the cause and finishes `inbound`. `state` is safe to read from any thread.
public protocol MessageChannel: AnyObject, Sendable {
    var state: ChannelState { get }
    var inbound: AsyncStream<Data> { get }
    func send(_ frame: Data)
    func close()
}
