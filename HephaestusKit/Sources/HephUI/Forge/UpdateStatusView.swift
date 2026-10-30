import Foundation
import HephClient
import HephCore
import SwiftUI
#if os(macOS)
import HephHost
#endif

/// This device's update status; also embedded in Settings ▸ Forge & Updates (macOS) (docs/ui/forge.md,
/// "UpdateStatusView"). The texts are those of docs/forge/update.md, "Statuses".
public struct UpdateStatusView: View {
    #if os(macOS)
    @Environment(UpdateModel.self) private var model
    @Environment(SettingsStore.self) private var settings
    #else
    @Environment(Workspace.self) private var workspace
    #endif

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .idle:
            Text(verbatim: "Build \(model.currentBuild).")
            if let latest = model.latestBuild, latest > model.currentBuild {
                Text(availableText(latest))
                if !model.canInstall {
                    Text("Hephaestus updates itself only when it runs from /Applications or ~/Applications. This copy "
                        + "runs from " + (model.installedAppPath as NSString).deletingLastPathComponent + ".")
                }
            } else {
                Text("Up to date.")
            }
            if let lastChecked = model.lastChecked {
                Text("Last checked " + lastChecked.formatted(.relative(presentation: .named)) + ".")
            }
            HStack(spacing: 8) {
                Button("Check Now") {
                    model.checkNow()
                }
                if !settings.settings.updates.enabled, model.canInstall,
                   let latest = model.latestBuild, latest > model.currentBuild {
                    Button("Install") {
                        model.install()
                    }
                }
            }
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
            }
        case .downloading(let build):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: "Downloading build \(build)…")
            }
        case .ready(let build):
            Text("Update ready — restarting when idle")
            Text(verbatim: "Build \(build) is installed when no Claude session, run or move is active.")
            Button("Restart Now") {
                model.restartNow()
            }
        case .installing(let build):
            Text(verbatim: "Installing build \(build). Hephaestus restarts.")
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
            Button("Check Now") {
                model.checkNow()
            }
        }
    }

    /// "Build <N> is available.", "Build <N>" linking to the release when its URL is known.
    private func availableText(_ build: Int) -> AttributedString {
        var buildText = AttributedString("Build \(build)")
        if let address = model.latestReleaseURL, let url = URL(string: address) {
            buildText.link = url
        }
        return buildText + AttributedString(" is available.")
    }
    #else
    @ViewBuilder
    private var content: some View {
        let build = workspace.device.build
        Text(verbatim: "Build \(build).")
        if workspace.forge.forgeHostID != nil, let release = workspace.forge.state?.latestRelease {
            if release.build > build {
                Text(verbatim: "Build \(release.build) is available.")
            } else {
                Text("Up to date.")
            }
        }
    }
    #endif
}
