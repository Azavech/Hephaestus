import CryptoKit
import Foundation
import Synchronization
import XCTest
@testable import HephCore
@testable import HephNet

final class TransportTests: XCTestCase {
    /// A TLS-PSK WebSocket on 127.0.0.1: the `hello` result, then the `mesh.snapshot` result, then a `mesh.changed`
    /// emitted by the server, all within 5 s.
    func testHandshakeRequestAndEvent() async throws {
        let started = ContinuousClock.now
        let date = try XCTUnwrap(WireCoding.parseDate("2026-10-29T21:00:00.000Z"))
        let main = DeviceInfo(id: UUID(), name: "Studio", platform: .macOS, isMain: true, appVersion: "1.0",
                              build: 1)
        let remote = DeviceInfo(id: UUID(), name: "Sam's iPad", platform: .iPadOS, isMain: false, appVersion: "1.0",
                                build: 1)
        let record = DeviceRecord(id: main.id, name: main.name, platform: .macOS, isMain: true,
                                  addresses: ["127.0.0.1"], port: 47100, appVersion: "1.0", build: 1,
                                  pairedAt: date, updatedAt: date, revoked: false)
        let snapshot = MeshSnapshot(meshID: testCredentials.meshID, devices: [record],
                                    presence: [Presence(deviceID: main.id, online: true, lastSeen: date, via: [main.id])])

        let psk = try XCTUnwrap(MeshCrypto.transportKey(testCredentials))
        let listener = WebSocketListener(port: 0, psk: psk, identity: MeshConstants.transportIdentity,
                                         host: "127.0.0.1")
        let servers = ServerPeers()
        try await listener.start(onChannel: { channel in
            let peer = RPCPeer(channel: channel)
            servers.add(peer)
            Task {
                await peer.setRequestHandler { request in
                    switch request.knownMethod {
                    case .hello?:
                        _ = try request.decodeParams(HelloParams.self)
                        return try WireCoding.encodeJSON(HelloResult(device: main, mesh: snapshot))
                    case .meshSnapshot?:
                        return try WireCoding.encodeJSON(snapshot)
                    default:
                        throw ProtocolError(.badRequest, "Unknown method \(request.method).")
                    }
                }
                await peer.run()
            }
        })
        addTeardownBlock {
            listener.stop()
            servers.closeAll()
        }
        XCTAssertGreaterThan(listener.port, 0)

        let url = try XCTUnwrap(WebSocketChannel.url(host: "127.0.0.1", port: listener.port,
                                                     path: MeshConstants.transportPath))
        XCTAssertEqual(url.absoluteString, "wss://127.0.0.1:\(listener.port)/hephaestus")
        let channel = try await WebSocketChannel.connect(url: url, credentials: testCredentials, timeout: .seconds(5))
        XCTAssertTrue(channel.isClient)
        XCTAssertEqual(channel.state, .open)

        let client = RPCPeer(channel: channel, requestTimeout: .seconds(5))
        let received = EventRecorder()
        let eventsTask = Task {
            for await event in client.events {
                received.append(event)
            }
        }
        let runTask = Task { await client.run() }
        addTeardownBlock {
            client.close()
            await runTask.value
            await eventsTask.value
        }

        let hello = try await client.request(.hello, HelloParams(device: remote, protocolVersion: WireCoding.protocolVersion),
                                             as: HelloResult.self)
        XCTAssertEqual(hello.device, main)
        XCTAssertEqual(hello.mesh, snapshot)

        let meshSnapshot = try await client.request(.meshSnapshot, EmptyPayload(), as: MeshSnapshot.self)
        XCTAssertEqual(meshSnapshot, snapshot)

        let server = try XCTUnwrap(servers.first)
        server.emit(.meshChanged(MeshChangedPayload(snapshot: snapshot)))
        try await waitUntil { received.count >= 1 }
        let event = try XCTUnwrap(received.first)
        XCTAssertEqual(event.name, EventName.meshChanged.rawValue)
        XCTAssertEqual(try event.decodeParams(MeshChangedPayload.self), MeshChangedPayload(snapshot: snapshot))

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    /// The client uses another key: opening the channel throws and the listener delivers no channel.
    func testWrongKeyFailsHandshake() async throws {
        let psk = try XCTUnwrap(MeshCrypto.transportKey(testCredentials))
        let listener = WebSocketListener(port: 0, psk: psk, identity: MeshConstants.transportIdentity,
                                         host: "127.0.0.1")
        let delivered = Counter()
        let handshakeFailures = Counter()
        try await listener.start(onChannel: { channel in
            delivered.increment()
            channel.close()
        }, onHandshakeFailure: {
            handshakeFailures.increment()
        })
        addTeardownBlock { listener.stop() }

        let url = try XCTUnwrap(WebSocketChannel.url(host: "127.0.0.1", port: listener.port,
                                                     path: MeshConstants.transportPath))
        do {
            let channel = try await WebSocketChannel.connect(url: url, credentials: otherCredentials, timeout: .seconds(5))
            channel.close()
            XCTFail("The channel opened with another key.")
        } catch {
            XCTAssertEqual(error as? MeshTransportError, .authenticationFailed)
        }
        try await waitUntil { handshakeFailures.value >= 1 }
        XCTAssertEqual(delivered.value, 0)
    }
}

/// The server peers of the listener, in arrival order.
private final class ServerPeers: Sendable {
    private let peers = Mutex<[RPCPeer]>([])

    var first: RPCPeer? {
        peers.withLock { $0.first }
    }

    func add(_ peer: RPCPeer) {
        peers.withLock { $0.append(peer) }
    }

    func closeAll() {
        for peer in peers.withLock({ $0 }) {
            peer.close()
        }
    }
}

/// The events a client peer received, in arrival order.
private final class EventRecorder: Sendable {
    private let events = Mutex<[InboundEvent]>([])

    var count: Int {
        events.withLock { $0.count }
    }

    var first: InboundEvent? {
        events.withLock { $0.first }
    }

    func append(_ event: InboundEvent) {
        events.withLock { $0.append(event) }
    }
}

private final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int {
        count.withLock { $0 }
    }

    func increment() {
        count.withLock { $0 += 1 }
    }
}
