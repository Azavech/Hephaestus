import Foundation

/// The front matter of a Markdown source: when the first line is `---` (trailing blanks allowed) and a later line is
/// `---` or `...`, the lines from the first to that line. It is not rendered; the rest is the body.
enum FrontMatter {
    /// The source without its front matter; the whole source when it has none.
    static func body(of source: String) -> Substring {
        let utf8 = source.utf8
        var lineStart = utf8.startIndex
        var isFirstLine = true
        while lineStart < utf8.endIndex {
            let lineBreak = utf8[lineStart...].firstIndex(of: lineFeed) ?? utf8.endIndex
            let nextLine = lineBreak < utf8.endIndex ? utf8.index(after: lineBreak) : utf8.endIndex
            // A line ends before its `\n`, and before a `\r` just ahead of it.
            var contentEnd = lineBreak
            if contentEnd > lineStart, utf8[utf8.index(before: contentEnd)] == carriageReturn {
                contentEnd = utf8.index(before: contentEnd)
            }
            let content = utf8[lineStart..<contentEnd]
            if isFirstLine {
                guard isOpening(content) else { return source[...] }
                isFirstLine = false
            } else if content.elementsEqual("---".utf8) || content.elementsEqual("...".utf8) {
                return source[nextLine...]
            }
            lineStart = nextLine
        }
        return source[...]
    }

    /// `---` followed only by blanks.
    private static func isOpening(_ line: Substring.UTF8View) -> Bool {
        guard line.starts(with: "---".utf8) else { return false }
        return line.dropFirst(3).allSatisfy { $0 == space || $0 == tab }
    }

    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let space = UInt8(ascii: " ")
    private static let tab = UInt8(ascii: "\t")
}
