import Foundation

/// The languages the editor and the Markdown code blocks highlight.
public enum EditorLanguage: String, CaseIterable, Sendable {
    case swift, go, markdown, yaml, json, plain

    /// The language of a file, by the extension of its last path component, compared case-insensitively.
    public init(fileName: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "swift": self = .swift
        case "go": self = .go
        case "md", "markdown": self = .markdown
        case "yml", "yaml": self = .yaml
        case "json": self = .json
        default: self = .plain
        }
    }

    /// The language of a Markdown code fence, by the first word of its info string (split at white space and `{`),
    /// lowercased.
    public init(fenceInfo: String) {
        let word = fenceInfo.split(whereSeparator: { $0.isWhitespace || $0 == "{" }).first?.lowercased() ?? ""
        switch word {
        case "swift": self = .swift
        case "go", "golang": self = .go
        case "md", "markdown": self = .markdown
        case "yml", "yaml": self = .yaml
        case "json": self = .json
        default: self = .plain
        }
    }

    /// What Tab inserts: a tab character for Go, four spaces otherwise.
    public var indentUnit: String {
        self == .go ? "\t" : "    "
    }
}
