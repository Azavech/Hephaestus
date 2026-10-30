import Foundation
import SwiftUI

/// The address field of the active tab (docs/ui/web.md, "Address field").
struct AddressBar: View {
    /// The live web view of the active tab, if any.
    let controller: WebTabController?
    /// The stored URL of the active tab.
    let storedURL: String
    let isFocused: FocusState<Bool>.Binding

    @State private var text = ""
    /// Return was pressed: leaving the field keeps what Return loaded.
    @State private var didSubmit = false

    /// The web view's URL, or the stored URL when the tab has no live web view; empty for `about:blank`.
    private var shownURL: String {
        let url = controller.map { $0.url?.absoluteString ?? "" } ?? storedURL
        return url == "about:blank" ? "" : url
    }

    var body: some View {
        TextField("Search or enter address", text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .submitLabel(.go)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.webSearch)
            #endif
            .focused(isFocused)
            .onSubmit(submit)
            #if os(macOS)
            .onExitCommand(perform: restore)
            #else
            .onKeyPress(.escape) {
                restore()
                return .handled
            }
            #endif
            .onAppear {
                text = shownURL
            }
            .onChange(of: shownURL) { _, url in
                if !isFocused.wrappedValue {
                    text = url
                }
            }
            .onChange(of: isFocused.wrappedValue) { _, focused in
                if !focused && !didSubmit {
                    restore()
                }
                didSubmit = false
            }
    }

    /// Return: loads the resolved address in the active tab as a user navigation; nothing when it resolves to nil.
    private func submit() {
        guard let url = WebAddress.resolve(text), let controller else { return }
        controller.load(url, origin: .user)
        text = url.absoluteString
        didSubmit = true
        isFocused.wrappedValue = false
    }

    /// Escape, or leaving the field without Return: the shown URL again.
    private func restore() {
        text = shownURL
    }
}
