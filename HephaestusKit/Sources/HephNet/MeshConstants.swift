import Foundation

/// The constants of the mesh (docs/devices/mesh.md, "Constants").
public enum MeshConstants {
    /// Bonjour service type.
    public static let serviceType = "_hephaestus._tcp"
    /// URL path of mesh connections.
    public static let transportPath = "/hephaestus"
    /// URL path of pairing connections.
    public static let pairingPath = "/pair"
    /// PSK identity of mesh connections.
    public static let transportIdentity = "hephaestus"
    /// PSK identity of pairing connections.
    public static let pairingIdentity = "hephaestus-pairing"
    /// HKDF salt of the transport PSK.
    public static let transportSalt = "hephaestus-transport-v1"
    /// HKDF salt of the pairing PSK.
    public static let pairingSalt = "hephaestus-pairing-v1"
    /// HKDF info of the pairing exchange key.
    public static let pairKeyInfo = "hephaestus-pair-key"
    /// Pings (both sides); idle checks.
    public static let pingInterval: Duration = .seconds(10)
    /// A channel without inbound traffic for this long closes.
    public static let idleTimeout: Duration = .seconds(30)
    /// One address of a peer link dial.
    public static let addressTimeout: Duration = .seconds(5)
    /// Reconnect delays, in seconds; the last one repeats.
    public static let backoff: [Int] = [1, 2, 5, 10, 30]
    /// A pairing window closes after this long.
    public static let pairingWindowDuration: Duration = .seconds(300)
    /// Failed TLS handshakes that close a pairing window.
    public static let pairingMaxFailures = 5
    /// Wait for the next pairing message.
    public static let pairingStepTimeout: Duration = .seconds(15)
    /// `mesh.changed` and `mesh.sync` coalescing.
    public static let coalescingDelay: Duration = .milliseconds(250)
    /// `registry.json` write coalescing.
    public static let registrySaveDelay: Duration = .seconds(1)
    /// `mesh.sync` sent by `resignMain()`.
    public static let resignTimeout: Duration = .seconds(2)
    /// `mesh.rekey` requests; the `mesh.sync` of Revoking step 6.
    public static let rekeyTimeout: Duration = .seconds(30)
    /// Periodic recomputation of a Main's addresses.
    public static let addressRefreshInterval: Duration = .seconds(60)
    /// Recomputation of a Main's addresses after a network change.
    public static let pathChangeDelay: Duration = .seconds(2)
    /// Bonjour service name limit (UTF-8 bytes).
    public static let serviceNameMaxBytes = 63
}
