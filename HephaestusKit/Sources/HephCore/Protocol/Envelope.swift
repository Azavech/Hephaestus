import Foundation

// The envelope of docs/protocol/envelope.md: frames, encoding, topics, received requests and events.

public enum EnvelopeKind: String, Codable, Sendable {
    case request, response, event
}

/// A received frame, parsed once.
public struct ParsedFrame: Sendable {
    public let kind: EnvelopeKind
    public let id: Int?                  // request, response
    public let method: String?           // request
    public let event: String?            // event
    public let error: ProtocolError?     // error response
    /// UTF-8 JSON of `params` (request, event) or `result` (success response); `{}` when the member is missing or
    /// null, empty for an error response.
    public let body: Data
}

/// Params or result with no fields: encodes as `{}`, decodes from any object.
public struct EmptyPayload: Codable, Sendable, Hashable {
    public init() {}

    public init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: WireCodingKey.self)
    }

    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: WireCodingKey.self)
    }
}

/// A subscription topic.
public enum Topic: RawRepresentable, Hashable, Sendable {
    case session(UUID)
    case run(UUID)

    /// "session:<uuid>" or "run:<uuid>", uuid in either case; anything else is nil.
    public init?(rawValue: String) {
        let sessionPrefix = "session:"
        let runPrefix = "run:"
        if rawValue.hasPrefix(sessionPrefix), let id = UUID(uuidString: String(rawValue.dropFirst(sessionPrefix.count))) {
            self = .session(id)
        } else if rawValue.hasPrefix(runPrefix), let id = UUID(uuidString: String(rawValue.dropFirst(runPrefix.count))) {
            self = .run(id)
        } else {
            return nil
        }
    }

    /// The uuid in canonical uppercase form.
    public var rawValue: String {
        switch self {
        case .session(let id): return "session:" + id.uuidString
        case .run(let id): return "run:" + id.uuidString
        }
    }
}

/// A request received by an RPCPeer.
public struct InboundRequest: Sendable {
    public let id: Int
    public let method: String
    public let params: Data                        // UTF-8 JSON of the params object

    public init(id: Int, method: String, params: Data) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// `RPCMethod(rawValue: method)`.
    public var knownMethod: RPCMethod? { RPCMethod(rawValue: method) }

    /// Decodes `params` with `WireCoding.makeDecoder()`; a failure throws `badRequest`.
    public func decodeParams<P: Decodable>(_ type: P.Type = P.self) throws -> P {
        try WireCoding.decodePayload(type, from: params, name: method)
    }
}

/// An event received by an RPCPeer.
public struct InboundEvent: Sendable {
    public let name: String
    public let params: Data                        // UTF-8 JSON of the params object

    public init(name: String, params: Data) {
        self.name = name
        self.params = params
    }

    /// Decodes `params` with `WireCoding.makeDecoder()`; a failure throws `badRequest`.
    public func decodeParams<P: Decodable>(_ type: P.Type = P.self) throws -> P {
        try WireCoding.decodePayload(type, from: params, name: name)
    }
}

public enum WireCoding {
    public static let protocolVersion = 1
    /// 48 MiB of UTF-8.
    public static let maxFrameSize = 50_331_648

    /// `JSONEncoder` with sorted keys, slashes not escaped, dates in ISO 8601 UTC with milliseconds, `Data` in base64.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    /// `JSONDecoder` accepting dates with and without fractional seconds, `Data` in base64.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(text).")
            }
            return date
        }
        decoder.dataDecodingStrategy = .base64
        return decoder
    }

    public static func encodeJSON(_ value: some Encodable) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    public static func encodeRequest(id: Int, method: String, params: some Encodable) throws -> Data {
        try encodeJSON(RequestFrame(id: id, kind: .request, method: method, params: params))
    }

    /// The bytes `{"id":<id>,"kind":"response","result":` + `resultJSON` + `}`; `resultJSON` must be a JSON object.
    public static func encodeResponse(id: Int, resultJSON: Data) -> Data {
        var frame = Data("{\"id\":\(id),\"kind\":\"response\",\"result\":".utf8)
        frame.append(resultJSON)
        frame.append(UInt8(ascii: "}"))
        return frame
    }

    public static func encodeError(id: Int, error: ProtocolError) throws -> Data {
        try encodeJSON(ErrorFrame(error: error, id: id, kind: .response))
    }

    public static func encodeEvent(name: String, params: some Encodable) throws -> Data {
        try encodeJSON(EventFrame(event: name, kind: .event, params: params))
    }

    /// Parses the frame once with `JSONSerialization`. A malformed frame, a `params` or `result` holding a number that
    /// is not finite included, throws `ProtocolError(.badRequest, "Malformed frame.")`.
    public static func parseFrame(_ frame: Data) throws -> ParsedFrame {
        let malformed = ProtocolError(.badRequest, "Malformed frame.")
        guard let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
              let kindText = object["kind"] as? String,
              let kind = EnvelopeKind(rawValue: kindText)
        else { throw malformed }
        let id = integer(object["id"])
        switch kind {
        case .request:
            guard let id, id >= 1, let method = object["method"] as? String else { throw malformed }
            return ParsedFrame(kind: .request, id: id, method: method, event: nil, error: nil,
                               body: try body(object["params"], malformed: malformed))
        case .response:
            guard let id else { throw malformed }
            if let errorMember = object["error"], !(errorMember is NSNull) {
                return ParsedFrame(kind: .response, id: id, method: nil, event: nil,
                                   error: protocolError(errorMember), body: Data())
            }
            return ParsedFrame(kind: .response, id: id, method: nil, event: nil, error: nil,
                               body: try body(object["result"], malformed: malformed))
        case .event:
            guard let event = object["event"] as? String else { throw malformed }
            return ParsedFrame(kind: .event, id: nil, method: nil, event: event, error: nil,
                               body: try body(object["params"], malformed: malformed))
        }
    }

    // MARK: - Internal

    /// Decodes params of a request or an event; a failure throws
    /// `badRequest` "Invalid params for <name>: <coding path of the failing member>.".
    static func decodePayload<P: Decodable>(_ type: P.Type, from data: Data, name: String) throws -> P {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            let path = codingPathText(error.failingPath)
            throw ProtocolError(.badRequest, path.isEmpty ? "Invalid params for \(name)." : "Invalid params for \(name): \(path).")
        } catch {
            throw ProtocolError(.badRequest, "Invalid params for \(name).")
        }
    }

    /// ISO 8601 UTC with milliseconds, the fraction truncated to the millisecond. The date is first rounded to the
    /// microsecond, which removes the binary error of a date parsed from text (`…00.999Z` is stored as
    /// `…00.998999953`), then the middle of its millisecond is formatted, which the format style truncates.
    static func formatDate(_ date: Date) -> String {
        let micros = (date.timeIntervalSinceReferenceDate * 1_000_000).rounded()
        let millis = (micros / 1_000).rounded(.down)
        return fractionalStyle.format(Date(timeIntervalSinceReferenceDate: (millis + 0.5) / 1_000))
    }

    /// The format with fractional seconds, then the same format without them.
    static func parseDate(_ text: String) -> Date? {
        if let date = try? fractionalStyle.parse(text) {
            return date
        }
        return try? wholeSecondsStyle.parse(text)
    }

    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondsStyle = Date.ISO8601FormatStyle()

    private struct RequestFrame<P: Encodable>: Encodable {
        let id: Int
        let kind: EnvelopeKind
        let method: String
        let params: P
    }

    private struct ErrorFrame: Encodable {
        let error: ProtocolError
        let id: Int
        let kind: EnvelopeKind
    }

    private struct EventFrame<P: Encodable>: Encodable {
        let event: String
        let kind: EnvelopeKind
        let params: P
    }

    /// An integer JSON number; booleans and fractional numbers are not ids.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }

    /// The `params` or `result` member written back to JSON; `{}` when it is missing or null. An object or an array
    /// must pass `JSONSerialization.isValidJSONObject(_:)` and a number must be finite, else the frame is malformed:
    /// `jsonObject(with:)` reads `-1e400` as minus infinity, and writing a non-finite number raises an Objective-C
    /// exception, which ends the app.
    private static func body(_ member: Any?, malformed: ProtocolError) throws -> Data {
        guard let member, !(member is NSNull) else { return Data("{}".utf8) }
        if member is NSArray || member is NSDictionary {
            guard JSONSerialization.isValidJSONObject(member) else { throw malformed }
        } else if let number = member as? NSNumber, !number.doubleValue.isFinite {
            throw malformed
        }
        do {
            return try JSONSerialization.data(withJSONObject: member,
                                              options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        } catch {
            throw malformed
        }
    }

    private static func protocolError(_ member: Any) -> ProtocolError {
        let object = member as? [String: Any]
        let code = (object?["code"] as? String).flatMap(ProtocolError.Code.init(rawValue:)) ?? .internal
        return ProtocolError(code, object?["message"] as? String ?? "")
    }
}

// MARK: - Coding paths

/// A coding key of the envelope types.
struct WireCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension DecodingError {
    /// The coding path of the failing member: the missing key included for `keyNotFound`.
    var failingPath: [CodingKey] {
        switch self {
        case .keyNotFound(let key, let context): return context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.codingPath
        @unknown default: return []
        }
    }
}

/// A coding path as text: keys joined with `.`, sequence indexes as `[i]` (`webTabs[1].url`).
func codingPathText(_ keys: [CodingKey]) -> String {
    var text = ""
    for key in keys {
        if let index = key.intValue {
            text += "[\(index)]"
        } else {
            if !text.isEmpty { text += "." }
            text += key.stringValue
        }
    }
    return text
}
