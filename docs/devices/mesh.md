# Mesh

files:
- HephaestusKit/Sources/HephNet/MeshConstants.swift
- HephaestusKit/Sources/HephNet/MeshCrypto.swift
- HephaestusKit/Sources/HephNet/MeshParameters.swift
- HephaestusKit/Sources/HephNet/WebSocketChannel.swift
- HephaestusKit/Sources/HephNet/WebSocketListener.swift
- HephaestusKit/Sources/HephNet/BonjourTXT.swift
- HephaestusKit/Sources/HephNet/BonjourBrowser.swift
- HephaestusKit/Sources/HephNet/PairingMessages.swift
- HephaestusKit/Sources/HephNet/PairingClient.swift
- HephaestusKit/Sources/HephHost/Mesh/MeshService.swift
- HephaestusKit/Sources/HephHost/Mesh/MeshRegistry.swift
- HephaestusKit/Sources/HephHost/Mesh/PresenceTable.swift
- HephaestusKit/Sources/HephHost/Mesh/PeerLinkManager.swift
- HephaestusKit/Sources/HephHost/Mesh/PairingHost.swift
- HephaestusKit/Sources/HephHost/Mesh/HostAddresses.swift

---

The mesh is the set of paired devices of the user. This doc specifies the mesh credentials and keys, the TLS-PSK
WebSocket transport, Bonjour discovery, pairing, the device registry, revocation and key rotation, presence, the peer
links between Mains, and `MeshService`, the host service that runs all of it on a Main. Roles and the device identity:
[roles.md](roles.md). Envelope, `MessageChannel`, `RPCPeer` and the handshake rules:
[../protocol/envelope.md](../protocol/envelope.md). Method contracts: [../protocol/methods.md](../protocol/methods.md).
Wire types (`DeviceInfo`, `DeviceRecord`, `Presence`, `MeshSnapshot`): [../protocol/types.md](../protocol/types.md).
The client side (connections to Mains, client presence merge, client handling of `mesh.rekey`):
[../client/workspace.md](../client/workspace.md). The host that calls `MeshService`:
[../services/host.md](../services/host.md).

## Components

| File                                  | Declares                                                     | Isolation                                             |
|---------------------------------------|--------------------------------------------------------------|-------------------------------------------------------|
| `HephNet/MeshConstants.swift`         | `MeshConstants`                                              | static values                                         |
| `HephNet/MeshCrypto.swift`            | `MeshCrypto`                                                 | pure functions                                        |
| `HephNet/MeshParameters.swift`        | `MeshParameters`                                             | pure function                                         |
| `HephNet/WebSocketChannel.swift`      | `WebSocketChannel`, `MeshTransportError`                     | state confined to one serial queue                    |
| `HephNet/WebSocketListener.swift`     | `WebSocketListener`                                          | state confined to one serial queue                    |
| `HephNet/BonjourTXT.swift`            | `BonjourTXT`, `BonjourAdvert`                                | pure functions                                        |
| `HephNet/BonjourBrowser.swift`        | `BonjourBrowser`                                             | state confined to one serial queue                    |
| `HephNet/PairingMessages.swift`       | `PairHello`, `PairCredentials`, `PairSecret`, `PairingCodec` | pure functions                                        |
| `HephNet/PairingClient.swift`         | `PairingClient`, `PairingError`                              | async functions                                       |
| `HephHost/Mesh/MeshService.swift`     | `MeshService`, `PeerLinkEvent`                               | actor                                                 |
| `HephHost/Mesh/MeshRegistry.swift`    | `MeshRegistry`                                               | struct owned by `MeshService`                         |
| `HephHost/Mesh/PresenceTable.swift`   | `PresenceTable`                                              | struct owned by `MeshService`                         |
| `HephHost/Mesh/PeerLinkManager.swift` | `PeerLinkManager`                                            | class owned by `MeshService`, used only on its actor  |
| `HephHost/Mesh/PairingHost.swift`     | `PairingHost`                                                | class owned by `MeshService`, used only on its actor  |
| `HephHost/Mesh/HostAddresses.swift`   | `HostAddresses`                                              | functions; its `NWPathMonitor` runs on a serial queue |

- A class "confined to one serial queue" owns a private `DispatchQueue` labeled `ca.azavech.hephaestus.<name>`
  (`websocket`, `listener`, `browser`, `pathmonitor`), touches its Network.framework objects and mutable state only on
  it, and is declared `@unchecked Sendable` with a comment saying so ([../architecture.md](../architecture.md)).
- Every `HephHost` file is wrapped in `#if os(macOS)`. `HephNet` compiles on every platform.
- Logging: `Log.net` in `HephNet`, `Log.host` in `HephHost`. Mesh keys, PSKs, pairing codes and sealed payloads are
  never logged.

## Constants

`MeshConstants` (`public enum`, `public static let` values):

| Constant                 | Value                       | Use                                                        |
|--------------------------|-----------------------------|------------------------------------------------------------|
| `serviceType`            | `"_hephaestus._tcp"`        | Bonjour service type                                       |
| `transportPath`          | `"/hephaestus"`             | URL path of mesh connections                               |
| `pairingPath`            | `"/pair"`                   | URL path of pairing connections                            |
| `transportIdentity`      | `"hephaestus"`              | PSK identity of mesh connections                           |
| `pairingIdentity`        | `"hephaestus-pairing"`      | PSK identity of pairing connections                        |
| `transportSalt`          | `"hephaestus-transport-v1"` | HKDF salt of the transport PSK                             |
| `pairingSalt`            | `"hephaestus-pairing-v1"`   | HKDF salt of the pairing PSK                               |
| `pairKeyInfo`            | `"hephaestus-pair-key"`     | HKDF info of the pairing exchange key                      |
| `pingInterval`           | `.seconds(10)`              | pings (both sides); idle checks                            |
| `idleTimeout`            | `.seconds(30)`              | a channel without inbound traffic for this long closes     |
| `addressTimeout`         | `.seconds(5)`               | one address of a peer link dial                            |
| `backoff`                | `[1, 2, 5, 10, 30]` seconds | reconnect delays; the last one repeats                     |
| `pairingWindowDuration`  | `.seconds(300)`             | a pairing window closes after this long                    |
| `pairingMaxFailures`     | `5`                         | failed TLS handshakes that close a pairing window          |
| `pairingStepTimeout`     | `.seconds(15)`              | wait for the next pairing message                          |
| `coalescingDelay`        | `.milliseconds(250)`        | `mesh.changed` and `mesh.sync` coalescing                  |
| `registrySaveDelay`      | `.seconds(1)`               | `registry.json` write coalescing                           |
| `resignTimeout`          | `.seconds(2)`               | `mesh.sync` sent by `resignMain()`                         |
| `rekeyTimeout`           | `.seconds(30)`              | `mesh.rekey` requests; the `mesh.sync` of Revoking step 6  |
| `addressRefreshInterval` | `.seconds(60)`              | periodic recomputation of a Main's addresses               |
| `pathChangeDelay`        | `.seconds(2)`               | recomputation of a Main's addresses after a network change |
| `serviceNameMaxBytes`    | `63`                        | Bonjour service name limit (UTF-8 bytes)                   |

The time values are `Duration` values, except `backoff`, an `[Int]` of seconds: a delay is
`.seconds(MeshConstants.backoff[min(failures, 5) - 1])` ([Dialing](#dialing)).

Values defined elsewhere: the listener port (`listenerPort`, default 47100, unless `HostOptions.listenerPort` replaces
it, [MeshService](#meshservice)) and the pairing port (`pairingPort`, default 47101) are device settings
([../data/app-storage.md](../data/app-storage.md)); the protocol version (1) and
the maximum frame size (50,331,648 bytes) are `WireCoding.protocolVersion` and `WireCoding.maxFrameSize`
([../protocol/envelope.md](../protocol/envelope.md)).

## Credentials

A mesh has a `meshID` (UUID) and a `meshKey` (32 random bytes). They travel and are stored as `MeshCredentials`
`{meshID: UUID, meshKey: Data}` ([../data/app-storage.md](../data/app-storage.md#keychain)).

- The text form of `meshID` (HKDF info, mesh tag) is `meshID.uuidString`, the canonical uppercase form. Credentials
  whose `meshKey` is not 32 bytes are treated as no credentials (logged).
- A mesh is created by `MeshService.ensureMesh()`: a Mac becoming a Main without credentials
  ([roles.md](roles.md#turning-main-on-macos)). `meshID = UUID()`, `meshKey = MeshCrypto.newMeshKey()`.
- Every member device stores the credentials with its credential store. A device belongs to at most one mesh: storing
  credentials replaces any previous ones. Pairing happens only in onboarding, where the device has no credentials
  ([../ui/onboarding.md](../ui/onboarding.md)); a device in a mesh leaves it first
  ([roles.md](roles.md#leaving-the-mesh)).
- `mesh.rekey` replaces `meshKey` and keeps `meshID` ([Revocation and key rotation](#revocation-and-key-rotation)).

### Credential store

The credential store (`MeshCredentialStore`, `KeychainCredentialStore.shared`, `InMemoryCredentialStore`) is defined
in [../data/app-storage.md](../data/app-storage.md#keychain); the app passes `KeychainCredentialStore.shared` to
`WorkspaceEnvironment.live(...)` ([../client/workspace.md](../client/workspace.md)) and to `HostService`, and
`MeshService` observes its `changes()` ([Receiving a new key](#receiving-a-new-key)).

## Keys

`MeshCrypto` (CryptoKit):

| Key or value            | Derivation                                                                                                                     | Size     |
|-------------------------|--------------------------------------------------------------------------------------------------------------------------------|----------|
| mesh key                | `SymmetricKey(size: .bits256)`, its bytes                                                                                      | 32 bytes |
| transport PSK           | HKDF-SHA256(ikm: meshKey, salt: UTF-8 of `"hephaestus-transport-v1"`, info: UTF-8 of the meshID text form)                     | 32 bytes |
| mesh tag                | SHA-256 of the UTF-8 of the meshID text form, lowercase hex, first 8 characters; `""` without credentials                      | 8 chars  |
| pairing code            | `String(format: "%06d", Int.random(in: 0...999_999))` (system CSPRNG)                                                          | 6 digits |
| pairing PSK             | HKDF-SHA256(ikm: UTF-8 of the 6-digit code, salt: UTF-8 of `"hephaestus-pairing-v1"`, info: empty)                             | 32 bytes |
| pairing exchange key k  | HKDF-SHA256(ikm: X25519 shared secret, salt: UTF-8 of the 6-digit code, info: UTF-8 of `"hephaestus-pair-key"`)                | 32 bytes |

```swift
public enum MeshCrypto {
    public static func newMeshKey() -> Data
    /// HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: meshKey), salt:, info:, outputByteCount: 32).
    /// nil for invalid credentials.
    public static func transportKey(_ credentials: MeshCredentials) -> SymmetricKey?
    public static func meshTag(_ credentials: MeshCredentials?) -> String
    public static func newPairingCode() -> String
    /// Exactly 6 ASCII digits.
    public static func isValidPairingCode(_ code: String) -> Bool
    public static func pairingKey(code: String) -> SymmetricKey
    /// Curve25519.KeyAgreement: privateKey.sharedSecretFromKeyAgreement(with: PublicKey(rawRepresentation:)), then
    /// sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: code, sharedInfo: "hephaestus-pair-key", 32).
    public static func exchangeKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                                   code: String) throws -> SymmetricKey
    /// ChaChaPoly.seal(plaintext, using: key).combined (12-byte nonce, ciphertext, 16-byte tag); no authenticated data.
    public static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data
    /// ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key).
    public static func open(_ sealed: Data, key: SymmetricKey) throws -> Data
}
```

Test vectors (computed with CryptoKit and checked with an independent RFC 5869 implementation; hex):

| Input                                                                                      | Output                                                             |
|--------------------------------------------------------------------------------------------|--------------------------------------------------------------------|
| transport PSK, meshKey = bytes 00 01 … 1f, meshID = `6F9619FF-8B86-D011-B42D-00C04FC964FF` | `10a66611c79e4e0f059d20a5951a0e5e989bfe7b4b91e63b5b07179c3fad5668` |
| mesh tag of meshID `6F9619FF-8B86-D011-B42D-00C04FC964FF`                                  | `2da8e55a`                                                         |
| pairing PSK, code `123456`                                                                 | `c2866a1203998d897adb92d1c31e9c0ba2b9ffb331ea96cfcd0d331ad2c10565` |
| k, private keys 32 × `11` and 32 × `22` (raw representations), code `123456`               | `c8cd48ce188fc40a60411bee09e76fb5dc4d6d00d170ada6702b9c77dfb64db4` |

## Transport

Every mesh and pairing connection is a WebSocket over TLS 1.2 with a pre-shared key: TCP, then TLS-PSK, then the
WebSocket upgrade. Text frames carry the JSON envelopes of [../protocol/envelope.md](../protocol/envelope.md).

### Parameters

```swift
public enum MeshParameters {
    public static func make(psk: SymmetricKey, identity: String, listener: Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let id = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, id as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options()
        if !listener { tcp.connectionTimeout = 5 }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        if listener { parameters.allowLocalEndpointReuse = true }
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = WireCoding.maxFrameSize
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }
}
```

Verified on this Mac (Xcode 27.1):

- A client must use a URL endpoint: `NWConnection(to: .url(<wss URL>), using:)`. With a host and port endpoint the
  WebSocket upgrade fails (the client ends in `waiting(POSIX 53)`).
- A wrong key fails the TLS handshake: the server connection goes to `failed(-9846: bad MAC)`, the client to
  `waiting(-9820: bad MAC)`. The client never reaches `failed` by itself; `waiting` is treated as a failure.
- With TLS resumption enabled, a client in the same process as a listener that was restarted with a new key resumed
  its earlier session and connected (from a separate process it was refused). With resumption and tickets disabled it
  is refused (`bad MAC`) and clients with the new key connect. Resumption stays disabled on both sides.
- With `autoReplyPing = true`, received pings still reach `receive` (opcode `.ping`, no data, `isComplete` true), the
  pong handler of a sent ping fires, and a received close frame arrives as opcode `.close`.
- With `receive(minimumIncompleteLength: 1, maximumLength: 65_536)`, a 4,000,000-byte text message arrived in 245
  chunks of at most 16,384 bytes, each carrying the `.text` metadata, the last with `isComplete` true. With a receiving
  `maximumMessageSize` of 1,000,000, the same message failed the receive with `POSIX 40: Message too long` before any
  chunk.
- A ping sent right after an 8,000,000-byte message, to a peer that read that message slowly, got its pong only after
  the peer had received the whole message; the send completion (`.contentProcessed`) of the large message fired at
  once.
- A listener created on the same port right after the previous one was cancelled starts, also while connections the
  previous one accepted stay open. A second listener on a port in use fails with `failed(POSIX 48: Address already in
  use)`, also with `allowLocalEndpointReuse`. So does a listener started right after a connection accepted on that
  port closed, by either side: always when started at once, sometimes still 10–25 ms later, never 40 ms or more later.
  The replacements of the mesh listener therefore retry ([Receiving a new key](#receiving-a-new-key)).

### WebSocketChannel

```swift
/// The TLS-PSK WebSocket MessageChannel. Its NWConnection and state are confined to one serial queue.
public final class WebSocketChannel: MessageChannel, @unchecked Sendable {
    // MessageChannel (protocol/envelope.md)
    public var state: ChannelState { get }
    public var inbound: AsyncStream<Data> { get }
    public func send(_ frame: Data)
    public func close()

    public let isClient: Bool
    /// "<host>:<port>" of the other side, for logs and messages.
    public let remoteDescription: String

    /// wss://<host>:<port><path>, built with URLComponents; a host containing ":" (IPv6) is written in brackets.
    /// nil when the host is empty, the port is outside 0…65535, or the URL cannot be built.
    public static func url(host: String, port: Int, path: String) -> URL?
    /// Opens a client channel and returns once the WebSocket is open.
    public static func connect(url: URL, psk: SymmetricKey, identity: String,
                               timeout: Duration = .seconds(10)) async throws -> WebSocketChannel
    /// The mesh connection: the transport PSK of `credentials` and the identity "hephaestus".
    /// Throws MeshTransportError.invalidCredentials when MeshCrypto.transportKey returns nil.
    public static func connect(url: URL, credentials: MeshCredentials,
                               timeout: Duration = .seconds(10)) async throws -> WebSocketChannel
}
```

`connect` starts `NWConnection(to: .url(url), using: MeshParameters.make(psk:identity:listener: false))` on the
channel's queue and waits:

| Before the channel is open                         | Result                                                                |
|----------------------------------------------------|-----------------------------------------------------------------------|
| state `.ready`                                     | returns the channel, state `.open`                                    |
| `.waiting(.tls(_))` or `.failed(.tls(_))`          | throws `MeshTransportError.authenticationFailed`                      |
| any other `.waiting(e)` or `.failed(e)`            | throws `MeshTransportError.unreachable(e.debugDescription)`           |
| no `.ready` within `timeout`                       | throws `MeshTransportError.timedOut`                                  |
| the calling task is cancelled                      | throws `CancellationError()`                                          |

In every failure case the `NWConnection` is cancelled first.

Receiving: once open, the channel reads in a loop with `connection.receive(minimumIncompleteLength: 1, maximumLength:
65_536)` and appends the chunks of a message until a chunk has `isComplete` true. The opcode is read from
`context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata`, which every
chunk carries.

| Received                                                           | Action                                                          |
|--------------------------------------------------------------------|-----------------------------------------------------------------|
| a chunk with `isComplete` false                                    | appended to the message being received                          |
| the last chunk of a `.text` message                                | the message's bytes are yielded to `inbound`                    |
| the last chunk of a `.binary`, `.ping`, `.pong` or `.cont` message | the message is dropped                                          |
| `.close`                                                           | the channel closes with reason "Closed by <remoteDescription>." |
| an error                                                           | the channel closes with reason `error.debugDescription`         |
| no data and no metadata (end of the stream)                        | the channel closes with reason "Closed by <remoteDescription>." |

Every received chunk, whatever its opcode, sets `lastInbound` to now.

Sending: `send(_:)` returns at once. On the channel's queue, while the state is `.open` and the frame is at most
`WireCoding.maxFrameSize` bytes, it calls `connection.send(content: frame, contentContext:
NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)]),
isComplete: true, completion: .contentProcessed { … })`. A completion with an error closes the channel with that
error as reason. A frame sent while closed is dropped; a larger frame is dropped and logged. Frames leave in the order
of the `send` calls.

Keep-alive, on the channel's queue, every `pingInterval` (10 s) from the opening:

- Both sides send a ping: `NWProtocolWebSocket.Metadata(opcode: .ping)` with
  `setPongHandler(queue) { error in … }` that sets `lastInbound` to now when `error` is nil; empty content. A side
  that sends a long frame gets no pong until the frame is through (verified above), so it relies on the pings of the
  other side.
- Both sides: when more than `idleTimeout` (30 s) passed since `lastInbound` (which starts at the opening), the
  channel closes with reason "No data received for 30 s."

Closing:

- `close()` (idempotent): when open, the state becomes `.closed(reason: nil)`, `inbound` finishes after the frames
  already received, a close frame is sent (`opcode .close`, `closeCode = .protocolCode(.normalClosure)`, no content)
  and the connection is cancelled when that send completes or after 1 s.
- A failure or a close by the other side: the state becomes `.closed(reason: <text>)`, `inbound` finishes, the
  connection is cancelled, the keep-alive stops.

### WebSocketListener

```swift
/// A listener of mesh or pairing connections. NWListener and state confined to one serial queue.
public final class WebSocketListener: @unchecked Sendable {
    /// port 0: any free port (tests). host: the local address to bind (tests: "127.0.0.1"); nil: every interface.
    public init(port: Int, psk: SymmetricKey, identity: String, host: String? = nil)
    /// Starts listening and returns once ready. onChannel gets every connection that completed the TLS and WebSocket
    /// handshakes (a server WebSocketChannel, open); onHandshakeFailure is called for each failed TLS handshake.
    /// Throws CancellationError when the calling task is cancelled or stop() runs before the listener is ready.
    public func start(onChannel: @escaping @Sendable (WebSocketChannel) -> Void,
                      onHandshakeFailure: @escaping @Sendable () -> Void = {}) async throws
    /// The bound port once started; 0 before.
    public var port: Int { get }
    /// The Bonjour advertisement (NWListener.service); nil removes it. May be called before or after start.
    public func setService(_ service: NWListener.Service?)
    /// Cancels the listener, which is cancelled when this returns, and the connections still in their handshakes
    /// (one that completes afterwards is closed, never delivered). Channels already delivered stay open.
    public func stop()
}
```

- `start` creates `NWListener(using: MeshParameters.make(psk:identity:listener: true), on: <port>)` (`.any` for 0). With
  a `host`, the parameters get `requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: <port>)` and the
  listener is `NWListener(using: <parameters>)`: it accepts only connections to that address (verified on this Mac with
  `"127.0.0.1"` and port `.any`: a client reached it through 127.0.0.1 and was refused through the Mac's LAN address).
  It waits for its state:

| Listener state                                              | Result                                                                                 |
|-------------------------------------------------------------|----------------------------------------------------------------------------------------|
| `.ready`                                                    | returns                                                                                |
| `.failed(.posix(.EADDRINUSE))` or `.waiting` with it        | throws `MeshTransportError.listenerFailed("Port <port> is already in use.")`           |
| any other `.failed(e)` or `.waiting(e)`                     | throws `MeshTransportError.listenerFailed("Cannot listen on port <port>: <e>.")`       |
| a port outside 0…65535                                      | throws `MeshTransportError.listenerFailed("Invalid port <port>.")`                     |

  After a failure the listener is cancelled.
- Each new connection is received on the listener's queue and becomes a server `WebSocketChannel`, whose
  `NWConnection` starts on the channel's own queue. `.ready`: the channel opens and is passed to `onChannel`.
  `.failed(.tls(_))` or `.waiting(.tls(_))` before `.ready` (as for a client): cancelled, `onHandshakeFailure()`. Any
  other failure, or no `.ready` within 10 s: cancelled. `onChannel` and `onHandshakeFailure` are called on the
  listener's queue.
- The URL path of the client is not checked: the two listeners of a Main differ by port, key and identity.

### MeshTransportError

```swift
public enum MeshTransportError: Error, Equatable, Sendable, LocalizedError {
    case authenticationFailed
    case unreachable(String)
    case timedOut
    case invalidCredentials
    case listenerFailed(String)
    public var errorDescription: String? { get }
}
```

| Case                    | `errorDescription`                                          |
|-------------------------|-------------------------------------------------------------|
| `authenticationFailed`  | "The mesh key was refused."                                 |
| `unreachable(detail)`   | "Cannot connect: <detail>"                                  |
| `timedOut`              | "The connection timed out."                                 |
| `invalidCredentials`    | "The mesh credentials are invalid."                         |
| `listenerFailed(text)`  | `text` (for example "Port 47100 is already in use.")        |

## Discovery

### TXT record

`BonjourTXT.record(...)` builds the TXT record of a Main's advertisement; every value is a string.

| Key     | Value                                                                                              |
|---------|----------------------------------------------------------------------------------------------------|
| `id`    | the Main's device id, `uuidString`                                                                 |
| `mesh`  | the mesh tag ([Keys](#keys)); `""` without credentials                                             |
| `pv`    | `"1"` (`WireCoding.protocolVersion`)                                                               |
| `host`  | the local host name with `.local` ([Addresses of a Main](#addresses-of-a-main)); `""` when unknown |
| `port`  | the listener port                                                                                  |
| `pair`  | `"1"` while a pairing window is open, else `"0"`                                                   |
| `pport` | the pairing port (`pairingPort` setting), always present                                           |

```swift
public struct BonjourAdvert: Hashable, Sendable {
    public var id: UUID             // TXT id
    public var name: String         // Bonjour service name
    public var meshTag: String      // TXT mesh, "" when absent
    public var protocolVersion: Int // TXT pv, 0 when absent or not an integer
    public var host: String         // TXT host
    public var port: Int            // TXT port
    public var pairingOpen: Bool    // TXT pair == "1"
    public var pairingPort: Int?    // TXT pport, nil when absent or invalid
    public init(id: UUID, name: String, meshTag: String, protocolVersion: Int, host: String, port: Int,
                pairingOpen: Bool, pairingPort: Int? = nil)
}

public enum BonjourTXT {
    public static func record(deviceID: UUID, meshTag: String, host: String, port: Int,
                              pairingOpen: Bool, pairingPort: Int) -> NWTXTRecord
    /// nil when id is not a UUID, host is empty, or port is not in 1…65535.
    public static func parse(name: String, txt: NWTXTRecord) -> BonjourAdvert?
    /// The device name cut to at most 63 UTF-8 bytes, at a Character boundary.
    public static func serviceName(_ deviceName: String) -> String
}
```

The Workspace keeps the adverts it sees in `seenHosts`
([../client/workspace.md](../client/workspace.md#bonjour-seen-hosts)).

### Advertising

A running Main advertises on its mesh listener: `listener.setService(NWListener.Service(name:
BonjourTXT.serviceName(<own record name>), type: "_hephaestus._tcp", domain: nil, txtRecord: BonjourTXT.record(...)))`
(`noAutoRename` stays false: the system adds a suffix when the name is taken; devices are matched by `id`, never by
name). `MeshService` sets the service again when its name, mesh tag, host name, listener port or pairing state
changes, and sets nil in `stopAdvertising()`. Without a running listener, or with `options.bonjour` false
([MeshService](#meshservice)), nothing is advertised.

### Browsing

```swift
/// A browser of _hephaestus._tcp. NWBrowser and state confined to one serial queue.
public final class BonjourBrowser: @unchecked Sendable {
    public init()
    /// Starts browsing; onChange receives the full list after every change, on the browser's queue.
    public func start(onChange: @escaping @Sendable ([BonjourAdvert]) -> Void)
    public func stop()
}
```

- `NWBrowser(for: .bonjourWithTXTRecord(type: "_hephaestus._tcp", domain: nil), using: NWParameters())`.
- On `browseResultsChangedHandler`, the list is rebuilt from all current results: each result whose endpoint is
  `.service(name:…)` and whose metadata is `.bonjour(txt)` gives `BonjourTXT.parse(name:txt:)`; results that do not
  parse are dropped; when two results carry the same `id`, the later one in iteration order wins.
- `.failed`: the browser is recreated after 5 s. `.waiting` (for example local network access denied,
  `NWError.dns(-65570)`) is logged; the browser keeps running and delivers results once access is granted.
- The Info.plist keys `NSBonjourServices` (`_hephaestus._tcp`) and `NSLocalNetworkUsageDescription` are required on
  every platform ([../architecture.md](../architecture.md#appinfoplist)).
- Users: the Workspace's live `browse` closure (Join screen, dialing; [../client/workspace.md](../client/workspace.md))
  and the peer links of a Main ([Peer links](#peer-links)) unless `options.bonjour` is false, each with its own
  instance.

### Addresses of a Main

`HostAddresses` computes the `addresses` of a Main's own record, in this order, without duplicates (first kept):

1. The local host name: `SCDynamicStoreCopyLocalHostName(nil)` + `.local` (for example `Sams-Mac-mini.local`);
   skipped when nil or empty.
2. The IPv4 addresses from `getifaddrs`: family `AF_INET`, flags `IFF_UP` and `IFF_RUNNING` set, `IFF_LOOPBACK` not
   set, not in `169.254.0.0/16`; formatted with `inet_ntop`; in `getifaddrs` order. VPN interfaces count, so
   Tailscale's `100.x.y.z` address appears when it is up.
3. The `additionalAddresses` device setting ([../data/app-storage.md](../data/app-storage.md)).

`MeshService` recomputes them when the mesh is ensured, when `startListener` starts the listener (a replacement after a
key change does not), `pathChangeDelay` (2 s) after each `NWPathMonitor` update (a monitor on its own queue, started
with the peer links), every `addressRefreshInterval` (60 s) while running, and on `mesh.setAddresses`. A result that
differs from the own record updates it ([This Main's record](#this-mains-record)); a different host name also updates
the advertisement.

## Pairing

A device joins the mesh by pairing with a Main: the Main shows a 6-digit code, the joiner types it, and the Main sends
the mesh credentials over a channel keyed by the code, sealed with an X25519 exchange so that someone who records the
traffic and later brute-forces the code still cannot read the mesh key.

Limit: TLS-PSK with a 6-digit code is not a password-authenticated key exchange. An attacker on the network that
answers the joiner in place of the Main can find the code offline from the joiner's handshake and pair while the window
is open. The pairing sheet shows the name of the device that joined
([../ui/devices.md](../ui/devices.md#pairing-code-sheet)); the user revokes a device they do not know, which rotates
the key.

### Pairing window (Main)

`PairingHost`, inside `MeshService`. `pairing.open` (from the Main's own UI over the loopback connection, or from any
connected device):

1. A window is open: returns it unchanged.
2. Otherwise: credentials missing → `ensureMesh()`. Code = `MeshCrypto.newPairingCode()`. A `WebSocketListener` starts
   on the `pairingPort` setting with `MeshCrypto.pairingKey(code:)` and identity `"hephaestus-pairing"`, bound to
   `options.listenerHost` like the mesh listener; a failure answers `unavailable` "Cannot open the pairing window:
   <errorDescription>". The window is `{code, expiresAt: now + 300 s, port}`; the advertisement gets `pair = "1"`.
3. Result `PairingOpenResult {code, expiresAt, port}` ([../protocol/methods.md](../protocol/methods.md#pairingopen)).

A `pairing.open` that arrives while another one is opening the window waits for it and answers the same. When the
window is closed while its listener starts (`pairing.close`, `stopListener()`, `resignMain()`), that listener is
stopped once ready and the request answers `unavailable` "Cannot open the pairing window: it was closed."

The window closes at the first of: one successful exchange; `pairingMaxFailures` (5) failed TLS handshakes (reported
by `onHandshakeFailure`; a wrong code fails there); `expiresAt`; `pairing.close`; `stopListener()`;
`resignMain()`. Closing stops the pairing listener, closes a channel still in an exchange and sets `pair = "0"`.
There is no event for it: the device showing the code learns of a success from `mesh.changed` (a new record) and
otherwise by the countdown ([../ui/devices.md](../ui/devices.md)).

### Exchange

Messages are envelope events ([../protocol/envelope.md](../protocol/envelope.md#envelope)), one per text frame, read
and written directly on the channel (no `RPCPeer`), encoded with `WireCoding.encodeEvent(name:params:)`. Binary values
are base64 strings and the `DeviceInfo` is the sender's identity ([roles.md](roles.md#identity)).

| Step | Direction     | Frame                                                                                           |
|------|---------------|-------------------------------------------------------------------------------------------------|
| 1    | joiner → Main | `{"event":"pair.hello","kind":"event","params":{"device":<DeviceInfo>,"publicKey":"<base64>"}}` |
| 2    | Main → joiner | `{"event":"pair.hello","kind":"event","params":{"device":<DeviceInfo>,"publicKey":"<base64>"}}` |
| 3    | both          | derive `k` from the X25519 shared secret ([Keys](#keys)); nothing is sent                       |
| 4    | Main → joiner | `{"event":"pair.credentials","kind":"event","params":{"sealed":"<base64>"}}`                    |
| 5    | joiner → Main | `{"event":"pair.done","kind":"event","params":{}}`                                              |

```swift
public struct PairHello: Codable, Sendable {          // pair.hello params
    public var device: DeviceInfo
    public var publicKey: Data                        // 32-byte raw X25519 key
    public init(device: DeviceInfo, publicKey: Data)
}
public struct PairCredentials: Codable, Sendable {    // pair.credentials params
    public var sealed: Data                           // MeshCrypto.seal(JSON of PairSecret, k)
    public init(sealed: Data)
}
public struct PairSecret: Codable, Sendable {         // the sealed plaintext
    public var meshID: UUID
    public var meshKey: Data
    public var snapshot: MeshSnapshot
    public init(meshID: UUID, meshKey: Data, snapshot: MeshSnapshot)
}
public enum PairingCodec {
    /// WireCoding.encodeEvent(name:params:).
    public static func encode<P: Encodable & Sendable>(_ name: String, _ params: P) throws -> Data
    /// WireCoding.parseFrame(frame) must succeed with kind event and event equal to `name`, else it throws
    /// PairingError.protocolError("Expected <name>."); then WireCoding.decodeJSON(P.self, from: body), a failure
    /// throwing PairingError.protocolError("Invalid <name>.").
    public static func decode<P: Decodable>(_ name: String, as: P.Type, frame: Data) throws -> P
}
```

Each side reads the frames of the channel's `inbound` stream in order, with one iterator. Waiting for a frame lasts at
most `pairingStepTimeout` (15 s); then the side closes the channel.

Example of the sealed plaintext (`WireCoding.makeEncoder()`, then sealed):

```json
{"meshID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","meshKey":"<base64 key>","snapshot":{"devices":[…],"meshID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","presence":[…]}}
```

The Main's side, for each channel delivered by the pairing listener (a channel arriving while another exchange runs
is closed at once):

1. Waits `pair.hello` (15 s). Checks: `publicKey` is 32 bytes; `device.id` is not this Main's id; `device.isMain` is
   false or `device.platform` is `macOS`.
2. Creates an ephemeral `Curve25519.KeyAgreement.PrivateKey()`, sends `pair.hello` with `localDevice()` and its
   `publicKey.rawRepresentation`, derives `k`.
3. Sends `pair.credentials` sealing `PairSecret {meshID, meshKey, snapshot: snapshot()}`.
4. Waits `pair.done` (15 s).
5. Writes the joiner's record, replacing any record with that id: `{id, name, platform, isMain, appVersion, build}`
   from its `DeviceInfo`, `addresses: []`, `port: 0`, `pairedAt` and `updatedAt` now, `revoked: false`. Saves, emits
   `mesh.changed`, syncs the peer Mains ([Registry](#registry)).
6. Closes the window (success) and the channel.

A failed step closes the channel; the window stays open and the failure does not count toward the 5 failed handshakes.
A joiner that received the credentials but did not send `pair.done` gets its record from its first `hello`
([Admission](#admission-hello)).

### Joining (PairingClient)

```swift
public enum PairingClient {
    /// The joiner side: connects to wss://<host>:<port>/pair, runs the exchange, stores the credentials with
    /// `credentialStore` and the snapshot with RegistryCache.save(_:_:), sends pair.done, returns the snapshot.
    public static func join(host: String, port: Int, code: String, device: DeviceInfo,
                            credentialStore: any MeshCredentialStore, appSupport: AppSupport) async throws -> MeshSnapshot
}

public enum PairingError: Error, Equatable, Sendable, LocalizedError {
    case invalidCode, rejected, unreachable(String), timedOut, protocolError(String)
    public var errorDescription: String? { get }
}
```

1. `code` must pass `isValidPairingCode` (`invalidCode`).
2. `WebSocketChannel.connect(url: url(host:port:path: "/pair"), psk: pairingKey(code:), identity: "hephaestus-pairing",
   timeout: 10 s)`: `authenticationFailed` → `rejected`; `unreachable` → `unreachable`; `timedOut` → `timedOut`. When
   `url(host:port:path:)` returns nil: `unreachable("Invalid address <host>.")`.
3. Creates an ephemeral key, sends `pair.hello` with `device` (the identity, with the name typed in the Join screen).
4. Waits `pair.hello` (15 s): the Main's `device.isMain` must be true and `publicKey` 32 bytes. Derives `k`.
5. Waits `pair.credentials` (15 s), opens it, decodes it as a `PairSecret` `secret` with `WireCoding.makeDecoder()`.
   Checks: `secret.meshKey` is 32 bytes, `secret.snapshot.meshID` equals `secret.meshID`.
6. `credentialStore.save(MeshCredentials(meshID: secret.meshID, meshKey: secret.meshKey))`, then
   `RegistryCache.save(secret.snapshot, appSupport)` ([../data/app-storage.md](../data/app-storage.md)).
7. Sends `pair.done`, waits at most 5 s for the Main to close, closes the channel, returns `secret.snapshot`.

Failures after step 2, each of which closes the channel:

- a wait for a frame that times out → `timedOut`; the channel closed while waiting → `rejected`; the calling task
  cancelled → `CancellationError`;
- a frame that `PairingCodec.decode` refuses → its `protocolError` ("Expected <name>." or "Invalid <name>.");
- a failed check of step 4, or a public key from which `k` cannot be derived → `protocolError("Invalid pair.hello.")`;
- a `pair.credentials` that does not open or decode, or fails a check of step 5 →
  `protocolError("Invalid pair.credentials.")`;
- a failure of step 6 (the credential store or `RegistryCache.save`) → that error, rethrown unchanged.

After `join` returns, the app calls `workspace.restart()` ([../client/workspace.md](../client/workspace.md#lifecycle)),
which reads the credentials and the saved registry and connects to the Mains of the snapshot.

| `PairingError`          | `errorDescription`                                     |
|-------------------------|--------------------------------------------------------|
| `invalidCode`           | "Enter the 6-digit code shown on the Main."            |
| `rejected`              | "Wrong code, or the pairing window has closed."        |
| `unreachable(detail)`   | "Cannot reach the Main: <detail>"                      |
| `timedOut`              | "The Main did not answer."                             |
| `protocolError(detail)` | "Pairing failed: <detail>"                             |

The join flow ([../ui/devices.md](../ui/devices.md#join-flow)) offers the Mains seen with `pair = "1"` (host = TXT
`host`, port = TXT `pport`) and a manual address field `host` or `host:port`, the port defaulting to 47101.

## Registry

Each Main holds the registry: one `DeviceRecord` per device that ever joined, revoked ones included
([../protocol/types.md](../protocol/types.md#devicerecord)). `MeshRegistry` holds the records, the merge rule and
the own-record rule; `MeshService` persists it and syncs it.

### Merge

`MeshRegistry.merge(_ incoming: [DeviceRecord]) -> [DeviceRecord]` (returns the records that changed):

- A record whose id is unknown is added.
- For a known id, the incoming record replaces the current one when its `updatedAt` is later, compared at
  millisecond precision (the precision of dates on the wire, [../protocol/envelope.md](../protocol/envelope.md));
  on equal `updatedAt` the current record stays.

A change this Main makes to a record it holds (admission, the own-record rule, rename, revocation, pairing) sets
`updatedAt` to now, or to 1 ms after the record's current `updatedAt` when now is not later at millisecond precision
(`MeshRegistry.updateDate(for:now:)`); every "`updatedAt` now" of this doc on an existing record is that date. A change
stamped in the same millisecond as the version it replaces would lose the merge on the other Mains, which keep their
record on equal `updatedAt`, and the registries would never converge.

After a merge that changed something, in order:

1. Every record that became `revoked`: every connection with that device is closed (its inbound connections with
   `peer.close()`, its outgoing peer link), and its presence and relayed entries are dropped.
2. The own-record rule runs ([This Main's record](#this-mains-record)).
3. The peer links are reconciled ([Peer links](#peer-links)).
4. The registry is saved, `mesh.changed` is emitted and `mesh.sync` is sent ([Change propagation](#change-propagation)).

Sources of incoming records: `mesh.sync` params (from a peer Main) and results, `hello` replies on outgoing peer
links, the pairing exchange, and the Main's own changes (`hello` admission, rename, revoke, addresses, own record).

### Admission (hello)

The host checks `hello` and calls `connectionOpened(device:connectionID:peer:)` after replying
([../services/host.md](../services/host.md#42-handshake)). `MeshService` then:

1. Records the connection: `connectionID` → `{deviceID: device.id, peer}` (direct connection,
   [Presence](#presence)).
2. Unknown `device.id`: adds the record `{id, name, platform, isMain, appVersion, build}` from `device`,
   `addresses: []`, `port: 0`, `pairedAt` and `updatedAt` now, `revoked: false`. The TLS-PSK handshake already proved
   membership.
3. Known id: when `platform`, `isMain`, `appVersion` or `build` differs from `device`, copies them with `updatedAt`
   now. When `device.isMain` is false and the record had `isMain` true, also sets `addresses: []` and `port: 0`. The
   name is never changed: the device adopts the record's name ([roles.md](roles.md#names)).
4. Presence and registry changes propagate ([Change propagation](#change-propagation)).

`connectionClosed(connectionID:)` removes the connection, updates presence, and calls
`host.migration.connectionClosed(connectionID:)` ([migration.md](migration.md#failures)).

### This Main's record

`MeshService` asserts the fields this Main owns in its own record, computed as:

| Field        | Value                                                                                    |
|--------------|------------------------------------------------------------------------------------------|
| `id`         | `device.json` id ([roles.md](roles.md#devicejson))                                       |
| `name`       | the existing record's name; for a new record, the `device.json` name                     |
| `platform`   | `macOS`                                                                                  |
| `isMain`     | `true` while running; `false` after `resignMain()`                                       |
| `addresses`  | `HostAddresses` ([Addresses of a Main](#addresses-of-a-main)); `[]` after `resignMain()` |
| `port`       | `boundListenerPort()`, else the `listenerPort` setting; `0` after `resignMain()`         |
| `appVersion` | `CFBundleShortVersionString`                                                             |
| `build`      | `CFBundleVersion` as `Int`, `0` when not an integer                                      |
| `pairedAt`   | the existing record's; for a new record, now                                             |
| `revoked`    | the existing record's; for a new record, `false`                                         |

The rule runs at `ensureMesh()`, when the mesh listener starts, and after every registry or address change: when a
computed field differs from the record, the record is rewritten with the computed fields and `updatedAt` now. This
repairs a merge that brought back older values of this Main's fields (for example a `hello` update made on another
Main before this Main's last `mesh.sync` arrived there).

### Rename and addresses

| Method               | Behavior                                                                                                                                      | Errors                                                                              |
|----------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| `mesh.renameDevice`  | trims `name`; sets `name` and `updatedAt` now on the record of `deviceID` (revoked or not); returns the record                                | `notFound` "No device <deviceID>."                                                  |
| `mesh.setAddresses`  | trims each entry, drops empty ones and repeats; saves the `additionalAddresses` setting; recomputes this Main's addresses; returns its record | `badRequest` with the setting rule's message ("an address must not contain spaces") |

The name is checked before the device. An empty name is refused with `badRequest` "Enter a device name." (the general
rule of [../protocol/methods.md](../protocol/methods.md), with the message of [roles.md](roles.md#names)); a reserved
name ([roles.md](roles.md#names)) with `badRequest` "Claude is a reserved name.".
When the renamed record is this Main's, the advertisement takes the new name. The renamed device itself adopts the
name from the next snapshot it receives ([roles.md](roles.md#names)).

### Persistence

- `ensureMesh()` loads `registry.json` with `RegistryCache.load` ([../data/app-storage.md](../data/app-storage.md)) and
  keeps it when its `meshID` equals the credentials' meshID; otherwise the registry starts empty. The `lastSeen` values
  of its `presence` seed the last-seen table ([Presence](#presence)). Then the own-record rule adds or updates this
  Main's record.
- `RegistryCache.save(snapshot(), appSupport)` runs `registrySaveDelay` (1 s) after the last change of the registry or
  of the last-seen table, at once after a revocation, and in `resignMain()` and `stopPeerLinks()` when a save is
  pending. A failed save is logged and retried at the next change.
- While the host runs, `MeshService` is the only writer of `registry.json`; the Workspace of a Main never writes it
  ([../client/workspace.md](../client/workspace.md#registry-persistence)).

### Change propagation

- `mesh.changed` (`MeshChangedPayload(snapshot: snapshot())`, [../protocol/events.md](../protocol/events.md)) is
  broadcast with `host.events.broadcast` `coalescingDelay` (250 ms) after the first of a burst of changes to the
  registry or to the presence report ([Presence](#presence)).
- `mesh.sync` is sent on every established outgoing peer link `coalescingDelay` after a change of the registry or of
  this Main's direct entries, with params `{devices: <all records>, presence: <direct entries>}`. The result is merged
  and stored as that Main's relayed entries. A failed `mesh.sync` is logged; the link's own error handling applies.
- A Main that receives `mesh.changed` on one of its outgoing peer links sends `mesh.sync` on that link (coalesced). This
  keeps the relayed entries of a peer current when the peer's own link to this Main is down.
- Every change converges: a merge that changes nothing triggers nothing.

## Revocation and key rotation

### Revoking

`mesh.revokeDevice {deviceID}` on the Main that receives it (the executing Main, X):

1. Checks: unknown `deviceID` → `notFound` "No device <deviceID>."; `deviceID` is X → `badRequest` "A Main cannot
   revoke itself.". An already revoked device: answers `{}` and does nothing else.
2. Sets `revoked: true` and `updatedAt` now on the record; saves at once. Removes its presence entries.
3. Generates a new key, `credentialStore.save(MeshCredentials(meshID: <same>, meshKey: <new>))`, and records it as the
   key in use (the key-change reaction below does not run for this change).
4. Answers `{}`. A device that revoked itself may lose its connection before the answer.
5. Closes every connection with the revoked device, inbound and outgoing.
6. Sends `mesh.sync` on its outgoing peer links, in parallel, and waits for the results (at most `rekeyTimeout`, 30 s,
   each), so the other Mains know the revocation before they get the key.
7. Replaces its mesh listener with one using the new transport key, as in step 2 of the key-change reaction below,
   with its retries: the connections step 5 closed can keep the port in use for a few milliseconds
   ([Parameters](#parameters)). Established connections, which carry the `mesh.rekey` requests of step 8, stay open.
8. Sends `mesh.rekey {meshKey: <new key>}` ([../protocol/methods.md](../protocol/methods.md#meshrekey)) on every
   inbound authenticated connection of a non-revoked device, in parallel, waiting at most `rekeyTimeout` (30 s) each.
   These include the outgoing peer links of the other Mains, the connections of every remote, and the loopback
   connection of its own UI, whose Workspace saves the same key again (the key-change reaction ignores it) and
   reconnects its network connections with it ([../client/workspace.md](../client/workspace.md#incoming-requests)).
   Failures are logged.
9. Closes its outgoing peer links and redials them with the new key, at once.
10. `mesh.changed` was emitted by step 2 through the normal propagation.

Each Main that receives the key on its outgoing link to X forwards it to its own remotes that X was not connected to
([Receiving a new key](#receiving-a-new-key)).

Devices offline during the rotation, and devices whose connections did not receive the key, keep the old key: every
Main that rotated refuses them (`authenticationFailed`), and they pair again ([roles.md](roles.md#leaving-the-mesh)).
The revoked device is refused the same way. A Main offline during the rotation keeps the old key: the other Mains
refuse its peer links and it never learns the revocation, so it keeps accepting the old key, the revoked device
included, until it leaves the mesh and pairs again.

### Receiving a new key

- A `Workspace` answers `mesh.rekey` on its connections, the loopback connection of a Main's own UI included
  ([../client/workspace.md](../client/workspace.md#incoming-requests)).
- On a Main, `mesh.rekey` arrives on its outgoing peer links (the Main is the client there; envelope rule: the client
  serves `mesh.rekey`). `MeshService` registers this handler on each outgoing link's `RPCPeer`: decode `meshKey`
  (32 bytes, else `badRequest` "The mesh key must be 32 bytes."); record the link's Main as the sender of that key
  (`MeshService` keeps the last key received this way and its sender); when the key differs from the stored key,
  `credentialStore.save(...)` with the same meshID (a failure answers `internal` "Could not store the mesh key.");
  answer `{}`. Any other method on an outgoing link is answered `badRequest` "Unknown method <name>.".

Key-change reaction: `ensureMesh()` records the loaded or created credentials as the key in use; the first time it runs
in a `MeshService` instance it also starts iterating `credentialStore.changes()`, for the life of the instance. When
yielded credentials have the meshID of the key in use and another `meshKey` (stored by an outgoing link's handler, or
by the Workspace of this Mac), `MeshService`:

1. Records the new key as the key in use.
2. When the mesh listener runs: replaces it with one using the new transport key, on the port and `listenerHost` it is
   bound to, with the `acceptor` of the last `startListener` call, and sets the advertisement again (when
   advertising). Established connections stay open; the pairing window is not affected (it seals the stored key at
   each exchange). A start that fails with `listenerFailed` is tried again every 50 ms, at most 40 times (2 s): the
   port of the listener just stopped can stay in use for a few milliseconds ([Parameters](#parameters)). During these
   tries nothing is advertised and `boundListenerPort()` keeps the port; a `startListener` or `stopListener()` call
   ends them. When the last try fails, or the start fails another way, the failure is logged and
   `HostService.listenerError` is set to its message (`host.setListenerError(_:)`), as for a failure of `start()`
   step 9 ([../services/host.md](../services/host.md#31-start)). The next steps then run, and the start is tried again
   in the background, with the key in use at each try, after each delay of `backoff` (1, 2, 5, 10, then every 30 s),
   each failure logged and setting `listenerError` to its message, until it succeeds, which clears `listenerError` and
   sets the advertisement again (when advertising), or until the next `startListener` or `stopListener()` call. During
   these background retries `boundListenerPort()` is nil and nothing is advertised; another key change, or
   [Revoking](#revoking) step 7, starts no replacement (the listener does not run): the next try, after its usual
   delay, uses the new key. A replacement that starts, at once or in the background, runs the own-record rule
   ([This Main's record](#this-mains-record)), as `startListener` does, but does not recompute the addresses: the
   record's `port` is the bound port again when the rule ran during the background retries and gave it the
   `listenerPort` setting.
3. Forwards the key at once, without waiting for the answers: `mesh.rekey {meshKey}` in parallel, at most
   `rekeyTimeout` each, failures logged, on each inbound authenticated connection of a remote that the sending Main X
   was not connected to. A remote here is a non-revoked device whose record has `isMain` false: peer Mains get
   nothing. X was connected to the devices of its relayed entries ([Direct entries](#direct-entries)), whose presence
   `via` lists X. X is the sender recorded with this key by the outgoing link's handler; when none is recorded (this
   Mac's Workspace stored the key first), no remote is excluded, and a remote that already holds the key answers `{}`
   and changes nothing. When a sender is recorded, the key also goes, in the same way, on this Mac's own loopback
   connection, so that this Mac's Workspace uses it ([../client/workspace.md](../client/workspace.md#incoming-requests))
   even when its own connection to X was down. There is no other condition and no timer.
4. When the peer links are started: closes every outgoing peer link and redials at once; each new link runs `hello`
   and `mesh.sync` ([Peer links](#peer-links)).

On a Mac whose host is stopped (no listener, no peer links, no inbound connection), only step 1 runs. Yielded
credentials whose `meshKey` equals the key in use are ignored. Credentials of another mesh, or none (`delete()`), are
not expected while the host runs (pairing and Leave mesh happen with the host stopped,
[roles.md](roles.md#leaving-the-mesh)); they are logged and ignored.

## Presence

Presence says which devices are online. Each Main reports what it sees directly and what its peer Mains see directly;
clients merge the reports of every Main they are connected to ([../protocol/types.md](../protocol/types.md#presence)).

### Direct entries

`PresenceTable` keeps, on each Main M:

- the connections of M: inbound authenticated connections (from `connectionOpened`) and established outgoing peer
  links, each with its device id;
- the relayed entries: for each peer Main P, the direct entries P sent last (`mesh.sync` params received from P, or a
  `mesh.sync` result from P);
- the last-seen table `[deviceID: Date]`, seeded from `registry.json`.

M's direct entries, built at time t: M itself and every non-revoked device with at least one connection to M, each
`{deviceID, online: true, lastSeen: t, via: [M]}`. Only online entries are direct entries; `mesh.sync` carries them
([../protocol/methods.md](../protocol/methods.md#meshsync)).

The relayed entries of P are dropped when M has no connection left with P (neither direction). Relayed entries are
never sent on: `mesh.sync` carries only direct entries.

### Presence report

`snapshot().presence` (the `MeshSnapshot` of `hello`, `mesh.snapshot` and `mesh.changed`), built at time t: one entry
per non-revoked device of the registry, sorted by device id:

| Field      | Value                                                                                                  |
|------------|--------------------------------------------------------------------------------------------------------|
| `online`   | true when the device is in M's direct entries or in the relayed entries of a peer Main still connected |
| `via`      | sorted union of `[M]` when direct and `[P]` for each peer Main P whose relayed entries list the device |
| `lastSeen` | online: t; offline: the last-seen table's value, else the record's `pairedAt`                          |

- When a device goes from online to offline in M's report (its last connection closed, or the relayed entries that
  listed it changed or were dropped), the last-seen table gets t for it.
- The report changes, for `mesh.changed`, when a device's `online` or `via` changes or an offline `lastSeen` changes;
  the `lastSeen` of online entries is not compared.
- The direct entries change, for `mesh.sync`, when the set of devices in them changes.

### Client view

The Workspace merges the reports of the Mains it is connected to with `PresenceModel.mergePresence`
([../client/workspace.md](../client/workspace.md#presence-merge)): a device is online when any report says so,
`lastSeen` is the most recent, `via` is the union; this device is always online; when a connection is lost, every
device its report showed online gets that moment as last seen; with no connected Main every other device is offline
with its cached `lastSeen`.

### Example

Studio `M` and Sam's MacBook Pro `B` are Mains; Sam's iPad `P` and an iPhone `I` are remotes.

| Time  | Event                                                                                      | M's report                                                         | What P shows                                       |
|-------|--------------------------------------------------------------------------------------------|--------------------------------------------------------------------|----------------------------------------------------|
| 09:00 | M and B start; links M→B and B→M open; `mesh.sync` both ways                               | M online via [M, B]; B online via [M, B]; P, I offline             | not connected                                      |
| 09:10 | P connects to M only                                                                       | P online via [M]                                                   | M, B, P online; I offline                          |
| 09:20 | I connects to B only; B's direct entries change; B sends `mesh.sync` to M                  | I online via [B]                                                   | I online                                           |
| 10:00 | I disconnects; B's direct entries lose I; B sends `mesh.sync` to M                         | I offline, `lastSeen` 10:00 (M's table)                            | I offline, last seen 10:00                         |
| 10:30 | B quits; both links close; M drops B's relayed entries                                     | B offline, `lastSeen` 10:30                                        | B offline, last seen 10:30                         |
| 10:31 | P loses its connection to M                                                                | (M sees P offline, `lastSeen` 10:31)                               | M last seen 10:31, B 10:30, I 10:00; P online      |

## Peer links

Every running Main connects as a client to every other Main of its registry: the outgoing peer links. Two Mains are
therefore linked twice, once in each direction; both links are kept. A Main sends its own requests to another Main
only on its own outgoing link to it (on a link a Main did not open it is the server, and a client serves only
`mesh.rekey`, [../protocol/envelope.md](../protocol/envelope.md#connections)). Each Main pushes its changes on its own
links ([Change propagation](#change-propagation)), so both directions stay informed.

### Dialing

`PeerLinkManager` keeps one link per Main to reach: every non-revoked record with `isMain` true other than this Main.
It reconciles after each registry change (new Main: link created; Main revoked or no longer a Main: link closed and
removed). For one link, an attempt tries the addresses in order, without duplicates:

1. The `host` and `port` of the Bonjour advert with the Main's id, when it is seen with `protocolVersion` 1 and a mesh
   tag equal to this Main's.
2. Each entry of the Main's record `addresses`, with the record's `port`.

For one address (URL `WebSocketChannel.url(host:port:path: "/hephaestus")`):

1. `WebSocketChannel.connect(url:credentials:timeout: addressTimeout)` (5 s).
2. An `RPCPeer` on the channel; its request handler serves `mesh.rekey` ([Receiving a new key](#receiving-a-new-key));
   a task iterates `peer.events` and passes each event to [Events on links](#events-on-links);
   `Task { await peer.run() }`.
3. Request `hello {device: localDevice(), protocolVersion: 1}`.
4. Outcome of steps 1–3:

| Outcome                                   | Action                                                                                                    |
|-------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| reply `device.id` is the Main's id        | the reply's `mesh.devices` are merged; the link is connected; next: `mesh.sync`                           |
| reply `device.id` is another device       | close; next address                                                                                       |
| `authenticationFailed`                    | close; the attempt stops (the key is not accepted by that Main at any address)                            |
| error `unauthorized`                      | close; no new attempt until the credentials change (this Main was revoked)                                |
| error `badRequest`                        | close; no new attempt until that Main's record changes (another protocol version)                         |
| any other failure                         | close; next address                                                                                       |

5. `mesh.sync {devices, presence}` on the link; its result is merged and stored as the Main's relayed entries. The link
   is now established: it counts as a connection for presence, `PeerLinkEvent.connected(<reply device>)` is yielded.

Backoff: after a failed attempt, or when an established link closes, the next attempt waits
`backoff[min(failures, 5) - 1]` seconds (1, 2, 5, 10, 30, then 30), `failures` counting since the last established
link. An attempt starts at once on `startPeerLinks()`, when the Main's Bonjour advert appears or changes, when its
record changes, and when the key in use changes.

When an established link closes (any reason, including the 30 s idle timeout of the channel), its connection leaves
presence, `PeerLinkEvent.disconnected(<id>)` is yielded, and the backoff applies. `stopPeerLinks()` closes every link,
stops the browser and the path monitor, and cancels the attempts.

### Events on links

Events that a peer Main broadcasts arrive on this Main's outgoing link to it, in its `peer.events`. For each event:

- `mesh.changed`: schedules a `mesh.sync` on that link ([Change propagation](#change-propagation));
- every event, `mesh.changed` included: yields `PeerLinkEvent.event(mainID:, <InboundEvent>)` for the other host
  services (the skills sync reacts to `skills.changed`, [../claude/skills.md](../claude/skills.md)).

### Requests to other Mains

- `connectedPeerMains()` returns the `DeviceInfo` (from the `hello` reply) of each Main with an established outgoing
  link, sorted by name.
- `requestPeer(_:method:params:as:timeout:)` sends one request on the established outgoing link to that Main through
  its `RPCPeer` and returns the decoded result. No established link, or the link closes before the response:
  `unavailable` "<name> is not connected." (the record's name, else the id). No response within `timeout`: the
  request is cancelled and `unavailable` "<name> did not answer in time." is thrown. These replace the `RPCPeer`
  errors "Not connected." and "The device did not answer in time.". Error responses are rethrown as received.
- Users: the identifier check of `projects.create` and `projects.import` ([../services/host.md](../services/host.md)),
  MCP tools acting on projects of other Mains ([../claude/mcp.md](../claude/mcp.md)), the skills sync
  ([../claude/skills.md](../claude/skills.md)), migration ([migration.md](migration.md)).

## MeshService

The host service of this doc. One instance, created by `HostService.init` and kept for the life of the app
([../services/host.md](../services/host.md#1-objects)).

### Lifecycle

| Call                       | Effect                                                                                                                                                                                                                                                                                                              |
|----------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `ensureMesh()`             | Loads the credentials; without them creates the mesh and saves it. Loads the registry ([Persistence](#persistence)), applies the own-record rule, starts iterating `credentialStore.changes()` the first time only. Throws a `DataError` when the credential store fails.                                           |
| `startListener(acceptor:)` | Starts a `WebSocketListener` with the transport key on `options.listenerPort` when it is set, else on the `listenerPort` setting, bound to `options.listenerHost` (`host:`); every channel it delivers is passed to `acceptor` in a new task. Throws `MeshTransportError.listenerFailed` (the host shows its text). |
| `stopListener()`           | Stops the listener and closes the pairing window. Established connections stay open.                                                                                                                                                                                                                                |
| `boundListenerPort()`      | The `port` of the mesh listener while it runs, kept during the tries every 50 ms of its replacement after a key change ([Receiving a new key](#receiving-a-new-key)); nil otherwise. Tests read the port of a listener started on port 0 with it.                                                                   |
| `startAdvertising()`       | Sets the Bonjour service on the listener ([Advertising](#advertising)); does nothing without a running listener or when `options.bonjour` is false.                                                                                                                                                                 |
| `stopAdvertising()`        | Removes the Bonjour service.                                                                                                                                                                                                                                                                                        |
| `startPeerLinks()`         | Starts its `BonjourBrowser` (not when `options.bonjour` is false: the links then dial the record addresses only), the path monitor and the address refresh, and the links ([Peer links](#peer-links)).                                                                                                              |
| `stopPeerLinks()`          | Closes every outgoing link, stops the browser, the path monitor and the refresh, writes a pending registry save.                                                                                                                                                                                                    |
| `resignMain()`             | [Resigning](#resigning).                                                                                                                                                                                                                                                                                            |

The host calls them in the order of [../services/host.md](../services/host.md#3-lifecycle). The key-change reaction
uses the `acceptor` of the last `startListener` call. `options` is the `HostOptions` the host was created with
([../services/host.md](../services/host.md#2-api-surface)); the app passes `HostOptions()`, which keeps the settings,
every interface and Bonjour.

### Resigning

`resignMain()` runs before `HostService.stop()` when Main is turned off or the Mac leaves the mesh
([roles.md](roles.md#turning-main-off-macos)): this Main's record gets `isMain: false`, `addresses: []`, `port: 0` and
`updatedAt` now; the registry is saved; `mesh.sync` is sent on every established outgoing link in parallel and waited
for at most `resignTimeout` (2 s) each; `mesh.changed` is broadcast at once; the pairing window closes. The other Mains
then close their links to this Mac, and remotes stop counting it as a Main.

### Requests served

`MeshService` conforms to `HostMethodHandler` for the methods the host routes to it
([../services/host.md](../services/host.md#44-dispatch)); params and results are the structs of
[../protocol/methods.md](../protocol/methods.md#mesh-and-pairing).

| Method               | Params                    | Result              | Behavior                                                                                                                                            |
|----------------------|---------------------------|---------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| `mesh.snapshot`      | `EmptyPayload`            | `MeshSnapshot`      | `snapshot()`                                                                                                                                        |
| `mesh.sync`          | `MeshSyncParams`          | `MeshSyncResult`    | merges `devices`; stores `presence` as the caller's relayed entries; returns `{devices: <all records after the merge>, presence: <direct entries>}` |
| `mesh.renameDevice`  | `MeshRenameDeviceParams`  | `DeviceRecord`      | [Rename and addresses](#rename-and-addresses)                                                                                                       |
| `mesh.revokeDevice`  | `MeshRevokeDeviceParams`  | `EmptyPayload`      | [Revoking](#revoking)                                                                                                                               |
| `mesh.setAddresses`  | `MeshSetAddressesParams`  | `DeviceRecord`      | [Rename and addresses](#rename-and-addresses)                                                                                                       |
| `pairing.open`       | `EmptyPayload`            | `PairingOpenResult` | [Pairing window](#pairing-window-main)                                                                                                              |
| `pairing.close`      | `EmptyPayload`            | `EmptyPayload`      | closes the window when one is open                                                                                                                  |

`mesh.sync` is accepted only from connections whose `hello` had `isMain` true (the host answers others with
`unauthorized`). The caller is `context.device.id`.

### Settings

`MeshService` reads the device settings `pairingPort` and `additionalAddresses` from the `SettingsStore` when it uses
them, and `listenerPort` at `ensureMesh()` and at each `startListener`: the listener binds that value unless
`options.listenerPort` is set, and the own-record rule uses it for `port` ([This Main's record](#this-mains-record))
until the next read. It writes `additionalAddresses` with `SettingsStore.update` for `mesh.setAddresses` (both on the
main actor, [../data/app-storage.md](../data/app-storage.md)).

### Swift API

```swift
public actor MeshService: HostMethodHandler {
    public init(host: HostService, appSupport: AppSupport, settings: SettingsStore,
                credentialStore: any MeshCredentialStore, options: HostOptions)

    // Lifecycle (services/host.md §3)
    public func ensureMesh() async throws
    public func startListener(acceptor: @escaping @Sendable (any MessageChannel) async -> Void) async throws
    public func stopListener() async
    /// The port of the running mesh listener, kept during the 50 ms tries of its replacement after a key change;
    /// nil otherwise.
    public func boundListenerPort() async -> Int?
    public func startAdvertising() async
    public func stopAdvertising() async
    public func startPeerLinks() async
    public func stopPeerLinks() async
    /// Main turned off or Leave mesh, before HostService.stop() (roles.md).
    public func resignMain() async

    // Connections (services/host.md §4)
    public func localDevice() async -> DeviceInfo                 // this Main: own record's name, isMain true
    public func snapshot() async -> MeshSnapshot                  // registry and presence report
    public func isRevoked(_ deviceID: UUID) async -> Bool
    public func connectionOpened(device: DeviceInfo, connectionID: UUID, peer: RPCPeer) async
    public func connectionClosed(connectionID: UUID) async

    // Peer links (other host services)
    public func connectedPeerMains() async -> [DeviceInfo]
    public func requestPeer<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ deviceID: UUID, method: String, params: P, as: R.Type, timeout: Duration) async throws -> R
    /// A new stream of link changes and of the events received on outgoing links.
    public func peerLinkEvents() -> AsyncStream<PeerLinkEvent>

    // HostMethodHandler: mesh.snapshot, mesh.sync, mesh.renameDevice, mesh.revokeDevice, mesh.setAddresses,
    // pairing.open, pairing.close. Public: a public actor conforming to the public protocol.
    public func handle(method: String, params: Data, context: RequestContext) async throws -> Data
}

public enum PeerLinkEvent: Sendable {
    case connected(DeviceInfo)                  // an outgoing link completed hello and its first mesh.sync
    case disconnected(UUID)                     // that link closed
    case event(mainID: UUID, InboundEvent)      // an event received on an outgoing link
}
```

- `HostService`, `HostOptions`, `RequestContext` and `HostMethodHandler`: [../services/host.md](../services/host.md).
  `RPCPeer`, `MessageChannel`, `InboundEvent`, `WireCoding`, `ProtocolError`:
  [../protocol/envelope.md](../protocol/envelope.md). `AppSupport`, `SettingsStore`, `MeshCredentials`,
  `MeshCredentialStore`, `RegistryCache`, `DataError`: [../data/app-storage.md](../data/app-storage.md).
- `device.json` ([roles.md](roles.md#devicejson)) gives this Main's id and its name before it has a record.
  `MeshService` reads it (`DeviceFile.load`) when it is created and, when it could not then, at each `ensureMesh()`:
  there a missing file throws `DataError.notFound("device.json: the file does not exist")` and an unreadable one the
  `DeviceFile.load` error, so `HostService.start()` fails. `localDevice()` before `ensureMesh()` uses the `device.json`
  name; without a readable `device.json`, an id generated once per `MeshService` instance and the name "Mac".
- Errors thrown by handlers are `ProtocolError` values with the codes of
  [../protocol/methods.md](../protocol/methods.md).
