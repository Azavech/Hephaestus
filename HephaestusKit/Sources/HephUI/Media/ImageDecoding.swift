import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image decoding with ImageIO (docs/ui/media.md, "Loading and caching"). Not isolated: callers run it in a detached
/// task, off the main actor.
enum ImageDecoding {
    /// The pixel width and height of the first image, swapped when its orientation is 5 to 8; nil when ImageIO cannot
    /// read the data.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    /// The first image, upright, its larger side at most `maxPixelSize` pixels; nil when ImageIO cannot read the data.
    static func thumbnail(of data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The first image upright at full size, encoded as PNG; nil when ImageIO cannot read the data.
    static func pngData(of data: Data) -> Data? {
        guard let size = pixelSize(of: data) else { return nil }
        let maxPixelSize = Int(max(size.width, size.height))
        guard maxPixelSize > 0, let image = thumbnail(of: data, maxPixelSize: maxPixelSize) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
