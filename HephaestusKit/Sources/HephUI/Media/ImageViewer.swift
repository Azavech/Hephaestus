import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Zoomable, pannable image that fits its frame at first. Shows nothing for data that is not an image
/// (docs/ui/media.md, "ImageViewer").
public struct ImageViewer: View {
    private let data: Data
    private let fileName: String
    private let zoomControl: ImageZoomControl?

    @State private var decoder = ImageViewerDecoder()

    public init(data: Data, fileName: String) {
        self.init(data: data, fileName: fileName, zoomControl: nil)
    }

    /// With a zoom control, for the full-screen viewer.
    init(data: Data, fileName: String, zoomControl: ImageZoomControl?) {
        self.data = data
        self.fileName = fileName
        self.zoomControl = zoomControl
    }

    public var body: some View {
        ZoomableImageView(image: decoder.image(for: data), zoomControl: zoomControl)
            .background(Color.clear)
            .accessibilityLabel(fileName)
    }
}

/// The last data decoded by an `ImageViewer` and its image, kept in the view's state: the same data is decoded once.
@MainActor
final class ImageViewerDecoder {
    #if os(macOS)
    typealias PlatformImage = NSImage
    #else
    typealias PlatformImage = UIImage
    #endif

    private var data: Data?
    private var image: PlatformImage?

    func image(for data: Data) -> PlatformImage? {
        if data != self.data {
            self.data = data
            image = Self.decode(data)
        }
        return image
    }

    /// `NSImage(data:)` or `UIImage(data:)`, at one pixel per point.
    private static func decode(_ data: Data) -> PlatformImage? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        let largest = image.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        if let largest, largest.pixelsWide > 0, largest.pixelsHigh > 0 {
            image.size = NSSize(width: largest.pixelsWide, height: largest.pixelsHigh)
        }
        return image
        #else
        return UIImage(data: data)
        #endif
    }
}
