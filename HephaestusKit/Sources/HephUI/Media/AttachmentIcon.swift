import Foundation
import UniformTypeIdentifiers

/// The SF Symbol of an attached file (docs/ui/media.md, "AttachmentIcon").
public enum AttachmentIcon {
    /// By MIME type, compared in lowercase without its parameters; `application/octet-stream` and an empty type go by
    /// the type of the file name's extension.
    public static func symbolName(mimeType: String, fileName: String) -> String {
        let type = String(mimeType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if type.hasPrefix("image/") {
            return "photo"
        }
        if type.hasPrefix("video/") {
            return "film"
        }
        if type.hasPrefix("audio/") {
            return "waveform"
        }
        if type.hasPrefix("text/") {
            return "doc.text"
        }
        switch type {
        case "application/pdf":
            return "doc.richtext"
        case "application/json", "application/yaml", "application/x-yaml", "application/xml":
            return "doc.text"
        case "application/zip", "application/gzip", "application/x-tar", "application/x-bzip2", "application/x-xz",
             "application/x-7z-compressed":
            return "doc.zipper"
        case "application/octet-stream", "":
            return symbolName(forFileName: fileName)
        default:
            return "doc"
        }
    }

    /// From `UTType(filenameExtension:)` of the file name's extension.
    private static func symbolName(forFileName fileName: String) -> String {
        let fileExtension = (fileName as NSString).pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return "doc" }
        if type.conforms(to: .image) {
            return "photo"
        }
        if type.conforms(to: .movie) {
            return "film"
        }
        if type.conforms(to: .audio) {
            return "waveform"
        }
        if type.conforms(to: .pdf) {
            return "doc.richtext"
        }
        if type.conforms(to: .text) {
            return "doc.text"
        }
        if type.conforms(to: .archive) {
            return "doc.zipper"
        }
        return "doc"
    }
}
