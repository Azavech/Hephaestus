import HephClient
import HephCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The menus and keyboard shortcuts of the app (docs/ui/shell.md §11). They act on the key window through its
/// focused values.
public struct HephaestusCommands: Commands {
    private let appModel: AppModel
    @FocusedValue(\.windowContext) private var windowContext
    @FocusedValue(\.newTicketAction) private var newTicketAction
    @FocusedValue(\.newWebTabAction) private var newWebTabAction
    @FocusedValue(\.saveDocumentAction) private var saveDocumentAction
    @FocusedValue(\.closeTabAction) private var closeTabAction
    @Environment(\.openWindow) private var openWindow

    public init(appModel: AppModel) {
        self.appModel = appModel
    }

    public var body: some Commands {
        #if os(macOS)
        CommandGroup(replacing: .appInfo) {
            Button("About Hephaestus") {
                showAboutPanel()
            }
        }
        #endif
        CommandGroup(replacing: .newItem) {
            #if os(macOS)
            Button("New Window") {
                openWindow(id: AppModel.mainWindowID)
            }
            .keyboardShortcut("n", modifiers: [.option, .command])
            #endif
            Button("New Ticket") {
                newTicketAction?()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(newTicketAction == nil)
            Button("New Web Tab") {
                newWebTabAction?()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(newWebTabAction == nil)
        }
        CommandGroup(replacing: .saveItem) {
            closeItem
            Button("Save") {
                saveDocumentAction?()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveDocumentAction == nil)
        }
        SidebarCommands()
        TextEditingCommands()
        CommandMenu("Navigate") {
            Button("Search…") {
                windowContext?.openSearch()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!showsShell)
            Divider()
            ForEach(SidebarSection.projectSections, id: \.self) { section in
                sectionButton(section, isEnabled: showsShell && windowContext?.selection.projectID != nil)
            }
            Divider()
            ForEach(SidebarSection.workspaceSections, id: \.self) { section in
                sectionButton(section, isEnabled: showsShell)
            }
        }
        FeedbackCommands()
    }

    /// The key window shows the shell: a main window in the ready phase, not in the "No Main online" state.
    private var showsShell: Bool {
        windowContext != nil && !appModel.showsNoMainOnline
    }

    /// Navigate ▸ <section>, with ⌘1–⌘7 for the project sections.
    @ViewBuilder
    private func sectionButton(_ section: SidebarSection, isEnabled: Bool) -> some View {
        let button = Button(section.title) {
            windowContext?.select(section)
        }
        .disabled(!isEnabled)
        if let key = section.shortcutKey {
            button.keyboardShortcut(key, modifiers: .command)
        } else {
            button
        }
    }

    /// ⌘W: Close Tab while a tab is current; on macOS, Close the key window otherwise.
    @ViewBuilder
    private var closeItem: some View {
        #if os(macOS)
        if let closeTabAction {
            Button("Close Tab") {
                closeTabAction()
            }
            .keyboardShortcut("w", modifiers: .command)
        } else {
            Button("Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        #else
        Button("Close Tab") {
            closeTabAction?()
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(closeTabAction == nil)
        #endif
    }

    #if os(macOS)
    /// The standard About panel, with the docs hash the app was generated from as credits.
    private func showAboutPanel() {
        let credits = NSAttributedString(
            string: "Docs \(DocsHash.embedded)",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
    #endif
}
