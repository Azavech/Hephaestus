import Foundation
import HephClient
import HephCore
import SwiftUI
import Synchronization
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import PhotosUI
import UIKit
#endif

/// A file or an image to attach, before its upload (docs/ui/media.md, "Attachment picking").
public struct AttachmentInput: Sendable, Hashable {
    public var fileName: String
    /// `.file` for files, `.data` for images and photos.
    public var source: UploadSource
    /// Bytes.
    public var size: Int

    public init(fileName: String, source: UploadSource, size: Int) {
        self.fileName = fileName
        self.source = source
        self.size = size
    }
}

/// The attach menu (`paperclip`): Choose Files… on every platform, Photo Library… on iOS and iPadOS.
public struct AttachmentPickerButton: View {
    private let onAdd: @MainActor ([AttachmentInput]) -> Void

    @Environment(WindowBanners.self) private var banners
    @State private var isImporterPresented = false
    #if os(iOS)
    @State private var isPhotosPickerPresented = false
    @State private var photoItems: [PhotosPickerItem] = []
    #endif

    public init(onAdd: @escaping @MainActor ([AttachmentInput]) -> Void) {
        self.onAdd = onAdd
    }

    public var body: some View {
        menu
            .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    takeFiles(urls)
                case .failure(let error):
                    banners.showError(error)
                }
            }
        #if os(iOS)
            .photosPicker(isPresented: $isPhotosPickerPresented, selection: $photoItems, maxSelectionCount: 10,
                          matching: .images)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                takePhotos(items)
            }
        #endif
    }

    private var menu: some View {
        Menu {
            Button("Choose Files…") {
                isImporterPresented = true
            }
            #if os(iOS)
            Button("Photo Library…") {
                isPhotosPickerPresented = true
            }
            #endif
        } label: {
            Label("Attach", systemImage: "paperclip")
        }
        .labelStyle(.iconOnly)
    }

    /// Takes the chosen files in a detached task, each between the start and the stop of its security-scoped access.
    private func takeFiles(_ urls: [URL]) {
        let onAdd = onAdd
        let banners = banners
        Task {
            let results = await Task.detached(priority: .userInitiated) {
                urls.map { url in
                    let isAccessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if isAccessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    return AttachmentFiles.take(url)
                }
            }.value
            let inputs = AttachmentTaking.collect(results) { banners.showError($0) }
            if !inputs.isEmpty {
                onAdd(inputs)
            }
        }
    }

    #if os(iOS)
    /// Each photo in order gives its data; "Photo.<extension>" from its first supported content type, else `jpg`.
    private func takePhotos(_ items: [PhotosPickerItem]) {
        let onAdd = onAdd
        let banners = banners
        Task {
            var results: [Result<AttachmentInput, AttachmentTakeFailure>] = []
            for item in items {
                let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let fileName = "Photo.\(fileExtension)"
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        results.append(.failure(AttachmentTakeFailure(fileName: fileName,
                                                                      reason: "the photo has no data")))
                        continue
                    }
                    results.append(.success(AttachmentInput(fileName: fileName, source: .data(data),
                                                            size: data.count)))
                } catch {
                    results.append(.failure(AttachmentTakeFailure(fileName: fileName,
                                                                  reason: error.localizedDescription)))
                }
            }
            photoItems = []
            let inputs = AttachmentTaking.collect(results) { banners.showError($0) }
            if !inputs.isEmpty {
                onAdd(inputs)
            }
        }
    }
    #endif
}

extension View {
    /// Accepts files and images dropped on the view.
    public func attachmentDrop(onAdd: @escaping @MainActor ([AttachmentInput]) -> Void) -> some View {
        modifier(AttachmentDropModifier(onAdd: onAdd))
    }
}

/// `.onDrop(of: [.fileURL, .image])`: each item gives its file URL, else its image converted to PNG.
private struct AttachmentDropModifier: ViewModifier {
    let onAdd: @MainActor ([AttachmentInput]) -> Void

    @Environment(WindowBanners.self) private var banners

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                take(providers)
                return true
            }
    }

    /// Calls `onAdd` once every provider has given its attachment or failed, in order.
    private func take(_ providers: [NSItemProvider]) {
        let onAdd = onAdd
        let banners = banners
        Task {
            var results: [Result<AttachmentInput, AttachmentTakeFailure>] = []
            for provider in providers {
                results.append(await AttachmentTaking.take(provider))
            }
            let inputs = AttachmentTaking.collect(results) { banners.showError($0) }
            if !inputs.isEmpty {
                onAdd(inputs)
            }
        }
    }
}

/// The files and images on a pasteboard, for ⌘V in a composer's text view. nil: nothing to attach.
@MainActor public enum AttachmentPasteboard {
    #if os(macOS)
    /// The file URLs; else, when there is no text, the PNG or TIFF image converted to PNG; else nil.
    public static func attachments(from pasteboard: NSPasteboard = .general) -> [AttachmentInput]? {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let urls = (objects ?? []).compactMap { $0 as? URL }
        if !urls.isEmpty {
            return AttachmentTaking.collect(urls.map { AttachmentFiles.take($0) }, report: postError)
        }
        guard pasteboard.string(forType: .string) == nil,
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        else { return nil }
        return AttachmentTaking.collect([AttachmentTaking.image(data, fileName: "Pasted Image.png")],
                                        report: postError)
    }
    #else
    /// When the pasteboard has images and no text: each image drawn upright and encoded as PNG; else nil.
    public static func attachments(from pasteboard: UIPasteboard = .general) -> [AttachmentInput]? {
        guard pasteboard.hasImages, !pasteboard.hasStrings, let images = pasteboard.images else { return nil }
        return images.map { image in
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            let png = UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
                image.draw(at: .zero)
            }
            return AttachmentInput(fileName: "Pasted Image.png", source: .data(png), size: png.count)
        }
    }
    #endif

    /// A paste has no environment: its errors go to the active window.
    private static func postError(_ message: String) {
        AppModel.shared.banners.post(Banner(style: .error, message: message))
    }
}

/// The temporary copies of attached files (Files).
public enum AttachmentFiles {
    /// `<temporary directory>/Hephaestus-Attachments/`, deleted with its content at its first use in a process.
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Hephaestus-Attachments", isDirectory: true)
    }

    /// Whether the root was prepared in this process.
    private static let isRootPrepared = Mutex(false)

    /// Deletes the file of a `.file` source when it is a temporary copy made here; does nothing otherwise.
    public static func discard(_ source: UploadSource) {
        guard case .file(let url) = source else { return }
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else {
            return
        }
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A regular file: its name and size. macOS: the file itself; iOS and iPadOS: a copy in
    /// `<root>/<new UUID>/<name>`, made while the chosen or dropped URL is usable. The content is not read.
    static func take(_ url: URL) -> Result<AttachmentInput, AttachmentTakeFailure> {
        let fileName = url.lastPathComponent
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                return .failure(AttachmentTakeFailure(fileName: fileName, reason: "not a regular file"))
            }
            let size = values.fileSize ?? 0
            #if os(macOS)
            return .success(AttachmentInput(fileName: fileName, source: .file(url), size: size))
            #else
            try prepareRoot()
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: url, to: copy)
            return .success(AttachmentInput(fileName: fileName, source: .file(copy), size: size))
            #endif
        } catch {
            return .failure(AttachmentTakeFailure(fileName: fileName, reason: error.localizedDescription))
        }
    }

    /// At the first use in a process: deletes the copies of earlier launches.
    private static func prepareRoot() throws {
        try isRootPrepared.withLock { isPrepared in
            guard !isPrepared else { return }
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: root.path) {
                try fileManager.removeItem(at: root)
            }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            isPrepared = true
        }
    }
}

/// A file or image that could not be taken.
struct AttachmentTakeFailure: Error, Sendable {
    let fileName: String
    let reason: String
}

/// What the pickers share: drops, image conversion, and the error reports.
enum AttachmentTaking {
    /// A dropped item: its file URL, taken inside the load's completion; else its image, converted to PNG.
    static func take(_ provider: NSItemProvider) async -> Result<AttachmentInput, AttachmentTakeFailure> {
        let suggestedName = provider.suggestedName ?? "file"
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    guard let url else {
                        let reason = error?.localizedDescription ?? "no file URL"
                        continuation.resume(returning: .failure(AttachmentTakeFailure(fileName: suggestedName,
                                                                                      reason: reason)))
                        return
                    }
                    continuation.resume(returning: AttachmentFiles.take(url))
                }
            }
        }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                guard let data else {
                    let reason = error?.localizedDescription ?? "no image data"
                    continuation.resume(returning: .failure(AttachmentTakeFailure(fileName: "Dropped Image.png",
                                                                                  reason: reason)))
                    return
                }
                continuation.resume(returning: image(data, fileName: "Dropped Image.png"))
            }
        }
    }

    /// Image data converted with `ImageDecoding.pngData(of:)`.
    static func image(_ data: Data, fileName: String) -> Result<AttachmentInput, AttachmentTakeFailure> {
        guard let png = ImageDecoding.pngData(of: data) else {
            return .failure(AttachmentTakeFailure(fileName: fileName, reason: "the image could not be converted"))
        }
        return .success(AttachmentInput(fileName: fileName, source: .data(png), size: png.count))
    }

    /// The attachments taken, in order; each failure is logged and reported as "Couldn't attach “<name>”.".
    @MainActor
    static func collect(_ results: [Result<AttachmentInput, AttachmentTakeFailure>],
                        report: (String) -> Void) -> [AttachmentInput] {
        var inputs: [AttachmentInput] = []
        for result in results {
            switch result {
            case .success(let input):
                inputs.append(input)
            case .failure(let failure):
                Log.ui.error("Could not attach a file: \(failure.reason)")
                report("Couldn't attach “\(failure.fileName)”.")
            }
        }
        return inputs
    }
}
