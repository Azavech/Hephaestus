import Foundation
import HephClient
import HephCore
import Observation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The load error of a tab, shown over its web content (docs/ui/web.md, "Load errors").
struct WebLoadError: Equatable {
    /// The error's `localizedDescription`.
    let message: String
    /// The URL under `NSURLErrorFailingURLErrorKey`, else nil.
    let url: URL?
}

/// Owns the `WKWebView` of one tab: its navigation state, the origins of its navigations, the write-back of user
/// navigations and the remote updates of the stored URL (docs/ui/web.md, "Web views", "Sync rules").
@MainActor @Observable
final class WebTabController: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Where a main-frame navigation comes from (docs/ui/web.md, "Navigation origins").
    enum Origin: Equatable {
        case initial, remote, user, page

        /// Initial and remote navigations, and the 2 s after them, are never written back.
        var isQuiet: Bool {
            self == .initial || self == .remote
        }
    }

    let tabID: UUID
    let webView: WKWebView
    @ObservationIgnored weak var section: WebSectionModel?

    private(set) var url: URL?
    private(set) var title: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var estimatedProgress: Double = 0
    private(set) var loadError: WebLoadError?
    /// The token of the `WebViewHost` showing the web view; the tab is displayed while it is not nil.
    private(set) var displayHost: UUID?

    /// The last URL this device wrote back: its echo changes nothing.
    @ObservationIgnored private(set) var lastWrittenURL: String?
    /// The origin of the next `load(_:)` of this controller.
    @ObservationIgnored private var pendingOrigin: Origin?
    /// The origin of the main-frame action allowed last, recorded when its navigation starts.
    @ObservationIgnored private var actionOrigin: Origin?
    /// The origins of the navigations that have started and not ended yet.
    @ObservationIgnored private var navigationOrigins: [ObjectIdentifier: Origin] = [:]
    /// The end of the quiet period after the last initial or remote navigation.
    @ObservationIgnored private var quietEnd: ContinuousClock.Instant?
    @ObservationIgnored private var writeBackTask: Task<Void, Never>?
    /// A stored URL changed elsewhere while the tab was not displayed.
    @ObservationIgnored private var pendingRemoteURL: String?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// The schemes the web view navigates to; any other main-frame navigation is opened by the system.
    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob"]
    /// The navigation types that are user navigations when the controller did not start the load.
    private static let userNavigationTypes: Set<WKNavigationType> = [
        .linkActivated, .formSubmitted, .formResubmitted, .backForward, .reload,
    ]

    /// Creates the web view and loads the stored URL with origin `initial`; `about:blank` loads nothing.
    init(tab: WebTab, section: WebSectionModel) {
        tabID = tab.id
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.section = section
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if os(macOS)
        webView.allowsMagnification = true
        #endif
        observeWebView()
        if tab.url != "about:blank", let url = URL(string: tab.url) {
            load(url, origin: .initial)
        }
    }

    // MARK: - Controls

    /// Loads a URL; the controller's loads are `initial`, `remote` or `user` navigations.
    func load(_ url: URL, origin: Origin) {
        pendingOrigin = origin
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    /// The Reload of a load error: loads its URL as a user navigation, or reloads when it has none.
    func reloadAfterError() {
        if let url = loadError?.url {
            load(url, origin: .user)
        } else {
            reload()
        }
    }

    // MARK: - Display

    /// A host shows the web view: the tab is displayed, and a stored URL changed meanwhile is applied.
    func claim(_ token: UUID) {
        displayHost = token
        if let url = pendingRemoteURL {
            applyRemote(url)
        }
    }

    /// A host that held the web view went away.
    func unclaim(_ token: UUID) {
        if displayHost == token {
            displayHost = nil
        }
    }

    /// Stops the web view, removes it from its container, clears its delegates and cancels the pending write-back.
    func release() {
        webView.stopLoading()
        webView.removeFromSuperview()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        writeBackTask?.cancel()
        writeBackTask = nil
        for observation in observations {
            observation.invalidate()
        }
        observations = []
        displayHost = nil
    }

    // MARK: - Remote updates

    /// The stored URL changed from elsewhere (docs/ui/web.md, "Remote updates").
    func storedURLChanged(_ url: String) {
        guard url != lastWrittenURL else { return }
        // A change made elsewhere: an older write of this device can no longer echo.
        lastWrittenURL = nil
        if displayHost != nil {
            applyRemote(url)
        } else {
            pendingRemoteURL = url
        }
    }

    private func applyRemote(_ urlString: String) {
        pendingRemoteURL = nil
        guard webView.url?.absoluteString != urlString, let url = URL(string: urlString) else { return }
        load(url, origin: .remote)
    }

    // MARK: - Write-back

    /// Inside an initial or remote navigation, or within 2 s after it ended.
    private var isQuiet: Bool {
        if navigationOrigins.values.contains(where: \.isQuiet) || actionOrigin?.isQuiet == true {
            return true
        }
        if let quietEnd, ContinuousClock.now < quietEnd {
            return true
        }
        return false
    }

    /// Restarts the 1 s timer of the write-back, outside the quiet period.
    private func triggerWriteBack() {
        guard !isQuiet else { return }
        writeBackTask?.cancel()
        writeBackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await self?.writeBack()
        }
    }

    /// Sends the web view's URL and title, unless the URL is not an http or https URL with a host, equals the stored
    /// URL, or the Main is not connected.
    private func writeBack() async {
        writeBackTask = nil
        guard !isQuiet, let url = webView.url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty,
              let section
        else { return }
        let urlString = url.absoluteString
        guard urlString != section.storedURLs[tabID], let connection = section.connection,
              connection.isConnected
        else { return }
        lastWrittenURL = urlString
        do {
            _ = try await connection.updateTab(projectID: section.projectID, tabID: tabID,
                                               patch: WebTabPatch(url: urlString, title: webView.title ?? ""))
        } catch {
            let message = Banner.message(of: error)
            Log.ui.error("Write-back of web tab \(self.tabID, privacy: .public) failed: \(message)")
        }
    }

    // MARK: - Key-value observation

    private func observeWebView() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.urlDidChange()
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.title = self.webView.title
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.canGoBack = self.webView.canGoBack
                }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.canGoForward = self.webView.canGoForward
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = self.webView.isLoading
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.estimatedProgress = self.webView.estimatedProgress
                }
            },
        ]
    }

    /// A change of the web view's URL while it is not loading is a same-document navigation (`pushState`,
    /// `replaceState`, anchors): it triggers the write-back, unless it applies an initial or remote load.
    private func urlDidChange() {
        url = webView.url
        guard !webView.isLoading else { return }
        if let origin = actionOrigin, origin.isQuiet {
            // A same-document initial or remote navigation: it ends here.
            actionOrigin = nil
            quietEnd = .now + .seconds(2)
            return
        }
        triggerWriteBack()
    }

    // MARK: - Navigation origins

    /// Ends a navigation and returns its origin; an initial or remote navigation starts the 2 s quiet period.
    @discardableResult
    private func endNavigation(_ navigation: WKNavigation?) -> Origin? {
        guard let navigation else { return nil }
        let origin = navigationOrigins.removeValue(forKey: ObjectIdentifier(navigation))
        if origin?.isQuiet == true {
            quietEnd = .now + .seconds(2)
        }
        return origin
    }

    private func origin(of navigation: WKNavigation?) -> Origin? {
        navigation.flatMap { navigationOrigins[ObjectIdentifier($0)] }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }
        let origin: Origin
        if let pending = pendingOrigin {
            origin = pending
            pendingOrigin = nil
        } else if Self.userNavigationTypes.contains(navigationAction.navigationType) {
            origin = .user
        } else {
            origin = .page
        }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !Self.webSchemes.contains(scheme) {
            decisionHandler(.cancel)
            openWithSystem(url)
            return
        }
        actionOrigin = origin
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType,
           let url = navigationResponse.response.url {
            // The system's default browser downloads it.
            decisionHandler(.cancel)
            openWithSystem(url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        let origin = actionOrigin ?? .page
        actionOrigin = nil
        if let navigation {
            navigationOrigins[ObjectIdentifier(navigation)] = origin
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if origin(of: navigation) == .user {
            triggerWriteBack()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if endNavigation(navigation) == .user {
            triggerWriteBack()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        endNavigation(navigation)
        record(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        endNavigation(navigation)
        record(error)
    }

    /// Sets `loadError`, except for a cancelled navigation and an interrupted frame load (WebKitErrorDomain 102).
    private func record(_ error: any Error) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            return
        }
        if error.domain == "WebKitErrorDomain" && error.code == 102 {
            return
        }
        loadError = WebLoadError(message: error.localizedDescription,
                                 url: error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
    }

    // MARK: - WKUIDelegate

    /// A page opening a window for an http or https URL opens it in a new tab, which becomes the pending tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            section?.openTabFromPage(url)
        }
        return nil
    }

    #if os(macOS)
    /// A file input: an `NSOpenPanel` with the parameters' multiple selection and directories.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let window = webView.window
        Task {
            let response: NSApplication.ModalResponse
            if let window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = await panel.begin()
            }
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
    #endif

    // MARK: - System

    private func openWithSystem(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
