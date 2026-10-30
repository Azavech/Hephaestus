import CoreGraphics
import Foundation
import HephClient
import SwiftUI

/// Thumbnail of an image attachment; opens the full-screen viewer (docs/ui/media.md, "ImageThumbnail").
public struct ImageThumbnail: View {
    private let fileName: String
    private let mimeType: String
    private let size: Int
    private let cacheKey: String
    private let maxSize: CGSize
    private let download: DownloadAction

    @State private var state: LoadState = .downloading(nil)
    /// Incremented by Retry: the download starts again.
    @State private var attempt = 0
    @State private var viewerItem: ImageViewerItem?
    /// Reads the file for the viewer; cancelled when the view goes away.
    @State private var openTask: Task<Void, Never>?

    public init(fileName: String, mimeType: String, size: Int, cacheKey: String,
                maxSize: CGSize = CGSize(width: 240, height: 180), download: @escaping DownloadAction) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.cacheKey = cacheKey
        self.maxSize = maxSize
        self.download = download
    }

    private enum LoadState {
        case downloading(TransferProgress?)
        /// The thumbnail and the downloaded file; no file when the thumbnail came from `MediaCache`.
        case loaded(CGImage, file: URL?)
        case failed(String)
        /// The downloaded data is not an image ImageIO can read.
        case notDecoded
    }

    private struct LoadID: Equatable {
        let cacheKey: String
        let attempt: Int
    }

    /// 2 × the larger side of `maxSize`.
    private var maxPixelSize: Int {
        Int(2 * max(maxSize.width, maxSize.height))
    }

    public var body: some View {
        content
            .task(id: LoadID(cacheKey: cacheKey, attempt: attempt)) {
                await load()
            }
            .onDisappear {
                openTask?.cancel()
                openTask = nil
            }
            .imageViewer(item: $viewerItem)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .downloading(let progress):
            placeholder {
                VStack(spacing: 6) {
                    if let progress {
                        ProgressView(value: progress.fraction)
                            .frame(width: 80)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                    }
                    Text(MediaFormat.progress(progress ?? TransferProgress(completed: 0, total: size)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(fileName)
        case .loaded(let image, let file):
            Button {
                openViewer(file: file)
            } label: {
                thumbnail(image)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(fileName)
            #if os(macOS)
            .help(fileName)
            #endif
        case .failed(let message):
            placeholder {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Download failed")
                        .font(.caption)
                    Button("Retry") {
                        attempt += 1
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .help(message)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(fileName)
            .accessibilityValue(message)
        case .notDecoded:
            AttachmentChip(fileName: fileName, mimeType: mimeType, size: size, cacheKey: cacheKey, download: download)
        }
    }

    /// The 120 × 90 pt rounded rectangle of the downloading and failed states.
    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.1))
            .frame(width: 120, height: 90)
            .overlay {
                content()
            }
    }

    /// The thumbnail at most `maxSize` and at most its pixel size (one pixel is one point), aspect ratio kept.
    private func thumbnail(_ image: CGImage) -> some View {
        let pixelWidth = CGFloat(image.width)
        let pixelHeight = CGFloat(image.height)
        let scale = pixelWidth > 0 && pixelHeight > 0
            ? min(1, maxSize.width / pixelWidth, maxSize.height / pixelHeight)
            : 0
        return Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: pixelWidth * scale, height: pixelHeight * scale)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            }
    }

    /// Looks in `MediaCache`, else downloads and decodes the thumbnail off the main actor.
    private func load() async {
        let maxPixelSize = maxPixelSize
        if let cached = MediaCache.thumbnail(for: cacheKey, maxPixelSize: maxPixelSize) {
            state = .loaded(cached, file: nil)
            return
        }
        state = .downloading(nil)
        do {
            let url = try await download { progress in
                state = .downloading(progress)
            }
            let image = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return ImageDecoding.thumbnail(of: data, maxPixelSize: maxPixelSize)
            }.value
            guard !Task.isCancelled else { return }
            if let image {
                MediaCache.insert(image, for: cacheKey, maxPixelSize: maxPixelSize)
                state = .loaded(image, file: url)
            } else {
                state = .notDecoded
            }
        } catch {
            // A cancellation shows nothing: the next appearance starts again.
            guard !(error is CancellationError), !Task.isCancelled else { return }
            state = .failed(Banner.message(of: error))
        }
    }

    /// Opens the full-screen viewer with the data of the downloaded file. A thumbnail that came from `MediaCache`
    /// calls `download` first, which returns the cached file at once.
    private func openViewer(file: URL?) {
        guard openTask == nil else { return }
        openTask = Task {
            defer { openTask = nil }
            do {
                let url: URL
                if let file {
                    url = file
                } else {
                    url = try await download { _ in }
                }
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                guard !Task.isCancelled else { return }
                viewerItem = ImageViewerItem(data: data, fileName: fileName)
            } catch {
                guard !(error is CancellationError), !Task.isCancelled else { return }
                state = .failed(Banner.message(of: error))
            }
        }
    }
}
