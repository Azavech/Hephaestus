import CryptoKit
import Foundation
import HephCore
import Network
import Security

/// The parameters of every mesh and pairing connection: TCP, TLS 1.2 with a pre-shared key, then the WebSocket upgrade
/// (docs/devices/mesh.md, "Parameters").
public enum MeshParameters {
    public static func make(psk: SymmetricKey, identity: String, listener: Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let id = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, id as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options()
        if !listener { tcp.connectionTimeout = 5 }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        if listener { parameters.allowLocalEndpointReuse = true }
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = WireCoding.maxFrameSize
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }
}
