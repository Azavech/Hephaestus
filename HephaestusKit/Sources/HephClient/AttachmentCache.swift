import Foundation

/// The device's cache of the files downloaded from the Mains: task attachments, files attached to session messages and
/// large project files (docs/client/workspace.md, "Cache paths"; docs/data/app-storage.md, "Caches").
public struct AttachmentCache: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// <Caches>/Hephaestus/Attachments. It does not throw; the folders are created by the downloads.
    public static func standard() -> AttachmentCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return AttachmentCache(root: caches.appending(path: "Hephaestus", directoryHint: .isDirectory)
            .appending(path: "Attachments", directoryHint: .isDirectory))
    }

    /// `<mainDeviceID>/<projectID>/tasks/<taskID>/<fileName>`
    public func taskAttachment(mainDeviceID: UUID, projectID: String, taskID: String, fileName: String) -> URL {
        projectFolder(mainDeviceID: mainDeviceID, projectID: projectID)
            .appending(path: "tasks", directoryHint: .isDirectory)
            .appending(component: taskID, directoryHint: .isDirectory)
            .appending(component: fileName, directoryHint: .notDirectory)
    }

    /// `<mainDeviceID>/<projectID>/sessions/<session id in lowercase>/<fileName>`
    public func sessionAttachment(mainDeviceID: UUID, projectID: String, sessionID: UUID, fileName: String) -> URL {
        projectFolder(mainDeviceID: mainDeviceID, projectID: projectID)
            .appending(path: "sessions", directoryHint: .isDirectory)
            .appending(component: sessionID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(component: fileName, directoryHint: .notDirectory)
    }

    /// `<mainDeviceID>/<projectID>/files/<path>`, `path` being a project path.
    public func projectFile(mainDeviceID: UUID, projectID: String, path: String) -> URL {
        var url = projectFolder(mainDeviceID: mainDeviceID, projectID: projectID)
            .appending(path: "files", directoryHint: .isDirectory)
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            url = url.appending(component: String(component), directoryHint: .inferFromPath)
        }
        return url
    }

    /// `<root>/<mainDeviceID in canonical uppercase form>/<projectID>`
    private func projectFolder(mainDeviceID: UUID, projectID: String) -> URL {
        root.appending(component: mainDeviceID.uuidString, directoryHint: .isDirectory)
            .appending(component: projectID, directoryHint: .isDirectory)
    }
}
