import HephClient
import HephCore
import SwiftUI

/// The ticket list (docs/ui/tickets.md, "Ticket list"): above it a filter field, the filter menu and the New Ticket button (in
/// the navigation bar in compact width); then the Bundles section, the tickets in one section per status and a Broken
/// section. Several tickets can be selected ("Multi-selection"): ⌘-click and ⇧-click in regular width, the Select mode
/// with its bottom bar in compact width.
struct TicketListView: View {
    let store: ProjectStore
    @Bindable var state: TicketListState
    let isCompact: Bool
    /// Opens the New Ticket sheet.
    let onNewTicket: () -> Void
    /// Opens the New Bundle sheet with these tickets.
    let onNewBundle: ([String]) -> Void

    @Environment(WindowContext.self) private var context
    @State private var ticketToDelete: TicketItem?
    @State private var bundleToDelete: BundleItem?

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            if isCompact {
                ToolbarItem(placement: .primaryAction) {
                    newTicketButton
                }
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    selectButton
                }
                if state.isSelecting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        selectionActions
                    }
                }
                #endif
            }
        }
        #if os(iOS)
        .environment(\.editMode, editMode)
        #endif
        .modifier(TicketDeleteConfirmation(ticket: $ticketToDelete, store: store))
        .modifier(BundleDeleteConfirmation(bundle: $bundleToDelete, store: store))
    }

    // MARK: - Compact selection

    #if os(iOS)
    /// The edit mode of the list: active in the Select mode.
    private var editMode: Binding<EditMode> {
        Binding(
            get: { state.isSelecting ? .active : .inactive },
            set: { state.isSelecting = $0.isEditing }
        )
    }

    /// "Select" turns on the edit mode, in which ticket rows show selection circles; "Done" turns it off and empties the
    /// selection.
    private var selectButton: some View {
        Button(state.isSelecting ? "Done" : "Select") {
            if state.isSelecting {
                state.isSelecting = false
                context.selection.item = state.select([], isBroken: isBroken)
            } else {
                state.isSelecting = true
            }
        }
    }

    /// The bottom bar of the Select mode: New Bundle and the Add to Bundle menu, enabled when a ticket is selected.
    @ViewBuilder
    private var selectionActions: some View {
        let ticketIDs = state.selectedTicketIDs(in: store.tickets)
        Button("New Bundle") {
            onNewBundle(ticketIDs)
        }
        .disabled(ticketIDs.isEmpty || !TicketsScreen.isConnected(store))
        Spacer()
        AddToBundleMenu(store: store, ticketIDs: ticketIDs)
    }
    #endif

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $state.text)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            filterMenu
            if !isCompact {
                newTicketButton
            }
        }
    }

    /// Statuses shown (toggles) and Sort (picker); the symbol is filled when a setting differs from its default.
    private var filterMenu: some View {
        Menu {
            ForEach(TicketStatus.allCases, id: \.self) { status in
                Toggle(status.displayName, isOn: statusBinding(status))
            }
            Divider()
            Picker("Sort", selection: $state.sort) {
                ForEach(TicketListState.Sort.allCases, id: \.self) { sort in
                    Text(sort.title)
                        .tag(sort)
                }
            }
            .pickerStyle(.menu)
        } label: {
            Image(systemName: state.isDefault
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var newTicketButton: some View {
        Button(action: onNewTicket) {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .disabled(!TicketsScreen.isConnected(store))
    }

    private func statusBinding(_ status: TicketStatus) -> Binding<Bool> {
        Binding(
            get: { state.statuses.contains(status) },
            set: { isOn in
                if isOn {
                    state.statuses.insert(status)
                } else {
                    state.statuses.remove(status)
                }
            }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let sections = state.sections(of: store.tickets)
        let bundles = state.shownBundles(of: store.bundles, tickets: store.tickets)
        if store.tickets.isEmpty {
            ContentUnavailableView {
                Text("No tickets yet")
            } actions: {
                Button("New Ticket", action: onNewTicket)
                    .disabled(!TicketsScreen.isConnected(store))
            }
        } else if sections.isEmpty && bundles.isEmpty {
            ContentUnavailableView {
                Text("No matching tickets")
            } actions: {
                Button("Clear Filter") {
                    state.reset()
                }
            }
        } else {
            List(selection: selectionBinding) {
                if !bundles.isEmpty {
                    Section {
                        ForEach(bundles) { bundle in
                            BundleRow(store: store, bundle: bundle) {
                                bundleToDelete = bundle
                            }
                            .tag(bundle.id)
                            .selectionDisabled(state.isSelecting)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Label("Bundles", systemImage: "square.stack.3d.up")
                            Text("\(bundles.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.tickets) { ticket in
                            TicketRow(store: store, ticket: ticket, bundleTicketIDs: bundleTicketIDs(for: ticket),
                                    onNewBundle: onNewBundle) {
                                ticketToDelete = ticket
                            }
                            .tag(ticket.id)
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
        }
    }

    /// The tickets of New Bundle from Selection… and Add to Bundle of a row: the selected tickets, or this ticket when it is
    /// not selected.
    private func bundleTicketIDs(for ticket: TicketItem) -> [String] {
        guard state.selectedIDs.contains(ticket.id) else { return [ticket.id] }
        return state.selectedTicketIDs(in: store.tickets)
    }

    private func isBroken(_ id: String) -> Bool {
        store.ticket(id)?.parseError != nil
    }

    /// `TicketStatusBadge` and the count; the Broken header is `exclamationmark.triangle`, "Broken" and the count.
    private func sectionHeader(_ section: TicketListSection) -> some View {
        HStack(spacing: 6) {
            switch section.kind {
            case .status(let status):
                TicketStatusBadge(status: status)
            case .broken:
                Label("Broken", systemImage: "exclamationmark.triangle")
            }
            Text("\(section.tickets.count)")
                .foregroundStyle(.secondary)
        }
    }

    /// The list's selection, `state.selectedIDs`. A change applies the rules of Multi-selection and sets
    /// `selection.item`: the id when one row is selected, else nil.
    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: { state.selectedIDs },
            set: { ids in
                let item = state.select(ids, isBroken: isBroken)
                if context.selection.item != item {
                    context.selection.item = item
                }
            }
        )
    }
}

/// The Add to Bundle menu (docs/ui/tickets.md, "Multi-selection"): the bundles in `draft` status, in the order of the
/// Bundles section; choosing one calls `updateBundle` with its tickets, then the given tickets that are not in it, by
/// ticket number. Without such a bundle it holds the disabled item "No bundle to add to".
struct AddToBundleMenu: View {
    let store: ProjectStore
    /// The tickets to add.
    let ticketIDs: [String]

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners

    var body: some View {
        let bundles = TicketListState.byLastUpdate(store.bundles, tickets: store.tickets)
            .filter(BundleScreen.canChangeTickets)
        Menu("Add to Bundle") {
            if bundles.isEmpty {
                Button("No bundle to add to") {}
                    .disabled(true)
            } else {
                ForEach(bundles) { bundle in
                    Button {
                        add(to: bundle)
                    } label: {
                        Text(verbatim: "\(bundle.name) (\(bundle.id))")
                    }
                }
            }
        }
        .disabled(ticketIDs.isEmpty || !TicketsScreen.isConnected(store))
    }

    private func add(to bundle: BundleItem) {
        let projectID = store.projectID
        let bundleID = bundle.id
        let ticketIDs = BundleScreen.ticketIDs(of: bundle, adding: ticketIDs)
        Task {
            await banners.perform {
                let connection = try TicketsScreen.connection(of: store, workspace: workspace)
                _ = try await connection.updateBundle(projectID: projectID, bundleID: bundleID,
                                                      patch: BundlePatch(ticketIDs: ticketIDs))
            }
        }
    }
}
