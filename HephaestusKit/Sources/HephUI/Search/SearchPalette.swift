import Foundation
import HephClient
import HephCore
import SwiftUI

/// The search palette of regular width, shown by MainShell over the whole window while `context.isSearchPresented`
/// is true (docs/ui/search.md, "Search palette (regular)").
public struct SearchPalette: View {
    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @State private var model: SearchModel?
    /// The highlighted result, an index in display order.
    @State private var highlighted = 0
    /// The height of the results, measured; the scroll view is at most 420 pt high.
    @State private var resultsHeight: CGFloat = 420
    @FocusState private var isFieldFocused: Bool

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .onTapGesture {
                        close()
                    }
                if let model {
                    panel(model)
                        .frame(width: max(0, min(640, geometry.size.width - 32)))
                        .padding(.top, 72)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .onAppear {
            if model == nil {
                model = SearchModel(workspace: workspace)
            }
        }
    }

    private func panel(_ model: SearchModel) -> some View {
        VStack(spacing: 0) {
            fieldRow(model)
                .padding(12)
            Divider()
            SearchScopeBar(scopes: Bindable(model).scopes)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            results(model)
            SearchResultsList.FailureLines(model: model)
                .padding(.horizontal, 12)
                .padding(.vertical, model.failures.isEmpty ? 0 : 8)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 1)
        }
        .shadow(radius: 24, y: 8)
        .onChange(of: model.results) {
            highlighted = 0
        }
    }

    private func fieldRow(_ model: SearchModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: Bindable(model).text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFieldFocused)
                .onKeyPress(.downArrow) {
                    move(by: 1, in: model)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(by: -1, in: model)
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .onSubmit {
                    submit(model)
                }
                #if os(macOS)
                .onExitCommand {
                    close()
                }
                #endif
                .onAppear {
                    isFieldFocused = true
                }
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
            if !model.text.isEmpty {
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func results(_ model: SearchModel) -> some View {
        if let reason = SearchResultsList.emptyReason(model: model, workspace: workspace) {
            SearchResultsList.StateMessage(reason: reason)
                .frame(height: 120)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    SearchResultsList(model: model, highlighted: $highlighted) { result in
                        open(result)
                    }
                    .padding(.horizontal, 4)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        resultsHeight = height
                    }
                }
                .frame(height: min(resultsHeight, 420))
                .onChange(of: highlighted) {
                    proxy.scrollTo(highlighted)
                }
            }
        }
    }

    // MARK: - Actions

    private func move(by offset: Int, in model: SearchModel) {
        let count = model.results.count
        guard count > 0 else { return }
        highlighted = min(max(highlighted + offset, 0), count - 1)
    }

    /// ↩ opens the highlighted result; with no result shown, it searches now.
    private func submit(_ model: SearchModel) {
        let ordered = SearchResultsList.displayOrder(model.results)
        if SearchResultsList.emptyReason(model: model, workspace: workspace) == nil,
           ordered.indices.contains(highlighted) {
            open(ordered[highlighted])
        } else {
            model.searchNow()
        }
    }

    private func open(_ result: SearchResult) {
        SearchNavigation.open(result, in: context)
    }

    private func close() {
        context.isSearchPresented = false
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    SearchPalette()
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
