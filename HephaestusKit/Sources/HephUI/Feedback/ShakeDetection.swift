#if os(iOS)
import UIKit

// Shake detection: the feedback entry point of iOS and iPadOS (docs/forge/feedback.md, "Shake detection").

extension Notification.Name {
    /// Posted when the device is shaken; the object is the UIWindow that received the motion event.
    public static let deviceDidShake = Notification.Name("HephaestusDeviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: self)
        }
        super.motionEnded(motion, with: event)
    }
}
#endif
