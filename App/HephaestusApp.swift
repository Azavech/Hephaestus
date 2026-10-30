import SwiftUI
import HephUI

@main
struct HephaestusApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(HephaestusAppDelegate.self) private var appDelegate
    #endif
    private let appModel = AppModel.shared

    var body: some Scene {
        WindowGroup("Hephaestus", id: AppModel.mainWindowID) {
            RootView()
                .environment(appModel)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
        .commands { HephaestusCommands(appModel: appModel) }

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appModel)
        }
        #endif
    }
}
