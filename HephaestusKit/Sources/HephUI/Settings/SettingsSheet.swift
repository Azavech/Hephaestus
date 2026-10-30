#if os(iOS)
import Foundation
import HephClient
import HephCore
import SwiftUI

/// The settings of iOS and iPadOS, presented by the Settings button of the Devices screen (docs/ui/settings.md,
/// "iOS and iPadOS: SettingsSheet").
public struct SettingsSheet: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var autosaveError: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("This Device") {
                    DeviceNameField()
                    Toggle(isOn: autosave) {
                        Text("Save edits automatically")
                        Text("Editors save 1.5 s after the last change.")
                    }
                    if let autosaveError {
                        Text(autosaveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                AboutSection()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var autosave: Binding<Bool> {
        Binding {
            settings.settings.autosave
        } set: { value in
            do {
                try settings.update { $0.autosave = value }
                autosaveError = nil
            } catch {
                autosaveError = Banner.message(of: error)
            }
        }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    SettingsSheet()
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
#endif
