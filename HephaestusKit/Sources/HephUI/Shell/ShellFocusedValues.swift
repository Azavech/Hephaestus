import SwiftUI

/// The focused values of the shell (docs/ui/shell.md §11.3). A view publishes an action with `.focusedSceneValue`
/// only while it is shown and the action is possible; elsewhere the value is nil and the menu item is disabled.
extension FocusedValues {
    /// The window's context; published by `RootView` while the phase is `.ready`.
    @Entry public var windowContext: WindowContext?

    /// Closes the current editor tab, document or web tab; published while one is current.
    public var closeTabAction: (() -> Void)? {
        get { self[CloseTabActionKey.self] }
        set { self[CloseTabActionKey.self] = newValue }
    }

    /// Opens a new web tab; published while the Web section is shown and its Main is connected.
    public var newWebTabAction: (() -> Void)? {
        get { self[NewWebTabActionKey.self] }
        set { self[NewWebTabActionKey.self] = newValue }
    }
}

/// The key of `closeTabAction`.
private struct CloseTabActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// The key of `newWebTabAction`.
private struct NewWebTabActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
