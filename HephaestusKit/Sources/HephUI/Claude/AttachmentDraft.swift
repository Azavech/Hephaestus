import Foundation
import HephClient
import HephCore
import UniformTypeIdentifiers

/// An attachment of a message composer, uploaded to the project's Main as soon as it is added (docs/ui/sessions.md,
/// "Message composer").
public struct AttachmentDraft: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// nil until the first progress report.
        case uploading(TransferProgress?)
        /// at: when the upload completed.
        case uploaded(UploadRef, at: Date)
        /// The error's message.
        case failed(String)
    }

    public let id: UUID
    public var fileName: String
    public var source: UploadSource
    public var size: Int
    public var isImage: Bool
    public var state: State

    /// A new attachment for a picked file or image: a new id, state `uploading(nil)`, `isImage` true when the
    /// `UTType` of the file name's extension conforms to `.image`.
    init(input: AttachmentInput) {
        id = UUID()
        fileName = input.fileName
        source = input.source
        size = input.size
        let fileExtension = (input.fileName as NSString).pathExtension
        isImage = UTType(filenameExtension: fileExtension)?.conforms(to: .image) ?? false
        state = .uploading(nil)
    }

    /// The upload of an `uploaded` attachment.
    var uploadRef: UploadRef? {
        if case .uploaded(let ref, _) = state {
            return ref
        }
        return nil
    }
}

/// The text and the attachments of a message composer.
public struct ComposerDraft: Equatable, Sendable {
    public var text: String = ""
    public var attachments: [AttachmentDraft] = []

    /// The UploadRef of every uploaded attachment, in tray order.
    public var uploads: [UploadRef] {
        attachments.compactMap(\.uploadRef)
    }

    /// Every attachment is uploaded.
    public var isUploaded: Bool {
        attachments.allSatisfy { $0.uploadRef != nil }
    }
}
