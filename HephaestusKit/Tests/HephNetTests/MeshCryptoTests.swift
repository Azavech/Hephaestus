import CryptoKit
import Foundation
import XCTest
@testable import HephCore
@testable import HephNet

final class MeshCryptoTests: XCTestCase {
    /// The test vectors of docs/devices/mesh.md ("Keys"), as lowercase hex of the key bytes.
    func testVectors() throws {
        let meshID = try XCTUnwrap(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        let credentials = MeshCredentials(meshID: meshID, meshKey: Data((0...31).map { UInt8($0) }))

        let transportKey = try XCTUnwrap(MeshCrypto.transportKey(credentials))
        XCTAssertEqual(hex(transportKey), "10a66611c79e4e0f059d20a5951a0e5e989bfe7b4b91e63b5b07179c3fad5668")

        XCTAssertEqual(MeshCrypto.meshTag(credentials), "2da8e55a")

        XCTAssertEqual(hex(MeshCrypto.pairingKey(code: "123456")),
                       "c2866a1203998d897adb92d1c31e9c0ba2b9ffb331ea96cfcd0d331ad2c10565")

        let first = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let second = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        let exchange = "c8cd48ce188fc40a60411bee09e76fb5dc4d6d00d170ada6702b9c77dfb64db4"
        let forward = try MeshCrypto.exchangeKey(privateKey: first, peerPublicKey: second.publicKey.rawRepresentation,
                                                 code: "123456")
        XCTAssertEqual(hex(forward), exchange)
        let backward = try MeshCrypto.exchangeKey(privateKey: second, peerPublicKey: first.publicKey.rawRepresentation,
                                                  code: "123456")
        XCTAssertEqual(hex(backward), exchange)
    }

    private func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }
}
