#if os(macOS)
import Foundation

/// A header line of a request or a response.
struct HTTPHeader: Sendable, Equatable {
    var name: String
    var value: String
}

/// One HTTP/1.x request of the MCP server (docs/claude/mcp.md §3).
struct HTTPRequest: Sendable, Equatable {
    var method: String          // "POST"
    var target: String          // "/mcp" or "/mcp?x=1"
    var path: String            // target up to the first "?"
    var version: String         // "HTTP/1.1" or "HTTP/1.0"
    var headers: [HTTPHeader]   // in order
    var body: Data

    /// First value of a header, name compared case-insensitively.
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// HTTP/1.1: false only with "Connection: close"; HTTP/1.0: true only with "Connection: keep-alive".
    var keepAlive: Bool {
        let options = headers
            .filter { $0.name.caseInsensitiveCompare("Connection") == .orderedSame }
            .flatMap { $0.value.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if version == "HTTP/1.0" {
            return options.contains("keep-alive")
        }
        return !options.contains("close")
    }
}

enum HTTPParseError: Error, Equatable { case malformed, headersTooLarge, bodyTooLarge }

/// Parses the bytes received on one connection into requests, in order. Bytes after a complete request stay for the
/// next one (pipelining).
struct HTTPRequestParser: Sendable {
    private enum Framing: Sendable {
        case none
        case length(Int)
        case chunked
    }

    private enum ChunkState: Sendable {
        case size                   // reading a chunk size line
        case data(remaining: Int)   // reading the bytes of a chunk
        case dataEnd                // the CRLF after the bytes of a chunk
        case trailers               // trailer lines up to an empty line
    }

    private struct Head: Sendable {
        var method: String
        var target: String
        var version: String
        var headers: [HTTPHeader]
        var framing: Framing
    }

    private let maxHeaderBytes: Int
    private let maxBodyBytes: Int
    /// Received bytes; those before `position` are consumed.
    private var buffer: [UInt8] = []
    private var position = 0
    /// Where the search for the end of the head resumes.
    private var scanFrom = 0
    /// The head of the request whose body is being read.
    private var head: Head?
    private var body: [UInt8] = []
    private var chunk: ChunkState = .size

    private static let crlf: [UInt8] = [0x0D, 0x0A]

    init(maxHeaderBytes: Int = 65_536, maxBodyBytes: Int = 8_388_608) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    /// The next complete request, nil when more bytes are needed.
    mutating func nextRequest() throws -> HTTPRequest? {
        if head == nil {
            guard let parsed = try readHead() else { return nil }
            head = parsed
            body = []
            chunk = .size
        }
        guard let current = head else { return nil }
        let complete: Bool
        switch current.framing {
        case .none:
            complete = true
        case .length(let length):
            guard buffer.count - position >= length else { return nil }
            body = Array(buffer[position..<(position + length)])
            position += length
            complete = true
        case .chunked:
            complete = try readChunks()
        }
        guard complete else { return nil }
        head = nil
        compact()
        return HTTPRequest(method: current.method, target: current.target,
                           path: String(current.target.prefix { $0 != "?" }), version: current.version,
                           headers: current.headers, body: Data(body))
    }

    // MARK: - Head

    private mutating func readHead() throws -> Head? {
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        let start = max(position, scanFrom - 3)
        guard let end = Self.find(terminator, in: buffer, from: start) else {
            scanFrom = buffer.count
            if buffer.count - position > maxHeaderBytes {
                throw HTTPParseError.headersTooLarge
            }
            return nil
        }
        guard end - position <= maxHeaderBytes else { throw HTTPParseError.headersTooLarge }
        let text = String(decoding: buffer[position..<end], as: UTF8.self)
        position = end + terminator.count
        scanFrom = position
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPParseError.malformed }

        // Request line: exactly three parts separated by single spaces.
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else { throw HTTPParseError.malformed }

        // Header lines: `name: value`.
        var headers: [HTTPHeader] = []
        for line in lines.dropFirst() {
            guard let first = line.first, first != " ", first != "\t",
                  let colon = line.firstIndex(of: ":")
            else { throw HTTPParseError.malformed }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else {
                throw HTTPParseError.malformed
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.append(HTTPHeader(name: name, value: value))
        }

        // Body framing.
        let transferEncodings = headers.filter { $0.name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }
        let lengths = headers.filter { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
        let framing: Framing
        if !transferEncodings.isEmpty {
            guard transferEncodings.allSatisfy({ $0.value.caseInsensitiveCompare("chunked") == .orderedSame }) else {
                throw HTTPParseError.malformed
            }
            framing = .chunked
        } else if let declared = lengths.first?.value {
            guard lengths.allSatisfy({ $0.value == declared }), !declared.isEmpty,
                  declared.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) })
            else { throw HTTPParseError.malformed }
            guard let length = Int(declared), length <= maxBodyBytes else { throw HTTPParseError.bodyTooLarge }
            framing = .length(length)
        } else {
            framing = .none
        }
        return Head(method: parts[0], target: parts[1], version: parts[2], headers: headers, framing: framing)
    }

    // MARK: - Chunked body

    /// Reads the chunks available; true once the body and its trailers are complete.
    private mutating func readChunks() throws -> Bool {
        while true {
            switch chunk {
            case .size:
                guard let line = try readLine() else { return false }
                let digits = line.prefix { $0 != ";" }.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit }) else {
                    throw HTTPParseError.malformed
                }
                guard let size = Int(digits, radix: 16), size <= maxBodyBytes - body.count else {
                    throw HTTPParseError.bodyTooLarge
                }
                chunk = size == 0 ? .trailers : .data(remaining: size)
            case .data(let remaining):
                let available = buffer.count - position
                guard available > 0 else { return false }
                let count = min(available, remaining)
                body.append(contentsOf: buffer[position..<(position + count)])
                position += count
                chunk = remaining == count ? .dataEnd : .data(remaining: remaining - count)
            case .dataEnd:
                guard buffer.count - position >= 2 else { return false }
                guard buffer[position] == 0x0D, buffer[position + 1] == 0x0A else { throw HTTPParseError.malformed }
                position += 2
                chunk = .size
            case .trailers:
                guard let line = try readLine() else { return false }
                if line.isEmpty {
                    return true
                }
            }
        }
    }

    /// The next line ending with CRLF, without it; nil when it is not complete. A line longer than the header limit is
    /// malformed.
    private mutating func readLine() throws -> String? {
        guard let end = Self.find(Self.crlf, in: buffer, from: position) else {
            if buffer.count - position > maxHeaderBytes {
                throw HTTPParseError.malformed
            }
            return nil
        }
        let line = String(decoding: buffer[position..<end], as: UTF8.self)
        position = end + 2
        return line
    }

    // MARK: - Buffer

    /// Drops the consumed bytes.
    private mutating func compact() {
        guard position > 0 else { return }
        buffer.removeFirst(position)
        scanFrom = max(0, scanFrom - position)
        position = 0
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= pattern.count, start <= bytes.count - pattern.count else { return nil }
        var index = max(start, 0)
        let last = bytes.count - pattern.count
        while index <= last {
            if bytes[index] == pattern[0] {
                var matches = true
                for offset in 1..<pattern.count where bytes[index + offset] != pattern[offset] {
                    matches = false
                    break
                }
                if matches { return index }
            }
            index += 1
        }
        return nil
    }
}
#endif
