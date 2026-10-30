import Foundation
import HephClient
import QuickLook
import SwiftUI

/// A project file too large for the editor: an image is downloaded and shown in an ImageViewer, another file opens in
/// Quick Look on demand (docs/ui/media.md, "LargeFileView").
public struct LargeFileView: View {
    private let fileName: String
    private let download: DownloadAction

    @State private var phase: Phase = .ready
    /// The download that runs, in the view's task: cancelled when the view goes away or by Cancel.
    @State private var request: Request?
    /// What the last download was for, for Retry.
    @State private var lastPurpose: Purpose = .quickLook
    /// The image file's data turned out not to be an image ImageIO can read.
    @State private var isImageUnreadable = false
    @State private var previewURL: URL?

    public init(fileName: String, download: @escaping DownloadAction) {
        self.fileName = fileName
        self.download = download
    }

    private enum Purpose: Equatable {
        case showImage, quickLook
    }

    private struct Request: Equatable {
        let id = UUID()
        let purpose: Purpose
    }

    private enum Phase {
        case ready
        case downloading(TransferProgress?)
        case failed(String)
        case image(Data)
    }

    /// The image extensions of the Code section (docs/ui/code.md, "Loading").
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico",
    ]

    private var isImageFile: Bool {
        Self.imageExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    public var body: some View {
        Group {
            if case .image(let data) = phase {
                ImageViewer(data: data, fileName: fileName)
            } else {
                column
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: fileName) {
            request = nil
            previewURL = nil
            isImageUnreadable = false
            phase = .ready
            if isImageFile {
                start(.showImage)
            }
        }
        .task(id: request) {
            await runDownload()
        }
        .quickLookPreview($previewURL)
    }

    private var column: some View {
        VStack(spacing: 8) {
            Image(systemName: AttachmentIcon.symbolName(mimeType: "", fileName: fileName))
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(fileName)
                .font(.headline)
            Text("This file is larger than 10 MB.")
                .foregroundStyle(.secondary)
            switch phase {
            case .ready, .image:
                if isImageFile && !isImageUnreadable {
                    Button("Show Image") {
                        start(.showImage)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Quick Look") {
                        start(.quickLook)
                    }
                    .buttonStyle(.bordered)
                }
            case .downloading(let progress):
                if let progress {
                    ProgressView(value: progress.fraction)
                        .frame(width: 240)
                    Text(MediaFormat.progress(progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 240)
                }
                Button("Cancel") {
                    request = nil
                    phase = .ready
                }
            case .failed(let message):
                Text("Couldn't download “\(fileName)”: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    start(lastPurpose)
                }
            }
        }
        .padding()
    }

    private func start(_ purpose: Purpose) {
        lastPurpose = purpose
        phase = .downloading(nil)
        request = Request(purpose: purpose)
    }

    private func runDownload() async {
        guard let current = request else { return }
        do {
            let url = try await download { progress in
                if request == current {
                    phase = .downloading(progress)
                }
            }
            guard request == current else { return }
            switch current.purpose {
            case .showImage:
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                let isReadable = await Task.detached(priority: .userInitiated) {
                    ImageDecoding.pixelSize(of: data) != nil
                }.value
                guard request == current else { return }
                request = nil
                if isReadable {
                    phase = .image(data)
                } else {
                    isImageUnreadable = true
                    phase = .ready
                }
            case .quickLook:
                request = nil
                phase = .ready
                previewURL = url
            }
        } catch {
            // Cancel and the view going away cancel the task: Cancel has already set the ready state.
            guard request == current, !(error is CancellationError), !Task.isCancelled else { return }
            request = nil
            phase = .failed(Banner.message(of: error))
        }
    }
}
