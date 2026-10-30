#if os(macOS)
import AppKit
import Foundation
import HephClient
import SwiftUI
import XCTest
@testable import HephUI

/// The window content of every section except `web`, from the preview workspace (docs/testing.md,
/// HephUISnapshotTests): drawn off screen by an `NSHostingView` in a window that is never ordered in, and written to
/// `$TMPDIR/HephaestusSnapshots/<section>.png`. The sidebar comes out blank.
@MainActor
final class ScreenSnapshotTests: XCTestCase {
    func testSectionSnapshots() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let appModel = AppModel.preview()
        let appSupportRoot = appModel.appSupport.root
        addTeardownBlock {
            try? FileManager.default.removeItem(at: appSupportRoot)
        }
        let studio = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HephaestusSnapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for section in SidebarSection.allCases where section != .web {
            let selection = Selection(mainDeviceID: studio, projectID: section.isProjectSection ? "HEPH" : nil,
                                      section: section)
            // 1. The window is never ordered in.
            let hosting = NSHostingView(rootView: MainShell().previewWindow(appModel, selection: selection))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                  styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.contentView = hosting

            // 2. The views' tasks run.
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
            hosting.layoutSubtreeIfNeeded()

            // 3. The drawing, 2560 × 1600 pixels for 1280 × 800 points.
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2560, pixelsHigh: 1600,
                                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                                        bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = NSSize(width: 1280, height: 800)
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

            // 4. Nothing on screen, and not one color: the pixels whose x and y are multiples of 40 differ.
            XCTAssertFalse(window.isVisible, "The window of \(section.rawValue) is visible")
            let first = bitmap.colorAt(x: 0, y: 0)
            let hasTwoColors = stride(from: 0, to: bitmap.pixelsHigh, by: 40).contains { y in
                stride(from: 0, to: bitmap.pixelsWide, by: 40).contains { x in bitmap.colorAt(x: x, y: y) != first }
            }
            XCTAssertTrue(hasTwoColors, "The drawing of \(section.rawValue) is of one color")

            // 5.
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]),
                                    "No PNG for \(section.rawValue)")
            try png.write(to: folder.appendingPathComponent("\(section.rawValue).png"))
            window.contentView = nil
        }
    }
}
#endif
