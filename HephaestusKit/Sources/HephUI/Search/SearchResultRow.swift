import Foundation
import HephClient
import HephCore
import SwiftUI

/// One search result (docs/ui/search.md, "Row"): the kind's symbol, then the title, the location and the snippet.
struct SearchResultRow: View {
    private let result: SearchResult
    private let model: SearchModel
    private let isHighlighted: Bool
    @Environment(Workspace.self) private var workspace

    init(result: SearchResult, model: SearchModel, isHighlighted: Bool) {
        self.result = result
        self.model = model
        self.isHighlighted = isHighlighted
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: SearchResultsList.symbol(of: result.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(SearchHighlighting.attributed(result.title, ranges: model.highlights(in: result.title)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                location
                if !result.snippet.isEmpty {
                    Text(SearchHighlighting.attributed(result.snippet, ranges: model.highlights(in: result.snippet)))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.2))
            }
        }
    }

    @ViewBuilder
    private var location: some View {
        if result.kind == .devices {
            let presence = UUID(uuidString: result.itemID).flatMap { workspace.presence[$0] }
            PresenceLabel(isOnline: presence?.online ?? false, lastSeen: presence?.lastSeen)
        } else {
            Text(locationText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// "<Main>", "<Main> ▸ <project>" or "<Main> ▸ <project> ▸ <path>", by kind.
    private var locationText: String {
        let main = Self.mainName(result.deviceID, in: workspace)
        switch result.kind {
        case .projects, .skills, .devices:
            return main
        case .tickets, .comments, .webTabs, .sessions:
            return "\(main) ▸ \(projectName)"
        case .docs, .code:
            var parts = [main, projectName]
            if let path = result.path {
                parts.append(path)
            }
            return parts.joined(separator: " ▸ ")
        }
    }

    /// The project's name in its Main's tree, else its identifier.
    private var projectName: String {
        guard let projectID = result.projectID else { return "" }
        return workspace.summary(of: projectID, on: result.deviceID)?.name ?? projectID
    }

    /// The name of a Main: its connection's name, else its registry name, else "Unknown Main".
    @MainActor
    static func mainName(_ mainDeviceID: UUID, in workspace: Workspace) -> String {
        if let connection = workspace.connection(mainDeviceID) {
            return connection.name
        }
        return workspace.mesh?.devices.first { $0.id == mainDeviceID }?.name ?? "Unknown Main"
    }
}
