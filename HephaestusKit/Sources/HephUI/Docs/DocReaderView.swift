import Foundation
import HephClient
import HephCore
import HephMarkdown
import SwiftUI

/// The rendered document: a centered column of at most 760 pt in a scroll view (docs/ui/docs.md, "Reader").
struct DocReaderView: View {
    /// The Markdown source: the document's text, unsaved edits included, or the preview text.
    let source: String
    let document: EditorDocument
    let model: DocsSectionModel
    let store: ProjectStore
    /// The reader of reading mode scrolls to the model's pending anchor; the live preview does not.
    let appliesPendingAnchor: Bool

    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                MarkdownView(
                    source,
                    basePath: ProjectPath.parent(of: document.path),
                    imageLoader: Self.imageLoader(files: model.files),
                    linkHandler: { target in
                        router(proxy).open(target)
                    }
                )
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .task(id: AnchorRequest(anchor: appliesPendingAnchor ? model.pendingAnchor : nil,
                                    isText: document.content == .text)) {
                await applyPendingAnchor(proxy)
            }
        }
    }

    private struct AnchorRequest: Equatable {
        let anchor: String?
        let isText: Bool
    }

    /// On the next main-actor turn after the content rendered: scrolls to the pending anchor, then clears it. An
    /// unknown slug scrolls nowhere.
    private func applyPendingAnchor(_ proxy: ScrollViewProxy) async {
        guard appliesPendingAnchor, document.content == .text, let anchor = model.pendingAnchor else { return }
        await Task.yield()
        guard !Task.isCancelled, model.pendingAnchor == anchor else { return }
        proxy.scrollTo(MarkdownAnchor(slug: anchor), anchor: .top)
        model.pendingAnchor = nil
    }

    private func router(_ proxy: ScrollViewProxy) -> DocLinkRouter {
        DocLinkRouter(store: store, model: model, context: context, banners: banners, openURL: openURL) { slug in
            withAnimation {
                proxy.scrollTo(MarkdownAnchor(slug: slug), anchor: .top)
            }
        }
    }

    /// Project images are read with `files.read`; `http` and `https` images with `URLSession`; anything else fails
    /// (docs/ui/docs.md, "Images").
    static func imageLoader(files: ProjectFiles) -> MarkdownImageLoader {
        { target in
            switch target {
            case .project(let path, _):
                return try await files.read(path).data
            case .external(let url):
                let scheme = url.scheme?.lowercased()
                guard scheme == "http" || scheme == "https" else {
                    throw URLError(.unsupportedURL)
                }
                let (data, response) = try await URLSession.shared.data(from: url)
                if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                    throw URLError(.badServerResponse)
                }
                return data
            case .anchor:
                throw URLError(.unsupportedURL)
            }
        }
    }
}
