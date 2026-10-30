import CryptoKit
import Foundation
import HephCore
import Synchronization

/// The joiner side of pairing (docs/devices/mesh.md, "Joining (PairingClient)"). Pairing codes, keys and sealed
/// payloads are never logged.
public enum PairingClient {
    /// The joiner side: connects to wss://<host>:<port>/pair, runs the exchange, stores the credentials with
    /// `credentialStore` and the snapshot with RegistryCache.save(_:_:), sends pair.done, returns the snapshot.
    public static func join(host: String, port: Int, code: String, device: DeviceInfo,
                            credentialStore: any MeshCredentialStore, appSupport: AppSupport) async throws -> MeshSnapshot {
        // 1. The code.
        guard MeshCrypto.isValidPairingCode(code) else {
            throw PairingError.invalidCode
        }

        // 2. The channel keyed by the code.
        guard let url = WebSocketChannel.url(host: host, port: port, path: MeshConstants.pairingPath) else {
            throw PairingError.unreachable("Invalid address \(host).")
        }
        let channel: WebSocketChannel
        do {
            channel = try await WebSocketChannel.connect(url: url, psk: MeshCrypto.pairingKey(code: code),
                                                         identity: MeshConstants.pairingIdentity,
                                                         timeout: .seconds(10))
        } catch let error as MeshTransportError {
            switch error {
            case .authenticationFailed: throw PairingError.rejected
            case .unreachable(let detail): throw PairingError.unreachable(detail)
            case .timedOut: throw PairingError.timedOut
            case .invalidCredentials, .listenerFailed: throw PairingError.unreachable(error.localizedDescription)
            }
        }

        var frames = channel.inbound.makeAsyncIterator()
        do {
            // 3. pair.hello with an ephemeral key.
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            channel.send(try encode(helloEvent, PairHello(device: device, publicKey: privateKey.publicKey.rawRepresentation)))

            // 4. The Main's pair.hello, then k.
            let hello = try PairingCodec.decode(helloEvent, as: PairHello.self, frame: try await nextFrame(&frames, channel))
            guard hello.device.isMain, hello.publicKey.count == 32 else {
                throw PairingError.protocolError("Invalid \(helloEvent).")
            }
            let key: SymmetricKey
            do {
                key = try MeshCrypto.exchangeKey(privateKey: privateKey, peerPublicKey: hello.publicKey, code: code)
            } catch {
                throw PairingError.protocolError("Invalid \(helloEvent).")
            }

            // 5. pair.credentials, opened and checked.
            let credentials = try PairingCodec.decode(credentialsEvent, as: PairCredentials.self,
                                                      frame: try await nextFrame(&frames, channel))
            let secret: PairSecret
            do {
                let plaintext = try MeshCrypto.open(credentials.sealed, key: key)
                secret = try WireCoding.makeDecoder().decode(PairSecret.self, from: plaintext)
            } catch {
                throw PairingError.protocolError("Invalid \(credentialsEvent).")
            }
            guard secret.meshKey.count == 32, secret.snapshot.meshID == secret.meshID else {
                throw PairingError.protocolError("Invalid \(credentialsEvent).")
            }

            // 6. The credentials, then the registry snapshot.
            try credentialStore.save(MeshCredentials(meshID: secret.meshID, meshKey: secret.meshKey))
            try RegistryCache.save(secret.snapshot, appSupport)

            // 7. pair.done; the Main closes the channel (at most 5 s).
            channel.send(try encode(doneEvent, EmptyPayload()))
            await waitForClose(&frames, channel, timeout: .seconds(5))
            channel.close()
            Log.net.notice("Joined the mesh \(secret.meshID.uuidString, privacy: .public) through \(channel.remoteDescription)")
            return secret.snapshot
        } catch {
            channel.close()
            Log.net.error("Pairing with \(channel.remoteDescription) failed: \(String(describing: error))")
            throw error
        }
    }

    // MARK: - Private

    private static let helloEvent = "pair.hello"
    private static let credentialsEvent = "pair.credentials"
    private static let doneEvent = "pair.done"

    private static func encode<P: Encodable & Sendable>(_ name: String, _ params: P) throws -> Data {
        do {
            return try PairingCodec.encode(name, params)
        } catch {
            throw PairingError.protocolError("Invalid \(name).")
        }
    }

    /// The next frame, waited for at most `pairingStepTimeout` (then the channel is closed): `timedOut` when the wait
    /// timed out, `rejected` when the channel closed, `CancellationError` when the calling task was cancelled.
    private static func nextFrame(_ frames: inout AsyncStream<Data>.Iterator, _ channel: WebSocketChannel) async throws -> Data {
        switch await next(&frames, channel, timeout: MeshConstants.pairingStepTimeout) {
        case .frame(let frame):
            return frame
        case .timedOut:
            throw PairingError.timedOut
        case .closed:
            try Task.checkCancellation()
            throw PairingError.rejected
        }
    }

    /// Reads and ignores frames until the channel closes, at most `timeout`.
    private static func waitForClose(_ frames: inout AsyncStream<Data>.Iterator, _ channel: WebSocketChannel,
                                     timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return }
            switch await next(&frames, channel, timeout: remaining) {
            case .frame:
                continue
            case .closed, .timedOut:
                return
            }
        }
    }

    private enum Wait {
        case frame(Data)
        case closed
        case timedOut
    }

    /// Waits for the next frame of `frames`; after `timeout` the channel is closed, which ends the wait.
    private static func next(_ frames: inout AsyncStream<Data>.Iterator, _ channel: WebSocketChannel,
                             timeout: Duration) async -> Wait {
        let expired = ExpiryFlag()
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            expired.set()
            channel.close()
        }
        defer { timer.cancel() }
        guard let frame = await frames.next() else {
            return expired.isSet ? .timedOut : .closed
        }
        return .frame(frame)
    }
}

/// Whether a wait timed out; set by the timer task, read by the waiter.
private final class ExpiryFlag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool {
        value.withLock { $0 }
    }

    func set() {
        value.withLock { $0 = true }
    }
}

public enum PairingError: Error, Equatable, Sendable, LocalizedError {
    case invalidCode, rejected, unreachable(String), timedOut, protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCode: return "Enter the 6-digit code shown on the Main."
        case .rejected: return "Wrong code, or the pairing window has closed."
        case .unreachable(let detail): return "Cannot reach the Main: \(detail)"
        case .timedOut: return "The Main did not answer."
        case .protocolError(let detail): return "Pairing failed: \(detail)"
        }
    }
}
