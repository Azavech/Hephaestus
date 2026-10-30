import Foundation
import HephClient
import HephCore
import SwiftUI

/// The Devices section; also the Devices tab of the macOS Settings (docs/ui/devices.md, "Device list").
public struct DevicesView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Workspace.self) private var workspace
    @Environment(Selection.self) private var selection
    /// The list's selection when the window's section is not Devices (Settings tab, the sheet of "No Main online").
    @State private var selectedID: String?
    @State private var pairingTarget: PairingTarget?
    #if os(iOS)
    @State private var showsSettings = false
    #endif

    public init() {}

    public var body: some View {
        content
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    pairButton
                }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                #endif
            }
            .sheet(item: $pairingTarget) { target in
                PairingCodeSheet(mainDeviceID: target.id)
            }
            #if os(iOS)
            .sheet(isPresented: $showsSettings) {
                SettingsSheet()
            }
            #endif
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if let mesh = workspace.mesh {
            let records = mesh.devices.filter { !$0.revoked }
            let mains = ordered(records.filter(\.isMain))
            let remotes = ordered(records.filter { !$0.isMain })
            ScrollViewReader { proxy in
                List(selection: listSelection) {
                    if !mains.isEmpty {
                        Section("Mains") {
                            rows(mains)
                        }
                    }
                    if !remotes.isEmpty {
                        Section("Remotes") {
                            rows(remotes)
                        }
                    }
                }
                .onAppear {
                    scrollToSelectedItem(proxy)
                }
                .onChange(of: selection.item) {
                    scrollToSelectedItem(proxy)
                }
            }
        } else {
            EmptyStateView(symbol: "laptopcomputer.and.iphone", title: "No devices")
        }
    }

    private func rows(_ records: [DeviceRecord]) -> some View {
        ForEach(records, id: \.id.uuidString) { record in
            DeviceRow(record: record, isThisDevice: record.id == workspace.device.id)
                .tag(record.id.uuidString)
        }
    }

    /// While the window's section is Devices, the list selects `selection.item`; otherwise it keeps its own selection.
    private var listSelection: Binding<String?> {
        Binding {
            selection.section == .devices ? selection.item : selectedID
        } set: { newValue in
            if selection.section == .devices {
                selection.item = newValue
            } else {
                selectedID = newValue
            }
        }
    }

    /// An item set from elsewhere (search) scrolls to its row.
    private func scrollToSelectedItem(_ proxy: ScrollViewProxy) {
        guard selection.section == .devices, let item = selection.item else { return }
        proxy.scrollTo(item)
    }

    /// This device first, then by name.
    private func ordered(_ records: [DeviceRecord]) -> [DeviceRecord] {
        let thisDevice = workspace.device.id
        return records.sorted { lhs, rhs in
            if (lhs.id == thisDevice) != (rhs.id == thisDevice) {
                return lhs.id == thisDevice
            }
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    // MARK: - Pairing

    /// "Pair a New Device…" (docs/ui/devices.md, "Toolbar").
    @ViewBuilder
    private var pairButton: some View {
        if appModel.identity.isMain {
            Button {
                pairingTarget = PairingTarget(id: workspace.device.id)
            } label: {
                pairLabel
            }
        } else {
            let connected = workspace.mains.filter { workspace.connection($0.id)?.isConnected == true }
            if connected.isEmpty {
                Button {} label: {
                    pairLabel
                }
                .disabled(true)
                .help("No Main is online.")
            } else if connected.count == 1, let main = connected.first {
                Button {
                    pairingTarget = PairingTarget(id: main.id)
                } label: {
                    pairLabel
                }
            } else {
                Menu {
                    ForEach(connected) { main in
                        Button(main.name) {
                            pairingTarget = PairingTarget(id: main.id)
                        }
                    }
                } label: {
                    pairLabel
                }
            }
        }
    }

    private var pairLabel: some View {
        Label("Pair a New Device…", systemImage: "plus")
    }

    /// The Main whose pairing window the sheet opens.
    private struct PairingTarget: Identifiable {
        let id: UUID
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    DevicesView()
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, section: .devices))
}
