#if os(macOS)
import Foundation

/// The rules and the environment of the sessions of cli.md 3.5.
enum ForgeSessionRules {
    /// --allowedTools of feedback (regeneration: false) and regeneration sessions; branch: the setting forge.branch.
    static func allowedTools(regeneration: Bool, branch: String) -> [String] {
        let feedback = [
            "mcp__hephaestus",
            "Bash(git status *)",
            "Bash(git diff *)",
            "Bash(git log *)",
            "Bash(git show *)",
            "Bash(git add *)",
            "Bash(git rm *)",
            "Bash(git commit *)",
            "Bash(git reset --soft origin/\(branch))",
            "Bash(git stash *)",
            "Bash(git fetch origin \(branch))",
            "Bash(git fetch --quiet origin \(branch))",
            "Bash(git pull --rebase origin \(branch))",
            "Bash(git pull --ff-only origin \(branch))",
            "Bash(git rev-parse *)",
            "Bash(git ls-files *)",
            "Bash(git branch *)",
            "Bash(scripts/check-public.sh --staged)",
        ]
        guard regeneration else { return feedback }
        return feedback + [
            "Bash(xcodebuild *)",
            "Bash(swift *)",
            "Bash(scripts/*)",
            "Bash(./scripts/*)",
        ]
    }

    /// --disallowedTools; repositoryRoot: the absolute path of the repository root (below), which starts with "/".
    static func disallowedTools(repositoryRoot: String) -> [String] {
        // The protected paths are absolute, from the repository root, so that each rule starts with Edit(//; Claude
        // Code's settings and the project data folders stay relative to the project root.
        let protectedPaths = [
            "docs/general.md",
            "docs/public-repository.md",
            "scripts/check-public.sh",
            ".githooks/**",
            ".github/**",
            ".gitignore",
            "CLAUDE.md",
            "HephaestusKit/Sources/HephHost/Forge/ForgePushGate.swift",
            "HephaestusKit/Sources/HephHost/Forge/ForgeGit.swift",
            "HephaestusKit/Sources/HephHost/Forge/ForgeChecks.swift",
            "HephaestusKit/Sources/HephHost/Forge/PrivateTerms.swift",
            "HephaestusKit/Sources/HephHost/Claude/ForgeSessionRules.swift",
            "HephaestusKit/Sources/HephHost/Claude/ForgePrompts.swift",
            "HephaestusKit/Sources/HephHost/MCP/MCPToolKinds.swift",
            "HephaestusKit/Tests/HephHostTests/PublicCheckTests.swift",
            "HephaestusKit/Tests/HephHostTests/ForgePushTests.swift",
        ]
        return [
            "Bash(git push *)",
            "Bash(git config *)",
            "Bash(git -c *)",
            "Bash(git remote *)",
            "Bash(git update-ref *)",
            "Bash(git filter-branch *)",
            "Bash(git replace *)",
            "Bash(git notes *)",
            "Bash(git fetch *--upl*)",
            "Bash(git pull *--upl*)",
            "Bash(git diff *--output*)",
            "Bash(git log *--output*)",
            "Bash(git show *--output*)",
            "Bash(git stash *--output*)",
        ] + protectedPaths.map { "Edit(/" + repositoryRoot + "/" + $0 + ")" } + [
            "Edit(.claude/**)",
            "Edit(.mcp.json)",
            "Edit(**/.hephaestus/**)",
        ]
    }

    /// The login environment with the changes below.
    static func environment(_ login: [String: String]) -> [String: String] {
        // Removed: the commit identity, the git settings given in the environment and the GitHub tokens.
        let removed: Set<String> = [
            "GIT_AUTHOR_NAME",
            "GIT_AUTHOR_EMAIL",
            "GIT_COMMITTER_NAME",
            "GIT_COMMITTER_EMAIL",
            "EMAIL",
            "GIT_CONFIG_PARAMETERS",
            "GIT_CONFIG_COUNT",
            "GH_TOKEN",
            "GITHUB_TOKEN",
        ]
        /// GIT_CONFIG_KEY_<n> and GIT_CONFIG_VALUE_<n>, <n> being one or more ASCII digits.
        func isNumbered(_ name: String) -> Bool {
            for prefix in ["GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"] where name.hasPrefix(prefix) {
                let number = name.dropFirst(prefix.count)
                if !number.isEmpty, number.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }) {
                    return true
                }
            }
            return false
        }
        var environment = login.filter { name, _ in !removed.contains(name) && !isNumbered(name) }
        // Added: every push URL rewritten to a scheme without a remote helper, no git hook, UTC dates.
        environment["GIT_CONFIG_COUNT"] = "2"
        environment["GIT_CONFIG_KEY_0"] = "url.hephaestus-no-push://blocked/.pushInsteadOf"
        environment["GIT_CONFIG_VALUE_0"] = ""
        environment["GIT_CONFIG_KEY_1"] = "core.hooksPath"
        environment["GIT_CONFIG_VALUE_1"] = "/dev/null"
        environment["TZ"] = "UTC"
        return environment
    }
}
#endif
