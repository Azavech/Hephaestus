#if os(macOS)
import CryptoKit
import Foundation
import HephCore
import HephNet

/// The pairing window of a Main (docs/devices/mesh.md, "Pairing window (Main)" and "Exchange"). Owned by MeshService
/// and used only on its actor: every method runs isolated to the MeshService it is given.
final class PairingHost {
    private struct Window {
        let code: String
        let expiresAt: Date
        let port: Int
    }

    private var window: Window?
    private var opening: Task<PairingOpenResult, Error>?
    private var listener: WebSocketListener?
    private var failures = 0
    /// The channel of the exchange in progress.
    private var exchange: WebSocketChannel?
    private var expiry: Task<Void, Never>?
    /// Changes with each window; callbacks of an older window are ignored.
    private var generation = 0

    var isOpen: Bool {
        window != nil
    }

    /// pairing.open: returns the open window unchanged, or opens one.
    func open(mesh: isolated MeshService) async throws -> PairingOpenResult {
        if let window {
            return PairingOpenResult(code: window.code, expiresAt: window.expiresAt, port: window.port)
        }
        if let opening {
            return try await opening.value
        }
        let task = Task<PairingOpenResult, Error> {
            try await mesh.openPairingWindow()
        }
        opening = task
        defer { opening = nil }
        return try await task.value
    }

    /// Opens a window: a listener on the pairingPort setting keyed by a new code (step 2).
    func start(mesh: isolated MeshService) async throws -> PairingOpenResult {
        if mesh.credentials == nil {
            try await mesh.loadMesh()
        }
        let code = MeshCrypto.newPairingCode()
        generation += 1
        let current = generation
        let started = WebSocketListener(port: await mesh.pairingPortSetting(), psk: MeshCrypto.pairingKey(code: code),
                                        identity: MeshConstants.pairingIdentity, host: mesh.options.listenerHost)
        do {
            try await started.start(onChannel: { [weak mesh] channel in
                Task { await mesh?.pairingChannel(channel, generation: current) }
            }, onHandshakeFailure: { [weak mesh] in
                Task { await mesh?.pairingHandshakeFailed(generation: current) }
            })
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw ProtocolError(.unavailable, "Cannot open the pairing window: \(text)")
        }
        guard generation == current else {
            started.stop()
            throw ProtocolError(.unavailable, "Cannot open the pairing window: it was closed.")
        }
        listener = started
        failures = 0
        let opened = Window(code: code, expiresAt: Date().addingTimeInterval(300), port: started.port)
        window = opened
        expiry = Task { [weak mesh] in
            do {
                try await Task.sleep(for: MeshConstants.pairingWindowDuration)
            } catch {
                return
            }
            await mesh?.pairingExpired(generation: current)
        }
        Log.host.notice("A pairing window is open on port \(opened.port, privacy: .public)")
        await mesh.updateAdvertisement()
        return PairingOpenResult(code: opened.code, expiresAt: opened.expiresAt, port: opened.port)
    }

    /// Closes the window: the pairing listener stops, a channel still in an exchange closes, `pair` becomes "0".
    func close(mesh: isolated MeshService) async {
        generation += 1
        listener?.stop()
        listener = nil
        exchange?.close()
        exchange = nil
        expiry?.cancel()
        expiry = nil
        guard window != nil else { return }
        window = nil
        Log.host.notice("The pairing window closed")
        await mesh.updateAdvertisement()
    }

    /// The window of that generation expired.
    func expired(generation: Int, mesh: isolated MeshService) async {
        guard generation == self.generation else { return }
        await close(mesh: mesh)
    }

    /// A failed TLS handshake (a wrong code): the fifth closes the window.
    func handshakeFailed(generation: Int, mesh: isolated MeshService) async {
        guard generation == self.generation, window != nil else { return }
        failures += 1
        if failures >= MeshConstants.pairingMaxFailures {
            await close(mesh: mesh)
        }
    }

    /// A channel of the pairing listener: the Main's side of the exchange; a channel arriving while another exchange
    /// runs is closed at once.
    func channelArrived(_ channel: WebSocketChannel, generation: Int, mesh: isolated MeshService) async {
        guard generation == self.generation, let window, exchange == nil else {
            channel.close()
            return
        }
        exchange = channel
        let joined = await runExchange(channel, code: window.code, mesh: mesh)
        if exchange === channel {
            exchange = nil
        }
        channel.close()
        if joined, generation == self.generation {
            await close(mesh: mesh)
        }
    }

    // MARK: - Exchange

    /// Steps 1–5 of the Main's side; false when a step failed (the window stays open).
    private func runExchange(_ channel: WebSocketChannel, code: String, mesh: isolated MeshService) async -> Bool {
        var frames = channel.inbound.makeAsyncIterator()
        do {
            // 1. pair.hello of the joiner.
            guard let helloFrame = await nextFrame(&frames, channel, mesh: mesh) else { return false }
            let hello = try PairingCodec.decode(Self.helloEvent, as: PairHello.self, frame: helloFrame)
            guard hello.publicKey.count == 32, hello.device.id != mesh.ownID,
                  !hello.device.isMain || hello.device.platform == .macOS
            else {
                Log.host.error("Pairing refused an invalid pair.hello")
                return false
            }
            // 2. This Main's pair.hello and k.
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            channel.send(try PairingCodec.encode(Self.helloEvent,
                                                 PairHello(device: mesh.localDeviceInfo(),
                                                           publicKey: privateKey.publicKey.rawRepresentation)))
            let key = try MeshCrypto.exchangeKey(privateKey: privateKey, peerPublicKey: hello.publicKey, code: code)
            // 3. pair.credentials, sealing the stored key.
            guard let credentials = (try? mesh.credentialStore.load()) ?? mesh.credentials else { return false }
            let secret = PairSecret(meshID: credentials.meshID, meshKey: credentials.meshKey,
                                    snapshot: mesh.currentSnapshot())
            let sealed = try MeshCrypto.seal(try WireCoding.makeEncoder().encode(secret), key: key)
            channel.send(try PairingCodec.encode(Self.credentialsEvent, PairCredentials(sealed: sealed)))
            // 4. pair.done.
            guard let doneFrame = await nextFrame(&frames, channel, mesh: mesh) else { return false }
            _ = try PairingCodec.decode(Self.doneEvent, as: EmptyPayload.self, frame: doneFrame)
            // 5. The joiner's record.
            mesh.recordPairedDevice(hello.device)
            Log.host.notice("The device \(hello.device.id.uuidString, privacy: .public) joined the mesh")
            return true
        } catch {
            Log.host.error("A pairing exchange failed: \(String(describing: error))")
            return false
        }
    }

    private static let helloEvent = "pair.hello"
    private static let credentialsEvent = "pair.credentials"
    private static let doneEvent = "pair.done"

    /// The next frame, waited for at most `pairingStepTimeout`; then the channel is closed and nil returned.
    private func nextFrame(_ frames: inout AsyncStream<Data>.Iterator, _ channel: WebSocketChannel,
                           mesh: isolated MeshService) async -> Data? {
        let timer = Task {
            do {
                try await Task.sleep(for: MeshConstants.pairingStepTimeout)
            } catch {
                return
            }
            channel.close()
        }
        defer { timer.cancel() }
        return await frames.next(isolation: mesh)
    }
}
#endif
