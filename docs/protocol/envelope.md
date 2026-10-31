# Wire protocol: envelope

files:
- HephaestusKit/Sources/HephCore/Protocol/Envelope.swift
- HephaestusKit/Sources/HephCore/Protocol/ProtocolError.swift
- HephaestusKit/Sources/HephNet/MessageChannel.swift
- HephaestusKit/Sources/HephNet/RPCPeer.swift
- HephaestusKit/Sources/HephNet/LoopbackChannel.swift

---

Every connection to a Main carries JSON envelopes over one message channel: a TLS-PSK WebSocket between devices
([devices/mesh.md](../devices/mesh.md)), or a `LoopbackChannel` between a Main's own UI and its host
([architecture.md](../architecture.md)). This document defines the frames, the handshake, errors, encoding,
subscriptions, delivery rules, and the Swift types that carry them. The shared types are in [types.md](types.md), the
methods in [methods.md](methods.md), the events in [events.md](events.md).

## Connections

- The device that opens a connection is its client; the Main that accepts it is its server. A Main that connects to
  another Main (a peer link, [devices/mesh.md](../devices/mesh.md)) is the client of that connection.
- Both sides send requests. Only the server sends events.
- The server serves the methods of [methods.md](methods.md). The client serves one method, `mesh.rekey`.
- One `RPCPeer` runs on each side of each connection.

## Frames

- One envelope per WebSocket text frame: a JSON object encoded as UTF-8, with nothing before or after it. Binary
  frames are not used; a received binary frame is ignored.
- Maximum frame size: 48 MiB, 50,331,648 bytes of UTF-8 (`WireCoding.maxFrameSize`).

| Situation                                   | Behavior                                                                              |
|---------------------------------------------|---------------------------------------------------------------------------------------|
| An outgoing request is larger than the max  | Not sent; `RPCPeer.request` throws `tooLarge`                                         |
| An outgoing response is larger than the max | Replaced by an error response `tooLarge` with the same `id`                           |
| An outgoing event is larger than the max    | Dropped and logged                                                                    |
| An incoming frame is larger than the max    | The WebSocket transport closes the connection (`maximumMessageSize`, devices/mesh.md) |

- Base64 makes binary data 4/3 larger, so the binary content of one frame is limited to about 36 MiB in total. Method
  limits on content sizes are in [methods.md](methods.md#limits). Files of any size cross in chunks of at most 4 MiB:
  uploads towards a Main ([methods.md](methods.md#uploads)), ranged reads back.

## Envelope

```json
{"id":7,"kind":"request","method":"tickets.create","params":{"name":"Fix the sidebar","projectID":"HEPH"}}
{"id":7,"kind":"response","result":{"comments":[],"created":"2026-10-29T21:04:00.123Z","description":"","id":"HEPH-13","name":"Fix the sidebar","status":"todo","updated":"2026-10-29T21:04:00.123Z"}}
{"error":{"code":"notFound","message":"Project HEPH is not hosted on this Main."},"id":7,"kind":"response"}
{"event":"ticket.removed","kind":"event","params":{"projectID":"HEPH","ticketID":"HEPH-13"}}
```

| Member   | JSON type | Present in         | Meaning                                                         |
|----------|-----------|--------------------|-----------------------------------------------------------------|
| `kind`   | string    | every envelope     | `request`, `response` or `event`                                |
| `id`     | number    | request, response  | Request id; a response repeats the id of the request it answers |
| `method` | string    | request            | Method name ([methods.md](methods.md))                          |
| `params` | object    | request, event     | Method params or event payload; `{}` when it has no fields      |
| `result` | object    | response (success) | Method result; `{}` when it has no fields                       |
| `error`  | object    | response (failure) | `{"code": <error code>, "message": <text>}`                     |
| `event`  | string    | event              | Event name ([events.md](events.md))                             |

- Senders always include `params` in requests and events, and exactly one of `result` and `error` in responses. A
  receiver treats a missing or `null` `params` or `result` as `{}`, and a response whose `error` member is present and
  not `null` as an error response. An `error` member that is not an object with a known `code` reads as code
  `internal`, with its `message` when that is a string, else `""`.
- Unknown members are ignored.
- A frame is malformed when it is not a JSON object, its `kind` is missing or unknown, it lacks a member its kind
  requires (`id` ≥ 1 and `method` for a request, `id` for a response, `event` for an event), or its `params` (request,
  event) or the `result` of a success response holds a number that is not finite once read (a negative number too
  large for a `Double`, such as `-1e400`, reads as minus infinity). A malformed frame is logged and ignored.
- A request whose `method` the receiver does not serve is answered with `badRequest` "Unknown method <name>." An event
  whose name the receiver does not know is ignored.

## Request ids

- Each side numbers the requests it sends on a connection 1, 2, 3… A new connection starts again at 1.
- The two sides number independently: the `id` of a response refers to a request sent by the receiver of that
  response.
- A response whose `id` matches no pending request (never sent, timed out or cancelled) is ignored.

## Handshake

1. The client opens the channel and sends the request `hello` ([methods.md](methods.md#hello)) as its first frame. It
   sends nothing else until the `hello` response arrives.
2. The server answers with a `HelloResult` and the connection is authenticated, or with an error response and then
   closes the connection (the errors are listed with `hello`).
3. Before the handshake succeeds, the server closes the connection without a reply when it receives a request other
   than `hello` or an event, and when no `hello` request has arrived 10 s after the connection opened. Responses and
   malformed frames received before `hello` are ignored.
4. A connection whose `hello` has `device.isMain == true` is a peer link. Peer links may call the Main-only methods
   ([methods.md](methods.md#callers)).
5. The server registers the connection for broadcast events when it accepts `hello`, so events can reach the client
   before the `hello` response ([Delivery rules](#delivery-rules)).
6. The client checks that the `device.id` of the result is the Main it meant to reach. On a mismatch it closes the
   connection and tries the Main's next address ([client/workspace.md](../client/workspace.md)).
7. On `unauthorized` the client stops reconnecting to that Main: the device was revoked
   ([devices/mesh.md](../devices/mesh.md)). On `badRequest` it reports that the Main uses another protocol version
   ([client/workspace.md](../client/workspace.md)).

## Errors

The `error` member is `{"code": <code>, "message": <text>}`. The codes, with the general case of each
([methods.md](methods.md) lists the cases of every method):

| Code           | Used when                                                                 |
|----------------|---------------------------------------------------------------------------|
| `badRequest`   | Params do not decode, a value is invalid, the method is unknown           |
| `unauthorized` | `hello` from a revoked device; a caller the method does not accept        |
| `notFound`     | A referenced item does not exist                                          |
| `conflict`     | The request contradicts the current state                                 |
| `locked`       | The target is locked: a locked web tab, a project that is migrating       |
| `unavailable`  | Something the request needs is not available; also the local errors below |
| `tooLarge`     | A size limit is exceeded                                                  |
| `internal`     | Any other failure: I/O error, process spawn failure, encoding failure     |

- `message` is one short English sentence suitable for the error banner ([ui/shell.md](../ui/shell.md)), for example
  "Ticket HEPH-12 does not exist." It never contains a stack trace.
- Local errors, thrown by `RPCPeer.request` and never sent on the wire:

| Situation                                                 | Thrown error                                                        |
|-----------------------------------------------------------|---------------------------------------------------------------------|
| No response within the request timeout                    | `ProtocolError(.unavailable, "The device did not answer in time.")` |
| The connection closed while the request was pending       | `ProtocolError(.unavailable, "Not connected.")`                     |
| `request` called on a closed peer                         | `ProtocolError(.unavailable, "Not connected.")`                     |
| The encoded request is larger than the maximum frame size | `ProtocolError(.tooLarge, "The request is larger than 48 MiB.")`    |
| The result does not decode as the expected type           | `ProtocolError(.internal, "Invalid response to <method>.")`         |
| The calling task was cancelled                            | `CancellationError()`                                               |

- A received error code unknown to this build decodes as `internal`.

## Encoding

| Value                   | JSON                                                                      |
|-------------------------|---------------------------------------------------------------------------|
| Field names             | The Swift property names (camelCase), no key conversion                   |
| `Date`                  | String, ISO 8601 UTC with milliseconds: `2026-10-29T21:04:00.123Z`        |
| `Data`                  | String, base64 with the standard alphabet and padding, no line breaks     |
| `UUID`                  | String, canonical uppercase form (`7C3A0E1B-29D4-4E6A-9B1F-3C2D5E8A4F10`) |
| Enum                    | Its raw value string ([types.md](types.md))                               |
| Optional                | Member omitted when `nil`                                                 |
| `Int`, `Double`, `Bool` | Number, number, `true`/`false`                                            |

- Encoder: `JSONEncoder` with `outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`, `dateEncodingStrategy`
  `.custom` writing `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` (UTC; the date is first rounded to the
  microsecond, then its fraction is truncated to the millisecond, so a date decoded from a frame encodes to the same
  text: without the rounding, `…00.999Z` would encode as `…00.998Z`), `dataEncodingStrategy = .base64`. Member order
  carries no meaning.
- Decoder: `JSONDecoder` with `dateDecodingStrategy` `.custom` accepting the format with fractional seconds and the
  same format without them (`2026-10-29T21:04:00Z`), `dataDecodingStrategy = .base64`. Optional members may be
  omitted or `null`. `UUID` strings are accepted in either case.
- Code compares ids as `UUID` values, never as strings. Dates that went through the wire are compared at millisecond
  precision.

## Subscriptions

- Topics name the streams of subscriber events ([events.md](events.md)):

| Topic                 | Events                                           |
|-----------------------|--------------------------------------------------|
| `session:<sessionID>` | `session.event`, `session.delta` of that session |

- The id is written in canonical uppercase form; a server parses it case-insensitively (`Topic`).
- `subscribe {topics}` and `unsubscribe {topics}` ([methods.md](methods.md#subscribe)) change the subscriptions of the
  connection they are sent on. Subscriptions end when the connection closes.
- Subscribing to a topic already subscribed, or unsubscribing a topic not subscribed, changes nothing. A topic whose
  session does not exist (yet or any more) is accepted.
- A client subscribes to the topics of what it shows (an open session) and subscribes again after each
  reconnect. It subscribes before fetching what the topic streams (`sessions.history`), so that nothing
  is lost between the fetch and the first event.

## Delivery rules

- Broadcast events go to every authenticated connection of the emitting Main: remotes, peer links, and the loopback
  connection of the Main's own UI. Subscriber events go only to the connections subscribed to their topic. Which event
  is which: [events.md](events.md).
- A Main emits events about itself and what it hosts only. Mains never relay events of other Mains: a device receives
  the events of each Main on its own connection to that Main.
- Frames on one connection arrive in the order they were sent. There is no order across connections.
- No replay: events emitted while a connection is down are lost. After each successful handshake the client fetches
  again everything it shows (`projects.list`, `projects.snapshot`, `sessions.history`, …) and
  subscribes again ([client/workspace.md](../client/workspace.md)).
- Each event carries the complete new state of what it names, or its removal, except `session.delta`,
  which carries an increment. A client applies events as follows:
  - An event about something the client does not mirror is ignored.
  - While a request that loads a mirror is in flight (`hello` for the mesh snapshot, `projects.list`, `skills.list`,
    `projects.snapshot`, `sessions.history`), the events for that mirror are queued. Right after the response is
    stored, the queued events are applied in arrival order. This is required: an event can arrive before the response
    to a request the server answered from older state.
  - `session.delta` follows the rules of [events.md](events.md).

## Timeouts

- Every request a peer sends fails after 30 s without a response (`RPCPeer.defaultTimeout`), unless the caller gives
  another timeout. No method waits for long work: long work continues after the response and reports through events
  ([methods.md](methods.md)).
- A response that arrives after the timeout is ignored. The other side may still have performed the request; the client
  learns the outcome from events or by fetching again.
- Handshake timeout on the server: 10 s ([Handshake](#handshake)). WebSocket keep-alive and idle timeout:
  [devices/mesh.md](../devices/mesh.md).

## Versioning

- Protocol version: `1` (`WireCoding.protocolVersion`), sent in `hello` and advertised in the Bonjour TXT key `pv`
  ([devices/mesh.md](../devices/mesh.md)).
- A documentation change that builds of the current version can still decode (a new optional field, a new method, a new
  event) keeps the version. Any other change to the wire format (a new enum value, a new required field, a changed
  type or meaning) increments it. Devices on different versions cannot connect: `hello` fails with `badRequest`.

## Swift API

### Envelope.swift (HephCore)

```swift
public enum EnvelopeKind: String, Codable, Sendable {
    case request, response, event
}

/// A received frame, parsed once.
public struct ParsedFrame: Sendable {
    public let kind: EnvelopeKind
    public let id: Int?                  // request, response
    public let method: String?           // request
    public let event: String?            // event
    public let error: ProtocolError?     // error response
    /// UTF-8 JSON of `params` (request, event) or `result` (success response); `{}` when the member is missing or
    /// null, empty for an error response.
    public let body: Data
}

/// Params or result with no fields: encodes as `{}`, decodes from any object.
public struct EmptyPayload: Codable, Sendable, Hashable {
    public init() {}
}

/// A subscription topic.
public enum Topic: RawRepresentable, Hashable, Sendable {
    case session(UUID)
    public init?(rawValue: String)        // "session:<uuid>", uuid in either case; anything else is nil
    public var rawValue: String { get }   // uuid in canonical uppercase form
}

/// A request received by an RPCPeer.
public struct InboundRequest: Sendable {
    public let id: Int
    public let method: String
    public let params: Data                        // UTF-8 JSON of the params object
    public init(id: Int, method: String, params: Data)
    public var knownMethod: RPCMethod? { get }     // RPCMethod(rawValue: method)
    public func decodeParams<P: Decodable>(_ type: P.Type = P.self) throws -> P
}

/// An event received by an RPCPeer.
public struct InboundEvent: Sendable {
    public let name: String
    public let params: Data                        // UTF-8 JSON of the params object
    public init(name: String, params: Data)
    public func decodeParams<P: Decodable>(_ type: P.Type = P.self) throws -> P
}

public enum WireCoding {
    public static let protocolVersion = 1
    public static let maxFrameSize = 50_331_648
    public static func makeEncoder() -> JSONEncoder
    public static func makeDecoder() -> JSONDecoder
    public static func encodeJSON(_ value: some Encodable) throws -> Data
    public static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
    public static func encodeRequest(id: Int, method: String, params: some Encodable) throws -> Data
    public static func encodeResponse(id: Int, resultJSON: Data) -> Data
    public static func encodeError(id: Int, error: ProtocolError) throws -> Data
    public static func encodeEvent(name: String, params: some Encodable) throws -> Data
    public static func parseFrame(_ frame: Data) throws -> ParsedFrame
}
```

- `makeEncoder()` and `makeDecoder()` return new instances configured as in [Encoding](#encoding). Every frame, and
  every file the docs say is coded "as on the wire", uses them. `encodeJSON` and `decodeJSON` are shorthands for them.
- `encodeResponse` builds the bytes `{"id":<id>,"kind":"response","result":` + `resultJSON` + `}`; `resultJSON` must
  be a JSON object.
- `parseFrame` parses the frame once with `JSONSerialization.jsonObject(with:)` (no options), reads `kind`, `id`,
  `method`, `event` and `error`, and writes the `params` or `result` member back to JSON with
  `JSONSerialization.data(withJSONObject:options:)` (options `.sortedKeys`, `.withoutEscapingSlashes`,
  `.fragmentsAllowed`) as `body`. Before writing, it checks the member: an object or an array must pass
  `JSONSerialization.isValidJSONObject(_:)`, and a number must be finite. `jsonObject(with:)` reads `-1e400` as minus
  infinity, and writing a non-finite number raises an Objective-C exception, which ends the app. A malformed frame
  ([Envelope](#envelope)), a member that fails this check included, throws
  `ProtocolError(.badRequest, "Malformed frame.")`.
- `.fragmentsAllowed` writes a member that is a string, a number or a boolean as that JSON value; without it,
  `JSONSerialization` raises an Objective-C exception, which ends the app. Such a member, like an array, then fails to
  decode: params with `badRequest` (`decodeParams`, below), a result with `internal` "Invalid response to <method>."
  ([Errors](#errors)).
- `decodeParams` decodes `params` with `makeDecoder()`. A failure throws
  `ProtocolError(.badRequest, "Invalid params for <method or event>: <coding path of the failing member>.")`, the path
  written as the `<path>` of [data/project-yml.md](../data/project-yml.md#reading) (`attachments[0].uploadID`), a
  missing key included; when the path is empty (the params themselves do not decode), it throws
  `ProtocolError(.badRequest, "Invalid params for <method or event>.")`.
- `Topic` has no `Codable` conformance: params carry topics as strings ([methods.md](methods.md#subscribe)).
- `RPCMethod` is declared in Methods.swift ([methods.md](methods.md#swift-api)).

### ProtocolError.swift (HephCore)

```swift
public struct ProtocolError: Error, Codable, Sendable, Hashable, LocalizedError {
    public enum Code: String, Codable, Sendable, CaseIterable {
        case badRequest, unauthorized, notFound, conflict, locked, unavailable, tooLarge, `internal`
    }
    public var code: Code
    public var message: String
    public init(_ code: Code, _ message: String)
    /// Converts any error thrown by a request handler.
    public init(_ error: any Error)
    public var errorDescription: String? { get }   // message
}
```

- JSON: `{"code": <raw value>, "message": <text>}`.
- `Code` decodes an unknown raw value as `.internal`.
- `init(_ error:)`: a `ProtocolError` is kept as it is; a `DecodingError` becomes `badRequest` "Invalid params."; any
  other error becomes `internal` with the error's `localizedDescription` as message.

### MessageChannel.swift (HephNet)

```swift
public enum ChannelState: Sendable, Equatable {
    case open
    case closed(reason: String?)   // nil: closed by this side
}

public protocol MessageChannel: AnyObject, Sendable {
    var state: ChannelState { get }
    var inbound: AsyncStream<Data> { get }
    func send(_ frame: Data)
    func close()
}
```

A conformer (`WebSocketChannel` in [devices/mesh.md](../devices/mesh.md), `LoopbackChannel` below) follows these rules:

- It is created open by its transport (connect or accept) and never reopens; a reconnect creates a new channel.
- `inbound` returns the same stream on every access. It yields the bytes of each received text frame in arrival order
  and finishes after the channel closes, once the frames received before closing have been yielded. It has one
  consumer, the `RPCPeer`. Its buffer is unbounded.
- `send` enqueues one text frame and returns without waiting. Frames leave in the order of the `send` calls. A frame
  sent after the channel closed is dropped.
- `close()` is idempotent: it sets `state` to `.closed(reason: nil)` unless already closed, closes the transport and
  finishes `inbound`.
- A transport failure or a close by the other side sets `.closed(reason:)` with a description of the cause and
  finishes `inbound`.
- `state` is safe to read from any thread.

### RPCPeer.swift (HephNet)

```swift
public actor RPCPeer {
    /// Returns the UTF-8 JSON of the result object (WireCoding.encodeJSON(result)).
    public typealias RequestHandler = @Sendable (InboundRequest) async throws -> Data

    public static let defaultTimeout: Duration = .seconds(30)

    public nonisolated let channel: any MessageChannel
    /// The events received, in arrival order; finishes when the connection has closed.
    public nonisolated let events: AsyncStream<InboundEvent>

    public init(channel: any MessageChannel, requestTimeout: Duration = RPCPeer.defaultTimeout)
    public func setRequestHandler(_ handler: @escaping RequestHandler)

    /// Reads the channel until it closes. Returns after every pending request has failed and `events` finished.
    public func run() async
    public var isClosed: Bool { get }

    /// `timeout` nil: the peer's request timeout.
    public func request<R: Decodable & Sendable>(
        _ method: String, _ params: some Encodable & Sendable, as resultType: R.Type = R.self,
        timeout: Duration? = nil
    ) async throws -> R
    public func request<R: Decodable & Sendable>(
        _ method: RPCMethod, _ params: some Encodable & Sendable, as resultType: R.Type = R.self,
        timeout: Duration? = nil
    ) async throws -> R

    public nonisolated func emit(_ event: ServerEvent)
    public nonisolated func emit(_ name: String, _ params: some Encodable & Sendable)
    public nonisolated func emit(frame: Data)

    public nonisolated func close()
}
```

Usage: the owner creates the peer on an open channel, sets the request handler, starts `run()` (in a task, or awaited
by the code that serves the connection), consumes `events` if it uses events, then sends requests. `run()` is called
once. A method without params passes `EmptyPayload()`; a method without result fields is requested
`as: EmptyPayload.self`. `ServerEvent` is declared in Events.swift ([events.md](events.md#swift-api)).

Behavior:

- `run()` reads `channel.inbound` frame by frame and parses each with `WireCoding.parseFrame`:
  - Malformed frame: logged and ignored.
  - Request: handled in a new `Task`, started in arrival order; requests are handled concurrently. The task calls the
    request handler (no handler set: `badRequest` "Unknown method <name>."). Returned bytes are sent with
    `encodeResponse`; a thrown error is converted with `ProtocolError.init(_:)` and sent with `encodeError`. A response
    larger than `WireCoding.maxFrameSize` is replaced by `tooLarge` "The response is larger than 48 MiB.". A handler
    still running when the channel closes runs to its end; its response is dropped.
  - Response: completes the pending request with that `id`; ignored when there is none.
  - Event: yielded to `events` (unbounded buffer), in arrival order. A side that receives no events can leave the stream
    unconsumed.
  - When `inbound` finishes: the peer is closed, every pending request fails with `unavailable` "Not connected.",
    `events` finishes, and `run()` returns.
- `request`: fails at once with `unavailable` when the peer is closed. Otherwise it takes the next request id, encodes
  the request (larger than the maximum frame size: throws `tooLarge`, nothing sent), registers it as pending, sends it
  and waits. A success response's `body` is decoded as `R` with `decodeJSON` (failure: `internal` "Invalid response to
  <method>."); an error response is thrown as its `ProtocolError`. After the timeout without a response it throws
  `unavailable` "The device did not answer in time." and forgets the request. When the calling task is cancelled, the
  request is forgotten and `CancellationError` is thrown.
- `emit(_:)` encodes the event and sends it; `emit(frame:)` sends an event frame encoded beforehand (a Main sending one
  event to many connections encodes it once with `ServerEvent.encodeFrame()` or `WireCoding.encodeEvent`). An event
  that fails to encode or is larger than the maximum frame size is dropped and logged. Events emitted on a closed
  channel are dropped.
- `close()` closes the channel; `run()` then ends as above.
- Logging: `Log.net` ([architecture.md](../architecture.md#logging)), `error` for malformed frames, dropped events and
  handler errors of code `internal`; `debug` once for each frame sent or received, with its size and never its params:
  a request with its method and id, a response with its id, an event with its name, except an event frame a caller
  passes to `emit(frame:)`, logged with its size only (it was encoded beforehand).

### LoopbackChannel.swift (HephNet)

```swift
public final class LoopbackChannel: MessageChannel {
    public static func makePair() -> (client: LoopbackChannel, server: LoopbackChannel)
    public var state: ChannelState { get }
    public var inbound: AsyncStream<Data> { get }
    public func send(_ frame: Data)
    public func close()
}
```

- An in-process pair of channels: a frame sent on one end is yielded by the other end's `inbound`, in order, without
  size checks (the `RPCPeer` on each end checks sizes).
- `close()` on either end closes both: both states become `.closed(reason: nil)` and both `inbound` streams finish
  after yielding the frames already sent.
- The two ends share one lock-protected state (`Mutex` from the Synchronization module).
- Use: a Main's own UI talks to its own host through a loopback pair. The workspace connects the client end like any
  Main connection ([client/workspace.md](../client/workspace.md)) and the host accepts the server end like a network
  connection ([services/host.md](../services/host.md)). The same handshake, methods and events apply, `mesh.rekey`
  included: after a key change the host sends it there so that its own UI reconnects to the other Mains with the new
  key ([devices/mesh.md](../devices/mesh.md#revocation-and-key-rotation)). Tests use pairs to run peers without a
  network.
