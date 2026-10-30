#if os(macOS)
import Foundation
import HephCore

/// The mesh registry of a Main (docs/devices/mesh.md, "Registry"): one DeviceRecord per device that ever joined,
/// revoked ones included, with the merge rule and the own-record rule. MeshService persists and syncs it.
struct MeshRegistry: Sendable {
    let meshID: UUID
    /// The records, in the order they were added.
    private(set) var records: [DeviceRecord]

    init(meshID: UUID, records: [DeviceRecord] = []) {
        self.meshID = meshID
        self.records = []
        _ = merge(records)
    }

    func record(_ id: UUID) -> DeviceRecord? {
        records.first { $0.id == id }
    }

    func isRevoked(_ id: UUID) -> Bool {
        record(id)?.revoked ?? false
    }

    /// Adds the record, or replaces the record with its id.
    mutating func set(_ record: DeviceRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    /// An unknown id is added; a known one is replaced when the incoming `updatedAt` is later, compared at
    /// millisecond precision (equal: the current record stays). Returns the records that changed.
    mutating func merge(_ incoming: [DeviceRecord]) -> [DeviceRecord] {
        var changed: [DeviceRecord] = []
        for record in incoming {
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                guard Self.milliseconds(record.updatedAt) > Self.milliseconds(records[index].updatedAt),
                      records[index] != record
                else { continue }
                records[index] = record
            } else {
                records.append(record)
            }
            changed.removeAll { $0.id == record.id }
            changed.append(record)
        }
        return changed
    }

    /// The own-record rule (docs/devices/mesh.md, "This Main's record"): when a computed field differs from this
    /// Main's record, the record is rewritten with the computed fields and `updatedAt` now. True when it was rewritten.
    mutating func assertOwnRecord(id: UUID, defaultName: String, isMain: Bool, addresses: [String], port: Int,
                                  appVersion: String, build: Int, now: Date) -> Bool {
        let existing = record(id)
        let computed = DeviceRecord(id: id,
                                    name: existing?.name ?? defaultName,
                                    platform: .macOS,
                                    isMain: isMain,
                                    addresses: addresses,
                                    port: port,
                                    appVersion: appVersion,
                                    build: build,
                                    pairedAt: existing?.pairedAt ?? now,
                                    updatedAt: existing?.updatedAt ?? now,
                                    revoked: existing?.revoked ?? false)
        if let existing, existing == computed {
            return false
        }
        var rewritten = computed
        rewritten.updatedAt = updateDate(for: id, now: now)
        set(rewritten)
        return true
    }

    /// The `updatedAt` of a change made here to the record `id`: now, or 1 ms after the record's current `updatedAt`
    /// when now is not later at millisecond precision, so that the change wins the merges of the other Mains.
    func updateDate(for id: UUID, now: Date) -> Date {
        guard let current = record(id)?.updatedAt, Self.milliseconds(now) <= Self.milliseconds(current) else {
            return now
        }
        return Date(timeIntervalSince1970: TimeInterval(Self.milliseconds(current) + 1) / 1_000)
    }

    /// A date at millisecond precision, as it goes through the wire (rounded to the microsecond first, then the
    /// millisecond truncated).
    static func milliseconds(_ date: Date) -> Int64 {
        let micros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        return Int64((micros / 1_000).rounded(.down))
    }
}
#endif
