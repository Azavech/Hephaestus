import Foundation
import XCTest
@testable import HephClient
@testable import HephCore

final class PresenceMergeTests: XCTestCase {
    private let now = TestEnvironment.now
    private let localID = TestMesh.local.id

    private func date(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    private func record(_ name: String, id: UUID = UUID(), updatedAt: Date? = nil, revoked: Bool = false)
        -> DeviceRecord {
        DeviceRecord(id: id, name: name, platform: .iPadOS, isMain: false, addresses: [], port: 0, appVersion: "1.0",
                     build: 1, pairedAt: TestMesh.pairedAt, updatedAt: updatedAt ?? TestMesh.updatedAt,
                     revoked: revoked)
    }

    func testRegistryLastWriterWins() {
        let id = UUID()
        let older = record("Zed", id: id, updatedAt: date(-10))
        let newer = record("Alpha", id: id, updatedAt: date(-5))
        XCTAssertEqual(PresenceModel.mergeRegistry([older], with: [newer]), [newer])
        XCTAssertEqual(PresenceModel.mergeRegistry([newer], with: [older]), [newer])

        let sameDate = record("Other", id: id, updatedAt: date(-5))
        XCTAssertEqual(PresenceModel.mergeRegistry([newer], with: [sameDate]), [newer])

        let beta = record("beta")
        let gamma = record("Gamma")
        let merged = PresenceModel.mergeRegistry([gamma, newer], with: [beta])
        XCTAssertEqual(merged.map(\.name), ["Alpha", "beta", "Gamma"])
    }

    func testOnlineIfAnyReport() {
        let device = record("D")
        let mainA = UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!
        let mainB = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
        let reports = [
            [Presence(deviceID: device.id, online: true, lastSeen: date(-1), via: [mainA])],
            [Presence(deviceID: device.id, online: false, lastSeen: date(-30), via: [mainB, mainA])],
        ]
        let presence = PresenceModel.mergePresence(devices: [device], reports: reports, lastSeen: [:],
                                                   localDeviceID: localID, now: now)
        XCTAssertEqual(presence[device.id]?.online, true)
        XCTAssertEqual(presence[device.id]?.via, [mainB, mainA])
    }

    func testOfflineLastSeen() {
        let device = record("D")
        let reports = [
            [Presence(deviceID: device.id, online: false, lastSeen: date(-20), via: [])],
            [Presence(deviceID: device.id, online: false, lastSeen: date(-40), via: [])],
        ]
        let fromReports = PresenceModel.mergePresence(devices: [device], reports: reports,
                                                      lastSeen: [device.id: date(-30)], localDeviceID: localID,
                                                      now: now)
        XCTAssertEqual(fromReports[device.id]?.online, false)
        XCTAssertEqual(fromReports[device.id]?.lastSeen, date(-20))

        let fromTable = PresenceModel.mergePresence(devices: [device], reports: reports,
                                                    lastSeen: [device.id: date(-10)], localDeviceID: localID, now: now)
        XCTAssertEqual(fromTable[device.id]?.lastSeen, date(-10))

        let neither = PresenceModel.mergePresence(devices: [device], reports: [], lastSeen: [:],
                                                  localDeviceID: localID, now: now)
        XCTAssertEqual(neither[device.id]?.online, false)
        XCTAssertEqual(neither[device.id]?.lastSeen, TestMesh.pairedAt)
    }

    func testNoReports() {
        let first = record("A")
        let second = record("B")
        let presence = PresenceModel.mergePresence(devices: [first, second], reports: [],
                                                   lastSeen: [first.id: date(-15)], localDeviceID: localID, now: now)
        XCTAssertEqual(presence[first.id], Presence(deviceID: first.id, online: false, lastSeen: date(-15), via: []))
        XCTAssertEqual(presence[second.id],
                       Presence(deviceID: second.id, online: false, lastSeen: TestMesh.pairedAt, via: []))
    }

    func testLocalAndRevoked() {
        let local = record("This iPad", id: localID)
        let revoked = record("Old iPhone", revoked: true)
        let reports = [[
            Presence(deviceID: localID, online: false, lastSeen: date(-60), via: []),
            Presence(deviceID: revoked.id, online: true, lastSeen: date(-1), via: []),
        ]]
        let presence = PresenceModel.mergePresence(devices: [local, revoked], reports: reports, lastSeen: [:],
                                                   localDeviceID: localID, now: now)
        XCTAssertEqual(presence[localID], Presence(deviceID: localID, online: true, lastSeen: now, via: []))
        XCTAssertNil(presence[revoked.id])
        XCTAssertEqual(presence.count, 1)
    }
}
