import SwiftUI

extension FocusedValues {
    /// Saves the shown document. Published by the Code and Docs sections and the skill file view while they show a
    /// document that can be saved; File ▸ Save (⌘S) calls it (shell.md).
    public var saveDocumentAction: (() -> Void)? {
        get { self[SaveDocumentActionKey.self] }
        set { self[SaveDocumentActionKey.self] = newValue }
    }
}

/// The key of `saveDocumentAction`. Declared by hand: an `@Entry` holding a closure warns that it may invalidate its
/// dependents on every update.
private struct SaveDocumentActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
