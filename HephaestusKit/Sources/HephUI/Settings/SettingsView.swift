#if os(macOS)
import Foundation
import HephClient
import HephCore
import SwiftUI

/// The macOS Settings scene (⌘,): the panes General, Devices, Claude, Skills and Forge & Updates
/// (docs/ui/settings.md, "macOS: SettingsView").
public struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.controlActiveState) private var controlActiveState
    /// The banners of the Settings window, created when it first appears.
    @State private var banners: WindowBanners?
    /// The selection of the Settings window (no section), created when it first appears.
    @State private var selection: Selection?

    public init() {}

    public var body: some View {
        Group {
            if let banners, let selection {
                tabs
                    .feedbackSupport(section: "settings")
                    .overlay(alignment: .bottom) {
                        BannerOverlay()
                    }
                    .environment(banners)
                    .environment(selection)
                    .environment(appModel.workspace)
                    .environment(appModel.settings)
                    .environment(appModel.updateModel)
                    .onChange(of: controlActiveState, initial: true) {
                        if controlActiveState == .key {
                            appModel.banners.activate(banners)
                        }
                    }
            } else {
                Color.clear
            }
        }
        .onAppear {
            if banners == nil {
                banners = WindowBanners()
            }
            if selection == nil {
                selection = appModel.workspace.makeSelection()
            }
        }
    }

    private var tabs: some View {
        TabView {
            GeneralSettingsPane()
                .frame(width: 620)
                .frame(minHeight: 380)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            DevicesView()
                .frame(width: 680, height: 520)
                .tabItem {
                    Label("Devices", systemImage: "laptopcomputer.and.iphone")
                }
            ClaudeSettingsPane()
                .frame(width: 620)
                .frame(minHeight: 380)
                .tabItem {
                    Label("Claude", systemImage: "bubble.left.and.bubble.right")
                }
            SkillsSettingsPane()
                .frame(width: 620)
                .frame(minHeight: 380)
                .tabItem {
                    Label("Skills", systemImage: "wand.and.stars")
                }
            ForgeSettingsPane()
                .frame(width: 620)
                .frame(minHeight: 380)
                .tabItem {
                    Label("Forge & Updates", systemImage: "hammer")
                }
        }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    SettingsView()
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
#endif
