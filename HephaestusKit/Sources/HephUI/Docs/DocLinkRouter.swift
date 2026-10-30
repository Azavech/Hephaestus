import Foundation
import HephClient
import HephCore
import HephMarkdown
import SwiftUI

/// The link handler of the Docs reader: anchors scroll, Markdown documents are shown, other project files open in the
/// Code section, web pages in a web tab (docs/ui/docs.md, "Links").
@MainActor
struct DocLinkRouter {
    let store: ProjectStore
    let model: DocsSectionModel
    /// The window's context.
    let context: WindowContext
    let banners: WindowBanners
    let openURL: OpenURLAction
    /// Scrolls the reader to a heading.
    let scrollToAnchor: @MainActor (String) -> Void

    func open(_ target: MarkdownLinkTarget) {
        switch target {
        case .anchor(let slug):
            scrollToAnchor(slug)
        case .project(let path, let anchor):
            let fileExtension = (path as NSString).pathExtension.lowercased()
            if fileExtension == "md" || fileExtension == "markdown" {
                let model = model
                Task {
                    await model.show(path: path, anchor: anchor, recordHistory: true)
                }
            } else {
                context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .code,
                                 item: path)
            }
        case .external(let url):
            let scheme = url.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                openWebTab(url)
            } else {
                openURL(url)
            }
        }
    }

    /// `openTab` of `store.connection`; on success the Web section shows the new tab.
    private func openWebTab(_ url: URL) {
        let store = store
        let context = context
        let banners = banners
        Task {
            await banners.perform {
                guard let connection = store.connection else {
                    throw ProtocolError(.unavailable, "The Main of \(store.projectID) is not available.")
                }
                let tab = try await connection.openTab(projectID: store.projectID, url: url.absoluteString,
                                                       title: nil, locked: nil)
                context.navigate(mainDeviceID: store.mainDeviceID, projectID: store.projectID, section: .web,
                                 item: tab.id.uuidString)
            }
        }
    }
}
