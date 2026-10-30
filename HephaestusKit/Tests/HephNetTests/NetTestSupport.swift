import CryptoKit
import Foundation
import XCTest
@testable import HephCore
@testable import HephNet

/// The mesh credentials of the tests: mesh id 00000000-0000-4000-8000-000000000100, a key of 32 bytes 0x01.
let testCredentials = MeshCredentials(meshID: UUID(uuidString: "00000000-0000-4000-8000-000000000100")!,
                                      meshKey: Data(repeating: 0x01, count: 32))

/// The same mesh id with another key: 32 bytes 0x02.
let otherCredentials = MeshCredentials(meshID: testCredentials.meshID, meshKey: Data(repeating: 0x02, count: 32))

extension XCTestCase {
    /// A new folder under the temporary directory, with a UUID in its name, removed at teardown.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephNetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

/// The error thrown by `waitUntil` when the condition does not hold in time.
struct WaitTimedOut: Error {}

/// Waits until `condition` holds, polling every 10 ms; fails the test and throws after `timeout`.
func waitUntil(timeout: Duration = .seconds(5), _ condition: () async throws -> Bool,
               file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("The condition did not hold within \(timeout).", file: file, line: line)
            throw WaitTimedOut()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Plays the Main's side of a pairing window with HephNet alone: a pairing listener on 127.0.0.1, and on the first
/// channel steps 1–4 of the Main's side of the exchange (docs/devices/mesh.md, "Exchange"), with `PairingCodec`.
actor TestPairingMain {
    /// The port of the pairing listener.
    nonisolated let port: Int
    /// The Main's identity sent in its `pair.hello`: the first Main record of the snapshot, else a new Mac.
    nonisolated let device: DeviceInfo
    /// The joiner's `DeviceInfo`, from its `pair.hello`.
    private(set) var joinerDevice: DeviceInfo?
    /// Whether `pair.done` arrived.
    private(set) var receivedDone = false

    private let listener: WebSocketListener
    private let channels: AsyncStream<WebSocketChannel>.Continuation
    private let code: String
    private let credentials: MeshCredentials
    private let snapshot: MeshSnapshot
    private var serving: Task<Void, Never>?
    private var channel: WebSocketChannel?

    init(code: String, credentials: MeshCredentials, snapshot: MeshSnapshot) async throws {
        let listener = WebSocketListener(port: 0, psk: MeshCrypto.pairingKey(code: code),
                                         identity: MeshConstants.pairingIdentity, host: "127.0.0.1")
        let (stream, continuation) = AsyncStream.makeStream(of: WebSocketChannel.self)
        try await listener.start(onChannel: { channel in
            continuation.yield(channel)
        })
        self.listener = listener
        self.channels = continuation
        self.port = listener.port
        self.code = code
        self.credentials = credentials
        self.snapshot = snapshot
        if let record = snapshot.devices.first(where: \.isMain) {
            device = DeviceInfo(id: record.id, name: record.name, platform: .macOS, isMain: true,
                                appVersion: record.appVersion, build: record.build)
        } else {
            device = DeviceInfo(id: UUID(), name: "Test Main", platform: .macOS, isMain: true, appVersion: "1.0",
                                build: 1)
        }
        serving = Task { await self.serveFirst(of: stream) }
    }

    /// Stops the listener and closes the channel being served.
    func stop() {
        listener.stop()
        channels.finish()
        serving?.cancel()
        channel?.close()
    }

    private func serveFirst(of stream: AsyncStream<WebSocketChannel>) async {
        for await channel in stream {
            guard self.channel == nil else {
                channel.close()
                continue
            }
            self.channel = channel
            await serve(channel)
        }
    }

    private func serve(_ channel: WebSocketChannel) async {
        var frames = channel.inbound.makeAsyncIterator()
        do {
            // 1. pair.hello from the joiner.
            guard let helloFrame = await frames.next() else { return }
            let hello = try PairingCodec.decode("pair.hello", as: PairHello.self, frame: helloFrame)
            joinerDevice = hello.device
            guard hello.publicKey.count == 32, hello.device.id != device.id,
                  !hello.device.isMain || hello.device.platform == .macOS
            else {
                channel.close()
                return
            }
            // 2. pair.hello with an ephemeral key; k.
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            channel.send(try PairingCodec.encode("pair.hello",
                                                 PairHello(device: device, publicKey: privateKey.publicKey.rawRepresentation)))
            let key = try MeshCrypto.exchangeKey(privateKey: privateKey, peerPublicKey: hello.publicKey, code: code)
            // 3. pair.credentials.
            let secret = PairSecret(meshID: credentials.meshID, meshKey: credentials.meshKey, snapshot: snapshot)
            let sealed = try MeshCrypto.seal(try WireCoding.makeEncoder().encode(secret), key: key)
            channel.send(try PairingCodec.encode("pair.credentials", PairCredentials(sealed: sealed)))
            // 4. pair.done.
            guard let doneFrame = await frames.next() else { return }
            _ = try PairingCodec.decode("pair.done", as: EmptyPayload.self, frame: doneFrame)
            receivedDone = true
            channel.close()
        } catch {
            channel.close()
        }
    }
}
