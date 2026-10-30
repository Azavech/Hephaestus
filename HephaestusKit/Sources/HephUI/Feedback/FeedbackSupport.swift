import Foundation
import HephClient
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension View {
    /// Applied by the shell to every window root, and to the macOS Settings root with section "settings"
    /// (docs/forge/feedback.md, "Window binding").
    public func feedbackSupport(section: String? = nil) -> some View {
        modifier(FeedbackSupportModifier(section: section))
    }
}

/// Creates the window's FeedbackController, puts it in the environment, binds it to the Workspace, the window's
/// WindowContext when there is one, and the window itself; on iOS and iPadOS it also forwards shakes.
private struct FeedbackSupportModifier: ViewModifier {
    let section: String?
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var windowContext: WindowContext?
    @State private var controller = FeedbackController()

    func body(content: Content) -> some View {
        content
            .environment(controller)
            .background {
                FeedbackWindowReader { window in
                    controller.attach(to: window)
                }
                .frame(width: 0, height: 0)
            }
            .onAppear {
                controller.bind(workspace: workspace, context: windowContext, section: section)
            }
            .onChange(of: windowContext.map { ObjectIdentifier($0) }) {
                controller.bind(workspace: workspace, context: windowContext, section: section)
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { notification in
                controller.handleShake(notification)
            }
            #endif
    }
}

#if os(macOS)
/// A zero-size view that reports the window it moves to.
private struct FeedbackWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
#else
/// A zero-size view that reports the window it moves to.
private struct FeedbackWindowReader: UIViewRepresentable {
    let onWindow: (UIWindow?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: UIView {
        var onWindow: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindow?(window)
        }
    }
}
#endif
