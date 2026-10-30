import Foundation

/// The error of an error response: `{"code": <raw value>, "message": <text>}` (docs/protocol/envelope.md).
public struct ProtocolError: Error, Codable, Sendable, Hashable, LocalizedError {
    public enum Code: String, Codable, Sendable, CaseIterable {
        case badRequest, unauthorized, notFound, conflict, locked, unavailable, tooLarge, `internal`

        /// A raw value unknown to this build decodes as `internal`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Code(rawValue: raw) ?? .internal
        }
    }

    public var code: Code
    /// One short English sentence suitable for the error banner.
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    /// Converts any error thrown by a request handler: a `ProtocolError` is kept as it is; a `DecodingError` becomes
    /// `badRequest` "Invalid params."; any other error becomes `internal` with its `localizedDescription`.
    public init(_ error: any Error) {
        if let protocolError = error as? ProtocolError {
            self = protocolError
        } else if error is DecodingError {
            self.init(.badRequest, "Invalid params.")
        } else {
            self.init(.internal, error.localizedDescription)
        }
    }

    /// The message.
    public var errorDescription: String? { message }
}
