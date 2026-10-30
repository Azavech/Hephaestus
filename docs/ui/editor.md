# Code editor (HephEditor)

files:
- HephaestusKit/Sources/HephEditor/CodeEditorView.swift
- HephaestusKit/Sources/HephEditor/CodeEditorProxy.swift
- HephaestusKit/Sources/HephEditor/EditorLanguage.swift
- HephaestusKit/Sources/HephEditor/EditorTheme.swift
- HephaestusKit/Sources/HephEditor/EditorController.swift
- HephaestusKit/Sources/HephEditor/LineIndex.swift
- HephaestusKit/Sources/HephEditor/MacEditorView.swift
- HephaestusKit/Sources/HephEditor/LineNumberRulerView.swift
- HephaestusKit/Sources/HephEditor/IOSEditorView.swift
- HephaestusKit/Sources/HephEditor/LineNumberGutterView.swift
- HephaestusKit/Sources/HephEditor/Highlighting/SyntaxHighlighter.swift
- HephaestusKit/Sources/HephEditor/Highlighting/CodeScanner.swift
- HephaestusKit/Sources/HephEditor/Highlighting/SwiftGrammar.swift
- HephaestusKit/Sources/HephEditor/Highlighting/GoGrammar.swift
- HephaestusKit/Sources/HephEditor/Highlighting/MarkdownGrammar.swift
- HephaestusKit/Sources/HephEditor/Highlighting/YAMLGrammar.swift
- HephaestusKit/Sources/HephEditor/Highlighting/JSONGrammar.swift

---

`HephEditor` is the text editor of the Code screen ([code.md](code.md)), the Docs editor ([docs.md](docs.md)) and the
skill file editor ([skills.md](skills.md)), and the syntax highlighter of Markdown code blocks
([markdown.md](markdown.md)). It imports Foundation, SwiftUI, AppKit (macOS) or UIKit (iOS, iPadOS), and `HephCore`
only for `Log.editor` ([../architecture.md](../architecture.md#logging)). `MacEditorView.swift` and
`LineNumberRulerView.swift` are wrapped in `#if os(macOS)`, `IOSEditorView.swift` and `LineNumberGutterView.swift` in
`#if os(iOS)`. Both text views use TextKit 1.

## Swift API

```swift
/// A code editor for one text: line numbers, current-line highlight, auto-indent, find, syntax highlighting.
public struct CodeEditorView: View {
    public init(
        text: Binding<String>,
        language: EditorLanguage,
        isEditable: Bool = true,
        selection: Binding<NSRange>? = nil,
        proxy: CodeEditorProxy? = nil,
        onChange: (@MainActor (String) -> Void)? = nil
    )
}

/// Lets a screen trigger editor actions that have no other entry point (the Find button on iOS).
@MainActor public final class CodeEditorProxy {
    public init()
    public func showFind()
}

public enum EditorLanguage: String, CaseIterable, Sendable {
    case swift, go, markdown, yaml, json, plain
    public init(fileName: String)        // by file extension, see Languages
    public init(fenceInfo: String)       // by the info string of a Markdown code fence
    public var indentUnit: String { get } // "\t" for go, four spaces otherwise
}

public enum TokenKind: String, CaseIterable, Sendable {
    case keyword, type, builtin, string, number, comment, attribute, directive
    case key, heading, emphasis, strong, code, link, markup
}

public struct HighlightToken: Equatable, Sendable {
    public var range: NSRange            // UTF-16 offsets in the highlighted text
    public var kind: TokenKind
    public init(range: NSRange, kind: TokenKind)
}

public enum SyntaxHighlighter {
    public static let maximumLength: Int // 524_288: texts with more UTF-8 bytes are not highlighted
    public static func tokens(in text: String, language: EditorLanguage) -> [HighlightToken]
    @MainActor public static func attributedString(_ code: String, language: EditorLanguage) -> AttributedString
}

@MainActor public enum EditorTheme {
    #if os(macOS)
    public typealias PlatformColor = NSColor
    public typealias PlatformFont = NSFont
    #else
    public typealias PlatformColor = UIColor
    public typealias PlatformFont = UIFont
    #endif
    public static let fontSize: CGFloat  // 13
    public static func font(for kind: TokenKind?) -> PlatformFont    // nil: plain text
    public static func color(for kind: TokenKind?) -> PlatformColor  // nil: plain text
    public static var background: PlatformColor { get }
    public static var currentLine: PlatformColor { get }
    public static var gutterText: PlatformColor { get }
    public static var gutterCurrentText: PlatformColor { get }
    public static var gutterSeparator: PlatformColor { get }
}
```

- `CodeEditorView`, `CodeEditorProxy` and `EditorTheme` are main-actor. `SyntaxHighlighter.tokens(in:language:)` is a
  pure function, not isolated: it runs on any thread.
- `text`: after every user edit the binding is set to the full new text, then `onChange` is called with it. A text that
  comes in through the binding (the caller assigns another value) never sets the binding back and never calls
  `onChange`.
- `isEditable == false`: the text can be selected and copied, not changed; no current-line highlight.
- `selection`: when given, the editor selects that range (clamped to the text) when it is created and scrolls it into
  view on the next main-actor turn (`DispatchQueue.main.async`), once SwiftUI has given the text view its size; it sets
  the binding after every selection change. A selection change the editor makes during a SwiftUI update (the clamped
  first selection, the selection restored after a text replacement) reaches the binding on the next main-actor turn,
  not during the update. When the binding takes a value from outside (clamped to the text, it differs from the text
  view's selected range at a SwiftUI update), the editor selects it and scrolls it into view
  (`scrollRangeToVisible(_:)`). Screens keep it per document, so switching tabs comes back to the same place and a
  screen can move the cursor to a line (a search result, [code.md](code.md#line-selection)).
- `proxy`: when given, the editor registers its text view in it (weak reference). `showFind()` does nothing when no
  editor is registered.

## Text views

| Platform        | Representable         | Text view                                                                                        |
|-----------------|-----------------------|--------------------------------------------------------------------------------------------------|
| macOS           | `NSViewRepresentable` | `EditorNSTextView` (subclass of `NSTextView`), document view of an `NSScrollView` built by hand  |
| iOS and iPadOS  | `UIViewRepresentable` | `EditorUITextView` (subclass of `UITextView`)                                                    |

Both text views are created with `init(usingTextLayoutManager: false)` (`EditorNSTextView(usingTextLayoutManager:
false)`, `EditorUITextView(usingTextLayoutManager: false)`), so they run on TextKit 1: `layoutManager` and
`textStorage` are set and are the objects the editor works with. The subclasses declare no designated initializer.

### Configuration

| Setting         | macOS                                                                                                                                                                                                                                                                                                                                                                                                                                 | iOS and iPadOS                                                                                                                                                                                                                                                   |
|-----------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Font            | `NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)` (SF Mono)                                                                                                                                                                                                                                                                                                                                                                 | `UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)`                                                                                                                                                                                                      |
| Tabs            | paragraph style with `tabStops = []` and `defaultTabInterval` = 4 × the advance of a space in the font                                                                                                                                                                                                                                                                                                                                | same                                                                                                                                                                                                                                                             |
| Colors          | `textColor` and `insertionPointColor` = plain color; `backgroundColor` = `EditorTheme.background`; `drawsBackground = true` on the text view and the scroll view                                                                                                                                                                                                                                                                      | `textColor` and `tintColor` = plain color; `backgroundColor` = `EditorTheme.background`                                                                                                                                                                          |
| Plain text only | `isRichText = false`, `importsGraphics = false`, `usesRuler = false`, `isRulerVisible = false`                                                                                                                                                                                                                                                                                                                                        | `allowsEditingTextAttributes = false`                                                                                                                                                                                                                            |
| Substitutions   | `false`: `isAutomaticQuoteSubstitutionEnabled`, `isAutomaticDashSubstitutionEnabled`, `isAutomaticTextReplacementEnabled`, `isAutomaticSpellingCorrectionEnabled`, `isContinuousSpellCheckingEnabled`, `isGrammarCheckingEnabled`, `isAutomaticLinkDetectionEnabled`, `isAutomaticDataDetectionEnabled`, `isAutomaticTextCompletionEnabled`, `smartInsertDeleteEnabled`; `inlinePredictionType = .no`; `writingToolsBehavior = .none` | `autocorrectionType = .no`, `autocapitalizationType = .none`, `spellCheckingType = .no`, `smartQuotesType = .no`, `smartDashesType = .no`, `smartInsertDeleteType = .no`, `inlinePredictionType = .no`, `writingToolsBehavior = .none`, `dataDetectorTypes = []` |
| Undo            | `allowsUndo = true`                                                                                                                                                                                                                                                                                                                                                                                                                   | built in                                                                                                                                                                                                                                                         |
| Find            | `usesFindBar = true`, `isIncrementalSearchingEnabled = true`                                                                                                                                                                                                                                                                                                                                                                          | `isFindInteractionEnabled = true`                                                                                                                                                                                                                                |
| Wrapping        | lines wrap at the view width: `isHorizontallyResizable = false`, `isVerticallyResizable = true`, `autoresizingMask = [.width]`, `textContainer.widthTracksTextView = true`, `maxSize` = the greatest finite size; scroll view `hasVerticalScroller = true`, `hasHorizontalScroller = false`, `autohidesScrollers = true`                                                                                                              | lines wrap (default)                                                                                                                                                                                                                                             |
| Layout          | `layoutManager.allowsNonContiguousLayout = true`                                                                                                                                                                                                                                                                                                                                                                                      | default                                                                                                                                                                                                                                                          |
| Insets          | `textContainerInset = NSSize(width: 4, height: 6)`                                                                                                                                                                                                                                                                                                                                                                                    | `textContainerInset = UIEdgeInsets(top: 6, left: <gutter width> + 4, bottom: 6, right: 4)`                                                                                                                                                                       |
| Scrolling       | —                                                                                                                                                                                                                                                                                                                                                                                                                                     | `alwaysBounceVertical = true`, `keyboardDismissMode = .interactive`                                                                                                                                                                                              |
| Editable        | `isEditable = isEditable`, `isSelectable = true`                                                                                                                                                                                                                                                                                                                                                                                      | same                                                                                                                                                                                                                                                             |

The base attributes are the font, the plain color and the paragraph style. The typing attributes are reset to them
after every selection change, so typed text never takes the color of the token next to it.

### Text synchronization

The coordinator keeps `lastText`, the last string it wrote to the binding or accepted from it.

1. User edit (macOS `textDidChange(_:)`, iOS `textViewDidChange(_:)`): the text view's string is stored in `lastText`,
   the binding is set, `onChange` is called, and highlighting is scheduled (150 ms, [Highlighting in the
   editor](#highlighting-in-the-editor)).
2. SwiftUI update (`updateNSView`, `updateUIView`), when `text.wrappedValue != lastText`, replaces the text:
   1. the selected range and the scroll offset are remembered;
   2. `textStorage.setAttributedString(NSAttributedString(string: newText, attributes: <base attributes>))`;
   3. `undoManager?.removeAllActions()`: the undo actions refer to the old text;
   4. the selection is restored, clamped to the new length, and the scroll offset is restored, clamped to the content;
   5. `lastText = newText`; the line index is rebuilt; highlighting runs at once.
3. A change of `language` highlights again at once; a change of `isEditable` is applied to the text view.

### Line index

`LineIndex` (internal struct) holds `lineStarts: [Int]`: the UTF-16 offsets where lines start, `0` first, then the
offset after each `\n`. Only `\n` counts: a `\r\n` pair is one line break, a lone `\r` starts no line.

- `lineCount = lineStarts.count`; `lineNumber(at offset)` = 1 + the index of the last start ≤ `offset` (binary
  search).
- Rebuilt by a full scan when the whole text is set or replaced.
- Updated in `NSTextStorageDelegate.textStorage(_:didProcessEditing:range:changeInLength:)` when `editedMask` contains
  `.editedCharacters`, with `editedRange` (new coordinates) and `delta = changeInLength`:
  1. `oldEnd = editedRange.upperBound − delta`, the end of the replaced range in old coordinates;
  2. every start `s` with `editedRange.location < s ≤ oldEnd` is removed;
  3. `delta` is added to every start `s > oldEnd`;
  4. for each `\n` at offset `i` inside `editedRange`, `i + 1` is inserted, keeping the array sorted.

### Line numbers

- Gutter font: `monospacedDigitSystemFont(ofSize: 11, weight: .regular)`. Gutter width:
  `max(3, number of decimal digits of lineCount)` × the advance of `"8"` in that font + 10 pt.
- Each number is drawn right-aligned with 5 pt of right padding, vertically centered in the first line fragment of its
  line. Wrapped continuation fragments get no number. The extra line fragment (empty text, or text ending with `\n`)
  gets `lineCount`.
- The number of the line holding the insertion point uses `gutterCurrentText`; the others `gutterText`. The gutter is
  filled with `background` and has a 1 pt `gutterSeparator` line along its right edge.

macOS — `LineNumberRulerView` (subclass of `NSRulerView`, `init(scrollView:orientation: .verticalRuler)`):

- `clientView = textView`; `scrollView.verticalRulerView = ruler`; `scrollView.hasVerticalRuler = true`;
  `scrollView.rulersVisible = true`; `clipsToBounds = true`; `ruleThickness` = the gutter width, updated when the digit
  count changes.
- `drawHashMarksAndLabels(in:)`: the glyph range of the text view's `visibleRect` (moved by `−textContainerOrigin`)
  from `layoutManager.glyphRange(forBoundingRect:in:)`, walked with `enumerateLineFragments(forGlyphRange:using:)`; each
  fragment rect is converted from text view to ruler coordinates. A fragment starts a line when its first character is
  at offset 0 or follows a `\n`.
- Redrawn (`needsDisplay = true`) on text change, selection change, `NSView.boundsDidChangeNotification` of the clip
  view (`postsBoundsChangedNotifications = true`) and frame change.

iOS and iPadOS — `LineNumberGutterView` (subclass of `UIView`):

- A subview of the text view with `isUserInteractionEnabled = false` and `contentMode = .redraw`.
- `EditorUITextView.layoutSubviews()` sets `gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width:
  <gutter width>, height: bounds.height)`, calls `bringSubviewToFront(gutter)` and `gutter.setNeedsDisplay()`; scrolling
  runs `layoutSubviews`, so the gutter stays pinned and follows the text.
- `draw(_:)` walks the line fragments intersecting the visible rect (`contentOffset.y` to `contentOffset.y +
  bounds.height`, in text container coordinates: minus `textContainerInset.top`); a fragment's y in gutter coordinates
  is `fragment.minY + textContainerInset.top − contentOffset.y`.
- Also redrawn on text and selection changes. When the gutter width changes, `textContainerInset.left` follows it.

### Current-line highlight

When `isEditable` is true and the selection is empty, the line holding the insertion point is highlighted: the union of
its line fragment rects (the glyphs of `(text as NSString).lineRange(for: NSRange(location: caret, length: 0))`), or the
extra line fragment rect for an empty last line, over the full width of the text view, filled with `currentLine`.

- macOS: drawn by `EditorNSTextView.drawBackground(in:)` after `super`. On selection change the old and new rects are
  invalidated with `setNeedsDisplay(_:avoidAdditionalLayout: true)`.
- iOS and iPadOS: a plain `UIView` (`backgroundColor = currentLine`) inserted at index 0 of the text view's subviews,
  behind the text. Its frame (the rect moved by `textContainerInset`) is updated on selection change, text change and
  layout; it is hidden when the rule above does not hold.

### Typing

- Return inserts `"\n"` followed by the indentation of the current line: its leading spaces and tabs, from the line
  start up to the insertion point.
  - macOS: `EditorNSTextView.insertNewline(_:)` calls `insertText("\n" + indentation, replacementRange:
    selectedRange())`.
  - iOS and iPadOS: `EditorUITextView.insertText(_:)` calls `super.insertText("\n" + indentation)` when the text is
    `"\n"`.
- Tab inserts `language.indentUnit`: a tab character in Go files, four spaces otherwise.
  - macOS: `insertTab(_:)` calls `insertText(indentUnit, replacementRange: selectedRange())`.
  - iOS and iPadOS: `insertText(_:)` calls `super.insertText(indentUnit)` when the text is `"\t"`.
- Both go through the normal input path: they replace the selection, are undoable as typing, and are reported as user
  edits. Pasting and every other edit are left unchanged.
- macOS, when `isEditable` is false: `insertNewline(_:)` and `insertTab(_:)` call `super` (the default behavior).

### Find

- macOS: the find bar of the scroll view. The Edit ▸ Find items (⌘F, ⌘G, ⇧⌘G, …) come from `TextEditingCommands()`
  ([shell.md](shell.md#112-menus)) and reach the text view through the responder chain (`performTextFinderAction(_:)`);
  the editor adds no key handling of its own. `CodeEditorProxy.showFind()` makes the text view first responder, then
  calls `performTextFinderAction(_:)` with a sender (an `NSMenuItem`) whose `tag` is
  `NSTextFinder.Action.showFindInterface.rawValue`.
- iOS and iPadOS: `isFindInteractionEnabled = true`, so ⌘F on a hardware keyboard presents the find navigator.
  `CodeEditorProxy.showFind()` calls `findInteraction?.presentFindNavigator(showingReplace: false)`.

## Theme

Fonts: regular `monospacedSystemFont(ofSize: 13, weight: .regular)`, bold the same with `.bold`, italic the regular
font's descriptor with the italic trait.

Colors are dynamic, so they follow light and dark appearance without highlighting again: macOS `NSColor(name: nil)
{ appearance in … }`, dark when `appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua`; iOS `UIColor { traits
in … }`, dark when `traits.userInterfaceStyle == .dark`.

| Kind              | Light     | Dark      | Font    |
|-------------------|-----------|-----------|---------|
| plain text (nil)  | `#000000` | `#DFDFE0` | regular |
| `keyword`         | `#9B2393` | `#FF7AB2` | regular |
| `type`            | `#3900A0` | `#D0A8FF` | regular |
| `builtin`         | `#6C36A9` | `#A167E6` | regular |
| `string`          | `#C41A16` | `#FC6A5D` | regular |
| `number`          | `#1C00CF` | `#D0BF69` | regular |
| `comment`         | `#5D6C79` | `#6C7986` | regular |
| `attribute`       | `#815F03` | `#BF8555` | regular |
| `directive`       | `#643820` | `#FD8F3F` | regular |
| `key`             | `#0F68A0` | `#41A1C0` | regular |
| `heading`         | `#9B2393` | `#FF7AB2` | bold    |
| `emphasis`        | `#000000` | `#DFDFE0` | italic  |
| `strong`          | `#000000` | `#DFDFE0` | bold    |
| `code`            | `#C41A16` | `#FC6A5D` | regular |
| `link`            | `#0E0EFF` | `#5482FF` | regular |
| `markup`          | `#815F03` | `#BF8555` | regular |

| Element             | Light     | Dark      |
|---------------------|-----------|-----------|
| `background`        | `#FFFFFF` | `#1F1F24` |
| `currentLine`       | `#ECF5FF` | `#23252B` |
| `gutterText`        | `#A0A0A5` | `#6C6C70` |
| `gutterCurrentText` | `#000000` | `#DFDFE0` |
| `gutterSeparator`   | `#E5E5EA` | `#38383D` |

The selection colors are the system's.

## Languages

| `EditorLanguage` | File extensions   | Fence info words  | `indentUnit` |
|------------------|-------------------|-------------------|--------------|
| `swift`          | `swift`           | `swift`           | four spaces  |
| `go`             | `go`              | `go`, `golang`    | tab          |
| `markdown`       | `md`, `markdown`  | `md`, `markdown`  | four spaces  |
| `yaml`           | `yml`, `yaml`     | `yml`, `yaml`     | four spaces  |
| `json`           | `json`            | `json`            | four spaces  |
| `plain`          | any other, none   | any other, none   | four spaces  |

- `init(fileName:)` takes the extension of the last path component, compared case-insensitively.
- `init(fenceInfo:)` takes the first word of the info string (split at white space and `{`), lowercased.
- `plain` text is never highlighted.

## Highlighter

### Tokens

- `tokens(in:language:)` returns the tokens of the text sorted by location, never overlapping, never empty. Text outside
  every token is plain. It returns `[]` for `.plain` and for a text whose UTF-8 length is above `maximumLength`.
- A grammar works on the UTF-16 code units of the text (`Array(text.utf16)`), so token ranges are `NSRange`s of the
  text storage.
- A grammar is an ordered list of rules tried at the current position: the first rule that matches emits its tokens and
  moves past what it consumed; when no rule matches, the position moves by one code unit. Every rule consumes at least
  one code unit, and no input makes the scanner read past the end of the text or crash. Each rule says where an
  unterminated construct ends.
- Tokens are never merged: each lexical element is its own token, even next to another token of the same kind.
- `CodeScanner` (internal) holds the code units and the position, and offers the helpers the grammars share: peek,
  match a literal, consume while a class matches, find the line end.

### Character classes

| Class            | Code units                                                               |
|------------------|--------------------------------------------------------------------------|
| identifier start | `A`–`Z`, `a`–`z`, `_`, any code unit ≥ 0x80; in Swift also `$`           |
| identifier part  | an identifier start, `0`–`9`                                             |
| digit            | `0`–`9`                                                                  |
| hex digit        | `0`–`9`, `a`–`f`, `A`–`F`                                                |
| blank            | space, tab                                                               |
| line break       | `\n` (a `\r` before it is part of the line, except in Markdown and YAML) |

"Capitalized" means that the first code unit is `A`–`Z`. "After a dot" means that the code unit just before the
identifier is `.`. "Up to the line break" means up to the next `\n` or the end of the text, the `\n` excluded.

### Highlighting in the editor

`EditorController` (internal, main-actor) highlights the text storage of one editor.

- When: at once when the text is set or replaced through the binding and when the language changes; 150 ms after the
  last user edit (each edit restarts the delay).
- Limit: when the UTF-8 length of the text is above `SyntaxHighlighter.maximumLength` (524,288 bytes), the controller
  does not tokenize: the whole text takes the plain color and font and the previous tokens are forgotten. The check is
  made at each highlight: a text that becomes short enough is highlighted again.
- Off the main actor: the controller takes a copy of the text and the current edit generation (a counter incremented
  on every character edit) and, in a detached task (priority `.userInitiated`), runs `tokens(in:language:)`. Back on
  the main actor, the result is applied only when the generation has not changed; otherwise it is dropped (a newer
  highlight is already scheduled).
- Marked text: while the text view has marked text (an input method is composing), the application is postponed by
  another 150 ms.
- Edits: from each application, or removal by the limit, to the next, the controller keeps `a`, the smallest
  `editedRange.location` of the character edits, and `b`, the smallest distance from the end of an edit's
  `editedRange` to the end of the text after that edit, both read in
  `textStorage(_:didProcessEditing:range:changeInLength:)` ([Line index](#line-index)). The first `a` and the last `b`
  code units of the text are unchanged since the old text, the text the old tokens were computed for.
- Application, between `textStorage.beginEditing()` and `textStorage.endEditing()`, limited to the span where the old
  and new tokens differ or the text was edited:
  1. the edited part of the new text runs from `a` to the new text's length − `b`; there is none when no character
     edit was made since the old text;
  2. `p` = the number of leading tokens equal in both lists, counted while they end at or before the start of the
     edited part (when there is one);
  3. `delta` = the UTF-16 length of the new text − the length of the old text; `s` = the number of trailing tokens
     equal once each old token's location is moved by `delta`, counted while both remaining indices stay ≥ `p` and,
     when there is an edited part, the token starts at or after its end;
  4. when neither list has a token between its first `p` and its last `s` tokens and the edited part is empty or
     there is none, nothing is applied;
  5. the span starts at the smallest of the start of the edited part (when there is one) and the locations of the
     remaining tokens, and ends at the largest of the end of the edited part (when there is one) and the ends of the
     remaining tokens, clamped to the text length; the remaining tokens are the new ones and the old ones, these taken
     both unmoved and moved by `delta`;
  6. the span takes the plain color and font, then every new token intersecting the span takes its color and font.

  Typed and pasted text is plain until a highlight colors it ([Configuration](#configuration)). The edited part covers
  every inserted code unit, even when the token lists stay equal: a character of a token typed over itself, or a line
  pasted over itself, takes the token's color. `p` and `s` count only tokens over unchanged text, so a token equal in
  both lists but now over other code units (`1x` deleted from `1x1` in Swift) is applied again. The first highlight
  after the text is set or replaced applies to the whole text.

### attributedString(_:language:)

Returns `AttributedString(code)` with `foregroundColor` (a SwiftUI `Color` made from `EditorTheme.color(for:)`) on each
token range. Fonts are left to the caller. The language `plain`, and a code over `maximumLength`, give a string without
attributes.

## Grammars

### Swift

| Order | Rule                                                                                                                                 | Kind                          |
|-------|--------------------------------------------------------------------------------------------------------------------------------------|-------------------------------|
| 1     | `//` up to the line break                                                                                                            | `comment`                     |
| 2     | `/*` up to the matching `*/`, nested: each `/*` inside opens a level, each `*/` closes one; unterminated: to the end of the text     | `comment`                     |
| 3     | String literal (below)                                                                                                               | `string`                      |
| 4     | `@` followed by an identifier: the `@` and the identifier                                                                            | `attribute`                   |
| 5     | `#` followed by an identifier: the `#` and the identifier (`#if`, `#endif`, `#available`, `#selector`, `#Preview`, …)                | `directive`                   |
| 6     | Number (below)                                                                                                                       | `number`                      |
| 7     | `` ` ``, identifier parts, `` ` `` (an escaped identifier)                                                                           | none                          |
| 8     | Identifier (below)                                                                                                                   | `keyword`, `type` or none     |

String literal:

- It starts at `n ≥ 0` `#` followed by `"`. When that `"` is followed by two more `"`, the literal is multi-line and
  closes at `"""` followed by `n` `#`; otherwise it is single-line and closes at `"` followed by `n` `#`.
- Escape: a `\` followed by `n` `#`. Then `(` opens an interpolation; any other code unit is part of the escape (so `\"`
  never closes a literal), except a line break in a single-line literal: the literal ends before it, unterminated. A
  `\` not followed by `n` `#` is an ordinary character.
- Interpolation: the current string token ends after the `(`. The expression is scanned with these Swift rules,
  counting `(` and `)` outside the literals and comments it contains, up to the `)` that closes the interpolation; that
  `)` starts the next string token of the literal.
- Unterminated: a single-line literal ends before the line break; a multi-line literal, or an interpolation, at the end
  of the text.

Number (it starts with a digit):

- `0x`, then hex digits and `_`; then optionally `.` followed by a hex digit, then hex digits and `_`; then optionally
  `p` or `P`, an optional `+` or `-`, digits and `_`.
- `0o`, then `0`–`7` and `_`. `0b`, then `0`, `1` and `_`.
- Otherwise digits and `_`; then optionally `.` followed by a digit, then digits and `_`; then optionally `e` or `E`, an
  optional `+` or `-`, a digit, then digits and `_`.

Identifier: an identifier start, then identifier parts.

- After a dot: `self` and `init` are `keyword`; a capitalized identifier is `type`; any other gets no token.
- In the keyword list: `keyword`. Capitalized: `type`. Otherwise no token.

```text
actor any as associatedtype async await borrowing break case catch class consuming continue convenience default
defer deinit didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import
in indirect infix init inout internal is isolated lazy let macro mutating nil nonisolated nonmutating open operator
override postfix precedencegroup prefix private protocol public repeat required rethrows return self Self sending set
some static struct subscript super switch throw throws true try typealias unowned var weak where while willSet Any
```

### Go

| Order | Rule                                                                                                                                         | Kind                                  |
|-------|----------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------|
| 1     | `//go:` up to the line break                                                                                                                 | `directive`                           |
| 2     | `//` up to the line break                                                                                                                    | `comment`                             |
| 3     | `/*` up to the first `*/` (no nesting); unterminated: to the end of the text                                                                 | `comment`                             |
| 4     | `` ` `` up to the next `` ` ``: a raw string, which may span lines and has no escapes; unterminated: to the end of the text                  | `string`                              |
| 5     | `"` up to the next `"` that is not escaped; `\` escapes the next code unit, but never a line break; unterminated: ends before the line break | `string`                              |
| 6     | `'` up to the next `'` that is not escaped (a rune); same escapes and end as rule 5                                                          | `string`                              |
| 7     | Number (below)                                                                                                                               | `number`                              |
| 8     | Identifier (below)                                                                                                                           | `keyword`, `type`, `builtin` or none  |

Number (it starts with a digit, or with `.` followed by a digit):

- `0x` or `0X`: hex digits and `_`; optionally `.` and hex digits and `_`; optionally a `p` or `P` exponent (optional
  `+` or `-`, digits and `_`).
- `0b` or `0B`: `0`, `1` and `_`. `0o` or `0O`: `0`–`7` and `_`.
- Otherwise digits and `_`; optionally `.` followed by a digit, then digits and `_`; optionally an `e` or `E` exponent
  (optional `+` or `-`, a digit, then digits and `_`). The form starting with `.`: the `.`, digits and `_`, optional
  exponent.
- A final `i` (imaginary literal) belongs to the number.

Identifier: an identifier start, then identifier parts.

- After a dot: capitalized and followed (blanks skipped, on the same line) by anything but `(`: `type`; otherwise no
  token.
- A keyword, or `true`, `false`, `iota`, `nil`: `keyword`.
- A predeclared type: `type`. A predeclared function: `builtin`.
- Capitalized and followed (blanks skipped, on the same line) by anything but `(`: `type`.
- Otherwise no token.

```text
keywords:   break case chan const continue default defer else fallthrough for func go goto if import interface map
            package range return select struct switch type var
types:      any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string
            uint uint8 uint16 uint32 uint64 uintptr
functions:  append cap clear close complex copy delete imag len make max min new panic print println real recover
```

### Markdown

The text is read line by line; a line ends before its `\n`, or at the end of the text, and a `\r` just before that end
is not part of the line (as in [markdown.md](markdown.md#parsing), a `\r\n` pair is one line ending): the line ending
is never part of a token, and no rule below sees it. Front matter and fenced code blocks span lines; every other rule
applies to one line.

1. Front matter: when the first line is `---` (trailing blanks allowed) and a later line is `---` or `...`, both
   delimiter lines are `markup` and the lines between them are tokenized with the YAML grammar (offsets moved).
   Otherwise the first line follows the rules below.
2. Inside a fenced code block: a line made of up to 3 spaces, then at least as many fence characters as the opening
   fence (the same character), then optional blanks, closes the block. Every non-empty line of the block, both fence
   lines included, is one `code` token. A block without a closing fence lasts to the end of the text.
3. A line made of up to 3 spaces then at least 3 `` ` `` (with no other `` ` `` after them on the line) or at least 3
   `~` opens a fenced code block.
4. ATX heading: up to 3 spaces, 1 to 6 `#`, then a blank or the end of the line: the whole line is `heading`.
5. Thematic break or setext underline: with its blanks removed, the line is at least 3 times the same character among
   `-`, `*`, `_`, `=`, and nothing else: the whole line is `markup`.
6. Block markers at the start of the line, in this order:
   - block quotes: up to 3 spaces then `>`: each `>` is `markup`; repeated for nested quotes, one blank after each `>`
     being skipped;
   - one list marker: blanks, then `-`, `*` or `+`, or 1 to 9 digits followed by `.` or `)`, then a blank or the end of
     the line: the marker is `markup`. Right after it and one blank, a task box `[ ]`, `[x]` or `[X]` followed by a
     blank or the end of the line is `markup`;
   - then, when a quote or list marker was found and the rest of the line is an ATX heading (rule 4 without the
     indentation limit), it is `heading` and the line is done. Without a marker only rule 4 applies: `    # x` is no
     heading.
7. Inline elements, scanned left to right over the rest of the line:
   - `\` followed by an ASCII punctuation character: both are skipped, no token;
   - code span: a run of `n` `` ` `` up to the next run of exactly `n` `` ` `` on the line, both runs included:
     `code`; without a closing run the opening run is skipped;
   - link: an optional `!`, then `[` text `]` followed by `(` destination `)` or by `[` label `]`, brackets and
     parentheses balanced, on the line: `link` for the whole construct. A line whose first code unit is the `[` of
     `[` label `]:` (a link reference definition; not after indentation or a block marker) is `link` as a whole;
   - autolink: `<` followed by `http://`, `https://` or `mailto:`, up to `>`, with no blank inside: `link`;
   - bare URL: `http://` or `https://` at the start of the line or after a code unit that is neither a letter nor a
     digit, up to a blank or `<`; trailing `.`, `,`, `:`, `;`, `!`, `?`, `)`, `'`, `"` are left out: `link`;
   - strong: `**` or `__` followed by a non-blank, up to the next same pair on the line that follows a non-blank,
     delimiters included: `strong`; a `__` opens only when the code unit before it is neither a letter nor a digit;
   - emphasis: a single `*` or `_` followed by a non-blank, up to the next single same character on the line that
     follows a non-blank: `emphasis`; with `_`, the code unit before the opening is neither a letter nor a digit, and a
     closing candidate followed by a letter or a digit does not close: the search goes on (`_foo_bar_` is one
     emphasis).

### YAML

The text is read line by line, and lines end as in [Markdown](#markdown): a `\r` just before the `\n` or the end of
the text is not part of the line. Two states are carried between lines: an open block scalar (with the indentation of
the line that opened it) and an open quoted scalar.

1. Block scalar content: while a block scalar is open, a blank line (only blanks) gets no token, and a line indented
   more than the opening line is `string` from its first non-blank code unit to its end. Any other line closes the
   block scalar and follows the rules below.
2. A quoted scalar open at the end of the previous line continues from the start of the line (rule 4).
3. A line starting with `%` is `directive` as a whole. A line starting with `---` or `...` followed by a blank or the
   end of the line: those 3 code units are `directive`, and the rest of the line follows rule 4.
4. After the indentation, from left to right:
   - `#` at the start of the line or after a blank: `comment` to the end of the line;
   - `-` followed by a blank or the end of the line (a sequence entry): `markup`;
   - `"`: a quoted scalar up to the next `"` not escaped by `\`; `'`: a quoted scalar up to the next `'` that is not
     followed by another `'` (`''` is an escaped quote). Either may continue on the next lines; each line gets its own
     token, and all of them take the kind decided when the scalar closes (rule 5);
   - `&`, `*` or `!` followed by a non-blank (anchor, alias, tag), up to a blank or the end of the line: `attribute`;
   - `|` or `>` followed only by `+`, `-` or digits, then a blank, a comment or the end of the line, at a value
     position (first on the line or after a `---` marker, or after a `:` or a sequence `-` followed by one or more
     blanks): `markup`, and a block scalar opens with this line's indentation;
   - `[`, `]`, `{`, `}`, `,` and `:` get no token; `[` and `{` raise the flow depth of the line, `]` and `}` lower it;
   - any other code unit starts a plain scalar, up to the first of: the end of the line, ` #`, a `:` followed by a blank
     or the end of the line, and, when the flow depth is above 0, `,`, `]` or `}`. Trailing blanks are left out.
5. Kinds: a plain or quoted scalar followed, after blanks, by `:` and then a blank, the end of the line, `,`, `]` or `}`
   is `key`. Otherwise a quoted scalar is `string`, and a plain scalar is:
   - `number` when it matches `[-+]?[0-9][0-9_]*(\.[0-9_]*)?([eE][-+]?[0-9]+)?`, `0x[0-9a-fA-F_]+`, `0o[0-7_]+`,
     `[-+]?\.(inf|Inf|INF)` or `\.(nan|NaN|NAN)`;
   - `keyword` when it is `true`, `True`, `TRUE`, `false`, `False`, `FALSE`, `null`, `Null`, `NULL` or `~`;
   - `string` otherwise.

### JSON

| Order | Rule                                                                                                                                           | Kind              |
|-------|------------------------------------------------------------------------------------------------------------------------------------------------|-------------------|
| 1     | `"` up to the next `"` that is not escaped (`\` escapes the next code unit, but never a line break); unterminated: ends before the line break  | `key` or `string` |
| 2     | an optional `-` and a digit: `0` or a digit 1–9 followed by digits; optionally `.` and digits; optionally `e` or `E`, an optional sign, digits | `number`          |
| 3     | a run of letters that is `true`, `false` or `null`                                                                                             | `keyword`         |
| 4     | any other run of letters                                                                                                                       | none              |

A string is `key` when the next code unit that is neither a blank, a `\r` nor a line break is `:`, else `string`.

## Examples

These inputs and their tokens are the reference for `HephEditorTests` ([../testing.md](../testing.md)). With `\r\n`
line endings, the Markdown and YAML examples give the same token texts and kinds.

Swift:

```swift
@MainActor final class Greeter: Sendable {
    let name = "Hi \(user.first ?? "you")!" // greet
    /* outer /* inner */ still */ var n = 0x1F + 1_000.5e-3
    let raw = #"a "quoted" \#(name) text"#
}
```

| Token text                        | Kind        |
|-----------------------------------|-------------|
| `@MainActor`                      | `attribute` |
| `final`                           | `keyword`   |
| `class`                           | `keyword`   |
| `Greeter`                         | `type`      |
| `Sendable`                        | `type`      |
| `let`                             | `keyword`   |
| `"Hi \(`                          | `string`    |
| `"you"`                           | `string`    |
| `)!"`                             | `string`    |
| `// greet`                        | `comment`   |
| `/* outer /* inner */ still */`   | `comment`   |
| `var`                             | `keyword`   |
| `0x1F`                            | `number`    |
| `1_000.5e-3`                      | `number`    |
| `let`                             | `keyword`   |
| `#"a "quoted" \#(`                | `string`    |
| `) text"#`                        | `string`    |

`name`, `user`, `first` (after a dot), `n`, `raw` and the `name` of the raw string's interpolation get no token.

Go:

```go
//go:build darwin
package main

import "fmt"

// main prints.
func main() {
	s := `raw
line`
	r := 'x'
	fmt.Println(len(s), r, 0x1F, 1.5e3i, nil, Version, MakeThing(), time.Duration)
}
```

| Token text                                                 | Kind        |
|------------------------------------------------------------|-------------|
| `//go:build darwin`                                        | `directive` |
| `package`                                                  | `keyword`   |
| `import`                                                   | `keyword`   |
| `"fmt"`                                                    | `string`    |
| `// main prints.`                                          | `comment`   |
| `func`                                                     | `keyword`   |
| the raw string, from `` `raw `` to `` line` `` (two lines) | `string`    |
| `'x'`                                                      | `string`    |
| `len`                                                      | `builtin`   |
| `0x1F`                                                     | `number`    |
| `1.5e3i`                                                   | `number`    |
| `nil`                                                      | `keyword`   |
| `Version`                                                  | `type`      |
| `Duration`                                                 | `type`      |

`main`, `s`, `r`, `fmt`, `Println` (after a dot, followed by `(`), `MakeThing` (followed by `(`) and `time` get no
token.

Markdown:

```markdown
---
name: demo
---
# Title
- [x] **done** and `code`, see [docs](a.md)
```

| Token text     | Kind      |
|----------------|-----------|
| `---`          | `markup`  |
| `name`         | `key`     |
| `demo`         | `string`  |
| `---`          | `markup`  |
| `# Title`      | `heading` |
| `-`            | `markup`  |
| `[x]`          | `markup`  |
| `**done**`     | `strong`  |
| `` `code` ``   | `code`    |
| `[docs](a.md)` | `link`    |

YAML:

```yaml
id: HEPH   # project
tags: [a, "b"]
description: |
  Multi
  line
count: 12
on: true
anchor: &x ~
```

| Token text    | Kind        |
|---------------|-------------|
| `id`          | `key`       |
| `HEPH`        | `string`    |
| `# project`   | `comment`   |
| `tags`        | `key`       |
| `a`           | `string`    |
| `"b"`         | `string`    |
| `description` | `key`       |
| `\|`          | `markup`    |
| `Multi`       | `string`    |
| `line`        | `string`    |
| `count`       | `key`       |
| `12`          | `number`    |
| `on`          | `key`       |
| `true`        | `keyword`   |
| `anchor`      | `key`       |
| `&x`          | `attribute` |
| `~`           | `keyword`   |

JSON:

```json
{"name": "Hephaestus", "build": 12, "ok": true, "x": null, "v": -1.5e3}
```

| Token text     | Kind      |
|----------------|-----------|
| `"name"`       | `key`     |
| `"Hephaestus"` | `string`  |
| `"build"`      | `key`     |
| `12`           | `number`  |
| `"ok"`         | `key`     |
| `true`         | `keyword` |
| `"x"`          | `key`     |
| `null`         | `keyword` |
| `"v"`          | `key`     |
| `-1.5e3`       | `number`  |
