#if os(macOS)
import Foundation

/// Decodes the output of a run as UTF-8 across the chunks of its pipe (docs/services/runs.md §5).
struct UTF8StreamDecoder {
    /// The bytes of an incomplete UTF-8 sequence that ended the last chunk.
    private var pending: [UInt8] = []

    /// Decodes a chunk; an incomplete UTF-8 sequence at its end waits for the next chunk.
    /// Invalid bytes become U+FFFD.
    mutating func decode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var bytes = pending
        pending.removeAll()
        bytes.append(contentsOf: data)
        let held = Self.incompleteSuffixLength(of: bytes)
        if held > 0 {
            pending = Array(bytes.suffix(held))
            bytes.removeLast(held)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// What is left, incomplete bytes as U+FFFD.
    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    /// The number of bytes at the end of `bytes` that start a UTF-8 sequence without completing it: a lead byte
    /// followed by fewer continuation bytes than its sequence needs; 0 when the bytes end on a complete sequence, on
    /// ASCII or on bytes that start no sequence. Those bytes are decoded with the next chunk, so the text is the same as
    /// if the whole output had been decoded at once.
    private static func incompleteSuffixLength(of bytes: [UInt8]) -> Int {
        var index = bytes.count - 1
        var continuationBytes = 0
        while index >= 0, continuationBytes < 3 {
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 {
                continuationBytes += 1
                index -= 1
                continue
            }
            let sequenceLength: Int
            switch byte {
            case 0xC2...0xDF: sequenceLength = 2
            case 0xE0...0xEF: sequenceLength = 3
            case 0xF0...0xF4: sequenceLength = 4
            default: return 0
            }
            let available = bytes.count - index
            return available < sequenceLength ? available : 0
        }
        return 0
    }
}

/// The output kept for a run (docs/services/runs.md §5): its last 5,000 complete lines and its unterminated last line.
/// Lines end at "\n"; an unterminated line that reaches 16,384 characters gets a "\n" inserted, so the text stored and
/// the text streamed in `run.output` are the same.
struct RunOutputBuffer {
    static let maxLines = 5_000
    static let maxLineLength = 16_384               // characters

    /// The complete lines, without their "\n"; the kept ones start at `firstKept`.
    private var lines: [String] = []
    private var firstKept = 0
    /// The unterminated last line and its length in characters.
    private var current = ""
    private var currentLength = 0

    /// Appends text; returns it as stored (with the line breaks forced into over-long lines).
    mutating func append(_ text: String) -> String {
        var stored = ""
        stored.reserveCapacity(text.utf8.count)
        // The part of `text` not yet added to `stored` and `current` starts at `segmentStart`.
        var segmentStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            // A line ends at "\n", which a "\r\n" pair holds too ("\r\n" is one Character).
            if character == "\n" || character == "\r\n" {
                stored += text[segmentStart..<next]
                current += text[segmentStart..<index]
                if character == "\r\n" {
                    current += "\r"
                }
                endLine()
                segmentStart = next
            } else {
                currentLength += 1
                if currentLength >= Self.maxLineLength {
                    stored += text[segmentStart..<next]
                    stored += "\n"
                    current += text[segmentStart..<next]
                    endLine()
                    segmentStart = next
                }
            }
            index = next
        }
        stored += text[segmentStart...]
        current += text[segmentStart...]
        return stored
    }

    /// The kept lines, each followed by "\n", then the unterminated last line.
    var text: String {
        var result = ""
        var size = current.utf8.count
        for line in lines[firstKept...] {
            size += line.utf8.count + 1
        }
        result.reserveCapacity(size)
        for line in lines[firstKept...] {
            result += line
            result += "\n"
        }
        result += current
        return result
    }

    /// Ends the current line; beyond 5,000 complete lines the oldest is dropped.
    private mutating func endLine() {
        lines.append(current)
        current = ""
        currentLength = 0
        if lines.count - firstKept > Self.maxLines {
            firstKept += 1
            // The dropped lines are removed from the array once they are half of it.
            if firstKept >= Self.maxLines, firstKept * 2 >= lines.count {
                lines.removeFirst(firstKept)
                firstKept = 0
            }
        }
    }
}
#endif
