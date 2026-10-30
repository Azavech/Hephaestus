import Foundation
import HephCore

// The messages of the pairing exchange (docs/devices/mesh.md, "Exchange"): envelope events, one per text frame, read
// and written directly on the channel. Binary values are base64 strings. Sealed payloads are never logged.

/// `pair.hello` params.
public struct PairHello: Codable, Sendable {
    public var device: DeviceInfo
    /// 32-byte raw X25519 key.
    public var publicKey: Data

    public init(device: DeviceInfo, publicKey: Data) {
        self.device = device
        self.publicKey = publicKey
    }
}

/// `pair.credentials` params.
public struct PairCredentials: Codable, Sendable {
    /// MeshCrypto.seal(JSON of PairSecret, k).
    public var sealed: Data

    public init(sealed: Data) {
        self.sealed = sealed
    }
}

/// The sealed plaintext of `pair.credentials`.
public struct PairSecret: Codable, Sendable {
    public var meshID: UUID
    public var meshKey: Data
    public var snapshot: MeshSnapshot

    public init(meshID: UUID, meshKey: Data, snapshot: MeshSnapshot) {
        self.meshID = meshID
        self.meshKey = meshKey
        self.snapshot = snapshot
    }
}

public enum PairingCodec {
    /// WireCoding.encodeEvent(name:params:).
    public static func encode<P: Encodable & Sendable>(_ name: String, _ params: P) throws -> Data {
        try WireCoding.encodeEvent(name: name, params: params)
    }

    /// WireCoding.parseFrame(frame) must succeed with kind event and event equal to `name`, else it throws
    /// PairingError.protocolError("Expected <name>."); then WireCoding.decodeJSON(P.self, from: body), a failure
    /// throwing PairingError.protocolError("Invalid <name>.").
    public static func decode<P: Decodable>(_ name: String, as type: P.Type, frame: Data) throws -> P {
        guard let parsed = try? WireCoding.parseFrame(frame), parsed.kind == .event, parsed.event == name else {
            throw PairingError.protocolError("Expected \(name).")
        }
        do {
            return try WireCoding.decodeJSON(type, from: parsed.body)
        } catch {
            throw PairingError.protocolError("Invalid \(name).")
        }
    }
}
