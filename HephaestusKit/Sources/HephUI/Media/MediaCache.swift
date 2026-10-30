import CoreGraphics
import Foundation

/// The decoded thumbnails, by cache key and maximum pixel size (docs/ui/media.md, "Loading and caching"). Thumbnails
/// look here before downloading and decoding.
@MainActor
enum MediaCache {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 100 * 1024 * 1024
        return cache
    }()

    /// The thumbnail of `cacheKey` decoded at `maxPixelSize`, when the cache still holds it.
    static func thumbnail(for cacheKey: String, maxPixelSize: Int) -> CGImage? {
        cache.object(forKey: key(cacheKey, maxPixelSize))
    }

    /// Keeps a thumbnail; its cost is width × height × 4.
    static func insert(_ image: CGImage, for cacheKey: String, maxPixelSize: Int) {
        cache.setObject(image, forKey: key(cacheKey, maxPixelSize), cost: image.width * image.height * 4)
    }

    private static func key(_ cacheKey: String, _ maxPixelSize: Int) -> NSString {
        "\(maxPixelSize)|\(cacheKey)" as NSString
    }
}
