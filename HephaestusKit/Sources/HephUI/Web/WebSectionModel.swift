import Foundation
import HephClient
import HephCore
import Observation
#if os(iOS)
import UIKit
#endif

/// The state of the Web section of one project, shared by every window showing it, for the life of the process
/// (docs/ui/web.md, "Section model").
@MainActor @Observable
final class WebSectionModel {
    /// The models, by project identifier.
    private static var models: [String: WebSectionModel] = [:]

    /// The model of `store.projectID`, created on first use; its Main becomes `store.mainDeviceID`.
    static func shared(store: ProjectStore, workspace: Workspace) -> WebSectionModel {
        if let model = models[store.projectID] {
            if model.mainDeviceID != store.mainDeviceID {
                model.mainDeviceID = store.mainDeviceID
            }
            return model
        }
        let model = WebSectionModel(projectID: store.projectID, mainDeviceID: store.mainDeviceID,
                                    workspace: workspace)
        models[store.projectID] = model
        return model
    }

    let projectID: String
    let workspace: Workspace
    /// The Main hosting the project; requests of the model go to its connection.
    var mainDeviceID: UUID
    /// The shown tab; when nil or no longer listed, the first tab.
    var activeTabID: UUID?
    /// A tab to show as soon as it is listed; cleared when shown or when the user picks a tab.
    var pendingTabID: UUID?
    /// The live web views, by tab id.
    private(set) var controllers: [UUID: WebTabController] = [:]
    /// Tab ids, most recently shown first.
    private(set) var recent: [UUID] = []
    /// The stored URL of each tab as last seen, to detect changes.
    private(set) var storedURLs: [UUID: String] = [:]

    /// The tab ids of the last `apply`, in strip order.
    @ObservationIgnored private var lastOrder: [UUID] = []
    @ObservationIgnored private var memoryWarningTask: Task<Void, Never>?

    /// At most this many live web views, unless more are displayed.
    private static let maximumControllers = 8

    private init(projectID: String, mainDeviceID: UUID, workspace: Workspace) {
        self.projectID = projectID
        self.mainDeviceID = mainDeviceID
        self.workspace = workspace
        #if os(iOS)
        memoryWarningTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            ) {
                self?.releaseHiddenControllers()
            }
        }
        #endif
    }

    /// `workspace.connection(mainDeviceID)`
    var connection: MainConnection? {
        workspace.connection(mainDeviceID)
    }

    var isConnected: Bool {
        connection?.isConnected == true
    }

    /// The tab of `activeTabID`, else the first tab.
    func activeTab(in tabs: [WebTab]) -> WebTab? {
        tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    /// The stored title when not empty, else the URL's host, else "New Tab".
    static func displayTitle(of tab: WebTab) -> String {
        if !tab.title.isEmpty {
            return tab.title
        }
        if let host = URL(string: tab.url)?.host, !host.isEmpty {
            return host
        }
        return "New Tab"
    }

    /// Called with the tabs when the view appears and on every change of the project's tabs.
    func apply(_ tabs: [WebTab]) {
        let order = tabs.map(\.id)
        let listed = Set(order)
        // 1. The controllers of tabs no longer listed are released; a removed active tab is replaced by the tab that
        //    followed it, else the one before it.
        let previousActive = activeTabID.flatMap { lastOrder.contains($0) ? $0 : nil } ?? lastOrder.first
        for id in controllers.keys where !listed.contains(id) {
            release(id)
        }
        recent.removeAll { !listed.contains($0) }
        if let previousActive, !listed.contains(previousActive) {
            if let index = lastOrder.firstIndex(of: previousActive) {
                let following = lastOrder[(index + 1)...].first { listed.contains($0) }
                let preceding = lastOrder[..<index].last { listed.contains($0) }
                activeTabID = following ?? preceding
            } else {
                activeTabID = nil
            }
        }
        // 2. A pending tab that is listed becomes active.
        if let pendingTabID, listed.contains(pendingTabID) {
            activeTabID = pendingTabID
            self.pendingTabID = nil
        }
        // 3. A stored URL changed elsewhere reaches the live controller of its tab.
        for tab in tabs {
            if let stored = storedURLs[tab.id], stored != tab.url {
                controllers[tab.id]?.storedURLChanged(tab.url)
            }
        }
        storedURLs = Dictionary(tabs.map { ($0.id, $0.url) }, uniquingKeysWith: { _, last in last })
        lastOrder = order
    }

    /// The user picks a tab: it becomes active and the pending tab is cleared.
    func select(_ tabID: UUID) {
        activeTabID = tabID
        pendingTabID = nil
    }

    /// A tab to show: at once when it is already listed, else as soon as it is.
    func showWhenListed(_ tabID: UUID) {
        if lastOrder.contains(tabID) {
            activeTabID = tabID
            pendingTabID = nil
        } else {
            pendingTabID = tabID
        }
    }

    /// The live controller of the tab, created when missing (it starts the initial load); the tab moves to the front
    /// of `recent`. Above 8 live controllers, the least recently shown ones that are not displayed are released.
    func controller(for tab: WebTab) -> WebTabController {
        let controller: WebTabController
        if let existing = controllers[tab.id] {
            controller = existing
        } else {
            controller = WebTabController(tab: tab, section: self)
            controllers[tab.id] = controller
        }
        if recent.first != tab.id {
            recent.removeAll { $0 == tab.id }
            recent.insert(tab.id, at: 0)
        }
        if controllers.count > Self.maximumControllers {
            for id in recent.reversed() where controllers.count > Self.maximumControllers {
                if let candidate = controllers[id], candidate !== controller, candidate.displayHost == nil {
                    release(id)
                }
            }
        }
        return controller
    }

    /// A page opened a window: `openTab` with its URL and no title; the new tab becomes the pending tab.
    func openTabFromPage(_ url: URL) {
        guard let connection else {
            Log.ui.error("Could not open a tab for \(self.projectID, privacy: .public): no connection")
            return
        }
        let projectID = projectID
        Task {
            do {
                let tab = try await connection.openTab(projectID: projectID, url: url.absoluteString, title: nil,
                                                       locked: nil)
                showWhenListed(tab.id)
            } catch {
                let message = Banner.message(of: error)
                Log.ui.error("Could not open a tab for \(projectID, privacy: .public): \(message)")
                AppModel.shared.banners.post(Banner(style: .error, message: message))
            }
        }
    }

    /// Releasing a controller: `stopLoading()`, the web view removed from its container, its delegates cleared, its
    /// pending write-back cancelled. The tab gets a new web view the next time it is shown.
    private func release(_ tabID: UUID) {
        controllers.removeValue(forKey: tabID)?.release()
    }

    /// iOS and iPadOS memory warnings release every controller that is not displayed.
    private func releaseHiddenControllers() {
        for (id, controller) in controllers where controller.displayHost == nil {
            release(id)
        }
    }
}
