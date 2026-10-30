#if os(macOS)
import AppKit

/// The application delegate of the macOS app (docs/ui/shell.md §2.1).
@MainActor
public final class HephaestusAppDelegate: NSObject, NSApplicationDelegate {
    /// A termination is waiting for `AppModel.shutdown()`.
    private var isTerminating = false

    public override init() {
        super.init()
    }

    /// A Main keeps serving its devices with no window open.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Stops the app wiring first (at most 10 s), then lets the app terminate. The reply comes from a main-actor task,
    /// so `terminate` is called only from the run loop, never inside a main-actor job.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task { @MainActor in
            await AppModel.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
