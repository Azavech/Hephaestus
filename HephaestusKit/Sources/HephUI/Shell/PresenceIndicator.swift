import HephClient
import SwiftUI

/// The number of online devices in the toolbar (docs/ui/shell.md §9.1); it shows the Devices section.
struct PresenceIndicator: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context

    var body: some View {
        let online = workspace.onlineDeviceCount
        let total = workspace.mesh?.devices.filter { !$0.revoked }.count ?? 0
        Button {
            context.select(.devices)
        } label: {
            Label("\(online)", systemImage: "laptopcomputer.and.iphone")
                .labelStyle(.titleAndIcon)
        }
        .help("\(online) of \(total) devices online")
    }
}
