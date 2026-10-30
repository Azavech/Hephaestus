import Foundation

/// `projects.json` (Main only): the absolute paths of the top-level projects this Main hosts, in the order they were
/// registered (docs/data/app-storage.md).
public struct ProjectsFile: Codable, Sendable, Equatable {
    public var projects: [String]

    public init(projects: [String]) {
        self.projects = projects
    }

    /// No projects when missing. When unreadable: renamed to projects.json.unreadable (logged), no projects, and
    /// wasReset true.
    public static func load(_ appSupport: AppSupport) -> (file: ProjectsFile, wasReset: Bool) {
        do {
            return (try JSONFile.read(ProjectsFile.self, from: appSupport.projectsFile) ?? ProjectsFile(projects: []), false)
        } catch {
            let message = (error as? DataError)?.message ?? error.localizedDescription
            Log.core.error("Unreadable projects.json: \(message)")
            let source = appSupport.projectsFile
            let target = appSupport.root.appendingPathComponent("projects.json.unreadable", isDirectory: false)
            if rename(source.path, target.path) == 0 {
                Log.core.error("projects.json was renamed to projects.json.unreadable")
            } else {
                let reason = String(cString: strerror(errno))
                Log.core.error("projects.json could not be renamed to projects.json.unreadable: \(reason)")
            }
            return (ProjectsFile(projects: []), true)
        }
    }

    public func save(_ appSupport: AppSupport) throws {
        try JSONFile.write(self, to: appSupport.projectsFile)
    }

    /// Standardizes the path and appends it when it is not in the list.
    public mutating func add(_ path: String) {
        let standardized = Self.standardized(path)
        if !projects.contains(standardized) {
            projects.append(standardized)
        }
    }

    /// Removes the path, compared in its standardized form.
    public mutating func remove(_ path: String) {
        let standardized = Self.standardized(path)
        projects.removeAll { $0 == standardized || $0 == path }
    }

    /// `URL.standardizedFileURL.path`: absolute, `~` expanded, no trailing `/`, symlinks not resolved.
    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
