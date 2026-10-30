import Foundation
import Yams

/// The front matter of a skill's SKILL.md (docs/claude/skills.md §4): the text between a first line that is exactly
/// `---` (after an optional UTF-8 byte order mark) and the next line that is exactly `---`, parsed with Yams.
public enum SkillFrontMatter {
    /// The problem text of section 4 for a SKILL.md content, nil when valid. (That SKILL.md exists is checked by the
    /// caller.)
    public static func problem(in content: Data, skillName: String) -> String? {
        guard let text = String(data: content, encoding: .utf8) else {
            return "SKILL.md is not UTF-8 text."
        }
        guard let range = frontMatterRange(in: text) else {
            return "SKILL.md has no front matter between --- lines."
        }
        let mapping: Node.Mapping
        switch parse(String(text[range])) {
        case .success(let parsed):
            mapping = parsed
        case .failure(let failure):
            return "The front matter is not a valid YAML mapping: \(failure.reason)."
        }
        guard stringValue(in: mapping, forKey: "name") == skillName else {
            return "name in the front matter must be \"\(skillName)\"."
        }
        guard let description = stringValue(in: mapping, forKey: "description"),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "description is missing in the front matter."
        }
        guard description.count <= maxDescriptionLength else {
            return "description is longer than 1024 characters."
        }
        return nil
    }

    /// The description of a valid SKILL.md, nil otherwise.
    public static func description(in content: Data) -> String? {
        guard let text = String(data: content, encoding: .utf8),
              let range = frontMatterRange(in: text),
              case .success(let mapping) = parse(String(text[range])),
              let description = stringValue(in: mapping, forKey: "description"),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              description.count <= maxDescriptionLength
        else { return nil }
        return description
    }

    /// The SKILL.md of skills.create. The description has its line breaks replaced by spaces and is trimmed; the front
    /// matter is emitted by Yams from an ordered mapping (`name`, then `description`), so the description is quoted
    /// when YAML needs it.
    public static func template(name: String, description: String) -> String {
        let oneLine = String(description.map { $0.isNewline ? " " : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let values = TemplateValues(name: name, description: oneLine)
        let frontMatter = (try? YAMLCoding.makeEncoder().encode(values)) ?? "name: \(name)\ndescription: \(oneLine)\n"
        return "---\n" + frontMatter + "---\n\n# \(name)\n\nWrite here the instructions Claude follows when it uses this skill.\n"
    }

    /// The content with `name` set to `newName`; nil when the front matter cannot be parsed. The other keys keep their
    /// order and the body is unchanged.
    public static func renamed(_ content: String, to newName: String) -> String? {
        guard let range = frontMatterRange(in: content),
              case .success(var mapping) = parse(String(content[range]))
        else { return nil }
        let value = Node.scalar(newName.represented())
        if let index = mapping.firstIndex(where: { $0.key.scalar?.string == "name" }) {
            mapping[index] = (key: mapping[index].key, value: value)
        } else {
            mapping[Node("name")] = value
        }
        guard let frontMatter = try? Yams.serialize(node: .mapping(mapping), indent: 2, width: -1, allowUnicode: true,
                                                    sortKeys: false, newLineScalarStyle: .literal)
        else { return nil }
        return String(content[..<range.lowerBound]) + frontMatter + String(content[range.upperBound...])
    }

    // MARK: - Private

    private static let maxDescriptionLength = 1024

    private struct TemplateValues: Encodable {
        let name: String
        let description: String
    }

    private struct ParseFailure: Error {
        let reason: String
    }

    /// The front matter as a mapping, or why it is not one.
    private static func parse(_ frontMatter: String) -> Result<Node.Mapping, ParseFailure> {
        let node: Node?
        do {
            node = try Yams.compose(yaml: frontMatter)
        } catch {
            return .failure(ParseFailure(reason: YAMLCoding.problem(of: error)))
        }
        switch node {
        case .mapping(let mapping)?:
            return .success(mapping)
        case nil:
            return .failure(ParseFailure(reason: "it is empty"))
        case .sequence?:
            return .failure(ParseFailure(reason: "it is a sequence"))
        case .scalar?, .alias?:
            return .failure(ParseFailure(reason: "it is a scalar"))
        }
    }

    /// The value of `key` when it is a string scalar.
    private static func stringValue(in mapping: Node.Mapping, forKey key: String) -> String? {
        guard let value = mapping.first(where: { $0.key.scalar?.string == key })?.value,
              case .scalar(let scalar) = value,
              value.tag.rawValue == Tag.Name.str.rawValue
        else { return nil }
        return scalar.string
    }

    /// The range of the front matter's text: from after the opening `---` line to the start of the closing `---` line.
    /// Lines end with LF; a CR before it is not part of the line.
    private static func frontMatterRange(in text: String) -> Range<String.Index>? {
        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        if utf8.starts(with: [0xEF, 0xBB, 0xBF]) {
            lineStart = utf8.index(lineStart, offsetBy: 3)
        }
        let firstLine = line(in: utf8, from: lineStart)
        guard isFence(utf8[lineStart..<firstLine.end]), let contentStart = firstLine.next else { return nil }
        lineStart = contentStart
        while true {
            let current = line(in: utf8, from: lineStart)
            if isFence(utf8[lineStart..<current.end]) {
                return contentStart..<lineStart
            }
            guard let next = current.next else { return nil }
            lineStart = next
        }
    }

    /// The end of the line starting at `start` (before its LF) and the start of the next line (nil after the last).
    private static func line(in utf8: String.UTF8View, from start: String.Index) -> (end: String.Index, next: String.Index?) {
        guard let newline = utf8[start...].firstIndex(of: UInt8(ascii: "\n")) else {
            return (utf8.endIndex, nil)
        }
        return (newline, utf8.index(after: newline))
    }

    /// The line is exactly `---` (a CR at its end ignored).
    private static func isFence(_ line: Substring.UTF8View) -> Bool {
        var bytes = Array(line)
        if bytes.last == UInt8(ascii: "\r") {
            bytes.removeLast()
        }
        return bytes == Array("---".utf8)
    }
}
