#if os(macOS)
import AppKit
import Foundation
import HephClient
import HephCore
import SwiftUI

/// Settings ▸ General: this device's name and autosave, then the Main role and the Main settings
/// (docs/ui/settings.md, "General").
struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SettingsStore.self) private var settings
    @Environment(WindowBanners.self) private var banners
    /// The error message under each control, from its last write.
    @State private var errors: [Control: String] = [:]
    /// The value shown by the Main toggle while turning it on runs.
    @State private var pendingMainValue: Bool?
    @State private var isChangingMain = false
    @State private var becomeMainError: String?
    @State private var showsStopConfirmation = false
    @State private var showsMigrationAlert = false
    @State private var listenerPort = 0
    @FocusState private var isPortFocused: Bool

    private enum Control: Hashable {
        case autosave, projectsFolder, listenerPort
    }

    init() {}

    var body: some View {
        Form {
            Section("This Device") {
                DeviceNameField()
                Toggle(isOn: autosave) {
                    Text("Save edits automatically")
                    Text("Editors save 1.5 s after the last change.")
                }
                errorText(.autosave)
            }
            Section("Main") {
                Toggle(isOn: isMain) {
                    HStack(spacing: 8) {
                        Text("Use this Mac as a Main")
                        if isChangingMain {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isChangingMain)
                if appModel.identity.isMain {
                    projectsFolder
                    errorText(.projectsFolder)
                    TextField("Listener port", value: $listenerPort, format: .number.grouping(.never))
                        .focused($isPortFocused)
                        .onSubmit {
                            commitListenerPort()
                        }
                        .onChange(of: isPortFocused) {
                            if !isPortFocused {
                                commitListenerPort()
                            }
                        }
                    listenerCaption
                    errorText(.listenerPort)
                    AddressListEditor()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.settings.listenerPort, initial: true) {
            listenerPort = settings.settings.listenerPort
        }
        .task {
            // A replacement of the listener after a key change can set or clear the error.
            await appModel.refreshListenerError()
        }
        .alert("This Mac could not become a Main", isPresented: showsBecomeMainError) {
        } message: {
            Text(becomeMainError ?? "")
        }
        .alert("A project is being moved. Try again when the move has finished.", isPresented: $showsMigrationAlert) {}
        .alert("Stop using this Mac as a Main?", isPresented: $showsStopConfirmation) {
            Button("Stop", role: .destructive) {
                resignMain()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its projects stay on this Mac but other devices cannot open them until you turn this back on. "
                + "Running Claude sessions and runs are stopped.")
        }
    }

    // MARK: - Controls

    private var autosave: Binding<Bool> {
        Binding {
            settings.settings.autosave
        } set: { value in
            write(.autosave) { $0.autosave = value }
        }
    }

    private var projectsFolder: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(settings.settings.projectsFolder)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") {
                    chooseProjectsFolder()
                }
            }
        } label: {
            Text("Projects folder")
            Text("New projects and projects moved to this Mac are created here.")
        }
    }

    @ViewBuilder
    private var listenerCaption: some View {
        if let listenerError = appModel.listenerError {
            Text(listenerError)
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Text("Other devices connect to this Mac on port " + String(settings.settings.listenerPort) + ".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func errorText(_ control: Control) -> some View {
        if let message = errors[control] {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Writes

    /// Writes a key; a failure shows its message under the control, which returns to the stored value.
    @discardableResult
    private func write(_ control: Control, _ change: (inout DeviceSettings) -> Void) -> Bool {
        do {
            try settings.update(change)
            errors[control] = nil
            return true
        } catch {
            errors[control] = Banner.message(of: error)
            return false
        }
    }

    private func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.settings.projectsFolderURL
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                let path = (url.path as NSString).abbreviatingWithTildeInPath
                if path != settings.settings.projectsFolder {
                    write(.projectsFolder) { $0.projectsFolder = path }
                }
            }
        }
    }

    /// Commits the port on Return and when the field loses focus; a successful write restarts the listener.
    private func commitListenerPort() {
        let stored = settings.settings.listenerPort
        guard listenerPort != stored else { return }
        let port = listenerPort
        if write(.listenerPort, { $0.listenerPort = port }) {
            Task {
                await appModel.restartListener()
            }
        } else {
            listenerPort = stored
        }
    }

    // MARK: - Main role

    private var isMain: Binding<Bool> {
        Binding {
            pendingMainValue ?? appModel.identity.isMain
        } set: { value in
            if value {
                becomeMain()
            } else {
                requestResigningMain()
            }
        }
    }

    private var showsBecomeMainError: Binding<Bool> {
        Binding {
            becomeMainError != nil
        } set: { isPresented in
            if !isPresented {
                becomeMainError = nil
            }
        }
    }

    /// Turning it on: the toggle shows on with a spinner while the host starts; a failure turns it back off and
    /// shows the alert.
    private func becomeMain() {
        guard !isChangingMain, !appModel.identity.isMain else { return }
        pendingMainValue = true
        isChangingMain = true
        Task {
            do {
                try await appModel.becomeMain()
            } catch {
                becomeMainError = Banner.message(of: error)
            }
            pendingMainValue = nil
            isChangingMain = false
        }
    }

    /// Turning it off: refused while a project is being moved, else confirmed first; the toggle stays on meanwhile.
    private func requestResigningMain() {
        guard !isChangingMain, appModel.identity.isMain else { return }
        isChangingMain = true
        Task {
            let isMoving = await appModel.isMigrationActive()
            isChangingMain = false
            if isMoving {
                showsMigrationAlert = true
            } else {
                showsStopConfirmation = true
            }
        }
    }

    private func resignMain() {
        isChangingMain = true
        Task {
            await banners.perform {
                try await appModel.resignMain()
            }
            isChangingMain = false
        }
    }
}
#endif
