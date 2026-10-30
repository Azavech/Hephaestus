import Foundation
import HephClient
import HephCore
import SwiftUI

/// Brings a file into the attachment cache and returns its local URL; reports progress on the main actor.
public typealias DownloadAction =
    @MainActor (_ progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> URL

/// ImageThumbnail when mimeType starts with "image/", else AttachmentChip (docs/ui/media.md).
public struct AttachmentView: View {
    private let fileName: String
    private let mimeType: String
    private let size: Int
    private let cacheKey: String
    private let download: DownloadAction

    public init(fileName: String, mimeType: String, size: Int, cacheKey: String, download: @escaping DownloadAction) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.cacheKey = cacheKey
        self.download = download
    }

    public var body: some View {
        if mimeType.lowercased().hasPrefix("image/") {
            ImageThumbnail(fileName: fileName, mimeType: mimeType, size: size, cacheKey: cacheKey, download: download)
        } else {
            AttachmentChip(fileName: fileName, mimeType: mimeType, size: size, cacheKey: cacheKey, download: download)
        }
    }
}

/// The texts the media views share.
enum MediaFormat {
    /// A size in bytes (`ByteCountFormatter`, `.file`).
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "<completed> of <total>"
    static func progress(_ progress: TransferProgress) -> String {
        "\(size(progress.completed)) of \(size(progress.total))"
    }
}
