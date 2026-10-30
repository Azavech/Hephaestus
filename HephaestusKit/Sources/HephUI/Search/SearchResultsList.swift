import Foundation
import HephClient
import HephCore
import SwiftUI

/// The results of a search grouped by kind (docs/ui/search.md, "Results"). With a highlight binding (the palette) it
/// is a lazy stack with pinned headers, to be placed in a ScrollView; without one (the search screen) it is the
/// sections of a List.
struct SearchResultsList: View {
    private let model: SearchModel
    private let highlighted: Binding<Int>?
    private let onOpen: (SearchResult) -> Void

    init(model: SearchModel, highlighted: Binding<Int>?, onOpen: @escaping (SearchResult) -> Void) {
        self.model = model
        self.highlighted = highlighted
        self.onOpen = onOpen
    }

    var body: some View {
        let groups = Self.groups(model.results)
        if let highlighted {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            paletteRow(row, highlighted: highlighted)
                        }
                    } header: {
                        header(group)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                    }
                }
            }
        } else {
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        Button {
                            onOpen(row.result)
                        } label: {
                            SearchResultRow(result: row.result, model: model, isHighlighted: false)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    header(group)
                }
            }
        }
    }

    private func paletteRow(_ row: ResultRow, highlighted: Binding<Int>) -> some View {
        Button {
            onOpen(row.result)
        } label: {
            SearchResultRow(result: row.result, model: model, isHighlighted: highlighted.wrappedValue == row.index)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(row.index)
        #if os(macOS)
        .onHover { isInside in
            if isInside {
                highlighted.wrappedValue = row.index
            }
        }
        #endif
    }

    private func header(_ group: ResultGroup) -> some View {
        HStack(spacing: 4) {
            Text(Self.title(of: group.kind))
            Text(String(group.rows.count))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    // MARK: - Groups

    /// The results of one kind, in the model's order; each row carries its index in display order.
    struct ResultGroup: Identifiable {
        let kind: SearchScope
        let rows: [ResultRow]
        var id: SearchScope { kind }
    }

    struct ResultRow: Identifiable {
        let index: Int
        let result: SearchResult
        var id: Int { index }
    }

    /// The groups in `SearchScope.allCases` order; a kind without results has no group.
    static func groups(_ results: [SearchResult]) -> [ResultGroup] {
        var groups: [ResultGroup] = []
        var index = 0
        for kind in SearchScope.allCases {
            var rows: [ResultRow] = []
            for result in results where result.kind == kind {
                rows.append(ResultRow(index: index, result: result))
                index += 1
            }
            if !rows.isEmpty {
                groups.append(ResultGroup(kind: kind, rows: rows))
            }
        }
        return groups
    }

    /// The results in display order: groups in order, then rows in their group's order.
    static func displayOrder(_ results: [SearchResult]) -> [SearchResult] {
        groups(results).flatMap { group in group.rows.map(\.result) }
    }

    static func title(of kind: SearchScope) -> String {
        switch kind {
        case .projects: return "Projects"
        case .tasks: return "Tasks"
        case .comments: return "Comments"
        case .docs: return "Docs"
        case .code: return "Code"
        case .skills: return "Skills"
        case .webTabs: return "Web Tabs"
        case .sessions: return "Sessions"
        case .devices: return "Devices"
        }
    }

    static func symbol(of kind: SearchScope) -> String {
        switch kind {
        case .projects: return "folder"
        case .tasks: return "checklist"
        case .comments: return "text.bubble"
        case .docs: return "book.closed"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .skills: return "wand.and.stars"
        case .webTabs: return "globe"
        case .sessions: return "bubble.left.and.bubble.right"
        case .devices: return "laptopcomputer.and.iphone"
        }
    }

    // MARK: - States

    /// What is shown instead of the results (docs/ui/search.md, "States").
    enum EmptyReason: Equatable {
        case prompt
        case noMainOnline
        case searching
        case noResults(String)
    }

    /// The first state that applies; nil when the results are shown.
    @MainActor
    static func emptyReason(model: SearchModel, workspace: Workspace) -> EmptyReason? {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return .prompt
        }
        if !workspace.connections.values.contains(where: { $0.isConnected }) {
            return .noMainOnline
        }
        if model.results.isEmpty {
            return model.isSearching ? .searching : .noResults(text)
        }
        return nil
    }

    /// A state, centered and secondary.
    struct StateMessage: View {
        let reason: EmptyReason

        var body: some View {
            Group {
                switch reason {
                case .prompt:
                    Text("Search projects, tasks, comments, docs, code, skills, web tabs, sessions and devices.")
                case .noMainOnline:
                    Text("No Main is online.")
                case .searching:
                    ProgressView()
                case .noResults(let text):
                    Text("No results for “\(text)”")
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One orange caption line per Main that failed the current search, sorted by Main name.
    struct FailureLines: View {
        let model: SearchModel
        @Environment(Workspace.self) private var workspace

        /// A Main that did not answer, with its name and the error's message.
        private struct Failure: Identifiable {
            let id: UUID
            let name: String
            let message: String
        }

        var body: some View {
            let failures = model.failures
                .map { mainDeviceID, message in
                    Failure(id: mainDeviceID, name: SearchResultRow.mainName(mainDeviceID, in: workspace),
                            message: message)
                }
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
            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(failures) { failure in
                        Text(verbatim: "\(failure.name) did not answer: \(failure.message)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
