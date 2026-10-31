# Images and attachments

files:
- HephaestusKit/Sources/HephUI/Media/ImageViewer.swift
- HephaestusKit/Sources/HephUI/Media/ZoomableImageView.swift
- HephaestusKit/Sources/HephUI/Media/ImageViewerSheet.swift
- HephaestusKit/Sources/HephUI/Media/ImageThumbnail.swift
- HephaestusKit/Sources/HephUI/Media/AttachmentChip.swift
- HephaestusKit/Sources/HephUI/Media/AttachmentView.swift
- HephaestusKit/Sources/HephUI/Media/LargeFileView.swift
- HephaestusKit/Sources/HephUI/Media/AttachmentIcon.swift
- HephaestusKit/Sources/HephUI/Media/ImageDecoding.swift
- HephaestusKit/Sources/HephUI/Media/MediaCache.swift
- HephaestusKit/Sources/HephUI/Media/MediaFiles.swift
- HephaestusKit/Sources/HephUI/Media/AttachmentPicking.swift

---

`HephUI/Media` shows images and attached files: the zoomable image viewer (inline and full screen), image thumbnails,
attachment chips, Quick Look for other files, and the view of project files too large for the editor. It is used by
task comments ([tasks.md](tasks.md#rendering)), the attachments of session messages
([sessions.md](sessions.md#transcript)) and files opened in the Code section ([code.md](code.md#content)). It also owns
attachment picking: the attach menu, drops and pastes that give the `AttachmentInput` values of session messages and
task comments ([Attachment picking](#attachment-picking)).

The views never send requests themselves: the caller gives a `download` closure (`DownloadAction`) that brings the
file into the device's attachment cache and returns its local URL, reporting progress (`downloadAttachment`,
`downloadSessionAttachment` or `downloadFile` of [../client/workspace.md](../client/workspace.md#transfers)), and a
`cacheKey`, a string unique to that file (for example `<projectID>/<taskID>/<file>`). Files have no size limit. Errors
show in the view that failed, with a Retry button, and in the window's `WindowBanners`
([shell.md](shell.md#81-windowbanners)) where this doc says so.

## Swift API

```swift
// HephUI/Media — views are @MainActor; they read WindowBanners from the environment.

/// Zoomable, pannable image that fits its frame at first. Shows nothing for data that is not an image.
public struct ImageViewer: View {
    public init(data: Data, fileName: String)
}

public struct ImageViewerItem: Identifiable, Sendable {
    public let id: UUID
    public let data: Data
    public let fileName: String
    public init(data: Data, fileName: String)        // id = UUID()
}

extension View {
    /// Presents the full-screen image viewer while `item` is not nil.
    public func imageViewer(item: Binding<ImageViewerItem?>) -> some View
}

/// Brings a file into the attachment cache and returns its local URL; reports progress on the main actor.
/// Declared in AttachmentView.swift.
public typealias DownloadAction =
    @MainActor (_ progress: @escaping @MainActor (TransferProgress) -> Void) async throws -> URL

/// Thumbnail of an image attachment; opens the full-screen viewer.
public struct ImageThumbnail: View {
    public init(fileName: String, mimeType: String, size: Int, cacheKey: String,
                maxSize: CGSize = CGSize(width: 240, height: 180), download: @escaping DownloadAction)
}

/// Chip with the name and size of an attachment; opens Quick Look after download.
public struct AttachmentChip: View {
    public init(fileName: String, mimeType: String, size: Int, cacheKey: String, download: @escaping DownloadAction)
}

/// ImageThumbnail when mimeType starts with "image/", else AttachmentChip.
public struct AttachmentView: View {
    public init(fileName: String, mimeType: String, size: Int, cacheKey: String, download: @escaping DownloadAction)
}

/// A project file too large for the editor: an image is downloaded and shown in an ImageViewer, another file opens in
/// Quick Look on demand (LargeFileView).
public struct LargeFileView: View {
    public init(fileName: String, download: @escaping DownloadAction)
}

public enum AttachmentIcon {
    public static func symbolName(mimeType: String, fileName: String) -> String
}
```

`size` is in bytes (`TaskAttachment.size`, [../protocol/types.md](../protocol/types.md#taskattachment)); `mimeType` is
the attachment's `type`. `TransferProgress` is defined in [../client/workspace.md](../client/workspace.md#transfers).

## Loading and caching

- Files come from `download`: the client returns at once a file that its attachment cache already holds, and
  otherwise reads it in ranges of 4 MiB, reporting `TransferProgress` after each
  ([../client/workspace.md](../client/workspace.md#downloading)). The views read the downloaded file with
  `Data(contentsOf: url, options: .mappedIfSafe)`, in a detached task.
- A view's download runs in its own task: it is cancelled when the view goes away (`.task`), and the client then
  deletes the partial file; the next appearance starts again.
- While a download runs, the view shows its progress: a determinate `ProgressView(value: progress.fraction)` once a
  report arrived, an indeterminate one before. When it fails, the view shows the failure with a Retry button that
  calls `download` again; a cancellation shows nothing.
- `MediaCache` (internal, main-actor): an `NSCache` of decoded thumbnails (`CGImage`) by `cacheKey` and maximum pixel
  size, `totalCostLimit` 100 MiB, cost = width × height × 4. Thumbnails look there before downloading and decoding.
- `ImageDecoding` (internal, not isolated, ImageIO only):
  - `pixelSize(of data: Data) -> CGSize?`: `kCGImagePropertyPixelWidth` and `kCGImagePropertyPixelHeight` of the
    first image, swapped when `kCGImagePropertyOrientation` is 5 to 8; nil when ImageIO cannot read the data.
  - `thumbnail(of data: Data, maxPixelSize: Int) -> CGImage?`: `CGImageSourceCreateThumbnailAtIndex` with
    `kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceCreateThumbnailWithTransform` and
    `kCGImageSourceThumbnailMaxPixelSize`.
  - `pngData(of data: Data) -> Data?`: the first image upright at full size (`thumbnail(of:maxPixelSize:)` with the
    larger side of `pixelSize(of:)`), encoded by `CGImageDestinationCreateWithData` with `UTType.png.identifier` and
    one image; nil when ImageIO cannot read the data.
  Decoding runs in a detached task, off the main actor.
- One image pixel is one point everywhere in this doc.

## ImageThumbnail

| State       | View                                                                                                                                                                                                                                                                                                                                                          |
|-------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| downloading | a rounded rectangle 120 × 90 pt (`Color.secondary.opacity(0.1)`, corner radius 6) holding the download progress: a `ProgressView(value: progress.fraction)` 80 pt wide (indeterminate before the first report) and "<completed> of <total>" (`ByteCountFormatter`, `.file`, `.caption2`, secondary; 0 of `size` before the first report: "Zero KB of <size>") |
| loaded      | the thumbnail: `thumbnail(of:maxPixelSize: 2 × max(maxSize.width, maxSize.height))` shown `.resizable()`, `.aspectRatio(contentMode: .fit)`, at most `maxSize` and at most the image's pixel size; corner radius 6; 1 pt border `Color.secondary.opacity(0.3)`                                                                                                |
| failed      | the same rectangle holding `exclamationmark.triangle.fill` (orange), "Download failed" (`.caption`) and a "Retry" button (`.borderless`, `.caption`) that downloads again; the error's message in the help tag and as accessibility value                                                                                                                     |
| not decoded | the `AttachmentChip` of the same file (the downloaded data is not an image ImageIO can read)                                                                                                                                                                                                                                                                  |

- The download and the decoding start in `.task(id: cacheKey)`, after a look in `MediaCache`.
- Tap or click (loaded): the full-screen viewer (`.imageViewer(item:)`) with the data of the downloaded file; when the
  thumbnail came from `MediaCache`, `download` is called first (it returns the cached file at once).
- `.accessibilityLabel(fileName)`, `.help(fileName)` on macOS.

## AttachmentChip

- An `HStack(spacing: 6)`: a 16 pt leading element, then a `VStack(alignment: .leading)` with the file name
  (`.callout`, one line, middle truncation, at most 200 pt wide) and a second line (`.caption`, secondary), then a
  trailing element:

| State       | Leading                                                                                     | Second line                                                                                                        | Trailing                                     |
|-------------|---------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|----------------------------------------------|
| idle        | the symbol of `AttachmentIcon.symbolName(mimeType:fileName:)`                               | the size (`ByteCountFormatter`, `.file`)                                                                           | none                                         |
| downloading | a circular `ProgressView(value: progress.fraction)` (indeterminate before the first report) | "<completed> of <total>" (`ByteCountFormatter`, `.file`; 0 of `size` before the first report: "Zero KB of <size>") | none                                         |
| failed      | `exclamationmark.triangle.fill` (orange)                                                    | "Download failed"                                                                                                  | a "Retry" button (`.borderless`, `.caption`) |

- 6 pt vertical and 10 pt horizontal padding; background `Color.secondary.opacity(0.12)` in a rounded rectangle of
  corner radius 8. A plain button; `.accessibilityLabel("<name>, <size>")`, `.help(fileName)` on macOS (failed: the
  error's message).
- Tap or click (idle or failed), ignored while a download runs; Retry does the same:
  1. `download(progress)`: the chip is `downloading` and follows the reports.
  2. Quick Look shows the returned file: `.quickLookPreview($previewURL)` (SwiftUI modifier of the QuickLook
     framework), which uses `QLPreviewPanel` on macOS and `QLPreviewController` on iOS and iPadOS. Closing the preview
     sets `previewURL` to nil; the chip is idle again.
  A failure of step 1 sets the chip to failed and shows the error banner "Couldn't open “<name>”: <message>".

### AttachmentIcon

The MIME type is compared in lowercase, without its parameters (after `;`).

| MIME type                                                                                                                               | Symbol                                                                                                                                                                                                            |
|-----------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `image/*`                                                                                                                               | `photo`                                                                                                                                                                                                           |
| `video/*`                                                                                                                               | `film`                                                                                                                                                                                                            |
| `audio/*`                                                                                                                               | `waveform`                                                                                                                                                                                                        |
| `application/pdf`                                                                                                                       | `doc.richtext`                                                                                                                                                                                                    |
| `text/*`, `application/json`, `application/yaml`, `application/x-yaml`, `application/xml`                                               | `doc.text`                                                                                                                                                                                                        |
| `application/zip`, `application/gzip`, `application/x-tar`, `application/x-bzip2`, `application/x-xz`, `application/x-7z-compressed`    | `doc.zipper`                                                                                                                                                                                                      |
| `application/octet-stream`, empty                                                                                                       | from the file name's `UTType(filenameExtension:)`: conforms to `.image` → `photo`, `.movie` → `film`, `.audio` → `waveform`, `.pdf` → `doc.richtext`, `.text` → `doc.text`, `.archive` → `doc.zipper`, else `doc` |
| anything else                                                                                                                           | `doc`                                                                                                                                                                                                             |

## Quick Look files

Quick Look opens the downloaded files of the attachment cache directly. `MediaFiles` (internal, main-actor) writes the
files that Share needs for data held in memory (the full-screen viewer).

- Root: `FileManager.default.temporaryDirectory/Hephaestus-Media/`. The first use in a process deletes the root with
  its content (files of earlier launches), then creates it.
- `file(for data: Data, fileName: String, key: String) throws -> URL`: the folder is the root plus the first 16 hex
  characters of the SHA-256 of `key` (CryptoKit); the file name is `fileName` with `/` and `:` replaced by `-` (`file`
  when empty). The data is written atomically when the file does not exist yet; the URL is returned. The same key gives
  the same file for the life of the process.
- `existingFile(key: String, fileName: String) -> URL?`: that URL when the file exists.

## LargeFileView

`LargeFileView(fileName:download:)` stands in for the editor when a project file is larger than 10 MiB
([code.md](code.md#content)); its `download` reads the file with ranged `files.read` (`downloadFile`,
[../client/workspace.md](../client/workspace.md#downloading)).

A centered `VStack(spacing: 8)`: the symbol of `AttachmentIcon.symbolName(mimeType: "", fileName:)` (32 pt,
secondary), the file name (headline), "This file is larger than 10 MB." (secondary), then by state:

| State       | Shown under the texts                                                                                                                                                                                                                                                               |
|-------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| ready       | a button (`.bordered`): "Show Image" for an image file, "Quick Look" for another file                                                                                                                                                                                               |
| downloading | a `ProgressView(value: progress.fraction)` 240 pt wide (indeterminate before the first report), "<completed> of <total>" (`ByteCountFormatter`, `.file`, `.caption`, secondary), shown from the first report on since the view does not know the size before, and a "Cancel" button |
| failed      | "Couldn't download “<name>”: <message>" (`.caption`, red) and a "Retry" button                                                                                                                                                                                                      |
| image       | instead of the whole column, the `ImageViewer` of the downloaded file's data, filling the view                                                                                                                                                                                      |

- An image file has one of the image extensions of [code.md](code.md#loading) (compared ignoring case). The download
  starts when the view appears (`.task(id: fileName)`); then the image state. Data that ImageIO cannot read gives the
  ready state with the "Quick Look" button.
- Another file starts ready. "Quick Look" downloads it, then `.quickLookPreview($previewURL)` opens the returned file;
  closing the preview returns to ready. "Show Image" downloads and shows the image.
- Cancel cancels the download's task (the client deletes the partial file) and returns to ready. Retry downloads
  again.

## ImageViewer

`ImageViewer(data:fileName:)` decodes the data (`NSImage(data:)` on macOS, `UIImage(data:)` on iOS and iPadOS, both at
one pixel per point) and shows it in `ZoomableImageView`, the platform scroll view below, with a clear background.

Zoom rules, the same on every platform:

- `fit` = min(view width / image width, view height / image height).
- Minimum zoom = min(1, `fit`): a large image starts fitted, a small one at its actual size. Maximum zoom = 8.
- The image starts at the minimum zoom, centered. While the zoom is the minimum (within 0.001), a change of the view's
  size computes the minimum again and applies it.
- Double click or double tap: at the minimum zoom, zoom to min(8, max(1, 2 × minimum)) around the point; otherwise back
  to the minimum. Pinch zooms between the limits; dragging or scrolling pans when the image is larger than the view.
- An image smaller than the view is centered.

| Platform       | `ZoomableImageView`                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
|----------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| macOS          | `NSScrollView` with `allowsMagnification = true`, `minMagnification` and `maxMagnification` from the rules, `hasVerticalScroller` and `hasHorizontalScroller` true, `autohidesScrollers = true`, `drawsBackground = false`; its clip view centers a smaller document view; the document view is an `NSImageView` whose frame is the image's pixel size. Double click: an `NSClickGestureRecognizer` with `numberOfClicksRequired = 2`, then `setMagnification(_:centeredAt:)` |
| iOS and iPadOS | `UIScrollView` with `minimumZoomScale` and `maximumZoomScale` from the rules, scroll indicators hidden, `contentInsetAdjustmentBehavior = .never`, `viewForZooming` returning a `UIImageView` sized to the image; centering by setting `contentInset` to half the free space in `scrollViewDidZoom(_:)` and `layoutSubviews()`. Double tap: a `UITapGestureRecognizer` with `numberOfTapsRequired = 2`, then `zoom(to:animated: true)` with a rect around the tap point       |

`ImageZoomControl` (internal, main-actor) lets the full-screen viewer drive the zoom: `zoomIn()` multiplies the zoom
by 1.5, `zoomOut()` divides it by 1.5, both clamped to the limits, and `zoomToFit()` goes back to the minimum.
`ImageViewer` has an internal initializer that takes one.

## Full-screen viewer

`.imageViewer(item:)` presents, while `item` is not nil:

| Platform       | Presentation                                                                                                                                                                                                                     |
|----------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| iOS and iPadOS | `.fullScreenCover(item:)`: black background under the safe areas, the `ImageViewer`, and a top bar: Done (leading), the file name (white, one line), Share (trailing)                                                            |
| macOS          | `.sheet(item:)` sized `minWidth` 640, `idealWidth` 1000, `minHeight` 480, `idealHeight` 750 pt: a top bar with the file name (headline), Zoom Out, Zoom to Fit, Zoom In, Share, Save…, Done; under it the `ImageViewer` on black |

| Control     | Symbol                                         | Shortcut | Action                                                                                                                                                                                                                                                                                        |
|-------------|------------------------------------------------|----------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Done        | —                                              | Escape   | dismisses (`item = nil`)                                                                                                                                                                                                                                                                      |
| Zoom Out    | `minus.magnifyingglass`                        | ⌘−       | `zoomOut()` (macOS)                                                                                                                                                                                                                                                                           |
| Zoom to Fit | `arrow.up.left.and.down.right.magnifyingglass` | ⌘0       | `zoomToFit()` (macOS)                                                                                                                                                                                                                                                                         |
| Zoom In     | `plus.magnifyingglass`                         | ⌘=       | `zoomIn()` (macOS)                                                                                                                                                                                                                                                                            |
| Share       | `square.and.arrow.up`                          | —        | `ShareLink(item:)` of `MediaFiles.file(for:fileName:key:)` with the key `viewer/<item id>`, written on the main actor when the viewer appears (`.task(id: item.id)`); Share is disabled until the file is written; on iOS and iPadOS the share sheet also offers Save Image and Save to Files |
| Save…       | —                                              | —        | macOS: an `NSSavePanel` (`nameFieldStringValue` = the file name, `canCreateDirectories = true`); OK writes the data atomically; an error shows "Couldn't save “<name>”: <message>" in the window's error banner                                                                               |

## Attachment picking

The attach menu, drops and pastes turn files and images into `AttachmentInput` values: a file name, an `UploadSource`
([../client/workspace.md](../client/workspace.md#transfers)) and a size. `MessageComposer`
([sessions.md](sessions.md#message-composer)), the composer of session messages and task comments
([tasks.md](tasks.md#composer)), uploads each one in chunks as soon as it receives it. Files and images have no size
limit, and files are not read here.

```swift
// HephUI/Media/AttachmentPicking.swift — @MainActor. The button and the modifier read WindowBanners from the
// environment.

/// A file or an image to attach, before its upload.
public struct AttachmentInput: Sendable, Hashable {
    public var fileName: String
    public var source: UploadSource       // .file for files, .data for images and photos
    public var size: Int                  // bytes
    public init(fileName: String, source: UploadSource, size: Int)
}

/// The attach menu (`paperclip`): Choose Files… on every platform, Photo Library… on iOS and iPadOS.
public struct AttachmentPickerButton: View {
    public init(onAdd: @escaping @MainActor ([AttachmentInput]) -> Void)
}

extension View {
    /// Accepts files and images dropped on the view.
    public func attachmentDrop(onAdd: @escaping @MainActor ([AttachmentInput]) -> Void) -> some View
}

/// The files and images on a pasteboard, for ⌘V in a composer's text view. nil: nothing to attach.
@MainActor public enum AttachmentPasteboard {
    #if os(macOS)
    public static func attachments(from pasteboard: NSPasteboard = .general) -> [AttachmentInput]?
    #else
    public static func attachments(from pasteboard: UIPasteboard = .general) -> [AttachmentInput]?
    #endif
}

/// The temporary copies of attached files (Files).
public enum AttachmentFiles {
    /// Deletes the file of a `.file` source when it is a temporary copy made here; does nothing otherwise.
    public static func discard(_ source: UploadSource)
}
```

`onAdd` is called on the main actor, once per choice or drop, with the attachments in order; it is not called when
none could be taken.

| Source         | Platforms   | Takes                                                                | `fileName`                                      | `source`                                                                           |
|----------------|-------------|----------------------------------------------------------------------|-------------------------------------------------|------------------------------------------------------------------------------------|
| Choose Files…  | all         | the chosen files                                                     | the file's name                                 | `.file`, taken as in [Files](#files)                                               |
| Photo Library… | iOS, iPadOS | the chosen photos                                                    | "Photo.<extension>"                             | `.data`: the photo's data                                                          |
| drop           | all         | each dropped item: its file URL, else its image                      | a file: its name; an image: "Dropped Image.png" | a file: `.file`, taken as in [Files](#files); an image: `.data`, converted to PNG  |
| paste          | macOS       | the file URLs; when there is none and no text, the PNG or TIFF image | a file: its name; the image: "Pasted Image.png" | a file: `.file`, taken as in [Files](#files); the image: `.data`, converted to PNG |
| paste          | iOS, iPadOS | the images, when there is no text                                    | "Pasted Image.png"                              | `.data`: the image converted to PNG                                                |

`size` is the count of the data, or the file's size. A file or image that cannot be taken (not a regular file, a
failed copy, a failed conversion) is left out: the error banner shows "Couldn't attach “<name>”." and the error is
logged (`Log.ui`).

### Attach menu

- `AttachmentPickerButton` is a `Menu` labeled `Label("Attach", systemImage: "paperclip")` with
  `.labelStyle(.iconOnly)`. It keeps the platform's default menu style, chevron included: no `.menuStyle`,
  `.buttonStyle`, padding or frame of its own. Its items set state: "Choose Files…" sets `isImporterPresented`; "Photo
  Library…" (iOS and iPadOS) sets `isPhotosPickerPresented`.
- The pickers are modifiers of the menu, not menu items:
  `.fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true)` and,
  on iOS and iPadOS, `.photosPicker(isPresented: $isPhotosPickerPresented, selection: $photoItems,
  maxSelectionCount: 10, matching: .images)` (PhotosUI).
- Choose Files…: each chosen URL is taken ([Files](#files)) between `startAccessingSecurityScopedResource()` and, when
  that returned true, `stopAccessingSecurityScopedResource()`. A failure of the importer shows the error banner with
  its message.
- Photo Library…: when `photoItems` becomes non-empty, each item in order gives its data with
  `loadTransferable(type: Data.self)` (an error or a nil result: the photo cannot be taken); `<extension>` is the
  `preferredFilenameExtension` of the first of its `supportedContentTypes`, else `jpg`. Then `photoItems` is set to
  `[]`.

### Drops

- `attachmentDrop(onAdd:)` is `.onDrop(of: [.fileURL, .image], isTargeted: nil)`, whose action returns true.
- Each `NSItemProvider`, in order: when it has an item conforming to `.fileURL`, `loadObject(ofClass: URL.self)` gives
  the file, taken as in [Files](#files) inside the load's completion; else `loadDataRepresentation(forTypeIdentifier:
  UTType.image.identifier)` gives the image, converted with `ImageDecoding.pngData(of:)`.
- `onAdd` is called once every provider has given its attachment or failed.
- In "Couldn't attach “<name>”.", `<name>` is the provider's `suggestedName` (else "file") for a file whose URL cannot
  be loaded, and "Dropped Image.png" for an image.

### Pastes

`AttachmentPasteboard.attachments(from:)` runs at once on the main actor. It returns nil when the pasteboard holds
nothing to attach (the text view then pastes as usual), else the attachments it could take, which the text view adds
instead of pasting (possibly none):

| Platform       | Attachments, in this order of preference                                                                                                                                                                                                                                    |
|----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| macOS          | the file URLs of `readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])`, taken as in [Files](#files); else, when `string(forType: .string)` is nil, the data of type `.png`, else `.tiff`, converted with `ImageDecoding.pngData(of:)`; else nil |
| iOS and iPadOS | when `hasImages` is true and `hasStrings` is false, each element of `images`, drawn upright by a `UIGraphicsImageRenderer` of its `size` whose format has its `scale` (`pngData { _ in image.draw(at: .zero) }`); else nil                                                  |

It has no environment: it posts its error banners with `AppModel.shared.banners.post(Banner(style: .error, message:))`
([shell.md](shell.md#82-appbannerrouter)), which shows them in the active window, the one pasted into.

### Files

- A file must be a regular file (`URLResourceValues.isRegularFile`); its name is the URL's `lastPathComponent` and its
  size the `fileSize` resource value. Its content is not read here: the upload reads it chunk by chunk
  ([../client/workspace.md](../client/workspace.md#uploading)).
- macOS: the source is `.file(<the URL>)`.
- iOS and iPadOS: a chosen or dropped URL is usable only while the importer's security-scoped access is open or inside
  the drop's completion, so the file is copied there (`FileManager.default.copyItem(at:to:)`) to
  `<temporary directory>/Hephaestus-Attachments/<new UUID>/<name>`; the source is `.file(<the copy>)`.
- The folder `Hephaestus-Attachments/` is deleted with its content at its first use in a process (copies of earlier
  launches). `AttachmentFiles.discard(_:)` deletes the `<UUID>` folder of one copy; the composer calls it when the
  attachment leaves its draft ([sessions.md](sessions.md#message-composer)).
- Choices take their files in a detached task, drops inside the load's completion; pastes take them at once.

## Depends on

- [shell.md](shell.md): `WindowBanners`, `AppModel.banners`. [../protocol/types.md](../protocol/types.md):
  `TaskAttachment` (`type`, `size`), for the callers. [../client/workspace.md](../client/workspace.md#transfers):
  `UploadSource`, `TransferProgress`, the download functions the callers pass as `download`.
- [../architecture.md](../architecture.md#logging): `Log.ui`.
- Frameworks: ImageIO, QuickLook (SwiftUI `quickLookPreview`), UniformTypeIdentifiers, CryptoKit, PhotosUI (iOS and
  iPadOS), AppKit and UIKit.
