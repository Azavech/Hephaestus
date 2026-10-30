import Foundation
import HephClient
import HephCore
import SwiftUI

/// One device of the Devices list with its actions: Rename…, Revoke… and Leave Mesh… (docs/ui/devices.md, "Row").
struct DeviceRow: View {
    private let record: DeviceRecord
    private let isThisDevice: Bool
    @Environment(AppModel.self) private var appModel
    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    @State private var isRenaming = false
    @State private var isConfirmingRevoke = false
    @State private var isConfirmingLeave = false
    @State private var showsMigrationAlert = false

    init(record: DeviceRecord, isThisDevice: Bool) {
        self.record = record
        self.isThisDevice = isThisDevice
    }

    var body: some View {
        HStack(spacing: 12) {
            PlatformIcon(platform: record.platform)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.headline)
                    if isThisDevice {
                        Text("This Device")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                HStack(spacing: 0) {
                    Text(record.isMain ? "Main" : "Remote")
                    Text(" · ")
                    PresenceLabel(isOnline: presence?.online ?? false, lastSeen: presence?.lastSeen)
                    Text(" · ")
                    Text(verbatim: "Version \(record.appVersion) (\(record.build))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if record.isMain {
                    Text(addressLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contextMenu {
            actions
        }
        .sheet(isPresented: $isRenaming) {
            RenameDeviceSheet(deviceID: record.id)
        }
        .alert("Revoke “\(record.name)”?", isPresented: $isConfirmingRevoke) {
            Button("Revoke", role: .destructive) {
                revoke()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(record.name) is removed from the mesh and can no longer connect. The mesh key is replaced: the "
                + "devices connected now receive the new key and reconnect by themselves; the devices that are "
                + "offline now will have to pair again.")
        }
        .alert("Leave the mesh?", isPresented: $isConfirmingLeave) {
            Button("Leave Mesh", role: .destructive) {
                leaveMesh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device forgets the mesh key and the device list. Its record stays on the other devices until "
                + "one of them revokes it. To come back, pair it again.")
        }
        .alert("A project is being moved. Try again when the move has finished.", isPresented: $showsMigrationAlert) {}
    }

    // MARK: - Content

    private var presence: Presence? {
        workspace.presence[record.id]
    }

    /// The addresses joined with ", " then " · port <port>"; "No address" without addresses.
    private var addressLine: String {
        guard !record.addresses.isEmpty else { return "No address" }
        return record.addresses.joined(separator: ", ") + " · port \(record.port)"
    }

    @ViewBuilder
    private var actions: some View {
        Button("Rename…") {
            isRenaming = true
        }
        .disabled(appModel.renameConnection == nil)
        if !isThisDevice {
            Button("Revoke…") {
                isConfirmingRevoke = true
            }
            .disabled(revokingConnection == nil)
        }
        if isThisDevice {
            Button("Leave Mesh…") {
                beginLeavingMesh()
            }
        }
    }

    // MARK: - Revoke

    /// The local connection when it is connected, else the first connected Main other than this row's device
    /// (docs/ui/devices.md, "Revoke").
    private var revokingConnection: MainConnection? {
        if let local = workspace.localConnection, local.isConnected {
            return local
        }
        for main in workspace.mains where main.id != record.id {
            if let connection = workspace.connection(main.id), connection.isConnected {
                return connection
            }
        }
        return nil
    }

    private func revoke() {
        let deviceID = record.id
        Task {
            await banners.perform {
                guard let connection = revokingConnection else {
                    throw ProtocolError(.unavailable, "No Main is online.")
                }
                try await connection.revokeDevice(deviceID)
            }
        }
    }

    // MARK: - Leave mesh

    /// On a Main, refused while a project is being moved; otherwise the confirmation alert.
    private func beginLeavingMesh() {
        #if os(macOS)
        if appModel.identity.isMain {
            Task {
                if await appModel.isMigrationActive() {
                    showsMigrationAlert = true
                } else {
                    isConfirmingLeave = true
                }
            }
            return
        }
        #endif
        isConfirmingLeave = true
    }

    private func leaveMesh() {
        Task {
            await banners.perform {
                try await appModel.leaveMesh()
            }
        }
    }
}
