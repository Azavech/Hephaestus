import HephClient
import HephCore
import SwiftUI

/// The skills of the library: the caption "Library on <Main name>", a filter field and a `plus` button, then one row
/// per skill (docs/ui/skills.md, "Skill list").
struct SkillListView: View {
    let mainDeviceID: UUID
    let screen: SkillsScreenModel

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Library on \(ClaudeNames.mainName(mainDeviceID, in: workspace))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Filter", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button {
                    screen.isNewSkillPresented = true
                } label: {
                    Label("New Skill", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("New Skill")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if let skills = screen.skills {
            let matching = skills.filter { SkillFilter.matches($0, query: query) }
            if skills.isEmpty {
                VStack(spacing: 12) {
                    Text("No skills yet")
                        .foregroundStyle(.secondary)
                    Button("New Skill…") {
                        screen.isNewSkillPresented = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matching.isEmpty {
                Text("No matching skills")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selectedName) {
                    ForEach(matching) { skill in
                        SkillListRow(skill: skill)
                            .contextMenu {
                                Button("Rename…") {
                                    screen.renameTarget = SkillTarget(name: skill.name)
                                }
                                Button("Delete…") {
                                    screen.deleteTarget = SkillTarget(name: skill.name)
                                }
                            }
                            .tag(skill.name)
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The selected skill: the first part of `selection.item`; choosing a row selects the skill.
    private var selectedName: Binding<String?> {
        Binding(
            get: { SkillItem(context.selection.item)?.name },
            set: { name in
                guard let name, SkillItem(context.selection.item)?.name != name else { return }
                context.selection.item = name
            }
        )
    }
}

/// A row: the name (headline) and the description (secondary, up to 2 lines).
private struct SkillListRow: View {
    let skill: SkillSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(skill.name)
                .font(.headline)
                .lineLimit(1)
            if !skill.description.isEmpty {
                Text(skill.description)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The filter of the skill list: the query is split on whitespace; every word must occur, case- and
/// diacritic-insensitive, in the name or the description.
enum SkillFilter {
    static func matches(_ skill: SkillSummary, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { word in
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return skill.name.range(of: word, options: options) != nil
                || skill.description.range(of: word, options: options) != nil
        }
    }
}
