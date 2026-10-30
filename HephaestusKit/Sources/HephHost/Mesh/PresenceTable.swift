#if os(macOS)
import Foundation
import HephCore
import HephNet

/// What a Main knows of presence (docs/devices/mesh.md, "Presence"): its connections, the relayed entries of its peer
/// Mains and the last-seen table; it builds the direct entries and the presence report.
struct PresenceTable: Sendable {
    /// A connection of this Main: an inbound authenticated connection or an established outgoing peer link.
    struct Connection: Sendable {
        let deviceID: UUID
        let peer: RPCPeer
        let outgoing: Bool
    }

    /// What a presence report entry is compared on for `mesh.changed` (the lastSeen of online entries is not).
    private struct ReportKey: Equatable {
        let online: Bool
        let via: [UUID]
        let offlineLastSeen: Date?
    }

    /// By connection id (inbound) or link connection id (outgoing).
    private(set) var connections: [UUID: Connection] = [:]
    /// For each peer Main P, the direct entries P sent last.
    private(set) var relayed: [UUID: [Presence]] = [:]
    private(set) var lastSeen: [UUID: Date] = [:]
    private var lastOnline: Set<UUID> = []
    private var lastReport: [UUID: ReportKey] = [:]
    private var lastDirect: Set<UUID> = []

    init() {}

    /// The lastSeen values of a saved presence report (registry.json).
    mutating func seed(_ presence: [Presence]) {
        for entry in presence {
            lastSeen[entry.deviceID] = entry.lastSeen
        }
    }

    mutating func add(_ connectionID: UUID, deviceID: UUID, peer: RPCPeer, outgoing: Bool) {
        connections[connectionID] = Connection(deviceID: deviceID, peer: peer, outgoing: outgoing)
    }

    /// Removes a connection; the relayed entries of a peer Main with no connection left are dropped.
    @discardableResult
    mutating func remove(_ connectionID: UUID) -> Connection? {
        let removed = connections.removeValue(forKey: connectionID)
        dropRelayedWithoutConnection()
        return removed
    }

    /// Removes every connection with a device and drops its presence and relayed entries (a revoked device).
    mutating func removeDevice(_ deviceID: UUID) -> [Connection] {
        let removed = connections.filter { $0.value.deviceID == deviceID }
        for connectionID in removed.keys {
            connections[connectionID] = nil
        }
        relayed[deviceID] = nil
        for mainID in relayed.keys {
            relayed[mainID]?.removeAll { $0.deviceID == deviceID }
        }
        dropRelayedWithoutConnection()
        return Array(removed.values)
    }

    /// The `presence` of a `mesh.sync` from or to a peer Main: stored as its relayed entries while a connection with it
    /// exists.
    mutating func storeRelayed(_ entries: [Presence], from mainID: UUID) {
        relayed[mainID] = entries.filter(\.online)
        dropRelayedWithoutConnection()
    }

    func hasConnection(with deviceID: UUID) -> Bool {
        connections.values.contains { $0.deviceID == deviceID }
    }

    /// The relayed entries of a peer Main are dropped when no connection is left with it (neither direction).
    private mutating func dropRelayedWithoutConnection() {
        for mainID in relayed.keys where !hasConnection(with: mainID) {
            relayed[mainID] = nil
        }
    }

    /// This Main and every non-revoked device with at least one connection to it.
    func directDevices(selfID: UUID, records: [DeviceRecord]) -> Set<UUID> {
        let revoked = Set(records.filter(\.revoked).map(\.id))
        var devices: Set<UUID> = [selfID]
        for connection in connections.values where !revoked.contains(connection.deviceID) {
            devices.insert(connection.deviceID)
        }
        return devices
    }

    /// The direct entries at `now`, sorted by device id: `{deviceID, online: true, lastSeen: now, via: [self]}`.
    func directEntries(selfID: UUID, records: [DeviceRecord], at now: Date) -> [Presence] {
        directDevices(selfID: selfID, records: records)
            .sorted { $0.uuidString < $1.uuidString }
            .map { Presence(deviceID: $0, online: true, lastSeen: now, via: [selfID]) }
    }

    /// The presence report at `now`: one entry per non-revoked device of the registry, sorted by device id.
    func report(selfID: UUID, records: [DeviceRecord], at now: Date) -> [Presence] {
        let direct = directDevices(selfID: selfID, records: records)
        return records
            .filter { !$0.revoked }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { record in
                let via = self.via(record.id, direct: direct, selfID: selfID)
                let online = !via.isEmpty
                return Presence(deviceID: record.id, online: online,
                                lastSeen: online ? now : (lastSeen[record.id] ?? record.pairedAt), via: via)
            }
    }

    /// Recomputes the report at `now`: a device that went from online to offline gets `now` in the last-seen table.
    /// Returns whether the report changed (for mesh.changed), whether the set of direct devices changed (for
    /// mesh.sync) and whether the last-seen table changed (for the registry save).
    mutating func refresh(selfID: UUID, records: [DeviceRecord],
                          at now: Date) -> (reportChanged: Bool, directChanged: Bool, lastSeenChanged: Bool) {
        let direct = directDevices(selfID: selfID, records: records)
        var online: Set<UUID> = []
        var vias: [UUID: [UUID]] = [:]
        for record in records where !record.revoked {
            let via = self.via(record.id, direct: direct, selfID: selfID)
            vias[record.id] = via
            if !via.isEmpty {
                online.insert(record.id)
            }
        }
        var lastSeenChanged = false
        for deviceID in lastOnline.subtracting(online) {
            lastSeen[deviceID] = now
            lastSeenChanged = true
        }
        var report: [UUID: ReportKey] = [:]
        for record in records where !record.revoked {
            let isOnline = online.contains(record.id)
            report[record.id] = ReportKey(online: isOnline, via: vias[record.id] ?? [],
                                          offlineLastSeen: isOnline ? nil : (lastSeen[record.id] ?? record.pairedAt))
        }
        let reportChanged = report != lastReport
        let directChanged = direct != lastDirect
        lastOnline = online
        lastReport = report
        lastDirect = direct
        return (reportChanged, directChanged, lastSeenChanged)
    }

    /// The sorted union of `[self]` when direct and `[P]` for each peer Main P whose relayed entries list the device.
    private func via(_ deviceID: UUID, direct: Set<UUID>, selfID: UUID) -> [UUID] {
        var via: Set<UUID> = direct.contains(deviceID) ? [selfID] : []
        for (mainID, entries) in relayed where entries.contains(where: { $0.deviceID == deviceID }) {
            via.insert(mainID)
        }
        return via.sorted { $0.uuidString < $1.uuidString }
    }
}
#endif
