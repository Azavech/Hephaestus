import Foundation
#if os(macOS)
import AppKit
import WebKit
#else
import UIKit
#endif

/// Captures a window as a PNG before the feedback sheet appears (docs/forge/feedback.md, "Capture"). A capture that
/// fails gives no screenshot.
enum ScreenshotCapture {
    #if os(macOS)
    /// The window with its title bar and toolbar, its visible web views and its attached sheets.
    @MainActor
    static func capture(_ window: NSWindow) async -> Data? {
        guard let rep = await bitmap(of: window) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The frame view of `window` drawn into a bitmap, with the web views and the attached sheet drawn over it.
    @MainActor
    private static func bitmap(of window: NSWindow) async -> NSBitmapImageRep? {
        guard let frameView = window.contentView?.superview else { return nil }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        frameView.cacheDisplay(in: bounds, to: rep)

        // Web views are drawn by WebKit in another process and are blank in the cached image.
        for webView in webViews(in: frameView)
        where !webView.isHiddenOrHasHiddenAncestor && !webView.visibleRect.isEmpty {
            let image: NSImage
            do {
                image = try await webView.takeSnapshot(configuration: nil)
            } catch {
                continue
            }
            let clip = pointRect(webView.convert(webView.visibleRect, to: frameView), in: frameView)
            let target = pointRect(webView.convert(webView.bounds, to: frameView), in: frameView)
            draw(into: rep) {
                NSBezierPath.clip(clip)
                image.draw(in: target)
            }
        }

        if let sheet = window.attachedSheet, let sheetRep = await bitmap(of: sheet) {
            let origin = NSPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
            draw(into: rep) {
                sheetRep.draw(in: NSRect(origin: origin, size: sheet.frame.size))
            }
        }
        return rep
    }

    /// Every web view of the subtree of `view`, depth first.
    @MainActor
    private static func webViews(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        for subview in view.subviews {
            if let webView = subview as? WKWebView {
                found.append(webView)
            }
            found.append(contentsOf: webViews(in: subview))
        }
        return found
    }

    /// A rect of the frame view in point coordinates with the origin at the bottom left.
    @MainActor
    private static func pointRect(_ rect: NSRect, in frameView: NSView) -> NSRect {
        guard frameView.isFlipped else { return rect }
        var converted = rect
        converted.origin.y = frameView.bounds.height - rect.maxY
        return converted
    }

    /// Runs `drawing` with a graphics context on `rep`.
    @MainActor
    private static func draw(into rep: NSBitmapImageRep, _ drawing: () -> Void) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawing()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }
    #else
    /// The window with its presented sheets and web views.
    @MainActor
    static func capture(_ window: UIWindow) async -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.pngData()
    }
    #endif
}
