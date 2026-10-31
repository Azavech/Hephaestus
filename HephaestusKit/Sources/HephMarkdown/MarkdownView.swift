import SwiftUI

/// Loads the data of an active image.
public typealias MarkdownImageLoader = @MainActor (MarkdownLinkTarget) async throws -> Data
/// Called when an active link is clicked or tapped.
public typealias MarkdownLinkHandler = @MainActor (MarkdownLinkTarget) -> Void

/// How far a text selection reaches.
public enum MarkdownSelection: Hashable, Sendable {
    case perBlock      // each block is its own view; a selection stays inside one block
    case acrossBlocks  // the text blocks between two tables are one text view; a selection crosses them
}

/// Renders Markdown. Not scrollable: a VStack of blocks that takes the proposed width and its ideal height.
public struct MarkdownView: View {
    private let source: String
    private let basePath: String?
    private let imageLoader: MarkdownImageLoader?
    private let linkHandler: MarkdownLinkHandler?
    private let selection: MarkdownSelection

    @State private var cache = MarkdownDocumentCache()
    @State private var imageStore = MarkdownImageStore()
    @Environment(\.openURL) private var openURL

    /// - Parameters:
    ///   - source: The Markdown text. A new value, or a new `basePath`, is parsed again; the same values reuse the
    ///     last parse.
    ///   - basePath: The project-relative folder of the document (`""` is the project root). With a base path, every
    ///     resolvable link and image is active; without one, only `.external` targets are.
    ///   - imageLoader: Loads the data of an active image. When nil, `http` and `https` URLs are loaded with
    ///     `URLSession.shared` and any other target fails.
    ///   - linkHandler: Called when an active link is clicked or tapped. When nil, `.external` targets are opened with
    ///     the environment's `openURL` and other targets do nothing.
    ///   - selection: `.perBlock`: each block is its own view. `.acrossBlocks`: the text blocks between two tables,
    ///     images or thematic breaks are one text view, so a selection crosses them.
    public init(
        _ source: String,
        basePath: String? = nil,
        imageLoader: MarkdownImageLoader? = nil,
        linkHandler: MarkdownLinkHandler? = nil,
        selection: MarkdownSelection = .perBlock
    ) {
        self.source = source
        self.basePath = basePath
        self.imageLoader = imageLoader
        self.linkHandler = linkHandler
        self.selection = selection
    }

    public var body: some View {
        let document = cache.document(for: source, basePath: basePath)
        let context = MarkdownRenderContext(
            links: document.links,
            open: open,
            imageStore: imageStore,
            loadImage: imageLoader ?? MarkdownImageStore.loadWithURLSession
        )
        blocks(document.blocks, context: context)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                handle(url, links: document.links)
            })
    }

    @ViewBuilder
    private func blocks(_ blocks: [MarkdownBlock], context: MarkdownRenderContext) -> some View {
        switch selection {
        case .perBlock:
            MarkdownBlocksView(blocks: blocks, isNested: false, context: context)
        case .acrossBlocks:
            MarkdownRunsView(blocks: blocks, context: context)
        }
    }

    /// A `heph-md-link:<index>` URL calls the target of its link; any other URL gets the system action.
    private func handle(_ url: URL, links: [MarkdownLinkTarget]) -> OpenURLAction.Result {
        guard url.scheme == Self.linkScheme else { return .systemAction }
        let index = url.absoluteString.dropFirst(Self.linkScheme.count + 1)
        if let index = Int(index), links.indices.contains(index) {
            open(links[index])
        }
        return .handled
    }

    /// Passes `target` to the link handler, or opens an `.external` target with the environment's `openURL`.
    private func open(_ target: MarkdownLinkTarget) {
        if let linkHandler {
            linkHandler(target)
        } else if case .external(let url) = target {
            openURL(url)
        }
    }

    static let linkScheme = "heph-md-link"
}

/// What the block views need from the `MarkdownView`.
struct MarkdownRenderContext {
    /// The link table of the document.
    let links: [MarkdownLinkTarget]
    /// Opens a link target as a click on a text link does.
    let open: @MainActor (MarkdownLinkTarget) -> Void
    let imageStore: MarkdownImageStore
    let loadImage: MarkdownImageLoader
}

/// The last source parsed and its document, kept in the `MarkdownView`'s state.
@MainActor
final class MarkdownDocumentCache {
    private var source: String?
    private var basePath: String?
    private var document = MarkdownDocument.empty

    /// The document of `source`, parsed again only when the source or the base path changed.
    func document(for source: String, basePath: String?) -> MarkdownDocument {
        if source != self.source || basePath != self.basePath {
            document = MarkdownDocument.parse(source, basePath: basePath)
            self.source = source
            self.basePath = basePath
        }
        return document
    }
}
