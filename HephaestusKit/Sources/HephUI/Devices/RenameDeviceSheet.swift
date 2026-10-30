import Foundation
import HephClient
import HephCore
import SwiftUI

/// Renames a device of the mesh (docs/ui/devices.md, "Rename").
struct RenameDeviceSheet: View {
    private let deviceID: UUID
    @Environment(AppModel.self) private var appModel
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isRenaming = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    init(deviceID: UUID) {
        self.deviceID = deviceID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Rename \(currentName)")
                .font(.headline)
            TextField("Name", text: $name)
                .focused($isNameFocused)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    rename()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRename)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 360)
        #endif
        .onAppear {
            name = currentName
            isNameFocused = true
        }
    }

    /// The name of the device's record in `workspace.mesh`.
    private var currentName: String {
        workspace.mesh?.devices.first(where: { $0.id == deviceID })?.name ?? ""
    }

    private var canRename: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != currentName && !isRenaming
    }

    private func rename() {
        guard canRename else { return }
        let newName = name
        isRenaming = true
        errorMessage = nil
        Task {
            do {
                try await appModel.renameDevice(deviceID, to: newName)
                isRenaming = false
                dismiss()
            } catch {
                isRenaming = false
                errorMessage = Banner.message(of: error)
            }
        }
    }
}
