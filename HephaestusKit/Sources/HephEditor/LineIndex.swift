import Foundation

/// The UTF-16 offsets where the lines of a text start: `0` first, then the offset after each `\n`. Only `\n` counts:
/// a `\r\n` pair is one line break, a lone `\r` starts no line.
struct LineIndex {
    private(set) var lineStarts: [Int] = [0]

    init() {}

    init(string: NSString) {
        rebuild(string)
    }

    var lineCount: Int { lineStarts.count }

    /// 1 + the index of the last line start ≤ `offset`.
    func lineNumber(at offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(low, 1)
    }

    /// A full scan, when the whole text is set or replaced.
    mutating func rebuild(_ string: NSString) {
        var starts = [0]
        Self.forEachLineFeed(in: string, range: NSRange(location: 0, length: string.length)) { starts.append($0 + 1) }
        lineStarts = starts
    }

    /// Follows a character edit: `editedRange` in new coordinates, `delta` the change in length.
    mutating func update(editedRange: NSRange, changeInLength delta: Int, string: NSString) {
        let location = editedRange.location
        let newEnd = editedRange.location + editedRange.length
        // The end of the replaced range in old coordinates.
        let oldEnd = newEnd - delta
        // Starts in (location, oldEnd] are removed; starts after oldEnd move by delta.
        let removedFrom = firstIndex(after: location)
        let keptFrom = max(removedFrom, firstIndex(after: oldEnd))
        var replacement: [Int] = []
        let editedEnd = min(newEnd, string.length)
        if editedEnd > location {
            Self.forEachLineFeed(in: string, range: NSRange(location: location, length: editedEnd - location)) {
                replacement.append($0 + 1)
            }
        }
        replacement.append(contentsOf: lineStarts[keptFrom...].lazy.map { $0 + delta })
        lineStarts.replaceSubrange(removedFrom..., with: replacement)
    }

    /// The index of the first line start greater than `offset`.
    private func firstIndex(after offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// Calls `body` with the offset of each `\n` in `range`, reading the string in chunks.
    static func forEachLineFeed(in string: NSString, range: NSRange, _ body: (Int) -> Void) {
        let chunkLength = 4096
        var buffer = [unichar](repeating: 0, count: chunkLength)
        var location = range.location
        let end = range.location + range.length
        while location < end {
            let length = min(chunkLength, end - location)
            buffer.withUnsafeMutableBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                string.getCharacters(base, range: NSRange(location: location, length: length))
                for offset in 0..<length where pointer[offset] == 0x0A {
                    body(location + offset)
                }
            }
            location += length
        }
    }
}
