import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Lets the full-screen viewer drive the zoom of an `ImageViewer` (docs/ui/media.md, "ImageViewer").
@MainActor
final class ImageZoomControl {
    weak var target: (any ImageZoomTarget)?

    init() {}

    /// Multiplies the zoom by 1.5, within the limits.
    func zoomIn() {
        target?.zoomImage(by: 1.5)
    }

    /// Divides the zoom by 1.5, within the limits.
    func zoomOut() {
        target?.zoomImage(by: 1 / 1.5)
    }

    /// Back to the minimum zoom.
    func zoomToFit() {
        target?.zoomImageToMinimum()
    }
}

/// The platform scroll view an `ImageZoomControl` drives.
@MainActor
protocol ImageZoomTarget: AnyObject {
    func zoomImage(by factor: CGFloat)
    func zoomImageToMinimum()
}

/// The zoom rules, the same on every platform.
enum ImageZoomRules {
    static let maximum: CGFloat = 8
    /// Within this distance, a zoom is the minimum.
    static let tolerance: CGFloat = 0.001

    /// min(1, fit): a large image starts fitted, a small one at its actual size. nil while a size is empty.
    static func minimum(imageSize: CGSize, viewSize: CGSize) -> CGFloat? {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let fit = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return min(1, fit)
    }

    /// The zoom of a double click or tap at the minimum zoom.
    static func doubleTapZoom(minimum: CGFloat) -> CGFloat {
        min(maximum, max(1, 2 * minimum))
    }
}

#if os(macOS)

/// The zoomable image of `ImageViewer` on macOS: an `NSScrollView` whose document view is an `NSImageView`.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage?
    let zoomControl: ImageZoomControl?

    func makeNSView(context: Context) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView()
        view.show(image)
        zoomControl?.target = view
        return view
    }

    func updateNSView(_ view: ZoomableImageScrollView, context: Context) {
        if view.image !== image {
            view.show(image)
        }
        zoomControl?.target = view
    }
}

/// `allowsMagnification`, the limits of the zoom rules, a clip view that centers a smaller image, and a double click
/// that zooms in and back.
final class ZoomableImageScrollView: NSScrollView, ImageZoomTarget {
    private let imageView = NSImageView()
    private(set) var image: NSImage?
    private var minimumZoom: CGFloat = 1
    /// Until the first layout with a size, the image is not at its starting zoom yet.
    private var needsInitialZoom = true

    init() {
        super.init(frame: .zero)
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        contentView = clipView
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        maxMagnification = ImageZoomRules.maximum
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        imageView.animates = true
        documentView = imageView
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Shows an image at its pixel size, then at its starting zoom.
    func show(_ image: NSImage?) {
        self.image = image
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
        needsInitialZoom = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateMinimumZoom()
    }

    /// Computes the minimum again; applies it at the start and while the zoom is the minimum.
    private func updateMinimumZoom() {
        guard let newMinimum = ImageZoomRules.minimum(imageSize: imageView.frame.size, viewSize: contentSize) else {
            return
        }
        let wasAtMinimum = abs(magnification - minimumZoom) < ImageZoomRules.tolerance
        minimumZoom = newMinimum
        minMagnification = newMinimum
        if needsInitialZoom || wasAtMinimum {
            needsInitialZoom = false
            if abs(magnification - newMinimum) > .ulpOfOne {
                magnification = newMinimum
            }
        }
    }

    @objc private func doubleClicked(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: contentView)
        if abs(magnification - minimumZoom) < ImageZoomRules.tolerance {
            setMagnification(ImageZoomRules.doubleTapZoom(minimum: minimumZoom), centeredAt: point)
        } else {
            setMagnification(minimumZoom, centeredAt: point)
        }
    }

    func zoomImage(by factor: CGFloat) {
        let zoom = min(ImageZoomRules.maximum, max(minimumZoom, magnification * factor))
        setMagnification(zoom, centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
    }

    func zoomImageToMinimum() {
        setMagnification(minimumZoom, centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
    }
}

/// A clip view that centers a document view smaller than itself.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let documentFrame = documentView.frame
        if rect.width > documentFrame.width {
            rect.origin.x = documentFrame.minX - (rect.width - documentFrame.width) / 2
        }
        if rect.height > documentFrame.height {
            rect.origin.y = documentFrame.minY - (rect.height - documentFrame.height) / 2
        }
        return rect
    }
}

#else

/// The zoomable image of `ImageViewer` on iOS and iPadOS: a `UIScrollView` zooming a `UIImageView`.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    let zoomControl: ImageZoomControl?

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView()
        view.show(image)
        zoomControl?.target = view
        return view
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        if view.image !== image {
            view.show(image)
        }
        zoomControl?.target = view
    }
}

/// The limits of the zoom rules, hidden indicators, centering by content insets, and a double tap that zooms in and
/// back.
final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate, ImageZoomTarget {
    private let imageView = UIImageView()
    private(set) var image: UIImage?
    private var minimumZoom: CGFloat = 1
    /// Until the first layout with a size, the image is not at its starting zoom yet.
    private var needsInitialZoom = true
    private var lastBoundsSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        maximumZoomScale = ImageZoomRules.maximum
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Shows an image sized to its pixels, then at its starting zoom.
    func show(_ image: UIImage?) {
        self.image = image
        zoomScale = 1
        imageView.image = image
        let size = image?.size ?? .zero
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        needsInitialZoom = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateMinimumZoom()
        centerContent()
    }

    /// Computes the minimum again when the size changes; applies it at the start and while the zoom is the minimum.
    private func updateMinimumZoom() {
        guard needsInitialZoom || bounds.size != lastBoundsSize,
              let newMinimum = ImageZoomRules.minimum(imageSize: image?.size ?? .zero, viewSize: bounds.size)
        else { return }
        lastBoundsSize = bounds.size
        let wasAtMinimum = abs(zoomScale - minimumZoom) < ImageZoomRules.tolerance
        minimumZoom = newMinimum
        minimumZoomScale = newMinimum
        if needsInitialZoom || wasAtMinimum {
            needsInitialZoom = false
            zoomScale = newMinimum
        }
    }

    /// Insets of half the free space center an image smaller than the view.
    private func centerContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset {
            contentInset = inset
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if abs(zoomScale - minimumZoom) < ImageZoomRules.tolerance {
            let scale = ImageZoomRules.doubleTapZoom(minimum: minimumZoom)
            let point = recognizer.location(in: imageView)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                              width: size.width, height: size.height)
            zoom(to: rect, animated: true)
        } else {
            setZoomScale(minimumZoom, animated: true)
        }
    }

    func zoomImage(by factor: CGFloat) {
        setZoomScale(min(ImageZoomRules.maximum, max(minimumZoom, zoomScale * factor)), animated: true)
    }

    func zoomImageToMinimum() {
        setZoomScale(minimumZoom, animated: true)
    }
}

#endif
