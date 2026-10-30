import Foundation

/// The hidden names of docs/services/files.md §6: the file browser hides them unless "Show hidden files" is on, the
/// docs browser always hides them, and search never enters or searches them. `.gitignore` files are not read.
public enum IgnoreRules {
    /// .git, .hephaestus, .build, DerivedData, node_modules, .DS_Store
    public static let hiddenNames: Set<String> = [".git", ".hephaestus", ".build", "DerivedData", "node_modules", ".DS_Store"]

    /// True when `name`, one path component, is in hiddenNames (exact, case-sensitive).
    public static func isHidden(name: String) -> Bool {
        hiddenNames.contains(name)
    }

    /// True when a component of the project path `path` is hidden.
    public static func isHidden(path: String) -> Bool {
        path.split(separator: "/").contains { hiddenNames.contains(String($0)) }
    }
}
