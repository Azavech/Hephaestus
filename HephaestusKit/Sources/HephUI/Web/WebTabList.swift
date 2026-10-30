#if os(iOS)
import Foundation
import HephCore
import SwiftUI

/// The tabs in a sheet, compact width only (docs/ui/web.md, "WebTabList").
struct WebTabList: View {
    let tabs: [WebTab]
    let activeTabID: UUID?
    /// The Main is connected: the controls that send requests are enabled.
    let isConnected: Bool
    let onSelect: (UUID) -> Void
    let onClose: (WebTab) -> Void
    /// Moves a tab to an index.
    let onMove: (UUID, Int) -> Void
    let onNewTab: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(tabs) { tab in
                    Button {
                        onSelect(tab.id)
                        dismiss()
                    } label: {
                        row(tab)
                    }
                    .foregroundStyle(.primary)
                    .deleteDisabled(tab.locked || !isConnected)
                }
                .onDelete { offsets in
                    for index in offsets where tabs.indices.contains(index) {
                        onClose(tabs[index])
                    }
                }
                .onMove { source, destination in
                    guard isConnected, let index = source.first, tabs.indices.contains(index) else { return }
                    onMove(tabs[index].id, destination > index ? destination - 1 : destination)
                }
                .moveDisabled(!isConnected)
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        onNewTab()
                        dismiss()
                    } label: {
                        Label("New Tab", systemImage: "plus")
                    }
                    .disabled(!isConnected)
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func row(_ tab: WebTab) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(WebSectionModel.displayTitle(of: tab))
                    .lineLimit(1)
                Text(tab.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if tab.locked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            if tab.id == activeTabID {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
