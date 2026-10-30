import Foundation
import HephClient
import HephCore
import SwiftUI

/// The Web section of the project held by `store`. @MainActor; reads the Workspace, the window's Selection and
/// WindowBanners from the environment (docs/ui/web.md).
public struct WebTabsView: View {
    private let store: ProjectStore

    @Environment(Workspace.self) private var workspace
    @Environment(Selection.self) private var selection
    @Environment(WindowBanners.self) private var banners
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @FocusState private var isAddressFocused: Bool
    /// A tab opened by New Tab in this window: its address field takes the focus when it is shown.
    @State private var focusTabID: UUID?
    @State private var isTabListPresented = false

    public init(store: ProjectStore) {
        self.store = store
    }

    private var model: WebSectionModel {
        WebSectionModel.shared(store: store, workspace: workspace)
    }

    /// The project's tabs, in strip order.
    private var tabs: [WebTab] {
        store.project?.webTabs ?? []
    }

    private var isCompact: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    public var body: some View {
        let model = model
        let tabs = tabs
        let activeTab = model.activeTab(in: tabs)
        let controller = activeTab.flatMap { model.controllers[$0.id] }
        content(model: model, tabs: tabs, activeTab: activeTab, controller: controller)
            .onAppear {
                model.apply(tabs)
                open(item: selection.item)
                syncSelectionItem()
            }
            .onChange(of: tabs) { _, newTabs in
                model.apply(newTabs)
            }
            .onChange(of: selection.item) { _, item in
                open(item: item)
            }
            .onChange(of: activeTab?.id) { _, id in
                selection.item = id?.uuidString
                if let id, id == focusTabID {
                    focusTabID = nil
                    isAddressFocused = true
                }
            }
            .task(id: activeTab?.id) {
                if let activeTab {
                    _ = model.controller(for: activeTab)
                }
            }
            .focusedSceneValue(\.newWebTabAction, model.isConnected ? newTab : nil)
            .focusedSceneValue(\.closeTabAction, activeTab.map { tab in { close(tab) } })
    }

    @ViewBuilder
    private func content(model: WebSectionModel, tabs: [WebTab], activeTab: WebTab?,
                         controller: WebTabController?) -> some View {
        if let activeTab {
            #if os(iOS)
            if isCompact {
                compactLayout(model: model, tabs: tabs, tab: activeTab, controller: controller)
            } else {
                regularLayout(model: model, tabs: tabs, tab: activeTab, controller: controller)
            }
            #else
            regularLayout(model: model, tabs: tabs, tab: activeTab, controller: controller)
            #endif
        } else {
            EmptyStateView(symbol: "globe", title: "No web tabs") {
                Button("New Tab", action: newTab)
                    .disabled(!model.isConnected)
            }
        }
    }

    // MARK: - Regular width

    private func regularLayout(model: WebSectionModel, tabs: [WebTab], tab: WebTab,
                               controller: WebTabController?) -> some View {
        VStack(spacing: 0) {
            WebTabStrip(
                tabs: tabs,
                activeTabID: tab.id,
                isConnected: model.isConnected,
                onSelect: { model.select($0) },
                onClose: close,
                onToggleLock: toggleLock,
                onOpenInBrowser: openInBrowser,
                onMove: move,
                onNewTab: newTab
            )
            Divider()
            HStack(spacing: 8) {
                backButton(controller)
                forwardButton(controller)
                reloadButton(controller)
                AddressBar(controller: controller, storedURL: tab.url, isFocused: $isAddressFocused)
                lockButton(tab, isConnected: model.isConnected)
                Button {
                    openInBrowser(tab)
                } label: {
                    Label("Open in Default Browser", systemImage: "safari")
                }
                .help("Open in Default Browser")
                .disabled(browserURL(of: tab) == nil)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            progressLine(controller)
            webContent(controller)
        }
    }

    // MARK: - Compact width

    #if os(iOS)
    private func compactLayout(model: WebSectionModel, tabs: [WebTab], tab: WebTab,
                               controller: WebTabController?) -> some View {
        VStack(spacing: 0) {
            progressLine(controller)
            webContent(controller)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                AddressBar(controller: controller, storedURL: tab.url, isFocused: $isAddressFocused)
                    .frame(minWidth: 200)
            }
            ToolbarItem(placement: .topBarTrailing) {
                reloadButton(controller)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                backButton(controller)
                Spacer()
                forwardButton(controller)
                Spacer()
                Button {
                    isTabListPresented = true
                } label: {
                    Label {
                        Text("\(tabs.count)")
                    } icon: {
                        Image(systemName: "square.on.square")
                    }
                    .labelStyle(.titleAndIcon)
                }
                Spacer()
                lockButton(tab, isConnected: model.isConnected)
                Spacer()
                Menu {
                    Button("New Tab", action: newTab)
                        .disabled(!model.isConnected)
                    Button("Open in Default Browser") {
                        openInBrowser(tab)
                    }
                    .disabled(browserURL(of: tab) == nil)
                    Button("Close Tab") {
                        close(tab)
                    }
                    .disabled(!model.isConnected)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isTabListPresented) {
            WebTabList(
                tabs: tabs,
                activeTabID: tab.id,
                isConnected: model.isConnected,
                onSelect: { model.select($0) },
                onClose: close,
                onMove: move,
                onNewTab: newTab
            )
        }
    }
    #endif

    // MARK: - Shared parts

    private func backButton(_ controller: WebTabController?) -> some View {
        Button {
            controller?.goBack()
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .help("Back")
        .disabled(controller?.canGoBack != true)
    }

    private func forwardButton(_ controller: WebTabController?) -> some View {
        Button {
            controller?.goForward()
        } label: {
            Label("Forward", systemImage: "chevron.right")
        }
        .help("Forward")
        .disabled(controller?.canGoForward != true)
    }

    /// Reload, or Stop while loading.
    @ViewBuilder
    private func reloadButton(_ controller: WebTabController?) -> some View {
        if controller?.isLoading == true {
            Button {
                controller?.stopLoading()
            } label: {
                Label("Stop", systemImage: "xmark")
            }
            .help("Stop")
        } else {
            Button {
                controller?.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Reload")
            .disabled(controller == nil)
        }
    }

    private func lockButton(_ tab: WebTab, isConnected: Bool) -> some View {
        Button {
            toggleLock(tab)
        } label: {
            Label(tab.locked ? "Unlock Tab" : "Lock Tab", systemImage: tab.locked ? "lock" : "lock.open")
        }
        .help(tab.locked ? "Unlock Tab" : "Lock Tab")
        .disabled(!isConnected)
    }

    /// A 2 pt accent-colored line showing `estimatedProgress` while loading.
    private func progressLine(_ controller: WebTabController?) -> some View {
        let isLoading = controller?.isLoading == true
        let progress = min(max(controller?.estimatedProgress ?? 0, 0), 1)
        return GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * progress)
        }
        .frame(height: 2)
        .opacity(isLoading ? 1 : 0)
    }

    /// The web view, covered by the load error state when there is one.
    private func webContent(_ controller: WebTabController?) -> some View {
        ZStack {
            if let controller {
                WebViewHost(controller: controller)
                if let error = controller.loadError {
                    EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't open the page",
                                   message: error.message) {
                        Button("Reload") {
                            controller.reloadAfterError()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func requireConnection() throws -> MainConnection {
        guard let connection = store.connection else {
            throw ProtocolError(.unavailable, "The Main of \(store.projectID) is not available.")
        }
        return connection
    }

    /// The current value of a tab, which may have changed since it was shown.
    private func current(_ tab: WebTab) -> WebTab {
        tabs.first { $0.id == tab.id } ?? tab
    }

    /// New Tab: `about:blank` titled "New Tab"; the new tab is shown as soon as it is listed and its address field
    /// takes the focus.
    private func newTab() {
        let model = model
        let projectID = store.projectID
        Task {
            await banners.perform {
                let tab = try await requireConnection().openTab(projectID: projectID, url: "about:blank",
                                                                title: "New Tab", locked: nil)
                focusTabID = tab.id
                model.showWhenListed(tab.id)
            }
        }
    }

    /// Close: a locked tab sends nothing and shows "This tab is locked", as does a `locked` error.
    private func close(_ tab: WebTab) {
        let tab = current(tab)
        guard !tab.locked else {
            banners.showInfo("This tab is locked")
            return
        }
        let projectID = store.projectID
        Task {
            do {
                try await requireConnection().closeTab(projectID: projectID, tabID: tab.id)
            } catch let error as ProtocolError where error.code == .locked {
                banners.showInfo("This tab is locked")
            } catch {
                banners.showError(error)
            }
        }
    }

    private func toggleLock(_ tab: WebTab) {
        let tab = current(tab)
        let projectID = store.projectID
        Task {
            await banners.perform {
                _ = try await requireConnection().updateTab(projectID: projectID, tabID: tab.id,
                                                            patch: WebTabPatch(locked: !tab.locked))
            }
        }
    }

    /// Reorder: `toIndex` is the tab's index after the move.
    private func move(_ tabID: UUID, toIndex: Int) {
        let projectID = store.projectID
        Task {
            await banners.perform {
                try await requireConnection().moveTab(projectID: projectID, tabID: tabID, toIndex: toIndex)
            }
        }
    }

    /// The web view's URL, else the stored URL; nil for `about:blank`.
    private func browserURL(of tab: WebTab) -> URL? {
        guard let url = model.controllers[tab.id]?.url ?? URL(string: tab.url),
              url.absoluteString != "about:blank"
        else { return nil }
        return url
    }

    private func openInBrowser(_ tab: WebTab) {
        if let url = browserURL(of: tab) {
            openURL(url)
        }
    }

    // MARK: - Navigation and selection

    /// An item naming a listed tab makes it active; an item naming a tab not listed yet becomes the pending tab.
    private func open(item: String?) {
        guard let item, let tabID = UUID(uuidString: item) else { return }
        let model = model
        if tabs.contains(where: { $0.id == tabID }) {
            if model.activeTab(in: tabs)?.id != tabID {
                model.select(tabID)
            }
        } else {
            model.pendingTabID = tabID
        }
    }

    /// `selection.item` is the active tab's id, unless it names the pending tab.
    private func syncSelectionItem() {
        let model = model
        if let item = selection.item, let tabID = UUID(uuidString: item), tabID == model.pendingTabID {
            return
        }
        let activeID = model.activeTab(in: tabs)?.id.uuidString
        if selection.item != activeID {
            selection.item = activeID
        }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    WebTabsView(store: appModel.workspace.projectStore(mainDeviceID: studio, projectID: "HEPH"))
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, projectID: "HEPH", section: .web))
}
