import Foundation
import HephCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Highlights the text storage of one editor: tokenizes a copy of the text off the main actor, then applies the
/// colors and fonts of the tokens that changed and of the edited part of the text.
@MainActor
final class EditorController {
    private let textStorage: NSTextStorage
    private(set) var language: EditorLanguage
    /// Whether the text view has marked text (an input method is composing).
    var hasMarkedText: @MainActor () -> Bool = { false }

    /// The tokens applied to the text storage, and the UTF-16 length of the text they were computed for (the old
    /// text of the next application).
    private var tokens: [HighlightToken] = []
    private var tokensTextLength = 0
    /// Incremented on every character edit.
    private var editGeneration = 0
    /// The character edits since the last application, or removal by the limit: `a` is the smallest
    /// `editedRange.location`, `b` the smallest distance from the end of an edit's `editedRange` to the end of the
    /// text after that edit. The first `a` and the last `b` code units of the text are unchanged since the old text.
    /// Both nil when no character edit was made.
    private var a: Int?
    private var b: Int?
    /// The first highlight after the text is set or replaced applies to the whole text.
    private var appliesToWholeText = true
    private var task: Task<Void, Never>?

    private static let delay: Duration = .milliseconds(150)

    init(textStorage: NSTextStorage, language: EditorLanguage) {
        self.textStorage = textStorage
        self.language = language
    }

    /// A character edit of the text storage, by the user or through the binding: `editedRange` is the edited range
    /// in the text after the edit, whose UTF-16 length is `length`.
    func noteCharacterEdit(editedRange: NSRange, length: Int) {
        editGeneration &+= 1
        let location = editedRange.location
        let distance = length - NSMaxRange(editedRange)
        a = min(a ?? location, location)
        b = min(b ?? distance, distance)
    }

    /// The whole text was set or replaced through the binding: highlights at once, over the whole text.
    func textWasReplaced() {
        appliesToWholeText = true
        schedule(after: nil)
    }

    /// Highlights again at once with the new language.
    func setLanguage(_ language: EditorLanguage) {
        guard language != self.language else { return }
        self.language = language
        schedule(after: nil)
    }

    /// A user edit: highlights 150 ms after the last one.
    func textWasEdited() {
        schedule(after: Self.delay)
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func schedule(after delay: Duration?) {
        task?.cancel()
        task = Task { [weak self] in
            if let delay {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.highlight()
        }
    }

    private func highlight() async {
        let text = textStorage.string
        let length = textStorage.length
        let generation = editGeneration
        let language = language
        let newTokens: [HighlightToken]? = await Task.detached(priority: .userInitiated) {
            guard text.utf8.count <= SyntaxHighlighter.maximumLength else { return nil }
            return SyntaxHighlighter.tokens(units: Array(text.utf16), language: language)
        }.value
        // A newer edit made this result stale: its own highlight is already scheduled.
        while true {
            guard !Task.isCancelled, generation == editGeneration else { return }
            guard hasMarkedText() else { break }
            do { try await Task.sleep(for: Self.delay) } catch { return }
        }
        guard textStorage.length == length else { return }
        if let newTokens {
            apply(newTokens, length: length)
        } else {
            removeHighlighting(length: length)
        }
    }

    /// Over the limit: the whole text takes the plain color and font, and the previous tokens are forgotten.
    private func removeHighlighting(length: Int) {
        Log.editor.debug("Text not highlighted: \(length, privacy: .public) UTF-16 units over the limit")
        textStorage.beginEditing()
        textStorage.addAttributes(Self.attributes(for: nil), range: NSRange(location: 0, length: length))
        textStorage.endEditing()
        tokens = []
        tokensTextLength = length
        appliesToWholeText = false
        a = nil
        b = nil
    }

    private func apply(_ newTokens: [HighlightToken], length: Int) {
        let span: NSRange?
        if appliesToWholeText {
            span = NSRange(location: 0, length: length)
        } else {
            span = Self.changedSpan(old: tokens, new: newTokens, delta: length - tokensTextLength,
                                    editedPart: editedPart(length: length), length: length)
        }
        if let span, span.length > 0 {
            textStorage.beginEditing()
            textStorage.addAttributes(Self.attributes(for: nil), range: span)
            for token in newTokens where NSIntersectionRange(token.range, span).length > 0 {
                let location = min(token.range.location, length)
                let range = NSRange(location: location, length: min(token.range.length, length - location))
                textStorage.addAttributes(Self.attributes(for: token.kind), range: range)
            }
            textStorage.endEditing()
        }
        tokens = newTokens
        tokensTextLength = length
        appliesToWholeText = false
        a = nil
        b = nil
    }

    /// The edited part of the text, whose UTF-16 length is `length`, since the old text: from `a` to `length` − `b`.
    /// Nil when no character edit was made since the old text.
    private func editedPart(length: Int) -> NSRange? {
        guard let a, let b else { return nil }
        return NSRange(location: a, length: max(0, length - b - a))
    }

    /// The span to apply, nil when neither token list has a remaining token and the edited part is empty or there is
    /// none.
    ///
    /// `p` leading tokens are equal; `s` trailing tokens are equal once each old token is moved by `delta`. When there
    /// is an edited part, `p` counts only tokens that end at or before its start and `s` only tokens that start at or
    /// after its end. The span covers the edited part (when there is one), the remaining new tokens and the remaining
    /// old tokens, these taken both unmoved and moved by `delta`, clamped to the text length.
    nonisolated static func changedSpan(
        old: [HighlightToken], new: [HighlightToken], delta: Int, editedPart: NSRange?, length: Int
    ) -> NSRange? {
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] {
            if let editedPart, NSMaxRange(new[p].range) > editedPart.location { break }
            p += 1
        }
        var s = 0
        while old.count - 1 - s >= p, new.count - 1 - s >= p {
            let oldToken = old[old.count - 1 - s]
            let newToken = new[new.count - 1 - s]
            let moved = HighlightToken(
                range: NSRange(location: oldToken.range.location + delta, length: oldToken.range.length),
                kind: oldToken.kind
            )
            guard moved == newToken else { break }
            if let editedPart, newToken.range.location < NSMaxRange(editedPart) { break }
            s += 1
        }
        let oldRemaining = old[p..<(old.count - s)]
        let newRemaining = new[p..<(new.count - s)]
        guard !oldRemaining.isEmpty || !newRemaining.isEmpty || (editedPart?.length ?? 0) > 0 else { return nil }
        var start = editedPart?.location ?? Int.max
        var end = editedPart.map(NSMaxRange) ?? Int.min
        for token in newRemaining {
            start = min(start, token.range.location)
            end = max(end, NSMaxRange(token.range))
        }
        for token in oldRemaining {
            start = min(start, token.range.location, token.range.location + delta)
            end = max(end, NSMaxRange(token.range), NSMaxRange(token.range) + delta)
        }
        start = min(max(start, 0), length)
        end = min(max(end, start), length)
        return NSRange(location: start, length: end - start)
    }

    private static func attributes(for kind: TokenKind?) -> [NSAttributedString.Key: Any] {
        guard let kind else { return plainAttributes }
        return tokenAttributes[kind] ?? plainAttributes
    }

    private static let plainAttributes: [NSAttributedString.Key: Any] = [
        .font: EditorTheme.font(for: nil), .foregroundColor: EditorTheme.color(for: nil),
    ]

    private static let tokenAttributes: [TokenKind: [NSAttributedString.Key: Any]] = Dictionary(
        uniqueKeysWithValues: TokenKind.allCases.map { kind in
            (kind, [.font: EditorTheme.font(for: kind), .foregroundColor: EditorTheme.color(for: kind)])
        }
    )
}
