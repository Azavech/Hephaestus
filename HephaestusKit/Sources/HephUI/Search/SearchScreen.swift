import Foundation
import HephClient
import HephCore
import SwiftUI

/// The search screen of compact width, the content of the `.search` sheet of MainShell (docs/ui/search.md,
/// "Search screen (compact)").
public struct SearchScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var model: SearchModel?
    @FocusState private var isSearchFocused: Bool

    public init() {}

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
                #if os(iOS)
                .searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
                #else
                .searchable(text: text, prompt: "Search")
                #endif
                .searchFocused($isSearchFocused)
                .onSubmit(of: .search) {
                    model?.searchNow()
                }
                .safeAreaInset(edge: .top) {
                    SearchScopeBar(scopes: scopes)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
        }
        .onAppear {
            if model == nil {
                model = SearchModel(workspace: workspace)
            }
            isSearchFocused = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            if let reason = SearchResultsList.emptyReason(model: model, workspace: workspace) {
                VStack(spacing: 8) {
                    SearchResultsList.StateMessage(reason: reason)
                    SearchResultsList.FailureLines(model: model)
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 16)
            } else {
                List {
                    SearchResultsList(model: model, highlighted: nil) { result in
                        open(result)
                    }
                    if !model.failures.isEmpty {
                        Section {
                            SearchResultsList.FailureLines(model: model)
                        }
                    }
                }
            }
        } else {
            Color.clear
        }
    }

    private var text: Binding<String> {
        Binding(get: { model?.text ?? "" }, set: { model?.text = $0 })
    }

    private var scopes: Binding<Set<SearchScope>> {
        Binding(get: { model?.scopes ?? [] }, set: { model?.scopes = $0 })
    }

    /// Opens the result, which dismisses the sheet.
    private func open(_ result: SearchResult) {
        SearchNavigation.open(result, in: context)
        dismiss()
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    SearchScreen()
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
