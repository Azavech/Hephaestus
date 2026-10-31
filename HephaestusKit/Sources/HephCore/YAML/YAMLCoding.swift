import Foundation
import Yams

/// The known keys of a YAML file, used to keep unknown keys on rewrite.
public indirect enum YAMLShape: Sendable {
    case value
    case mapping([String: YAMLShape])
    case list(identity: String, item: YAMLShape)
}

/// Reads and writes every YAML file of Hephaestus with Yams (docs/data/project-yml.md, "YAML coding").
public enum YAMLCoding {
    /// indent 2, width -1, allowUnicode true, newLineScalarStyle .literal.
    public static func makeEncoder() -> YAMLEncoder {
        let encoder = YAMLEncoder()
        encoder.options = YAMLEncoder.Options(indent: 2, width: -1, allowUnicode: true, sortKeys: false,
                                              newLineScalarStyle: .literal)
        return encoder
    }

    /// Encodes `value`; when `previousText` is a YAML mapping, removes its top-level `retiredKeys`, then merges its
    /// unknown keys with `shape`. Throws `DataError.io` when the value cannot be encoded.
    public static func encode<T: Encodable>(_ value: T, shape: YAMLShape, preserving previousText: String?,
                                            retiredKeys: Set<String> = []) throws -> String {
        let text: String
        do {
            text = try makeEncoder().encode(value)
        } catch {
            throw DataError.io("cannot encode the file: \(problem(of: error))")
        }
        guard let previousText,
              var old = try? Yams.compose(yaml: previousText), var oldMapping = old.mapping
        else { return text }
        if !retiredKeys.isEmpty {
            let kept = oldMapping.filter { pair in
                guard let name = pair.key.scalar?.string else { return true }
                return !retiredKeys.contains(name)
            }
            oldMapping = Node.Mapping(kept.map { ($0.key, $0.value) }, oldMapping.tag, oldMapping.style)
            old = .mapping(oldMapping)
        }
        do {
            guard let new = try Yams.compose(yaml: text) else { return text }
            return try Yams.serialize(node: merge(new: new, old: old, shape: shape), indent: 2, width: -1,
                                      allowUnicode: true, sortKeys: false, newLineScalarStyle: .literal)
        } catch {
            throw DataError.io("cannot encode the file: \(problem(of: error))")
        }
    }

    /// Decodes `text`; errors are DataError with messages prefixed by `fileName`.
    public static func decode<T: Decodable>(_ type: T.Type, from text: String, fileName: String) throws -> T {
        guard !text.allSatisfy({ $0.isWhitespace }) else {
            throw DataError.unreadable("\(fileName): the file is empty")
        }
        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch {
            throw DataError.unreadable("\(fileName): \(problem(of: error))")
        }
        guard let root, root.mapping != nil else {
            throw DataError.unreadable("\(fileName): the file is not a YAML mapping")
        }
        do {
            return try YAMLDecoder().decode(type, from: root)
        } catch let error as DataError {
            throw error
        } catch let error as DecodingError {
            throw DataError.invalid("\(fileName): \(problem(of: error))")
        } catch {
            throw DataError.unreadable("\(fileName): \(problem(of: error))")
        }
    }

    /// Merges the node of a new text with the node of the text the file had just before the write, so that the keys
    /// `shape` does not know keep their old values.
    public static func merge(new: Node, old: Node, shape: YAMLShape) -> Node {
        switch shape {
        case .value:
            return new
        case .mapping(let known):
            guard case .mapping(let newMapping) = new, case .mapping(let oldMapping) = old else { return new }
            var pairs: [(Node, Node)] = []
            var written = Set<String>()
            for (key, value) in newMapping {
                guard let name = key.scalar?.string else {
                    pairs.append((key, value))
                    continue
                }
                written.insert(name)
                if let oldValue = firstValue(in: oldMapping, forKey: name) {
                    pairs.append((key, merge(new: value, old: oldValue, shape: known[name] ?? .value)))
                } else {
                    pairs.append((key, value))
                }
            }
            for (key, value) in oldMapping {
                if let name = key.scalar?.string, known[name] != nil || written.contains(name) {
                    continue
                }
                pairs.append((rewritten(key), rewritten(value)))
            }
            return .mapping(Node.Mapping(pairs, newMapping.tag, newMapping.style))
        case .list(let identity, let item):
            guard case .sequence(let newSequence) = new, case .sequence(let oldSequence) = old else { return new }
            let items = newSequence.map { newItem -> Node in
                guard let id = identityValue(of: newItem, key: identity),
                      let oldItem = oldSequence.first(where: { identityValue(of: $0, key: identity) == id })
                else { return newItem }
                return merge(new: newItem, old: oldItem, shape: item)
            }
            return .sequence(Node.Sequence(items, newSequence.tag, newSequence.style))
        }
    }

    /// The date with its fractional seconds removed.
    public static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    /// wholeSeconds(Date()).
    public static func now() -> Date {
        wholeSeconds(Date())
    }

    // MARK: - Internal

    /// The `<problem>` of a reading error: the path of a decoding error, or the Yams parser message on one line, with
    /// its line and column.
    static func problem(of error: Error) -> String {
        if let error = error as? DecodingError {
            let path = codingPathText(error.failingPath)
            if case .keyNotFound = error {
                return "missing key \(path)"
            }
            return path.isEmpty ? "invalid value" : "\(path): invalid value"
        }
        if let error = error as? YamlError {
            return parserMessage(error)
        }
        return String(describing: error)
    }

    /// A Yams error as one line, without the excerpt of the file that Yams appends to its description.
    static func parserMessage(_ error: YamlError) -> String {
        func located(_ kind: String, _ context: YamlError.Context?, _ problem: String, _ mark: Mark) -> String {
            var text = "\(mark): error: \(kind): "
            if let context {
                text += "\(context.text) in line \(context.mark.line), column \(context.mark.column); "
            }
            return text + problem
        }
        switch error {
        case let .scanner(context, problem, mark, _):
            return located("scanner", context, problem, mark)
        case let .parser(context, problem, mark, _):
            return located("parser", context, problem, mark)
        case let .composer(context, problem, mark, _):
            return located("composer", context, problem, mark)
        case let .reader(problem, offset, _, _):
            return "error: reader: \(problem)" + (offset.map { " at offset \($0)" } ?? "")
        case let .duplicatedKeysInMapping(duplicates, _):
            let keys = duplicates.keys.sorted().map { key -> String in
                let marks = (duplicates[key] ?? []).compactMap { $0.mark.map(String.init(describing:)) }
                return "\(key.scalar?.string ?? "?") (\(marks.joined(separator: ", ")))"
            }
            return "error: parser: duplicated keys: " + keys.joined(separator: ", ")
        default:
            return String(describing: error)
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? "invalid YAML"
        }
    }

    // MARK: - Private

    private static func firstValue(in mapping: Node.Mapping, forKey name: String) -> Node? {
        mapping.first { $0.key.scalar?.string == name }?.value
    }

    /// The string value of the `key` member of a list item.
    private static func identityValue(of item: Node, key: String) -> String? {
        guard case .mapping(let mapping) = item else { return nil }
        return firstValue(in: mapping, forKey: key)?.scalar?.string
    }

    /// A node of the old text carried into the new one: flow collections become block collections (flow style is not
    /// kept); scalars keep their style, so a quoted string stays a string.
    private static func rewritten(_ node: Node) -> Node {
        switch node {
        case .scalar:
            return node
        case .mapping(let mapping):
            let pairs = mapping.map { (rewritten($0.key), rewritten($0.value)) }
            return .mapping(Node.Mapping(pairs, mapping.tag, .any))
        case .sequence(let sequence):
            return .sequence(Node.Sequence(sequence.map(rewritten), sequence.tag, .any))
        case .alias:
            return node
        }
    }
}
