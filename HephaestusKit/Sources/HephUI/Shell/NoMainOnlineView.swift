import HephClient
import HephCore
import SwiftUI

/// The content of a window on a device that is not a Main while none of its connections is connected
/// (docs/ui/shell.md §10). The window shows no toolbar in this state.
struct NoMainOnlineView: View {
    @Environment(Workspace.self) private var workspace
    @State private var isDevicesPresented = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                column
                    .frame(maxWidth: 520)
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .sheet(isPresented: $isDevicesPresented) {
            NavigationStack {
                DevicesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                isDevicesPresented = false
                            }
                        }
                    }
            }
        }
    }

    private var column: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No Main online")
                    .font(.title2)
                    .bold()
                Text("Hephaestus reconnects by itself as soon as a Main is reachable.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            mainList
            HStack(spacing: 12) {
                Button("Devices…") {
                    isDevicesPresented = true
                }
                #if os(macOS)
                SettingsLink {
                    Text("Settings…")
                }
                #endif
            }
        }
    }

    @ViewBuilder
    private var mainList: some View {
        let mains = SelectionDefaults.orderedMains(workspace)
        if mains.isEmpty {
            Text("This mesh has no Main.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(mains) { record in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        PlatformIcon(platform: record.platform)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(record.name)
                                PresenceLabel(isOnline: SelectionDefaults.isOnline(record.id, workspace: workspace),
                                              lastSeen: workspace.presence[record.id]?.lastSeen)
                            }
                            Text(Self.addressLine(record))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The record's addresses joined with ", ", then " · port <port>".
    private static func addressLine(_ record: DeviceRecord) -> String {
        let port = "port \(record.port)"
        guard !record.addresses.isEmpty else { return port }
        return record.addresses.joined(separator: ", ") + " · " + port
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    NoMainOnlineView()
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
