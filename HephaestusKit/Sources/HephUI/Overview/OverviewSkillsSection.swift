import HephClient
import HephCore
import Observation
import SwiftUI

/// The skills library of the project's Main, as the Overview's Skills section shows it (docs/ui/overview.md,
/// "Skills"): requested with `listSkills()` when the section appears and after each `connected` of the Main, replaced by
/// each `skills.changed` of that Main.
@MainActor @Observable
final class OverviewSkillsLibrary {
    /// nil until the first `listSkills()` result.
    private(set) var skills: [SkillSummary]?

    /// Loads the library, then follows the events of the Workspace until the calling task is cancelled.
    func run(store: ProjectStore, workspace: Workspace, banners: WindowBanners) async {
        let events = workspace.events()
        await load(store: store, banners: banners)
        for await event in events {
            switch event {
            case .connected(let mainDeviceID) where mainDeviceID == store.mainDeviceID:
                await load(store: store, banners: banners)
            case .event(let mainDeviceID, .skillsChanged(let payload)) where mainDeviceID == store.mainDeviceID:
                skills = payload.skills
            default:
                break
            }
        }
    }

    /// `listSkills()` on the project's Main while it is connected; a failure shows in the error banner.
    private func load(store: ProjectStore, banners: WindowBanners) async {
        guard let connection = store.connection, connection.isConnected else { return }
        var result: [SkillSummary]?
        await banners.perform {
            result = try await connection.listSkills()
        }
        if let result {
            skills = result
        }
    }
}

/// The Skills section of the Overview: "All skills", then one toggle per skill of the library. `project.skills` empty
/// means every skill of the library is enabled; names that are not in the library are not shown and are kept in every
/// list sent.
struct OverviewSkillsSection: View {
    let store: ProjectStore
    let project: Project
    let library: OverviewSkillsLibrary
    let isDisabled: Bool

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    /// The list sent, shown until the stored list changes; nil when the request failed.
    @State private var sent: (base: [String], value: [String])?

    var body: some View {
        Section {
            if let skills = library.skills {
                if skills.isEmpty {
                    Text(verbatim: "The library of \(OverviewScreen.mainName(store.mainDeviceID, workspace: workspace)) "
                         + "has no skills.")
                } else {
                    Toggle("All skills", isOn: allSkillsBinding(skills))
                        .disabled(isDisabled)
                    ForEach(skills) { skill in
                        Toggle(isOn: skillBinding(skill.name)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                Text(skill.description)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .disabled(isDisabled || isLocked(skill.name, in: skills))
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        } header: {
            Text("Skills")
        } footer: {
            if let skills = library.skills, isLastEnabled(in: skills) {
                Text("At least one skill stays enabled. Turn on All skills to enable every skill.")
            }
        }
    }

    /// The list shown: the one sent while the stored list has not changed since, else the stored one.
    private var enabledSkills: [String] {
        if let sent, sent.base == project.skills {
            return sent.value
        }
        return project.skills
    }

    /// On while the list is empty. Turning it off sends the names of every library skill; on sends `[]`.
    private func allSkillsBinding(_ skills: [SkillSummary]) -> Binding<Bool> {
        Binding(
            get: { enabledSkills.isEmpty },
            set: { isOn in
                send(isOn ? [] : skills.map(\.name))
            }
        )
    }

    /// On when every skill is enabled or the skill is listed; a change sends the list with that name added or removed.
    private func skillBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { enabledSkills.isEmpty || enabledSkills.contains(name) },
            set: { isOn in
                var list = enabledSkills
                if isOn {
                    if !list.contains(name) {
                        list.append(name)
                    }
                } else {
                    list.removeAll { $0 == name }
                }
                send(list)
            }
        )
    }

    /// "All skills" off and exactly one skill of the library on.
    private func isLastEnabled(in skills: [SkillSummary]) -> Bool {
        let enabled = enabledSkills
        guard !enabled.isEmpty else { return false }
        return skills.filter { enabled.contains($0.name) }.count == 1
    }

    /// Every toggle is disabled while all skills are enabled; the last enabled skill cannot be turned off.
    private func isLocked(_ name: String, in skills: [SkillSummary]) -> Bool {
        enabledSkills.isEmpty || (isLastEnabled(in: skills) && enabledSkills.contains(name))
    }

    /// `ProjectPatch(skills:)`.
    private func send(_ list: [String]) {
        guard list != enabledSkills else { return }
        let base = project.skills
        sent = (base: base, value: list)
        let projectID = store.projectID
        Task {
            let succeeded = await banners.perform {
                let connection = try OverviewScreen.connection(store.mainDeviceID, workspace: workspace)
                _ = try await connection.updateProject(projectID: projectID, patch: ProjectPatch(skills: list))
            }
            if !succeeded, sent?.value == list {
                sent = nil
            }
        }
    }
}
