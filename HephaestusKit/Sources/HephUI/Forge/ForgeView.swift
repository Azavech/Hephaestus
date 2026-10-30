import Foundation
import HephClient
import HephCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Forge section content: the Forge host, the docs hashes, the pipeline, CI, the latest release, the versions of
/// the devices and this device's update status (docs/ui/forge.md, "Screen").
public struct ForgeView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    @Environment(\.openURL) private var openURL

    public init() {}

    public var body: some View {
        let forge: ForgeModel = workspace.forge
        let hostID = forge.forgeHostID
        Form {
            forgeSection(forge, hostID: hostID)
            docsHashesSection(forge, hostID: hostID)
            if let hostID {
                if let state = forge.state {
                    ForgePipelineSection(state: state, hostID: hostID)
                    ciRunSection(state)
                    latestReleaseSection(state)
                } else {
                    loadingSection("Pipeline", forge)
                    loadingSection("CI Run", forge)
                    loadingSection("Latest Release", forge)
                }
            }
            devicesSection(forge)
            #if os(macOS)
            Section("This Mac") {
                UpdateStatusView()
            }
            #else
            Section("This Device") {
                UpdateStatusView()
            }
            #endif
        }
        .formStyle(.grouped)
        .task {
            await forge.refresh()
        }
    }

    // MARK: - Forge

    @ViewBuilder
    private func forgeSection(_ forge: ForgeModel, hostID: UUID?) -> some View {
        if let hostID, let config = forge.forgeConfigs[hostID] {
            let hostName = mainName(hostID)
            Section {
                LabeledContent("Forge host") {
                    HStack(spacing: 6) {
                        StatusDot(isOnline: true)
                        Text(hostName)
                    }
                }
                LabeledContent("Source project") {
                    HStack(spacing: 6) {
                        Text(config.sourceProjectID)
                        if let project = workspace.summary(of: config.sourceProjectID, on: hostID) {
                            Text(project.name)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Repository") {
                    if let url = URL(string: "https://github.com/" + config.repository) {
                        Link(config.repository, destination: url)
                    } else {
                        Text(config.repository)
                    }
                }
                LabeledContent("Branch", value: config.branch)
                LabeledContent("Regenerate automatically", value: config.autoRegenerate ? "On" : "Off")
                if forge.forgeHostIDs.count > 1 {
                    Text("Several Mains are set as the Forge: "
                        + forge.forgeHostIDs.map { mainName($0) }.joined(separator: ", ")
                        + ". Feedback goes to " + hostName + ".")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Forge")
            } footer: {
                Text("Change the source project, the branch and automatic regeneration in Settings ▸ Forge & Updates "
                    + "on " + hostName + ".")
                    .font(.caption)
            }
        } else {
            Section("Forge") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Forge online")
                        .font(.headline)
                    Text("The Forge is the Main where “Set as Forge” is on in Settings ▸ Forge & Updates.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Docs hashes

    private func docsHashesSection(_ forge: ForgeModel, hostID: UUID?) -> some View {
        Section("Docs Hashes") {
            LabeledContent("This app") {
                hashText(DocsHash.embedded)
            }
            if hostID != nil, let state = forge.state {
                LabeledContent("Forge app") {
                    hashText(state.appDocsHash)
                }
                let branch = (state.config ?? hostID.flatMap { forge.forgeConfigs[$0] })?.branch ?? ""
                let repository = (state.config ?? hostID.flatMap { forge.forgeConfigs[$0] })?.repository
                LabeledContent("Docs at origin/" + branch) {
                    if let head = state.head {
                        VStack(alignment: .trailing, spacing: 2) {
                            hashText(head.docsHash)
                            Text(AttributedString("commit ") + Self.commitText(head.commit, repository: repository)
                                + AttributedString(" · checked "
                                    + head.checkedAt.formatted(.relative(presentation: .named))))
                                .font(.caption)
                        }
                    } else {
                        Text("Not checked yet")
                    }
                }
                if let head = state.head {
                    LabeledContent("Code (App/DocsHash.txt)") {
                        if head.codeDocsHash.isEmpty {
                            Text("missing")
                        } else {
                            hashText(head.codeDocsHash)
                        }
                    }
                    LabeledContent("Status") {
                        if head.docsHash == head.codeDocsHash {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.green)
                                Text("In sync")
                            }
                        } else {
                            Text("Docs ahead of the code")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    /// The first 12 characters, monospaced; Copy copies the full value.
    private func hashText(_ value: String) -> some View {
        Text(String(value.prefix(12)))
            .monospaced()
            .contextMenu {
                Button("Copy") {
                    Self.copy(value)
                }
            }
    }

    // MARK: - CI run and release

    private func ciRunSection(_ state: ForgeState) -> some View {
        Section("CI Run") {
            if let run = state.cycle?.run {
                LabeledContent("Run", value: "#" + String(run.number))
                LabeledContent("Status", value: Self.runStatus(run))
                LabeledContent("Commit") {
                    Text(Self.commitText(run.headSHA, repository: (state.config ?? workspace.forge.forgeConfigs[
                        state.hostDeviceID])?.repository))
                }
                if let url = URL(string: run.url) {
                    Button("Open Run") {
                        openURL(url)
                    }
                }
            } else {
                Text("No CI run yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func latestReleaseSection(_ state: ForgeState) -> some View {
        Section("Latest Release") {
            if let release = state.latestRelease {
                LabeledContent("build-" + String(release.build),
                               value: "published " + release.publishedAt.formatted(.relative(presentation: .named)))
                if let url = URL(string: release.url) {
                    Button("Open Release") {
                        openURL(url)
                    }
                }
            } else {
                Text("No release yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One row while the state of the Forge host has not arrived: Loading…, or the load error.
    private func loadingSection(_ title: String, _ forge: ForgeModel) -> some View {
        Section(title) {
            if let loadError = forge.loadError {
                Text(loadError)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                }
            }
        }
    }

    // MARK: - Devices

    private func devicesSection(_ forge: ForgeModel) -> some View {
        let devices = (workspace.mesh?.devices ?? [])
            .filter { !$0.revoked }
            .sorted { lhs, rhs in
                switch lhs.name.localizedStandardCompare(rhs.name) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            }
        let latestRelease = forge.state?.latestRelease
        return Section("Devices") {
            ForEach(devices) { device in
                let presence = workspace.presence[device.id]
                HStack(spacing: 8) {
                    PlatformIcon(platform: device.platform)
                    Text(device.name)
                    Text(device.isMain ? "Main" : "Remote")
                        .foregroundStyle(.secondary)
                    PresenceLabel(isOnline: presence?.online ?? false, lastSeen: presence?.lastSeen)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: "\(device.appVersion) (\(device.build))")
                        if let latestRelease, device.build < latestRelease.build {
                            Text(verbatim: "Build \(latestRelease.build) available")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func mainName(_ mainDeviceID: UUID) -> String {
        if let connection = workspace.connection(mainDeviceID) {
            return connection.name
        }
        return workspace.mesh?.devices.first { $0.id == mainDeviceID }?.name ?? "Main"
    }

    /// The first 8 characters of a commit, linking to the commit on GitHub when the repository is known.
    static func commitText(_ sha: String, repository: String?) -> AttributedString {
        var text = AttributedString(String(sha.prefix(8)))
        if let repository, let url = URL(string: "https://github.com/\(repository)/commit/\(sha)") {
            text.link = url
        }
        return text
    }

    /// The run status as the CI Run section words it.
    private static func runStatus(_ run: ForgeRun) -> String {
        switch run.status {
        case "queued":
            return "Queued"
        case "in_progress":
            return "In progress"
        case "completed":
            if run.conclusion == "success" {
                return "Succeeded"
            }
            if let conclusion = run.conclusion {
                return "Failed (\(conclusion))"
            }
            return "Failed"
        default:
            return run.status
        }
    }

    private static func copy(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    ForgeView()
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, section: .forge))
}
