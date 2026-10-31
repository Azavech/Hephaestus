import Foundation
import HephClient
import HephCore
import SwiftUI

/// The Pipeline section of the Forge screen: the action button, the cycle and the feedback items
/// (docs/ui/forge.md, "Pipeline").
struct ForgePipelineSection: View {
    private let state: ForgeState
    private let hostID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    @State private var isRegenerating = false
    @State private var retryingTicketIDs: Set<String> = []

    init(state: ForgeState, hostID: UUID) {
        self.state = state
        self.hostID = hostID
    }

    var body: some View {
        Section("Pipeline") {
            actionRow
            if let cycle = state.cycle {
                cycleRows(cycle)
            }
            if state.items.isEmpty {
                Text("No feedback yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.items) { item in
                    itemRow(item)
                }
            }
        }
    }

    // MARK: - Action

    private var actionRow: some View {
        let stage = state.cycle?.state
        let isActive = stage.map { Self.activeStages.contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                regenerate()
            } label: {
                HStack(spacing: 6) {
                    if isRegenerating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(stage == .failed ? "Retry" : "Regenerate Now")
                }
            }
            .disabled(isActive || isRegenerating)
            if let lastError = state.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Cycle

    @ViewBuilder
    private func cycleRows(_ cycle: ForgeCycle) -> some View {
        HStack(spacing: 8) {
            Self.badge(cycle.state)
            Text(Self.triggerText(cycle.trigger))
            Text("started " + cycle.started.formatted(.relative(presentation: .named)))
                .foregroundStyle(.secondary)
            if cycle.attempts > 1 {
                Text(verbatim: "Attempt \(cycle.attempts)")
                    .foregroundStyle(.secondary)
            }
        }
        if let sessionID = cycle.sessionID {
            LabeledContent("Regeneration session") {
                Button("Open Session") {
                    openSession(sessionID)
                }
            }
        }
        if cycle.attempts == 0, cycle.regenCommit != nil {
            Text("No regeneration needed: docs and code were in sync.")
        }
        if let regenCommit = cycle.regenCommit {
            LabeledContent("Built commit") {
                Text(ForgeView.commitText(regenCommit, repository: repository))
            }
        }
        if cycle.state == .failed, let error = cycle.error {
            Text(error)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Items

    private func itemRow(_ item: ForgeItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.ticketID)
                        .monospaced()
                    Text(item.title)
                    Spacer(minLength: 0)
                    Self.badge(item.state)
                }
                Text(itemDetails(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.state == .failed, let error = item.error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            itemActions(item)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            context.selection.item = item.ticketID
        }
        .listRowBackground(context.selection.item == item.ticketID ? Color.accentColor.opacity(0.2) : nil)
    }

    /// "docs <sha8>" when the item has a docs commit, then "updated <relative>".
    private func itemDetails(_ item: ForgeItem) -> AttributedString {
        var details = AttributedString()
        if let docsCommit = item.docsCommit {
            details += AttributedString("docs ") + ForgeView.commitText(docsCommit, repository: repository)
                + AttributedString(" · ")
        }
        details += AttributedString("updated " + item.updated.formatted(.relative(presentation: .named)))
        return details
    }

    @ViewBuilder
    private func itemActions(_ item: ForgeItem) -> some View {
        if context.isCompact {
            Menu {
                itemActionButtons(item)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            HStack(spacing: 8) {
                itemActionButtons(item)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func itemActionButtons(_ item: ForgeItem) -> some View {
        Button("Open Ticket") {
            context.navigate(mainDeviceID: hostID, projectID: item.projectID, section: .tickets, item: item.ticketID)
        }
        Button("Open Discussion") {
            context.navigate(mainDeviceID: hostID, projectID: item.projectID, section: .claude,
                             item: item.feedbackSessionID.uuidString)
        }
        if item.state == .failed {
            Button("Retry") {
                retry(item.ticketID)
            }
            .disabled(retryingTicketIDs.contains(item.ticketID))
        }
    }

    // MARK: - Requests

    private var forge: ForgeModel {
        workspace.forge
    }

    /// The Forge host's configuration.
    private var config: ForgeConfig? {
        forge.forgeConfigs[hostID] ?? state.config
    }

    private var repository: String? {
        config?.repository
    }

    private func regenerate() {
        isRegenerating = true
        let forge = forge
        Task {
            await banners.perform {
                try await forge.regenerate()
            }
            isRegenerating = false
        }
    }

    private func retry(_ ticketID: String) {
        retryingTicketIDs.insert(ticketID)
        let forge = forge
        Task {
            await banners.perform {
                try await forge.retry(itemTicketID: ticketID)
            }
            retryingTicketIDs.remove(ticketID)
        }
    }

    private func openSession(_ sessionID: UUID) {
        context.navigate(mainDeviceID: hostID, projectID: config?.sourceProjectID, section: .claude,
                         item: sessionID.uuidString)
    }

    // MARK: - Labels

    /// The states of an active cycle.
    private static let activeStages: Set<ForgeStage> = [.regenerating, .regenPushed, .building, .released]

    private static func triggerText(_ trigger: ForgeTrigger) -> String {
        switch trigger {
        case .tool: return "Started when docs were pushed"
        case .manual: return "Started with Regenerate Now"
        case .automatic: return "Started automatically: docs ahead of the code"
        }
    }

    /// The state badge: a capsule with the state's text on its color.
    static func badge(_ stage: ForgeStage) -> some View {
        Text(badgeTitle(stage))
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(badgeColor(stage), in: Capsule())
    }

    private static func badgeTitle(_ stage: ForgeStage) -> String {
        switch stage {
        case .discussing: return "Discussing"
        case .docsPushed: return "Docs pushed"
        case .regenerating: return "Regenerating"
        case .regenPushed: return "Regeneration pushed"
        case .building: return "Building"
        case .released: return "Released"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    private static func badgeColor(_ stage: ForgeStage) -> Color {
        switch stage {
        case .discussing: return .gray
        case .docsPushed: return .blue
        case .regenerating, .regenPushed, .building: return .orange
        case .released, .done: return .green
        case .failed: return .red
        }
    }
}
