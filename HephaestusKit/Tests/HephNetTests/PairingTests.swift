import Foundation
import XCTest
@testable import HephCore
@testable import HephNet

final class PairingTests: XCTestCase {
    /// The joiner pairs with the right code: it gets the snapshot, stores the credentials and the registry, and the
    /// Main recorded the joiner's identity and `pair.done`.
    func testPairingFlow() async throws {
        let snapshot = try makeSnapshot()
        let main = try await TestPairingMain(code: "123456", credentials: testCredentials, snapshot: snapshot)
        addTeardownBlock { await main.stop() }
        let joiner = DeviceInfo(id: UUID(), name: "Sam's iPad", platform: .iPadOS, isMain: false, appVersion: "1.0",
                                build: 1)
        let store = InMemoryCredentialStore()
        let appSupport = AppSupport(root: try makeTemporaryDirectory())

        let result = try await PairingClient.join(host: "127.0.0.1", port: main.port, code: "123456", device: joiner,
                                                  credentialStore: store, appSupport: appSupport)

        XCTAssertEqual(result, snapshot)
        XCTAssertEqual(try store.load(), testCredentials)
        XCTAssertEqual(RegistryCache.load(appSupport), snapshot)
        let recordedJoiner = await main.joinerDevice
        XCTAssertEqual(recordedJoiner, joiner)
        try await waitUntil { await main.receivedDone }
    }

    /// The joiner types another code: `join` throws, no credentials are stored, and the Main never got `pair.hello`.
    func testWrongCode() async throws {
        let main = try await TestPairingMain(code: "123456", credentials: testCredentials, snapshot: try makeSnapshot())
        addTeardownBlock { await main.stop() }
        let joiner = DeviceInfo(id: UUID(), name: "Sam's iPad", platform: .iPadOS, isMain: false, appVersion: "1.0",
                                build: 1)
        let store = InMemoryCredentialStore()
        let appSupport = AppSupport(root: try makeTemporaryDirectory())

        do {
            _ = try await PairingClient.join(host: "127.0.0.1", port: main.port, code: "654321", device: joiner,
                                             credentialStore: store, appSupport: appSupport)
            XCTFail("The joiner paired with a wrong code.")
        } catch {
            XCTAssertEqual(error as? PairingError, .rejected)
        }

        XCTAssertNil(try store.load())
        let recordedJoiner = await main.joinerDevice
        XCTAssertNil(recordedJoiner)
    }

    /// A snapshot of the mesh of `testCredentials` holding the Main's record.
    private func makeSnapshot() throws -> MeshSnapshot {
        let date = try XCTUnwrap(WireCoding.parseDate("2026-10-29T21:00:00.000Z"))
        let mainID = UUID()
        let record = DeviceRecord(id: mainID, name: "Studio", platform: .macOS, isMain: true,
                                  addresses: ["127.0.0.1"], port: 47100, appVersion: "1.0", build: 1,
                                  pairedAt: date, updatedAt: date, revoked: false)
        return MeshSnapshot(meshID: testCredentials.meshID, devices: [record],
                            presence: [Presence(deviceID: mainID, online: true, lastSeen: date, via: [mainID])])
    }
}
