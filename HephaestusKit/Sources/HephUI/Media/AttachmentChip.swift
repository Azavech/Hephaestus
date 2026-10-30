import Foundation
import HephClient
import QuickLook
import SwiftUI

/// Chip with the name and size of an attachment; opens Quick Look after download (docs/ui/media.md,
/// "AttachmentChip").
public struct AttachmentChip: View {
    private let fileName: String
    private let mimeType: String
    private let size: Int
    private let cacheKey: String
    private let download: DownloadAction

    @Environment(WindowBanners.self) private var banners
    @State private var phase: Phase = .idle
    /// The download asked by a tap or Retry; it runs in the view's task, cancelled when the view goes away.
    @State private var request: UUID?
    @State private var previewURL: URL?

    public init(fileName: String, mimeType: String, size: Int, cacheKey: String, download: @escaping DownloadAction) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.cacheKey = cacheKey
        self.download = download
    }

    private enum Phase: Equatable {
        case idle
        case downloading(TransferProgress?)
        case failed(String)
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button(action: open) {
                HStack(spacing: 6) {
                    leading
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading) {
                        Text(fileName)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .leading)
                        Text(secondLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(fileName), \(MediaFormat.size(size))")
            if case .failed = phase {
                Button("Retry", action: open)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
        )
        #if os(macOS)
        .help(helpText)
        #endif
        .task(id: request) {
            await runDownload()
        }
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private var leading: some View {
        switch phase {
        case .idle:
            Image(systemName: AttachmentIcon.symbolName(mimeType: mimeType, fileName: fileName))
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var secondLine: String {
        switch phase {
        case .idle:
            return MediaFormat.size(size)
        case .downloading(let progress):
            return MediaFormat.progress(progress ?? TransferProgress(completed: 0, total: size))
        case .failed:
            return "Download failed"
        }
    }

    private var helpText: String {
        if case .failed(let message) = phase {
            return message
        }
        return fileName
    }

    /// Tap, click or Retry: downloads, then Quick Look shows the file. Ignored while a download runs.
    private func open() {
        if case .downloading = phase {
            return
        }
        phase = .downloading(nil)
        request = UUID()
    }

    private func runDownload() async {
        guard let id = request else { return }
        do {
            let url = try await download { progress in
                if request == id {
                    phase = .downloading(progress)
                }
            }
            guard request == id else { return }
            request = nil
            phase = .idle
            previewURL = url
        } catch {
            guard request == id else { return }
            request = nil
            if error is CancellationError || Task.isCancelled {
                // The view went away: the chip is idle again.
                phase = .idle
                return
            }
            let message = Banner.message(of: error)
            phase = .failed(message)
            banners.showError("Couldn't open “\(fileName)”: \(message)")
        }
    }
}
