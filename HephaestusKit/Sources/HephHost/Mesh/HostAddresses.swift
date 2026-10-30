#if os(macOS)
import Darwin
import Foundation
import HephCore
import Network
import SystemConfiguration

/// The `addresses` of a Main's own record (docs/devices/mesh.md, "Addresses of a Main"), and the network path monitor
/// whose updates make MeshService recompute them.
///
/// `@unchecked Sendable`: the NWPathMonitor and the callback are touched only on `queue`
/// (`ca.azavech.hephaestus.pathmonitor`).
final class HostAddresses: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ca.azavech.hephaestus.pathmonitor")
    private var monitor: NWPathMonitor?

    init() {}

    /// The local host name, then the IPv4 addresses, then the additional addresses; without duplicates (first kept).
    static func compute(additionalAddresses: [String]) -> [String] {
        var addresses: [String] = []
        for address in [localHostName()].compactMap({ $0 }) + ipv4Addresses() + additionalAddresses
        where !addresses.contains(address) {
            addresses.append(address)
        }
        return addresses
    }

    /// `SCDynamicStoreCopyLocalHostName(nil)` + `.local`; nil when unknown.
    static func localHostName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty else { return nil }
        return name + ".local"
    }

    /// The IPv4 addresses of `getifaddrs`, in its order: up and running, not loopback, not in 169.254.0.0/16.
    static func ipv4Addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var inet = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let host = UInt32(bigEndian: inet.s_addr)
            guard host >> 16 != 0xA9FE else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &inet, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let length = buffer.firstIndex(of: 0) ?? buffer.count
            addresses.append(String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return addresses
    }

    /// Starts a new path monitor; `onUpdate` is called on the monitor's queue after each update.
    func startMonitor(onUpdate: @escaping @Sendable () -> Void) {
        queue.sync {
            monitor?.cancel()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { _ in onUpdate() }
            monitor.start(queue: queue)
            self.monitor = monitor
        }
    }

    func stopMonitor() {
        queue.sync {
            monitor?.cancel()
            monitor = nil
        }
    }
}
#endif
