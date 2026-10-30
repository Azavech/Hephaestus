import Foundation
import HephCore
import Network

/// A Main seen by Bonjour: its service name and its TXT record (docs/devices/mesh.md, "TXT record").
public struct BonjourAdvert: Hashable, Sendable {
    public var id: UUID             // TXT id
    public var name: String         // Bonjour service name
    public var meshTag: String      // TXT mesh, "" when absent
    public var protocolVersion: Int // TXT pv, 0 when absent or not an integer
    public var host: String         // TXT host
    public var port: Int            // TXT port
    public var pairingOpen: Bool    // TXT pair == "1"
    public var pairingPort: Int?    // TXT pport, nil when absent or invalid

    public init(id: UUID, name: String, meshTag: String, protocolVersion: Int, host: String, port: Int,
                pairingOpen: Bool, pairingPort: Int? = nil) {
        self.id = id
        self.name = name
        self.meshTag = meshTag
        self.protocolVersion = protocolVersion
        self.host = host
        self.port = port
        self.pairingOpen = pairingOpen
        self.pairingPort = pairingPort
    }
}

/// The TXT record of a Main's advertisement; every value is a string.
public enum BonjourTXT {
    public static func record(deviceID: UUID, meshTag: String, host: String, port: Int,
                              pairingOpen: Bool, pairingPort: Int) -> NWTXTRecord {
        NWTXTRecord([
            "id": deviceID.uuidString,
            "mesh": meshTag,
            "pv": String(WireCoding.protocolVersion),
            "host": host,
            "port": String(port),
            "pair": pairingOpen ? "1" : "0",
            "pport": String(pairingPort),
        ])
    }

    /// nil when id is not a UUID, host is empty, or port is not in 1…65535.
    public static func parse(name: String, txt: NWTXTRecord) -> BonjourAdvert? {
        guard let id = txt["id"].flatMap(UUID.init(uuidString:)),
              let host = txt["host"], !host.isEmpty,
              let port = validPort(txt["port"])
        else { return nil }
        return BonjourAdvert(id: id,
                             name: name,
                             meshTag: txt["mesh"] ?? "",
                             protocolVersion: txt["pv"].flatMap { Int($0) } ?? 0,
                             host: host,
                             port: port,
                             pairingOpen: txt["pair"] == "1",
                             pairingPort: validPort(txt["pport"]))
    }

    /// The device name cut to at most 63 UTF-8 bytes, at a Character boundary.
    public static func serviceName(_ deviceName: String) -> String {
        var end = deviceName.startIndex
        var bytes = 0
        for index in deviceName.indices {
            let count = deviceName[index].utf8.count
            guard bytes + count <= MeshConstants.serviceNameMaxBytes else { break }
            bytes += count
            end = deviceName.index(after: index)
        }
        return String(deviceName[..<end])
    }

    /// An integer in 1…65535, else nil.
    private static func validPort(_ text: String?) -> Int? {
        guard let text, let port = Int(text), (1...65_535).contains(port) else { return nil }
        return port
    }
}
