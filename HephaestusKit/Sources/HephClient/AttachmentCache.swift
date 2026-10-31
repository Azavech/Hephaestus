import Foundation

/// The device's cache of the files downloaded from the Mains: ticket attachments, files attached to session messages
/// and large project files (docs/client/workspace.md, "Cache paths"; docs/data/app-storage.md, "Caches").
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

    /// `<mainDeviceID>/<projectID>/tickets/<ticketID>/<fileName>`
    public func ticketAttachment(mainDeviceID: UUID, projectID: String, ticketID: String, fileName: String) -> URL {
        projectFolder(mainDeviceID: mainDeviceID, projectID: projectID)
            .appending(path: "tickets", directoryHint: .isDirectory)
            .appending(component: ticketID, directoryHint: .isDirectory)
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

    /// Cache paths: moves the folders of earlier versions to their new name. Earlier versions, which called tickets
    /// tasks, kept ticket attachments in `<mainDeviceID>/<projectID>/tasks/`: each such folder is renamed `tickets`
    /// when the project's folder has no `tickets`, and else deleted (its files are downloaded again when they are
    /// opened). Failures are ignored.
    public func migrateFromTasks() {
        let fileManager = FileManager.default
        guard let mains = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for main in mains {
            guard let projects = try? fileManager.contentsOfDirectory(at: main, includingPropertiesForKeys: nil) else {
                continue
            }
            for project in projects {
                let tasks = project.appending(path: "tasks", directoryHint: .isDirectory)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: tasks.path, isDirectory: &isDirectory), isDirectory.boolValue
                else { continue }
                let tickets = project.appending(path: "tickets", directoryHint: .isDirectory)
                if fileManager.fileExists(atPath: tickets.path) {
                    try? fileManager.removeItem(at: tasks)
                } else {
                    try? fileManager.moveItem(at: tasks, to: tickets)
                }
            }
        }
    }

    /// `<root>/<mainDeviceID in canonical uppercase form>/<projectID>`
    private func projectFolder(mainDeviceID: UUID, projectID: String) -> URL {
        root.appending(component: mainDeviceID.uuidString, directoryHint: .isDirectory)
            .appending(component: projectID, directoryHint: .isDirectory)
    }
}
