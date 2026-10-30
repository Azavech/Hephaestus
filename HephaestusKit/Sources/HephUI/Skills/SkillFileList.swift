import HephClient
import HephCore
import SwiftUI

/// The files of a skill: `SKILL.md` first, then the other files by path; each row the full relative path and the
/// size, a dot before the path when the open document of that file has unsaved changes (docs/ui/skills.md, "File
/// list").
struct SkillFileList: View {
    enum Style {
        /// A selectable list (regular width).
        case list
        /// Rows of buttons inside the scroll view of the compact detail.
        case rows
    }

    let files: [SkillFile]
    let style: Style
    /// The path of the selected file.
    let selectedPath: String?
    /// The paths whose open document has unsaved changes.
    let modifiedPaths: Set<String>
    let onSelect: (String) -> Void
    /// Delete… (not on `SKILL.md`): the caller confirms, then deletes.
    let onDelete: (String) -> Void

    var body: some View {
        let ordered = Self.ordered(files)
        switch style {
        case .list:
            List(selection: selection) {
                ForEach(ordered) { file in
                    row(file)
                        .tag(file.path)
                }
            }
        case .rows:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ordered) { file in
                    Button {
                        onSelect(file.path)
                    } label: {
                        row(file)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private func row(_ file: SkillFile) -> some View {
        HStack(spacing: 6) {
            if modifiedPaths.contains(file.path) {
                Circle()
                    .fill(Color.primary)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Unsaved changes")
            }
            Text(file.path)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            if file.path != SkillItem.skillFile {
                Button("Delete…") {
                    onDelete(file.path)
                }
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { selectedPath },
            set: { path in
                if let path, path != selectedPath {
                    onSelect(path)
                }
            }
        )
    }

    /// `SKILL.md` first, then the other files by path (`localizedStandardCompare`).
    static func ordered(_ files: [SkillFile]) -> [SkillFile] {
        let skillFile = files.filter { $0.path == SkillItem.skillFile }
        let others = files.filter { $0.path != SkillItem.skillFile }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return skillFile + others
    }
}
