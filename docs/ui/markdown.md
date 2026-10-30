# Markdown rendering (HephMarkdown)

files:
- HephaestusKit/Sources/HephMarkdown/MarkdownView.swift
- HephaestusKit/Sources/HephMarkdown/MarkdownLinkTarget.swift
- HephaestusKit/Sources/HephMarkdown/MarkdownDocument.swift
- HephaestusKit/Sources/HephMarkdown/MarkdownInlines.swift
- HephaestusKit/Sources/HephMarkdown/MarkdownBlockView.swift
- HephaestusKit/Sources/HephMarkdown/MarkdownListView.swift
- HephaestusKit/Sources/HephMarkdown/MarkdownTableView.swift
- HephaestusKit/Sources/HephMarkdown/MarkdownCodeBlockView.swift
- HephaestusKit/Sources/HephMarkdown/MarkdownImageView.swift
- HephaestusKit/Sources/HephMarkdown/MarkdownSlug.swift
- HephaestusKit/Sources/HephMarkdown/FrontMatter.swift
- HephaestusKit/Sources/HephMarkdown/Autolinker.swift

---

`HephMarkdown` renders Markdown source as SwiftUI views. It is used by the Docs reader and preview
([docs.md](docs.md)), task descriptions and comments ([tasks.md](tasks.md)), assistant messages of Claude sessions
([sessions.md](sessions.md)) and the skill file preview ([skills.md](skills.md)). It depends on `HephCore`
(`Log.markdown`), `HephEditor` (code block highlighting) and the `Markdown` product of swift-markdown
([../architecture.md](../architecture.md#modules)).

Files that import both SwiftUI and Markdown qualify the names both modules declare: `Markdown.Text`,
`Markdown.Image`, `Markdown.Link`, `Markdown.Table` for the syntax tree, `SwiftUI.Text`, `SwiftUI.Image`,
`SwiftUI.Link`, `SwiftUI.Table` for the views.

## Swift API

```swift
/// Renders Markdown. Not scrollable: a VStack of blocks that takes the proposed width and its ideal height.
public struct MarkdownView: View {
    public init(
        _ source: String,
        basePath: String? = nil,
        imageLoader: MarkdownImageLoader? = nil,
        linkHandler: MarkdownLinkHandler? = nil
    )
}

public typealias MarkdownImageLoader = @MainActor (MarkdownLinkTarget) async throws -> Data
public typealias MarkdownLinkHandler = @MainActor (MarkdownLinkTarget) -> Void

public enum MarkdownLinkTarget: Hashable, Sendable {
    case anchor(String)                          // "#slug": a heading of the same document
    case project(path: String, anchor: String?)  // a project-relative path, with an optional heading slug
    case external(URL)                           // a URL with a scheme
    public static func resolve(_ destination: String, basePath: String) -> MarkdownLinkTarget?
}

/// The .id of each heading view, for ScrollViewReader.scrollTo.
public struct MarkdownAnchor: Hashable, Sendable {
    public let slug: String
    public init(slug: String)
}

```

`MarkdownView` is main-actor; `MarkdownLinkTarget` and `MarkdownAnchor` are `Sendable` values and `resolve` is a pure
function.

### Parameters

| Parameter     | Meaning                                                                                                                                                                                                                                                                                                                          |
|---------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `source`      | The Markdown text. A new value, or a new `basePath`, is parsed again; the same values reuse the last parse                                                                                                                                                                                                                       |
| `basePath`    | The project-relative folder of the document (`""` is the project root). With a `basePath`, every resolvable link and image is active. Without one (a task description, a comment, a message, a skill file), only `.external` targets are active: other links render as plain text and other images as their alt text, not loaded |
| `imageLoader` | Loads the data of an active image. When nil, `.external` targets with scheme `http` or `https` are loaded with `URLSession.shared.data(from:)` (a status outside 200–299 fails) and any other target fails                                                                                                                       |
| `linkHandler` | Called when an active link is clicked or tapped. When nil, `.external` targets are opened with the environment's `openURL` and other targets do nothing                                                                                                                                                                          |

## Parsing

1. Front matter (`FrontMatter`): when the first line of the source is `---` (trailing blanks allowed) and a later line
   is `---` or `...`, the lines from the first to that line are the front matter. It is not rendered; the rest is the
   body. Otherwise the body is the whole source. A line ends before its `\n` (the last line at the end of the source),
   and before a `\r` just ahead of that end, the last line included: a source ending with `---\r` closes its front
   matter.
2. `Document(parsing: body, options: [.disableSmartOpts])`. swift-markdown always enables the GitHub extensions for
   tables, strikethrough and task lists; `.disableSmartOpts` keeps quotes and dashes as typed. Block directives and
   symbol links stay disabled (no option).
3. The syntax tree is converted to an internal block model (`MarkdownDocument`: blocks, inline runs as
   `AttributedString`, image references, the link table, heading slugs) that the views render.

The view parses on the main actor when `source` or `basePath` changes; it keeps the last source, base path and their
`MarkdownDocument` in `@State`.

## Blocks

| Node                           | Rendering                                                                                                                        |
|--------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| `Heading`, level 1             | `.title` font, bold; followed by a `Divider`                                                                                     |
| `Heading`, level 2             | `.title2`, bold; followed by a `Divider`                                                                                         |
| `Heading`, level 3             | `.title3`, bold                                                                                                                  |
| `Heading`, level 4             | `.headline`                                                                                                                      |
| `Heading`, level 5             | `.subheadline`, bold                                                                                                             |
| `Heading`, level 6             | `.subheadline`, bold, secondary color                                                                                            |
| `Paragraph`                    | a `Text` of its inlines, `.body` font; split around images ([Images](#images))                                                   |
| `BlockQuote`                   | its blocks, secondary color, 12 pt leading padding, a rounded bar 3 pt wide (`Color.secondary.opacity(0.4)`) on the leading edge |
| `UnorderedList`, `OrderedList` | [Lists](#lists)                                                                                                                  |
| `CodeBlock`                    | [Code blocks](#code-blocks)                                                                                                      |
| `HTMLBlock`                    | a code block of `rawHTML`, not highlighted                                                                                       |
| `ThematicBreak`                | a `Divider` with 4 pt of vertical padding                                                                                        |
| `Table`                        | [Tables](#tables)                                                                                                                |

- Each heading view has `.id(MarkdownAnchor(slug:))` and `.accessibilityAddTraits(.isHeader)`.
- Node types not listed do not occur with the options above; if one does, it is skipped.

## Inlines

The inlines of a paragraph, heading or table cell become one `AttributedString` shown by a `Text`:

| Node                          | Result                                                                                                       |
|-------------------------------|--------------------------------------------------------------------------------------------------------------|
| `Text`                        | its string; bare URLs become links ([Autolinks](#autolinks))                                                 |
| `Emphasis`                    | `inlinePresentationIntent` gains `.emphasized`                                                               |
| `Strong`                      | `inlinePresentationIntent` gains `.stronglyEmphasized`                                                       |
| `Strikethrough`               | `inlinePresentationIntent` gains `.strikethrough`                                                            |
| `InlineCode`                  | its code, `inlinePresentationIntent` `.code` (monospaced), `backgroundColor` `Color.secondary.opacity(0.15)` |
| `Link`                        | its children, with the link attribute of [Links](#links) when the link is active                             |
| `Image`                       | [Images](#images)                                                                                            |
| `SoftBreak`                   | a space                                                                                                      |
| `LineBreak`                   | a line break                                                                                                 |
| `InlineHTML`                  | its `rawHTML`, styled like `InlineCode`                                                                      |
| `InlineAttributes`, any other | its children                                                                                                 |

Nested nodes combine: the presentation intents are unioned (bold italic code, …).

## Links

- A link is active when its destination resolves (`MarkdownLinkTarget.resolve(destination, basePath: basePath ?? "")`)
  and the [Parameters](#parameters) rule allows the target.
- Each active link gets an index in the view's link table; its runs get the attribute `link =
  URL(string: "heph-md-link:<index>")`. The view sets `.environment(\.openURL, OpenURLAction { url in … })`: a
  `heph-md-link` URL is looked up in the table, its target is passed to `linkHandler` (or the default of
  [Parameters](#parameters)), and the action returns `.handled`; any other URL returns `.systemAction`.
- SwiftUI shows link runs in the accent color.

`resolve(_ destination:basePath:)`:

1. The destination, trimmed; empty → nil.
2. `#<fragment>` → `.anchor(<fragment>)`, percent-decoded and lowercased; an empty fragment → nil.
3. A scheme (`^[A-Za-z][A-Za-z0-9+.-]*:`) → `.external(URL(string: destination))`; nil when `URL(string:)` is nil.
4. Otherwise a path, with an optional `?query` (dropped) and `#fragment`. The path is percent-decoded. A path starting
   with `/` is relative to the project root, any other to `basePath`. `.` components are dropped; `..` removes the
   previous component, and a `..` with nothing left to remove gives nil. Result: `.project(path:anchor:)` with the
   fragment percent-decoded and lowercased, nil when absent or empty.

| Destination, `basePath` `docs/ui`  | Target                                                            |
|------------------------------------|-------------------------------------------------------------------|
| `#editor`                          | `.anchor("editor")`                                               |
| `code.md`                          | `.project(path: "docs/ui/code.md", anchor: nil)`                  |
| `../protocol/methods.md#fileslist` | `.project(path: "docs/protocol/methods.md", anchor: "fileslist")` |
| `/App/HephaestusApp.swift`         | `.project(path: "App/HephaestusApp.swift", anchor: nil)`          |
| `my%20notes.md`                    | `.project(path: "docs/ui/my notes.md", anchor: nil)`              |
| `../../../x.md`                    | nil                                                               |
| `https://github.com/Azavech`       | `.external(https://github.com/Azavech)`                           |
| `mailto:sam@example.com`           | `.external(mailto:sam@example.com)`                               |

### Autolinks

swift-markdown does not enable the GitHub autolink extension, so `Autolinker` finds bare URLs in `Text` nodes outside
links: `http://` or `https://` at the start of the text or after a character that is neither a letter nor a digit, up to
the first white space or `<`. Trailing `.`, `,`, `:`, `;`, `!`, `?`, `'`, `"` are left out, and so is a trailing `)`
when the URL before it has no unmatched `(` (no more `(` than `)`), until the URL ends with none of them:
`https://example.com/A_(b)` keeps its `)`, `https://example.com/a).` loses `).`. Each URL is an `.external` link
(`<url>` written with angle brackets is already a `Link` node).

## Images

- A paragraph that contains images is split, in source order, into text runs (each a `Text`) and images (each a block
  view); text runs made only of white space are dropped. Each part is a block of its own, spaced as blocks
  ([Spacing](#spacing)). A paragraph without images is one `Text`.
- In headings and table cells, an image renders as its alt text, as text that keeps the presentation intents and the
  active link of the nodes around the image.
- Alt text: the plain text ([Heading slugs](#heading-slugs)) of the `Image` node's children. Source:
  `MarkdownLinkTarget.resolve(source, basePath: basePath ?? "")`; nil, or a target not allowed by
  [Parameters](#parameters), renders the failure view without loading.
- `MarkdownImageStore` (internal `@MainActor` class, `@State` of the `MarkdownView`, so it survives source changes)
  holds per target: loading, loaded image, or failed. A target not in the store is loaded in a `.task` of its view with
  the image loader.
- Decoding: ImageIO (`CGImageSourceCreateWithData`, first frame, `kCGImageSourceShouldCacheImmediately`); data ImageIO
  cannot read fails. SVG is not supported.
- Display: `Image(decorative: cgImage, scale: 1)` (one pixel per point), `.resizable()`, `.aspectRatio(contentMode:
  .fit)`, `.frame(maxWidth: <pixel width>)`: never wider than its natural size, narrowed to the available width.
  `.accessibilityLabel(<alt text>)`.

| State   | View                                                                                                                                                          |
|---------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| loading | a rounded rectangle 160 × 100 pt (`Color.secondary.opacity(0.1)`, corner radius 6) with a small `ProgressView`                                                |
| loaded  | the image                                                                                                                                                     |
| failed  | `photo` symbol and the alt text (or the source when the alt text is empty), secondary, with 8 pt of padding in the same rounded rectangle style, sized to fit |

- An image inside an active link is tappable: it calls the link's target like a text link.

## Lists

- An item is an `HStack(alignment: .firstTextBaseline, spacing: 6)` of its marker and a `VStack(alignment: .leading,
  spacing: 6)` of its blocks; nested lists are blocks of the item, so they are indented by the marker column.
- Unordered marker by nesting depth (1 = top level; every enclosing list counts, ordered or not): 1 `•`, 2 `◦`, 3 and
  deeper `▪`; secondary color; the marker column is 20 pt wide, trailing-aligned.
- Ordered marker: `<startIndex + item index>.` with `.monospacedDigit()`, in a column at least 20 pt wide,
  trailing-aligned.
- Task item (`ListItem.checkbox` not nil): the marker is `Image(systemName: "checkmark.square.fill")` in the accent
  color for `.checked`, `square` in the secondary color for `.unchecked`, instead of the bullet or number. It cannot be
  toggled.
- Items are 4 pt apart.

## Code blocks

- Language: `EditorLanguage(fenceInfo: language ?? "")` ([editor.md](editor.md#languages)). Text:
  `SyntaxHighlighter.attributedString(code, language:)` of the code without its final line break; `plain` and code over
  `SyntaxHighlighter.maximumLength` get no colors.
- View: a `ScrollView(.horizontal)` holding the `Text` in `.system(.callout, design: .monospaced)`, lines not wrapped
  (`fixedSize(horizontal: true, vertical: false)`), 12 pt padding, background `Color.secondary.opacity(0.08)` in a
  rounded rectangle of corner radius 6.

## Tables

- A `ScrollView(.horizontal)` holding a `Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0)`.
- First the head row (bold, background `Color.secondary.opacity(0.08)`), then the body rows; a row with fewer cells
  than `maxColumnCount` is completed with empty cells.
- Cell: its inlines as a `Text`, 6 pt vertical and 10 pt horizontal padding, a 1 pt `Color.secondary.opacity(0.3)`
  border (stroked overlay). Each cell fills its grid cell (`.frame(maxWidth: .infinity, maxHeight: .infinity)`, the
  grid fixed vertically with `.fixedSize(horizontal: false, vertical: true)`), so the borders of a row and of a column
  line up. Column alignment from `columnAlignments` on the head cells (`gridColumnAlignment`), and as the alignment of
  every cell's frame: `.left` or nil → leading, `.center` → center, `.right` → trailing.
- Spans: `colspan > 1` → `.gridCellColumns(colspan)`; a cell with `colspan == 0` (covered) is omitted; `rowspan` is
  ignored and covered cells (`rowspan == 0`) render empty.

## Heading slugs

The plain text of inline nodes, used for slugs and alt texts: the string of each `Text` node, the code of each code span
(without its backticks), a space for a `SoftBreak`, a line break for a `LineBreak`, nothing for inline HTML, and the
plain text of the children of any other node.

`MarkdownSlug.slug(for:)` (internal), from a heading's plain text:

1. lowercase;
2. remove every character that is not a letter or a digit (Unicode), a space, `-` or `_`;
3. replace each space by `-`.

Within one document a repeated slug gets `-1`, then `-2`, … (the first one not used yet), in document order.

| Heading text           | Slug               |
|------------------------|--------------------|
| `Code screen`          | `code-screen`      |
| `files.changed`        | `fileschanged`     |
| `Main ↔ Main`          | `main--main`       |
| `Tabs` (second time)   | `tabs-1`           |

## Selection and style

- `.textSelection(.enabled)` on the whole view.
- Fonts are text styles, so they follow Dynamic Type on iOS and iPadOS; the text color is the environment's
  foreground style.

## Spacing

| Between                                    | Space                    |
|--------------------------------------------|--------------------------|
| two blocks                                 | 12 pt                    |
| a heading and the block before it          | 20 pt (instead of 12 pt) |
| a heading of level 1 or 2 and its divider  | 6 pt                     |
| two list items                             | 4 pt                     |
| two blocks inside a list item or a quote   | 6 pt                     |

The view has no outer padding: the caller adds it.
