#if os(macOS)
import Foundation
import HephCore

/// Implemented by HostService (services/host.md).
public protocol MCPHost: Sendable {
    /// This Main (online is true).
    func localMain() async -> MCPMain
    /// The other non-revoked Mains of the registry; online = an outgoing peer link to it is open.
    func otherMains() async -> [MCPMain]
    /// Executes a protocol method with JSON params and returns the JSON result. On this Main: HostService.perform
    /// with RequestContext.local(device: <this Main's DeviceInfo>, author: "Claude"). On another Main: a request over
    /// the peer link (MeshService.requestPeer). Failures throw ProtocolError.
    func perform(_ method: String, params: Data, on deviceID: UUID) async throws -> Data
    /// Root folder of a project hosted on this Main, nil otherwise.
    func localProjectRoot(_ projectID: String) async -> URL?
    /// ForgeService.pushDocs / pushRegen (forge/pipeline.md): the text given back to Claude, or a thrown
    /// ProtocolError whose message is the error text.
    func forgePushDocs(sessionID: UUID) async throws -> String
    func forgePushRegen(sessionID: UUID) async throws -> String
}

/// A Main of the mesh, as the MCP tools see it.
public struct MCPMain: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var online: Bool

    public init(id: UUID, name: String, online: Bool) {
        self.id = id
        self.name = name
        self.online = online
    }
}
#endif
