import Foundation
import SwiftUI

/// The SF Symbol of a file tree item (docs/ui/code.md, "FileIcon").
enum FileIcon {
    /// By the extension of the file name, compared ignoring case; `folder` for a folder.
    static func symbolName(forFileName fileName: String, isDirectory: Bool) -> String {
        if isDirectory {
            return "folder"
        }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "swift":
            return "swift"
        case "go":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "markdown":
            return "doc.richtext"
        case "yml", "yaml", "json":
            return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico":
            return "photo"
        default:
            return "doc"
        }
    }

    /// The symbol as an image; a folder's is in the accent color.
    @ViewBuilder
    static func image(forFileName fileName: String, isDirectory: Bool) -> some View {
        let image = Image(systemName: symbolName(forFileName: fileName, isDirectory: isDirectory))
        if isDirectory {
            image.foregroundStyle(.tint)
        } else {
            image
        }
    }
}
