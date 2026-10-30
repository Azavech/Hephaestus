import Foundation
import HephCore
import SwiftUI

/// The tab strip of regular width: the tabs, then a "+" button (docs/ui/web.md, "WebTabStrip").
struct WebTabStrip: View {
    let tabs: [WebTab]
    let activeTabID: UUID?
    /// The Main is connected: the controls that send requests are enabled.
    let isConnected: Bool
    let onSelect: (UUID) -> Void
    let onClose: (WebTab) -> Void
    let onToggleLock: (WebTab) -> Void
    let onOpenInBrowser: (WebTab) -> Void
    /// Moves a tab to an index.
    let onMove: (UUID, Int) -> Void
    let onNewTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            WebTabStripItem(
                                tab: tab,
                                index: index,
                                isActive: tab.id == activeTabID,
                                isConnected: isConnected,
                                onSelect: onSelect,
                                onClose: onClose,
                                onToggleLock: onToggleLock,
                                onOpenInBrowser: onOpenInBrowser,
                                onMove: onMove
                            )
                            .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onAppear {
                    if let activeTabID {
                        proxy.scrollTo(activeTabID)
                    }
                }
                .onChange(of: activeTabID) { _, id in
                    if let id {
                        withAnimation {
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
            Button(action: onNewTab) {
                Label("New Tab", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("New Tab")
            .disabled(!isConnected)
            .padding(.horizontal, 8)
        }
        #if os(macOS)
        .frame(height: 30)
        #else
        .frame(height: 36)
        #endif
    }
}

/// One tab of the strip.
private struct WebTabStripItem: View {
    let tab: WebTab
    let index: Int
    let isActive: Bool
    let isConnected: Bool
    let onSelect: (UUID) -> Void
    let onClose: (WebTab) -> Void
    let onToggleLock: (WebTab) -> Void
    let onOpenInBrowser: (WebTab) -> Void
    let onMove: (UUID, Int) -> Void

    @State private var isHovered = false

    /// Not locked: shown on macOS while the pointer is over the tab, always on iPadOS.
    private var showsCloseButton: Bool {
        #if os(macOS)
        return !tab.locked && isHovered
        #else
        return !tab.locked
        #endif
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Text(WebSectionModel.displayTitle(of: tab))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if tab.locked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if showsCloseButton {
                Button {
                    onClose(tab)
                } label: {
                    Label("Close Tab", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Close Tab")
                .disabled(!isConnected)
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 120, maxWidth: 220)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(tab.id)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(tab.locked ? "Unlock Tab" : "Lock Tab") {
                onToggleLock(tab)
            }
            .disabled(!isConnected)
            Button("Open in Default Browser") {
                onOpenInBrowser(tab)
            }
            .disabled(tab.url == "about:blank")
            Button("Close Tab") {
                onClose(tab)
            }
            .disabled(!isConnected)
        }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard isConnected, let first = items.first, let id = UUID(uuidString: first), id != tab.id else {
                return false
            }
            onMove(id, index)
            return true
        }
        .padding(.vertical, 3)
    }
}
