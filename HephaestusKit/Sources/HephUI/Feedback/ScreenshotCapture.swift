import Foundation
#if os(macOS)
import AppKit
import ScreenCaptureKit
import WebKit
#else
import UIKit
#endif

/// Captures a window as a PNG before the feedback sheet appears (docs/forge/feedback.md, "Capture"). A capture that
/// fails gives no screenshot.
enum ScreenshotCapture {
    #if os(macOS)
    /// `CGRequestScreenCaptureAccess()` was called since the app launched.
    @MainActor private static var hasRequestedAccess = false

    /// The window with its title bar and toolbar and its attached sheets: drawn by ScreenCaptureKit when the app has
    /// the Screen Recording permission, else, or when that capture fails, by AppKit (the fallback capture). Without the
    /// permission, the first feedback since the app launched requests it after the capture, so the prompt is not in
    /// the image.
    @MainActor
    static func capture(_ window: NSWindow) async -> Data? {
        let rep: NSBitmapImageRep?
        if CGPreflightScreenCaptureAccess() {
            if let captured = await screenCaptureKitBitmap(of: window) {
                rep = captured
            } else {
                rep = await fallbackBitmap(of: window)
            }
        } else {
            rep = await fallbackBitmap(of: window)
            if !hasRequestedAccess {
                hasRequestedAccess = true
                CGRequestScreenCaptureAccess()
            }
        }
        return rep?.representation(using: .png, properties: [:])
    }

    /// The window as it is on screen, alone whatever covers it, the sidebar's translucent background and the web views
    /// included, with its attached sheet drawn over it. Nil when the window is not in the shareable content or a call
    /// throws.
    @MainActor
    private static func screenCaptureKitBitmap(of window: NSWindow) async -> NSBitmapImageRep? {
        let rep: NSBitmapImageRep
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let windowID = CGWindowID(window.windowNumber)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.capturesShadowsOnly = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            rep = NSBitmapImageRep(cgImage: image)
        } catch {
            return nil
        }
        // In points, so that the sheet is drawn in points.
        rep.size = window.frame.size
        if let sheet = window.attachedSheet, let sheetRep = await screenCaptureKitBitmap(of: sheet) {
            drawSheet(sheetRep, of: sheet, over: rep, in: window)
        }
        return rep
    }

    /// The frame view of `window` drawn by AppKit into a bitmap, with the web views and the attached sheet drawn over
    /// it. The sidebar's material is not drawn: the sidebar column is blank.
    @MainActor
    private static func fallbackBitmap(of window: NSWindow) async -> NSBitmapImageRep? {
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

        if let sheet = window.attachedSheet, let sheetRep = await fallbackBitmap(of: sheet) {
            drawSheet(sheetRep, of: sheet, over: rep, in: window)
        }
        return rep
    }

    /// Draws the capture of an attached sheet over the window's, at the sheet's place and frame size.
    @MainActor
    private static func drawSheet(_ sheetRep: NSBitmapImageRep, of sheet: NSWindow, over rep: NSBitmapImageRep,
                                  in window: NSWindow) {
        let origin = NSPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
        draw(into: rep) {
            sheetRep.draw(in: NSRect(origin: origin, size: sheet.frame.size))
        }
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
