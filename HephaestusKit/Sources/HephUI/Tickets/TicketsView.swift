import HephClient
import HephCore
import HephMarkdown
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Tickets section of the project held by `store` (docs/ui/tickets.md): the ticket list and the selected ticket or bundle.
///
/// | Width class     | Layout                                                                  |
/// |-----------------|-------------------------------------------------------------------------|
/// | regular, macOS  | `HSplitView`: ticket list (min 260, ideal 320, max 480 pt), ticket detail   |
/// | regular, iPadOS | `HStack(spacing: 0)`: ticket list (320 pt), `Divider`, ticket detail        |
/// | compact         | `NavigationStack` rooted at the ticket list; the detail is pushed         |
public struct TicketsView: View {
    private let store: ProjectStore

    @Environment(WindowContext.self) private var context
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var listState = TicketListState()
    /// The selected session tab of each ticket, remembered while this view exists.
    @State private var selectedSessions: [String: UUID] = [:]
    @State private var isNewTicketPresented = false
    /// The tickets of the New Bundle sheet while it is shown.
    @State private var newBundle: NewBundleRequest?

    public init(store: ProjectStore) {
        self.store = store
    }

    public var body: some View {
        let newTicketAction: (() -> Void)? = TicketsScreen.isConnected(store) ? { isNewTicketPresented = true } : nil
        layout
            .sheet(isPresented: $isNewTicketPresented) {
                NewTicketSheet(store: store) { ticket in
                    context.selection.item = ticket.id
                }
            }
            .sheet(item: $newBundle) { request in
                NewBundleSheet(store: store, ticketIDs: request.ticketIDs) { bundle in
                    // The compact Select mode ends with its selection, so that the new bundle is pushed.
                    listState.isSelecting = false
                    listState.selectedIDs = []
                    context.selection.item = bundle.id
                }
            }
            .onChange(of: context.selection.item, initial: true) { _, item in
                listState.follow(item: item)
            }
            .focusedSceneValue(\.newTicketAction, newTicketAction)
    }

    private var isCompact: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        if isCompact {
            NavigationStack {
                list
                    .navigationDestination(item: itemBinding) { itemID in
                        TicketDetailDestination(store: store, itemID: itemID, isCompact: true,
                                              selectedSessions: $selectedSessions)
                    }
            }
        } else {
            HStack(spacing: 0) {
                list
                    .frame(width: 320)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #endif
    }

    private var list: some View {
        TicketListView(store: store, state: listState, isCompact: isCompact) {
            isNewTicketPresented = true
        } onNewBundle: { ticketIDs in
            newBundle = NewBundleRequest(ticketIDs: ticketIDs)
        }
    }

    /// The detail area of regular width: the selected ticket or bundle, the actions on several selected tickets, or
    /// "Select a ticket".
    @ViewBuilder
    private var detail: some View {
        if let itemID = context.selection.item {
            TicketDetailDestination(store: store, itemID: itemID, isCompact: false, selectedSessions: $selectedSessions)
        } else if listState.selectedIDs.count > 1 {
            multipleSelection
        } else {
            ContentUnavailableView {
                Text("Select a ticket")
            }
        }
    }

    /// "<n> tickets selected", a New Bundle… button and the Add to Bundle menu.
    private var multipleSelection: some View {
        let ticketIDs = listState.selectedTicketIDs(in: store.tickets)
        return ContentUnavailableView {
            Text(verbatim: "\(listState.selectedIDs.count) tickets selected")
        } actions: {
            Button("New Bundle…") {
                newBundle = NewBundleRequest(ticketIDs: ticketIDs)
            }
            .disabled(ticketIDs.isEmpty || !TicketsScreen.isConnected(store))
            AddToBundleMenu(store: store, ticketIDs: ticketIDs)
                .fixedSize()
        }
    }

    /// `selection.item`, the selected ticket or bundle id. In compact width the pushed detail follows it, except in the
    /// Select mode, where rows are chosen without showing them; Back sets it to nil.
    private var itemBinding: Binding<String?> {
        Binding(
            get: { listState.isSelecting ? nil : context.selection.item },
            set: { context.selection.item = $0 }
        )
    }
}

/// The tickets of a New Bundle sheet to show.
private struct NewBundleRequest: Identifiable {
    let id = UUID()
    let ticketIDs: [String]
}

/// The detail of the ticket or bundle `itemID`, or "<ID> was deleted." when the store has neither.
private struct TicketDetailDestination: View {
    let store: ProjectStore
    let itemID: String
    let isCompact: Bool
    @Binding var selectedSessions: [String: UUID]

    var body: some View {
        if let bundle = store.bundle(itemID) {
            BundleDetailView(store: store, bundle: bundle)
                .id(itemID)
        } else if let ticket = store.ticket(itemID) {
            let ticketID = itemID
            TicketDetailView(
                store: store,
                ticket: ticket,
                isCompact: isCompact,
                selectedSessionID: Binding(
                    get: { selectedSessions[ticketID] },
                    set: { selectedSessions[ticketID] = $0 }
                )
            )
            .id(ticketID)
        } else {
            ContentUnavailableView {
                Text(verbatim: "\(itemID) was deleted.")
            }
        }
    }
}

/// Published by TicketsView with .focusedSceneValue; bound to File ▸ New Ticket (⌘N) by the shell's commands.
public struct NewTicketActionKey: FocusedValueKey {
    public typealias Value = () -> Void
}

extension FocusedValues {
    public var newTicketAction: (() -> Void)? {
        get { self[NewTicketActionKey.self] }
        set { self[NewTicketActionKey.self] = newValue }
    }
}

/// Helpers shared by the views of the Tickets screen.
@MainActor
enum TicketsScreen {
    /// The project's Main is connected: the controls that send requests are enabled.
    static func isConnected(_ store: ProjectStore) -> Bool {
        store.connection?.isConnected ?? false
    }

    /// The connection of the project's Main; without one, the offline error of the request API.
    static func connection(of store: ProjectStore, workspace: Workspace) throws -> MainConnection {
        if let connection = store.connection {
            return connection
        }
        let name = workspace.mains.first { $0.id == store.mainDeviceID }?.name ?? "Main"
        throw ProtocolError(.unavailable, "\(name) is offline.")
    }

    /// Copy ID.
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// The link rules of ticket descriptions and comments: an http(s) link opens a new web tab in the project, then the
    /// window shows that tab; a link with another scheme (for example `mailto:`) opens with the environment's
    /// `openURL`.
    static func openLink(_ target: MarkdownLinkTarget, store: ProjectStore, workspace: Workspace,
                         context: WindowContext, banners: WindowBanners, openURL: OpenURLAction) {
        guard case .external(let url) = target else { return }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            openURL(url)
            return
        }
        let mainDeviceID = store.mainDeviceID
        let projectID = store.projectID
        Task {
            await banners.perform {
                let connection = try connection(of: store, workspace: workspace)
                let tab = try await connection.openTab(projectID: projectID, url: url.absoluteString, title: nil,
                                                       locked: nil)
                context.navigate(mainDeviceID: mainDeviceID, projectID: projectID, section: .web,
                                 item: tab.id.uuidString)
            }
        }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    TicketsView(store: appModel.workspace.projectStore(mainDeviceID: studio, projectID: "HEPH"))
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, projectID: "HEPH", section: .tickets))
}
