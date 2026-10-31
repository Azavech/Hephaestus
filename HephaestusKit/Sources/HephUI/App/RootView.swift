import HephClient
import HephCore
import SwiftUI

/// The root view of every window (docs/ui/shell.md §5.1): it creates the window's context, restores and saves its
/// selection, and shows the launch, onboarding, "No Main online" or shell content.
public struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #else
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @SceneStorage(WindowStateKeys.mainDeviceID) private var storedMainDeviceID = ""
    @SceneStorage(WindowStateKeys.projectID) private var storedProjectID = ""
    @SceneStorage(WindowStateKeys.section) private var storedSection = ""
    @SceneStorage(WindowStateKeys.item) private var storedItem = ""
    @State private var context: WindowContext?
    /// The window restored a `projectID` whose check (§5.3) has not been made yet.
    @State private var checksRestoredProject = false

    public init() {}

    public var body: some View {
        Group {
            if let context {
                window(context)
            } else {
                Color.clear
            }
        }
        .onAppear(perform: makeContext)
        .task {
            await appModel.start()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch appModel.phase {
        case .launching:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .onboarding:
            OnboardingView()
        case .ready:
            if appModel.showsNoMainOnline {
                NoMainOnlineView()
            } else {
                MainShell()
            }
        }
    }

    private func window(_ context: WindowContext) -> some View {
        content
            .feedbackSupport()
            .migrationProgressPresenter()
            .permissionBanner()
            .overlay(alignment: .bottom) {
                BannerOverlay()
            }
            .focusedSceneValue(\.windowContext, appModel.phase == .ready ? context : nil)
            .environment(context)
            .environment(context.selection)
            .environment(context.banners)
            .environment(appModel.workspace)
            .environment(appModel.settings)
            #if os(macOS)
            .environment(appModel.updateModel)
            #endif
            .onChange(of: context.selection.mainDeviceID) { _, mainDeviceID in
                storedMainDeviceID = mainDeviceID?.uuidString ?? ""
                applyDefaults(context)
            }
            .onChange(of: context.selection.projectID) { _, projectID in
                storedProjectID = projectID ?? ""
                applyDefaults(context)
            }
            .onChange(of: context.selection.section) { _, section in
                storedSection = section?.rawValue ?? ""
            }
            .onChange(of: context.selection.item) { _, item in
                storedItem = item ?? ""
            }
            .onChange(of: appModel.workspace.topologyRevision) {
                applyDefaults(context)
            }
            .onChange(of: context.isCompact) {
                applyDefaults(context)
            }
            #if os(macOS)
            .onChange(of: controlActiveState, initial: true) { _, state in
                if state == .key {
                    appModel.banners.activate(context.banners)
                }
            }
            #else
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    appModel.banners.activate(context.banners)
                }
            }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    appModel.workspace.retryNow()
                }
            }
    }

    // MARK: - Window context and stored selection (§5.3)

    /// Creates the window's context once, restores the stored selection, then fills the empty fields; the changes made
    /// meanwhile are saved too.
    private func makeContext() {
        guard context == nil else { return }
        let context = WindowContext(selection: appModel.workspace.makeSelection())
        #if os(iOS)
        context.isCompact = horizontalSizeClass == .compact
        #endif
        let selection = context.selection
        selection.mainDeviceID = UUID(uuidString: storedMainDeviceID)
        selection.projectID = storedProjectID.isEmpty ? nil : storedProjectID
        // `tasks` is the raw value of the Tickets section before tasks were renamed tickets; a section this version
        // does not have (`runs` of earlier versions) restores as nil.
        selection.section = storedSection == "tasks" ? .tickets : SidebarSection(rawValue: storedSection)
        selection.item = storedItem.isEmpty ? nil : storedItem
        checksRestoredProject = selection.projectID != nil
        self.context = context
        applyDefaults(context)
        storedMainDeviceID = selection.mainDeviceID?.uuidString ?? ""
        storedProjectID = selection.projectID ?? ""
        storedSection = selection.section?.rawValue ?? ""
        storedItem = selection.item ?? ""
    }

    /// The restored project check, then `SelectionDefaults.apply`.
    private func applyDefaults(_ context: WindowContext) {
        checkRestoredProject(context.selection)
        SelectionDefaults.apply(to: context.selection, workspace: appModel.workspace, isCompact: context.isCompact)
    }

    /// The first time the defaults run while the selection's Main is connected with `projectsLoaded`: a restored
    /// project that is not in that Main's tree is cleared with the item, so that rule 2 selects a project. The check
    /// is made once, whatever its outcome.
    private func checkRestoredProject(_ selection: Selection) {
        guard checksRestoredProject, let mainDeviceID = selection.mainDeviceID,
              let connection = appModel.workspace.connection(mainDeviceID), connection.isConnected,
              connection.projectsLoaded
        else { return }
        checksRestoredProject = false
        if let projectID = selection.projectID, appModel.workspace.summary(of: projectID, on: mainDeviceID) == nil {
            selection.projectID = nil
            selection.item = nil
        }
    }
}

extension AppModel {
    /// The window shows "No Main online" (§5.1, §10): ready, this device is not a Main, none of its connections is
    /// connected and the grace period has elapsed.
    var showsNoMainOnline: Bool {
        phase == .ready && !identity.isMain && graceElapsed
            && !workspace.connections.values.contains(where: { $0.isConnected })
    }
}
