import Foundation
import HephClient
import HephCore
import SwiftUI

/// The "Device name" field of Settings ▸ General and of the iOS settings sheet (docs/ui/settings.md,
/// "Device name"): a local name before the device belongs to a mesh, the registry name afterwards.
struct DeviceNameField: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Workspace.self) private var workspace
    @State private var text = ""
    @State private var isRenaming = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init() {}

    var body: some View {
        TextField("Device name", text: $text)
            .focused($isFocused)
            .disabled(isRenaming || needsConnection)
            .onSubmit {
                commit()
            }
            .onChange(of: isFocused) {
                if !isFocused {
                    commit()
                }
            }
            .onChange(of: appModel.identity.name, initial: true) {
                text = appModel.identity.name
            }
        if needsConnection {
            Text("Connect to a Main to rename this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// In a mesh, the name changes only through a connected Main.
    private var needsConnection: Bool {
        workspace.hasMesh && appModel.renameConnection == nil
    }

    /// Commits on Return and when the field loses focus; a name equal to the stored one writes nothing.
    private func commit() {
        guard !isRenaming else { return }
        let name = text
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != appModel.identity.name else { return }
        if workspace.hasMesh {
            guard !needsConnection else { return }
            isRenaming = true
            Task {
                do {
                    try await appModel.renameDevice(appModel.identity.id, to: name)
                    errorMessage = nil
                } catch {
                    errorMessage = Banner.message(of: error)
                    text = appModel.identity.name
                }
                isRenaming = false
            }
        } else {
            do {
                try appModel.setLocalName(name)
                errorMessage = nil
            } catch {
                errorMessage = Banner.message(of: error)
                text = appModel.identity.name
            }
        }
    }
}
