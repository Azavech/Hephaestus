import CryptoKit
import Foundation
import HephCore

/// The keys of the mesh (docs/devices/mesh.md, "Keys"). Pure functions; keys, PSKs and codes are never logged.
public enum MeshCrypto {
    /// 32 random bytes: the bytes of `SymmetricKey(size: .bits256)`.
    public static func newMeshKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: meshKey), salt:, info:, outputByteCount: 32).
    /// nil for invalid credentials.
    public static func transportKey(_ credentials: MeshCredentials) -> SymmetricKey? {
        guard isValid(credentials) else { return nil }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: credentials.meshKey),
                                      salt: Data(MeshConstants.transportSalt.utf8),
                                      info: Data(credentials.meshID.uuidString.utf8),
                                      outputByteCount: 32)
    }

    /// SHA-256 of the UTF-8 of the meshID text form, lowercase hex, first 8 characters; "" without credentials.
    public static func meshTag(_ credentials: MeshCredentials?) -> String {
        guard let credentials, isValid(credentials) else { return "" }
        let digest = SHA256.hash(data: Data(credentials.meshID.uuidString.utf8))
        return String(hex(Data(digest)).prefix(8))
    }

    /// `String(format: "%06d", Int.random(in: 0...999_999))` with the system CSPRNG.
    public static func newPairingCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0...999_999, using: &generator))
    }

    /// Exactly 6 ASCII digits.
    public static func isValidPairingCode(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        return bytes.count == 6 && bytes.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }

    /// HKDF-SHA256(ikm: UTF-8 of the code, salt: UTF-8 of "hephaestus-pairing-v1", info: empty), 32 bytes.
    public static func pairingKey(code: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                               salt: Data(MeshConstants.pairingSalt.utf8),
                               info: Data(),
                               outputByteCount: 32)
    }

    /// Curve25519.KeyAgreement: privateKey.sharedSecretFromKeyAgreement(with: PublicKey(rawRepresentation:)), then
    /// sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: code, sharedInfo: "hephaestus-pair-key", 32).
    public static func exchangeKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                                   code: String) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                    salt: Data(code.utf8),
                                                    sharedInfo: Data(MeshConstants.pairKeyInfo.utf8),
                                                    outputByteCount: 32)
    }

    /// ChaChaPoly.seal(plaintext, using: key).combined (12-byte nonce, ciphertext, 16-byte tag); no authenticated data.
    public static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key).combined
    }

    /// ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key).
    public static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
    }

    // MARK: - Private

    /// Credentials whose `meshKey` is not 32 bytes are treated as no credentials (logged).
    private static func isValid(_ credentials: MeshCredentials) -> Bool {
        guard credentials.meshKey.count == 32 else {
            Log.net.error("Ignoring mesh credentials whose key has \(credentials.meshKey.count, privacy: .public) bytes")
            return false
        }
        return true
    }

    private static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 2)
        for byte in data {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
