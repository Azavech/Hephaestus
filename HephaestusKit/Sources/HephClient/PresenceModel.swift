import Foundation
import HephCore

/// The registry merge and the presence merge of the Workspace, as pure functions (docs/client/workspace.md, "Registry
/// merge" and "Presence merge").
public enum PresenceModel {
    /// For every device id present in either list, the record with the later `updatedAt` wins (compared at millisecond
    /// precision); on equal `updatedAt` the current record stays. The result is sorted by name
    /// (`localizedStandardCompare`), then id.
    public static func mergeRegistry(_ current: [DeviceRecord], with incoming: [DeviceRecord]) -> [DeviceRecord] {
        var records: [UUID: DeviceRecord] = [:]
        for record in current {
            records[record.id] = keepLater(records[record.id], record)
        }
        for record in incoming {
            records[record.id] = keepLater(records[record.id], record)
        }
        return sortedByName(Array(records.values))
    }

    /// The merged presence of every non-revoked device of `devices`: this device online now; every other device online
    /// when any report says so, with the most recent `lastSeen` of the reports and of `lastSeen` (else its `pairedAt`)
    /// and the union of the reports' `via`, sorted by `uuidString`.
    public static func mergePresence(devices: [DeviceRecord], reports: [[Presence]], lastSeen: [UUID: Date],
                                     localDeviceID: UUID, now: Date) -> [UUID: Presence] {
        var entriesByID: [UUID: [Presence]] = [:]
        for report in reports {
            for entry in report {
                entriesByID[entry.deviceID, default: []].append(entry)
            }
        }
        var result: [UUID: Presence] = [:]
        for record in devices where !record.revoked {
            if record.id == localDeviceID {
                result[record.id] = Presence(deviceID: record.id, online: true, lastSeen: now, via: [])
                continue
            }
            let entries = entriesByID[record.id] ?? []
            let online = entries.contains(where: \.online)
            var latest: Date? = lastSeen[record.id]
            for entry in entries where latest.map({ entry.lastSeen > $0 }) ?? true {
                latest = entry.lastSeen
            }
            var via = Set<UUID>()
            for entry in entries {
                via.formUnion(entry.via)
            }
            result[record.id] = Presence(deviceID: record.id, online: online, lastSeen: latest ?? record.pairedAt,
                                         via: via.sorted { $0.uuidString < $1.uuidString })
        }
        return result
    }

    // MARK: - Helpers

    /// The records sorted by name (`localizedStandardCompare`), then id.
    static func sortedByName(_ records: [DeviceRecord]) -> [DeviceRecord] {
        records.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// `incoming` when there is no current record or its `updatedAt` is later, else the current record.
    private static func keepLater(_ current: DeviceRecord?, _ incoming: DeviceRecord) -> DeviceRecord {
        guard let current else { return incoming }
        return milliseconds(incoming.updatedAt) > milliseconds(current.updatedAt) ? incoming : current
    }

    /// A date at millisecond precision, as it travels on the wire (docs/protocol/envelope.md, "Encoding").
    private static func milliseconds(_ date: Date) -> Int64 {
        let micros = (date.timeIntervalSinceReferenceDate * 1_000_000).rounded()
        return Int64((micros / 1_000).rounded(.down))
    }
}
