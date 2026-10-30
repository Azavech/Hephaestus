import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shows the web view of a tab. A web view is in one view hierarchy at a time: the host that appeared last claims
/// it; another host showing the same tab offers to show it here (docs/ui/web.md, "Display").
struct WebViewHost: View {
    let controller: WebTabController

    /// The token of this host.
    @State private var token = UUID()
    /// The controller this host claimed.
    @State private var claimed: WebTabController?

    var body: some View {
        Group {
            if controller.displayHost == token {
                WebViewContainer(webView: controller.webView)
            } else {
                VStack(spacing: 8) {
                    Text("Shown in another window")
                        .foregroundStyle(.secondary)
                    Button("Show Here") {
                        claim()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            claim()
        }
        .onChange(of: ObjectIdentifier(controller)) {
            claim()
        }
        .onDisappear {
            claimed?.unclaim(token)
            claimed = nil
        }
    }

    /// The web view moves into this host's container; a controller claimed before, for another tab, is no longer
    /// displayed by this host.
    private func claim() {
        if let claimed, claimed !== controller {
            claimed.unclaim(token)
        }
        claimed = controller
        controller.claim(token)
    }
}

#if os(macOS)
/// A container view holding the web view pinned to its edges.
private struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        Self.attach(webView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        Self.attach(webView, to: container)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
    }

    private static func attach(_ webView: WKWebView, to container: NSView) {
        guard webView.superview !== container else { return }
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
#else
/// A container view holding the web view pinned to its edges.
private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        Self.attach(webView, to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        Self.attach(webView, to: container)
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
    }

    private static func attach(_ webView: WKWebView, to container: UIView) {
        guard webView.superview !== container else { return }
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
#endif
