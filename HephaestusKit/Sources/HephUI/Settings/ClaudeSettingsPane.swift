#if os(macOS)
import AppKit
import Foundation
import HephClient
import HephCore
import SwiftUI

/// Settings ▸ Claude: the CLI path and status, the defaults of new sessions and the idle timeout (docs/ui/settings.md,
/// "Claude").
struct ClaudeSettingsPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Workspace.self) private var workspace
    @Environment(SettingsStore.self) private var settings
    @State private var path = ""
    @State private var model = ""
    @State private var isRefreshing = false
    /// The error message under each control, from its last write.
    @State private var errors: [Control: String] = [:]
    @FocusState private var isPathFocused: Bool

    private enum Control: Hashable {
        case path, model, permissionMode, idleMinutes
    }

    /// The idle choices: minutes and title.
    private static let idleChoices: [(minutes: Int, title: String)] = [
        (5, "5 minutes"), (10, "10 minutes"), (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"),
        (120, "2 hours"), (240, "4 hours"),
    ]

    init() {}

    var body: some View {
        if appModel.identity.isMain {
            form
        } else {
            EmptyStateView(symbol: "desktopcomputer", title: "This Mac is not a Main",
                           message: "Claude runs on Mains. Turn on “Use this Mac as a Main” in General.")
        }
    }

    private var form: some View {
        Form {
            Section("Claude CLI") {
                LabeledContent("Path") {
                    HStack(spacing: 8) {
                        TextField("Path", text: $path, prompt: Text("Automatic"))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .focused($isPathFocused)
                            .onSubmit {
                                commitPath()
                            }
                        Button("Choose…") {
                            choosePath()
                        }
                    }
                }
                .onChange(of: isPathFocused) {
                    if !isPathFocused {
                        commitPath()
                    }
                }
                errorText(.path)
                LabeledContent("Status") {
                    status
                }
            }
            Section {
                LabeledContent("Default model") {
                    ClaudeModelField(model: $model, placeholder: "CLI Default") {
                        commitModel()
                    }
                }
                errorText(.model)
                LabeledContent("Default permission mode") {
                    PermissionModePicker(selection: permissionMode, defaultLabel: nil)
                }
                errorText(.permissionMode)
            } header: {
                Text("New Sessions")
            } footer: {
                Text("Used for new sessions of projects that set no model or permission mode.")
            }
            Section("Idle Sessions") {
                Picker("Stop idle Claude processes after", selection: idleMinutes) {
                    ForEach(Self.idleChoices, id: \.minutes) { choice in
                        Text(choice.title)
                            .tag(choice.minutes)
                    }
                    let stored = settings.settings.sessionIdleMinutes
                    if !Self.idleChoices.contains(where: { $0.minutes == stored }) {
                        Text(String(stored) + " minutes")
                            .tag(stored)
                    }
                }
                .pickerStyle(.menu)
                errorText(.idleMinutes)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.settings.claudePath, initial: true) {
            path = settings.settings.claudePath
        }
        .onChange(of: settings.settings.defaultModel, initial: true) {
            model = settings.settings.defaultModel
        }
        .task {
            await refreshStatus()
        }
    }

    /// The CLI status from this Mac's host info.
    private var status: some View {
        HStack(spacing: 6) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            if let info = workspace.localConnection?.hostInfo {
                if info.claudeAvailable {
                    StatusDot(isOnline: true)
                    Text("Using " + info.claudePath)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                } else {
                    StatusDot(isOnline: false)
                    Text("Claude CLI not found. Install it or enter its path.")
                        .foregroundStyle(.red)
                }
            }
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

    // MARK: - Bindings

    private var permissionMode: Binding<PermissionMode?> {
        Binding {
            settings.settings.defaultPermissionMode
        } set: { mode in
            guard let mode, mode != settings.settings.defaultPermissionMode else { return }
            write(.permissionMode) { $0.defaultPermissionMode = mode }
        }
    }

    private var idleMinutes: Binding<Int> {
        Binding {
            settings.settings.sessionIdleMinutes
        } set: { minutes in
            guard minutes != settings.settings.sessionIdleMinutes else { return }
            write(.idleMinutes) { $0.sessionIdleMinutes = minutes }
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

    /// Commits the path on Return and when the field loses focus; each write refreshes the status.
    private func commitPath() {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != settings.settings.claudePath else {
            path = settings.settings.claudePath
            return
        }
        storePath(value)
    }

    private func storePath(_ value: String) {
        if write(.path, { $0.claudePath = value }) {
            Task {
                await refreshStatus()
            }
        } else {
            path = settings.settings.claudePath
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: ("~/.local/bin" as NSString).expandingTildeInPath,
                                 isDirectory: true)
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                let value = (url.path as NSString).abbreviatingWithTildeInPath
                guard value != settings.settings.claudePath else { return }
                storePath(value)
            }
        }
    }

    /// The model commits its trimmed text; empty means no model.
    private func commitModel() {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != settings.settings.defaultModel else {
            model = settings.settings.defaultModel
            return
        }
        if !write(.model, { $0.defaultModel = value }) {
            model = settings.settings.defaultModel
        }
    }

    /// `host.info` of this Mac again, with a spinner meanwhile.
    private func refreshStatus() async {
        guard let connection = workspace.localConnection else { return }
        isRefreshing = true
        await connection.refreshHostInfo()
        isRefreshing = false
    }
}
#endif
