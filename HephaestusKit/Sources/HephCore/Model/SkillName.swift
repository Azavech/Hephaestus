import Foundation

/// Skill names (docs/claude/skills.md §2): the folder name of a skill of a Main's library.
public enum SkillName {
    /// ^[a-z0-9-]{1,64}$
    public static func isValid(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return (1...64).contains(scalars.count)
            && scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}
