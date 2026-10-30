#if os(macOS)
import Foundation

/// Splits a byte stream into lines (docs/claude/cli.md §1.3): a line ends at byte 0x0A; the 0x0A and one 0x0D before
/// it are removed; each line is decoded as UTF-8 on its own, invalid sequences replaced by U+FFFD. A line longer than
/// 64 MiB is delivered in pieces of 64 MiB.
public struct LineReader: Sendable {
    private static let maxLineLength = 64 * 1_024 * 1_024
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    /// The bytes received of the current line.
    private var pending: [UInt8] = []

    public init() {}

    /// Appends a chunk; returns the lines it completes, in order.
    public mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        var start = data.startIndex
        while let end = data[start...].firstIndex(of: Self.lineFeed) {
            pending.append(contentsOf: data[start..<end])
            if pending.last == Self.carriageReturn {
                pending.removeLast()
            }
            var rest = pending[...]
            repeat {
                let piece = rest.prefix(Self.maxLineLength)
                lines.append(String(decoding: piece, as: UTF8.self))
                rest = rest.dropFirst(piece.count)
            } while !rest.isEmpty
            pending.removeAll(keepingCapacity: true)
            start = data.index(after: end)
        }
        pending.append(contentsOf: data[start...])
        // A line longer than 64 MiB: its full pieces leave now; the last byte stays, and so does a final 0x0D, which
        // may belong to the line end.
        let length = pending.count - (pending.last == Self.carriageReturn ? 1 : 0)
        if length > Self.maxLineLength {
            let sent = ((length - 1) / Self.maxLineLength) * Self.maxLineLength
            var offset = 0
            while offset < sent {
                lines.append(String(decoding: pending[offset..<(offset + Self.maxLineLength)], as: UTF8.self))
                offset += Self.maxLineLength
            }
            pending.removeFirst(sent)
        }
        return lines
    }

    /// Returns the unterminated rest, or nil when it is empty.
    public mutating func finish() -> String? {
        defer { pending.removeAll() }
        guard !pending.isEmpty else { return nil }
        return String(decoding: pending, as: UTF8.self)
    }
}
#endif
