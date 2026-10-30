import HephClient
import HephCore
import SwiftUI

/// The transcript of a session: `model.items` in a lazy stack that opens at the bottom, follows new items while at
/// the bottom, and loads the earlier pages as the user scrolls up (docs/ui/sessions.md, "Transcript").
struct TranscriptView: View {
    let model: SessionModel
    let store: ProjectStore
    /// The id of an item to scroll to (the status line's Review); set back to nil once done.
    @Binding var scrollRequest: String?

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners

    @State private var position = ScrollPosition(edge: .bottom)
    /// The end of the content is within 40 pt of the visible bottom edge.
    @State private var isAtBottom = true
    /// The scroll position is within one screen height of the top of the content.
    @State private var isInTopZone = false
    /// Loading an earlier page failed since the scroll position entered the top zone.
    @State private var earlierPageFailed = false
    /// The id of the first visible item.
    @State private var topItemID: String?

    /// How close to the bottom edge counts as "at the bottom".
    private static let bottomTolerance: CGFloat = 40
    /// The id of the spinner row shown while an earlier page loads.
    private static let spinnerID = "transcript:loading-earlier"

    var body: some View {
        Group {
            switch model.phase {
            case .loading where model.items.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where model.items.isEmpty:
                failure(message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded where model.items.isEmpty:
                Text("No messages yet.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                transcript
            }
        }
        .onChange(of: revealRequestID, initial: true) {
            revealIfNeeded()
        }
        .onChange(of: scrollRequest) { _, id in
            guard let id else { return }
            position.scrollTo(id: id, anchor: .center)
            scrollRequest = nil
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .loaded {
                earlierPageFailed = false
                loadEarlierIfNeeded()
                revealIfNeeded()
            }
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.isLoadingEarlier {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .id(Self.spinnerID)
                }
                ForEach(model.items) { item in
                    TranscriptRow(item: item, model: model, store: store)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
            TranscriptScrollMetrics(geometry)
        } action: { _, metrics in
            isAtBottom = metrics.distanceFromBottom <= Self.bottomTolerance
            let inTopZone = metrics.distanceFromTop < metrics.containerHeight
            if inTopZone != isInTopZone {
                isInTopZone = inTopZone
                if !inTopZone {
                    earlierPageFailed = false
                }
            }
            loadEarlierIfNeeded()
        }
        .onScrollTargetVisibilityChange(idType: String.self) { ids in
            topItemID = firstItemID(among: ids)
        }
        .onChange(of: model.items) { oldItems, newItems in
            itemsChanged(from: oldItems, to: newItems)
        }
        .onChange(of: model.isLoadingEarlier) { _, isLoading in
            if !isLoading {
                loadEarlierIfNeeded()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .failed(let message) = model.phase {
                failure(message)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isAtBottom {
                Button {
                    position.scrollTo(edge: .bottom)
                } label: {
                    Label("Jump to Latest", systemImage: "arrow.down.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help("Jump to Latest")
                .padding(16)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await model.reload()
                }
            }
        }
    }

    // MARK: Paging

    /// Loads the previous page while the scroll position is in the top zone and earlier events exist, one page at a
    /// time; after a failure, only once the position has left the zone and come back, or after a reload.
    private func loadEarlierIfNeeded() {
        guard isInTopZone, model.hasEarlier, !model.isLoadingEarlier, !earlierPageFailed,
              model.phase == .loaded
        else { return }
        let model = model
        Task {
            let succeeded = await banners.perform {
                try await model.loadEarlier()
            }
            if !succeeded {
                earlierPageFailed = true
            }
        }
    }

    /// Earlier events inserted: the item that was at the top stays at the top. Items added or grown at the bottom:
    /// the view follows them while at the bottom.
    private func itemsChanged(from oldItems: [TranscriptItem], to newItems: [TranscriptItem]) {
        if let oldFirst = oldItems.first?.id, newItems.first?.id != oldFirst,
           let index = newItems.firstIndex(where: { $0.id == oldFirst }), index > 0 {
            if let topItemID {
                position.scrollTo(id: topItemID, anchor: .top)
            }
        } else if isAtBottom {
            position.scrollTo(edge: .bottom)
        }
        revealIfNeeded()
    }

    /// The visible item that comes first in the transcript.
    private func firstItemID(among ids: [String]) -> String? {
        let visible = Set(ids)
        return model.items.first { visible.contains($0.id) }?.id
    }

    // MARK: Reveal

    private var revealRequestID: String? {
        workspace.sessionCenter.revealRequestID(mainID: model.mainID, sessionID: model.sessionID)
    }

    /// A permission to reveal (Show of the indicator or the banner): scrolls to its card, then clears the reveal.
    private func revealIfNeeded() {
        guard let requestID = revealRequestID else { return }
        let center: SessionCenter = workspace.sessionCenter
        let id = "permission:\(requestID)"
        if model.items.contains(where: { $0.id == id }) {
            position.scrollTo(id: id, anchor: .center)
            center.clearReveal(mainID: model.mainID, sessionID: model.sessionID)
        } else if model.phase == .loaded {
            center.clearReveal(mainID: model.mainID, sessionID: model.sessionID)
        }
    }
}

/// What the transcript reads of its scroll geometry.
private struct TranscriptScrollMetrics: Equatable {
    /// `contentOffset.y + contentInsets.top`
    let distanceFromTop: CGFloat
    /// From the visible bottom edge to the end of the content.
    let distanceFromBottom: CGFloat
    let containerHeight: CGFloat
    let contentHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        distanceFromTop = geometry.contentOffset.y + geometry.contentInsets.top
        let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
        distanceFromBottom = geometry.contentSize.height - visibleBottom
        containerHeight = geometry.containerSize.height
        contentHeight = geometry.contentSize.height
    }
}
