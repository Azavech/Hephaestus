import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// An image shown by the full-screen viewer.
public struct ImageViewerItem: Identifiable, Sendable {
    public let id: UUID
    public let data: Data
    public let fileName: String

    public init(data: Data, fileName: String) {
        id = UUID()
        self.data = data
        self.fileName = fileName
    }
}

extension View {
    /// Presents the full-screen viewer while `item` is not nil.
    public func imageViewer(item: Binding<ImageViewerItem?>) -> some View {
        modifier(ImageViewerPresentation(item: item))
    }
}

/// iOS and iPadOS: a full-screen cover; macOS: a sheet (docs/ui/media.md, "Full-screen viewer").
private struct ImageViewerPresentation: ViewModifier {
    @Binding var item: ImageViewerItem?

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .sheet(item: $item) { shown in
                ImageViewerSheet(item: shown) {
                    item = nil
                }
                .frame(minWidth: 640, idealWidth: 1000, minHeight: 480, idealHeight: 750)
            }
        #else
        content
            .fullScreenCover(item: $item) { shown in
                ImageViewerSheet(item: shown) {
                    item = nil
                }
            }
        #endif
    }
}

/// The content of the full-screen viewer: a top bar and the `ImageViewer`.
struct ImageViewerSheet: View {
    let item: ImageViewerItem
    let dismiss: () -> Void

    @Environment(WindowBanners.self) private var banners
    @State private var zoomControl = ImageZoomControl()
    /// The file Share sends, written for the item's data.
    @State private var shareURL: URL?

    var body: some View {
        content
            .task(id: item.id) {
                shareURL = try? MediaFiles.file(for: item.data, fileName: item.fileName,
                                                key: "viewer/\(item.id.uuidString)")
            }
    }

    #if os(macOS)
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(item.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    zoomControl.zoomOut()
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom Out")
                Button {
                    zoomControl.zoomToFit()
                } label: {
                    Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .keyboardShortcut("0", modifiers: .command)
                .help("Zoom to Fit")
                Button {
                    zoomControl.zoomIn()
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom In")
                shareButton
                Button("Save…", action: save)
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ImageViewer(data: item.data, fileName: item.fileName, zoomControl: zoomControl)
                .background(Color.black)
        }
    }

    /// An `NSSavePanel`; OK writes the data atomically.
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.fileName
        panel.canCreateDirectories = true
        let data = item.data
        let fileName = item.fileName
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try data.write(to: url, options: .atomic)
                }.value
            } catch {
                banners.showError("Couldn't save “\(fileName)”: \(Banner.message(of: error))")
            }
        }
    }
    #else
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Text(item.fileName)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                shareButton
                    .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ImageViewer(data: item.data, fileName: item.fileName, zoomControl: zoomControl)
        }
        .background(Color.black.ignoresSafeArea())
    }
    #endif

    /// `ShareLink` of the file written for the item; disabled until it is written.
    @ViewBuilder
    private var shareButton: some View {
        if let shareURL {
            ShareLink(item: shareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share")
        } else {
            Button {} label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(true)
        }
    }
}
