import Foundation
import HephClient
import HephCore
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The feedback of one window: captures the window, builds the context, presents the sheet and sends the feedback to
/// the Forge host (docs/forge/feedback.md). `.feedbackSupport(section:)` creates one per window and puts it in the
/// environment.
@MainActor @Observable
public final class FeedbackController {
    /// The draft of the presented sheet; nil while no sheet is presented.
    private(set) var draft: FeedbackDraft?

    @ObservationIgnored private(set) weak var workspace: Workspace?
    @ObservationIgnored private(set) weak var windowContext: WindowContext?
    @ObservationIgnored private var section: String?
    @ObservationIgnored private(set) weak var window: PlatformWindow?
    @ObservationIgnored private var isCapturing = false
    /// The presented sheet: its window (macOS) or its hosting controller (iOS, iPadOS).
    @ObservationIgnored private var presentedSheet: AnyObject?
    @ObservationIgnored private var sendTask: Task<Void, Never>?

    public init() {}

    // MARK: - Window binding

    /// Called by `.feedbackSupport(section:)` with the environment of its window.
    func bind(workspace: Workspace, context: WindowContext?, section: String?) {
        self.workspace = workspace
        windowContext = context
        self.section = section
        if let window, window.isKeyWindow {
            Registry.noteKeyWindow(window)
        }
    }

    /// Called with the window of the view of `.feedbackSupport(section:)` each time that view moves to a window.
    func attach(to window: PlatformWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        Registry.register(self, for: window)
    }

    #if os(iOS)
    /// A shake starts the feedback only when it was received by this controller's window.
    func handleShake(_ notification: Notification) {
        guard let shaken = notification.object as? UIWindow, shaken === window else { return }
        begin()
    }
    #endif

    // MARK: - Capture

    /// Captures the window, builds the context and presents the sheet; does nothing while busy or without a window.
    public func begin() {
        guard let window, workspace != nil, !isCapturing, draft == nil else { return }
        isCapturing = true
        Task {
            let screenshot = await ScreenshotCapture.capture(window)
            isCapturing = false
            guard draft == nil, let context = makeContext() else { return }
            draft = FeedbackDraft(screenshot: screenshot, context: context)
            present()
        }
    }

    /// The controller of the key window (of its top-level window when the key window is a sheet), else of the main
    /// window (macOS); of the key window of the foreground scene (iOS, iPadOS).
    public static func forKeyWindow() -> FeedbackController? {
        #if os(macOS)
        if var window = NSApp.keyWindow {
            while let parent = window.sheetParent {
                window = parent
            }
            if let controller = Registry.controller(for: window) {
                return controller
            }
        }
        if let mainWindow = NSApp.mainWindow, let controller = Registry.controller(for: mainWindow) {
            return controller
        }
        return nil
        #else
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let keyWindow = scene?.keyWindow else { return nil }
        return Registry.controller(for: keyWindow)
        #endif
    }

    /// The FeedbackContext of the capture (docs/forge/feedback.md, "Context").
    private func makeContext() -> FeedbackContext? {
        guard let workspace else { return nil }
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = (info?["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
        var selection = windowContext?.selection.feedbackSelection ?? FeedbackSelection()
        if let section {
            selection.section = section
        }
        return FeedbackContext(deviceID: workspace.device.id, deviceName: workspace.device.name,
                               platform: workspace.device.platform, appVersion: appVersion, build: build,
                               docsHash: DocsHash.embedded, selection: selection)
    }

    // MARK: - Sheet

    /// Presents the sheet so that it also appears over another sheet.
    private func present() {
        guard let window else {
            draft = nil
            return
        }
        #if os(macOS)
        let hosting = NSHostingController(rootView: FeedbackSheet(controller: self))
        hosting.sizingOptions = []
        let sheet = NSWindow(contentViewController: hosting)
        sheet.styleMask = [.titled]
        sheet.isReleasedWhenClosed = false
        sheet.setContentSize(NSSize(width: 560, height: 600))
        var parent = window
        while let attached = parent.attachedSheet {
            parent = attached
        }
        presentedSheet = sheet
        parent.beginSheet(sheet)
        #else
        guard var presenter = window.rootViewController else {
            draft = nil
            return
        }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let hosting = UIHostingController(rootView: FeedbackSheet(controller: self))
        if UIDevice.current.userInterfaceIdiom == .pad {
            hosting.modalPresentationStyle = .formSheet
        } else {
            hosting.modalPresentationStyle = .pageSheet
            hosting.sheetPresentationController?.detents = [.large()]
        }
        hosting.isModalInPresentation = true
        presentedSheet = hosting
        presenter.present(hosting, animated: true)
        #endif
    }

    /// Closes the sheet and forgets the draft.
    private func closeSheet() {
        #if os(macOS)
        if let sheet = presentedSheet as? NSWindow {
            if let parent = sheet.sheetParent {
                parent.endSheet(sheet)
            } else {
                sheet.orderOut(nil)
            }
        }
        #else
        (presentedSheet as? UIViewController)?.dismiss(animated: true)
        #endif
        presentedSheet = nil
        draft = nil
    }

    /// Cancel: closes the sheet and discards the draft.
    func cancel() {
        guard let draft, !draft.isSending else { return }
        closeSheet()
    }

    // MARK: - Sending

    /// Send (docs/forge/feedback.md, "Sending").
    func send() {
        guard let draft, !draft.isSending, let workspace else { return }
        let comment = draft.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { return }
        guard let hostID = workspace.forge.forgeHostID else {
            draft.errorMessage = "No Forge is online. Feedback goes to the Main where “Set as Forge” is on "
                + "(Settings ▸ Forge & Updates)."
            return
        }
        let forge: ForgeModel = workspace.forge
        draft.isSending = true
        draft.errorMessage = nil
        draft.uploadProgress = nil
        sendTask = Task {
            do {
                let result = try await forge.sendFeedback(screenshot: draft.screenshot, comment: comment,
                                                          context: draft.context) { progress in
                    draft.uploadProgress = progress
                }
                draft.isSending = false
                closeSheet()
                openSession(result, on: hostID)
            } catch {
                draft.isSending = false
                draft.errorMessage = Banner.message(of: error)
            }
        }
    }

    /// Opens the feedback session in this window, or, for a controller without a WindowContext (Settings), in the
    /// last active window, which comes to the front.
    private func openSession(_ result: ForgeFeedbackResult, on hostID: UUID) {
        if let windowContext {
            windowContext.navigate(mainDeviceID: hostID, projectID: result.projectID, section: .claude,
                                   item: result.sessionID.uuidString)
            return
        }
        guard let target = Registry.lastActive, let context = target.windowContext else { return }
        context.navigate(mainDeviceID: hostID, projectID: result.projectID, section: .claude,
                         item: result.sessionID.uuidString)
        #if os(macOS)
        target.window?.makeKeyAndOrderFront(nil)
        #endif
    }
}

// MARK: - Registry

extension FeedbackController {
    #if os(macOS)
    typealias PlatformWindow = NSWindow
    #else
    typealias PlatformWindow = UIWindow
    #endif

    /// The controllers of the windows, weak on both sides, and the last controller with a WindowContext whose window
    /// became key.
    @MainActor
    enum Registry {
        private struct Entry {
            weak var window: PlatformWindow?
            weak var controller: FeedbackController?
        }

        private static var entries: [Entry] = []
        private static var keyObserver: (any NSObjectProtocol)?
        /// The last controller with a WindowContext whose window became key.
        private(set) static weak var lastActive: FeedbackController?

        static func register(_ controller: FeedbackController, for window: PlatformWindow) {
            entries.removeAll { entry in
                entry.window == nil || entry.controller == nil || entry.controller === controller
                    || entry.window === window
            }
            entries.append(Entry(window: window, controller: controller))
            installKeyObserver()
            if window.isKeyWindow {
                noteKeyWindow(window)
            }
        }

        static func controller(for window: PlatformWindow) -> FeedbackController? {
            entries.first { $0.window === window }?.controller
        }

        /// A window became key: its controller becomes the last active one when it has a WindowContext.
        static func noteKeyWindow(_ window: PlatformWindow) {
            guard let controller = controller(for: window), controller.windowContext != nil else { return }
            lastActive = controller
        }

        private static func installKeyObserver() {
            guard keyObserver == nil else { return }
            #if os(macOS)
            let name = NSWindow.didBecomeKeyNotification
            #else
            let name = UIWindow.didBecomeKeyNotification
            #endif
            keyObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let window = notification.object as? PlatformWindow else { return }
                MainActor.assumeIsolated {
                    noteKeyWindow(window)
                }
            }
        }
    }
}

// MARK: - Draft

/// What the capture produced, the comment, and the state of the sending of one feedback sheet.
@MainActor @Observable
final class FeedbackDraft {
    /// The PNG of the window; nil when the capture failed.
    let screenshot: Data?
    /// The screenshot as an image for the sheet's preview.
    let previewImage: Image?
    let context: FeedbackContext
    var comment = ""
    var isSending = false
    /// The progress of the screenshot upload; nil before the first report.
    var uploadProgress: TransferProgress?
    var errorMessage: String?

    init(screenshot: Data?, context: FeedbackContext) {
        self.screenshot = screenshot
        self.context = context
        previewImage = screenshot.flatMap { Self.image(from: $0) }
    }

    private static func image(from data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }
}
