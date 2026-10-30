#if os(macOS)
import Foundation
import HephCore

/// One entry of `Skills/.index.json` (docs/claude/skills.md §7.1).
public struct SkillsIndexEntry: Sendable, Equatable, Codable {
    public var modified: Date
    public var deleted: Bool

    public init(modified: Date, deleted: Bool) {
        self.modified = modified
        self.deleted = deleted
    }
}

/// The sync index of the skills library, `Skills/.index.json`: one entry per skill name known to this Main. Load,
/// save, scan (§7.2) and prune. Dates are kept as the wire writes them and compared at millisecond precision.
struct SkillsIndex: Sendable, Equatable {
    var entries: [String: SkillsIndexEntry] = [:]

    /// Tombstones older than this are removed (§7.2 step 5).
    private static let tombstoneLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// The index file; an empty index when it is missing or unreadable, which the scan then rebuilds from the folders.
    static func load(from url: URL) -> SkillsIndex {
        do {
            guard let entries = try JSONFile.read([String: SkillsIndexEntry].self, from: url) else {
                return SkillsIndex()
            }
            var index = SkillsIndex()
            for (name, entry) in entries where SkillName.isValid(name) {
                index.entries[name] = SkillsIndexEntry(modified: truncated(entry.modified), deleted: entry.deleted)
            }
            return index
        } catch {
            let message = (error as? DataError)?.message ?? error.localizedDescription
            Log.host.error("The skills index is unreadable, it is rebuilt: \(message)")
            return SkillsIndex()
        }
    }

    /// Writes the index atomically, pretty-printed with sorted keys, dates as on the wire.
    func save(to url: URL) throws {
        try JSONFile.write(entries, to: url)
    }

    /// §7.2 steps 1 to 5 on the skill folders of `skillsFolder`. Returns true when the index changed.
    mutating func scan(skillsFolder: URL, now: Date) -> Bool {
        let now = Self.truncated(now)
        let before = entries
        let names = Set(Self.skillNames(in: skillsFolder))
        for name in names {
            let latest = Self.latestModification(of: skillsFolder.appendingPathComponent(name, isDirectory: true))
            if let entry = entries[name] {
                if entry.deleted {
                    // 2. The folder came back from the Trash or was made by hand.
                    entries[name] = SkillsIndexEntry(modified: now, deleted: false)
                } else if Self.milliseconds(entry.modified) < Self.milliseconds(latest) {
                    // 3. Edited outside Hephaestus.
                    entries[name] = SkillsIndexEntry(modified: latest, deleted: false)
                }
            } else {
                // 1. A folder without an entry.
                entries[name] = SkillsIndexEntry(modified: latest, deleted: false)
            }
        }
        // 4. Deleted outside Hephaestus.
        for (name, entry) in entries where !entry.deleted && !names.contains(name) {
            entries[name] = SkillsIndexEntry(modified: now, deleted: true)
        }
        // 5. Old tombstones.
        prune(now: now)
        return entries != before
    }

    /// Removes the tombstones whose `modified` is more than 30 days before `now`.
    mutating func prune(now: Date) {
        entries = entries.filter { _, entry in
            !(entry.deleted && now.timeIntervalSince(entry.modified) > Self.tombstoneLifetime)
        }
    }

    // MARK: - Folders and dates

    /// The skills of the library: the folders of `Skills/` whose name is a valid skill name.
    static func skillNames(in skillsFolder: URL) -> [String] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: skillsFolder.path) else { return [] }
        return names.filter { name in
            guard SkillName.isValid(name) else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: skillsFolder.appendingPathComponent(name).path,
                                          isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted()
    }

    /// `L` of a skill: the latest modification date among the regular files of its folder, recursively; the distant
    /// past when it has none.
    static func latestModification(of folder: URL) -> Date {
        var latest = Date.distantPast
        for file in regularFiles(in: folder) where file.modified > latest {
            latest = file.modified
        }
        return truncated(latest)
    }

    /// The regular files under `folder`, recursively, symbolic links not followed: their path relative to `folder`
    /// (`/`-separated), size and modification date.
    static func regularFiles(in folder: URL) -> [(path: String, size: Int, modified: Date)] {
        var files: [(path: String, size: Int, modified: Date)] = []
        func walk(_ url: URL, _ relative: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
            for name in names {
                let child = url.appendingPathComponent(name)
                let path = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(child.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    walk(child, path)
                case S_IFREG:
                    let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                        + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                    files.append((path, Int(info.st_size), modified))
                default:
                    continue
                }
            }
        }
        walk(folder, "")
        return files
    }

    /// The millisecond of a date as the wire writes it: rounded to the microsecond first, which removes the binary
    /// error of a date parsed from text, then truncated to the millisecond.
    static func milliseconds(_ date: Date) -> Int64 {
        let micros = (date.timeIntervalSinceReferenceDate * 1_000_000).rounded()
        return Int64((micros / 1_000).rounded(.down))
    }

    /// The date at millisecond precision.
    static func truncated(_ date: Date) -> Date {
        guard date > Date.distantPast else { return Date.distantPast }
        return Date(timeIntervalSinceReferenceDate: TimeInterval(milliseconds(date)) / 1_000)
    }
}
#endif
