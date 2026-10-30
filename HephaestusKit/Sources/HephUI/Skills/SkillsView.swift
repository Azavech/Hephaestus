import HephClient
import HephCore
import SwiftUI

/// The Skills section for the library of the Main `mainDeviceID` (the Main selected in the window's path bar).
/// @MainActor; reads the AppModel, the Workspace, the SettingsStore, the window's WindowContext and its WindowBanners
/// from the environment (docs/ui/skills.md).
public struct SkillsView: View {
    private let mainDeviceID: UUID

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    @Environment(AppModel.self) private var appModel
    @State private var screen = SkillsScreenModel()

    public init(mainDeviceID: UUID) {
        self.mainDeviceID = mainDeviceID
    }

    public var body: some View {
        Group {
            if workspace.connection(mainDeviceID)?.isConnected == true {
                if context.isCompact {
                    compactLayout
                } else {
                    regularLayout
                }
            } else {
                Text("\(ClaudeNames.mainName(mainDeviceID, in: workspace)) is offline. Skills are edited on a Main.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: mainDeviceID) {
            await followLibrary()
        }
        .onChange(of: screen.skills) { oldSkills, newSkills in
            // When the selected skill leaves the list (deleted or renamed elsewhere), the selection is cleared; a
            // rename made from this screen moves it to the new name instead, the same file selected.
            guard let selected = SkillItem(context.selection.item), let oldSkills, let newSkills,
                  oldSkills.contains(where: { $0.name == selected.name }),
                  !newSkills.contains(where: { $0.name == selected.name })
            else { return }
            if let rename = screen.renameInFlight, rename.oldName == selected.name,
               newSkills.contains(where: { $0.name == rename.newName }) {
                context.selection.item = SkillItem(name: rename.newName, path: rename.keptPath).item
            } else {
                context.selection.item = nil
            }
        }
        .sheet(isPresented: $screen.isNewSkillPresented) {
            NewSkillSheet(mainDeviceID: mainDeviceID, existingNames: Set((screen.skills ?? []).map(\.name))) { name in
                // The window selects the skill and SKILL.md opens in Edit mode.
                screen.editModeRequests.insert(SkillItem.key(name: name, path: SkillItem.skillFile))
                context.selection.item = context.isCompact
                    ? SkillItem(name: name, path: SkillItem.skillFile).item
                    : name
            }
        }
        .sheet(item: $screen.renameTarget) { target in
            RenameSkillSheet(
                mainDeviceID: mainDeviceID, currentName: target.name,
                otherNames: Set((screen.skills ?? []).map(\.name)).subtracting([target.name]), screen: screen,
                onStart: { newName in
                    // Recorded so that the rename's skills.changed, when it arrives before the answer, moves the
                    // selection to the new name instead of clearing it.
                    let selected = SkillItem(context.selection.item)
                    screen.renameInFlight = SkillRename(
                        oldName: target.name, newName: newName,
                        keptPath: selected?.name == target.name ? selected?.path : nil
                    )
                },
                onRenamed: { newName in
                    // The window selects the new name, with the same file selected.
                    let rename = screen.renameInFlight
                    screen.renameInFlight = nil
                    let path = rename?.oldName == target.name ? rename?.keptPath : nil
                    context.selection.item = SkillItem(name: newName, path: path).item
                },
                onFailed: {
                    screen.renameInFlight = nil
                }
            )
        }
        .confirmationDialog("Delete the skill “\(screen.deleteTarget?.name ?? "")”?",
                            isPresented: isDeleteConfirmationPresented, titleVisibility: .visible,
                            presenting: screen.deleteTarget) { target in
            Button("Delete", role: .destructive) {
                deleteSkill(target.name)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It is deleted from the library of every Main. This cannot be undone.")
        }
    }

    // MARK: Layouts

    private var skillList: some View {
        SkillListView(mainDeviceID: mainDeviceID, screen: screen)
    }

    @ViewBuilder private var regularLayout: some View {
        #if os(macOS)
        HSplitView {
            skillList
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            detailArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        HStack(spacing: 0) {
            skillList
                .frame(width: 280)
            Divider()
            detailArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
    }

    @ViewBuilder private var detailArea: some View {
        if let selected = SkillItem(context.selection.item) {
            SkillDetailView(mainDeviceID: mainDeviceID, name: selected.name, screen: screen, isCompact: false)
                .id(selected.name)
        } else {
            Text("Select a skill")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The stack's path follows `selection.item`: `<name>` gives [detail]; `<name>/<path>` gives [detail, file view].
    private var compactLayout: some View {
        NavigationStack(path: compactPath) {
            skillList
                .navigationDestination(for: SkillRoute.self) { route in
                    switch route {
                    case .detail(let name):
                        SkillDetailView(mainDeviceID: mainDeviceID, name: name, screen: screen, isCompact: true)
                    case .file(let name, let path):
                        SkillFileView(mainDeviceID: mainDeviceID, skillName: name, path: path, screen: screen)
                            .id(SkillItem.key(name: name, path: path))
                    }
                }
        }
    }

    private var compactPath: Binding<[SkillRoute]> {
        Binding(
            get: {
                guard let selected = SkillItem(context.selection.item) else { return [] }
                if let path = selected.path {
                    return [.detail(selected.name), .file(selected.name, path)]
                }
                return [.detail(selected.name)]
            },
            set: { routes in
                switch routes.last {
                case nil:
                    context.selection.item = nil
                case .detail(let name):
                    context.selection.item = name
                case .file(let name, let path):
                    context.selection.item = SkillItem(name: name, path: path).item
                }
            }
        )
    }

    // MARK: Library

    /// The list comes from `listSkills()` of the Main, requested when the screen appears and after each `connected`
    /// of the Main, and is replaced by the skills of each `skills.changed` from it. Until the first answer from that
    /// Main, the list shows a `ProgressView`.
    private func followLibrary() async {
        screen.skills = nil
        let events = workspace.events()
        if workspace.connection(mainDeviceID)?.isConnected == true {
            refreshLibrary()
        }
        for await event in events {
            switch event {
            case .connected(let id) where id == mainDeviceID:
                refreshLibrary()
            case .event(let id, .skillsChanged(let payload)) where id == mainDeviceID:
                screen.skills = payload.skills
            default:
                continue
            }
        }
    }

    private func refreshLibrary() {
        let workspace = workspace
        let mainDeviceID = mainDeviceID
        let screen = screen
        let router = appModel.banners
        Task {
            do {
                guard let connection = workspace.connection(mainDeviceID) else {
                    throw ProtocolError(.unavailable,
                                        "\(ClaudeNames.mainName(mainDeviceID, in: workspace)) is offline.")
                }
                screen.skills = try await connection.listSkills()
            } catch {
                router.post(Banner(style: .error, message: Banner.message(of: error)))
            }
        }
    }

    /// Delete: the open documents of the skill are discarded without saving, then `deleteSkill(name:)`; the selection
    /// is cleared when it was that skill. When the deletion fails, the documents are no longer discarded.
    private func deleteSkill(_ name: String) {
        let workspace = workspace
        let mainDeviceID = mainDeviceID
        let context = context
        let screen = screen
        let router = appModel.banners
        let discarded = screen.discardDocuments { $0.skillName == name }
        Task {
            let deleted = await banners.perform {
                guard let connection = workspace.connection(mainDeviceID) else {
                    throw ProtocolError(.unavailable,
                                        "\(ClaudeNames.mainName(mainDeviceID, in: workspace)) is offline.")
                }
                try await connection.deleteSkill(name: name)
                if SkillItem(context.selection.item)?.name == name {
                    context.selection.item = nil
                }
            }
            if !deleted {
                screen.restore(discarded, router: router)
            }
        }
    }

    private var isDeleteConfirmationPresented: Binding<Bool> {
        Binding(get: { screen.deleteTarget != nil }, set: { if !$0 { screen.deleteTarget = nil } })
    }
}

/// The state the views of the Skills section share.
@MainActor @Observable
final class SkillsScreenModel {
    /// The library of the Main; nil until the first answer from it.
    var skills: [SkillSummary]?
    /// The documents of the file views shown, by `SkillItem.key(name:path:)`.
    var openDocuments: [String: SkillFileDocument] = [:]
    /// The files to open in Edit mode when their view appears, by `SkillItem.key(name:path:)`.
    var editModeRequests: Set<String> = []
    var isNewSkillPresented = false
    var renameTarget: SkillTarget?
    var deleteTarget: SkillTarget?
    /// The rename this screen has sent and whose answer has not arrived.
    @ObservationIgnored var renameInFlight: SkillRename?

    func summary(of name: String) -> SkillSummary? {
        skills?.first { $0.name == name }
    }

    /// Rename first saves each open document of the skill that has unsaved changes, as ⌘S does, waiting for a save in
    /// flight; the first failure is thrown.
    func saveDocuments(ofSkill name: String) async throws {
        let documents = openDocuments.values
            .filter { $0.skillName == name && $0.isModified }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        for document in documents {
            try await document.save()
        }
    }

    /// A deletion this screen starts: the open documents that match are discarded, so that nothing saves them any
    /// more. Returns them for `restore(_:router:)`.
    func discardDocuments(where isIncluded: (SkillFileDocument) -> Bool) -> [SkillFileDocument] {
        let documents = openDocuments.values.filter(isIncluded)
        for document in documents {
            document.discard()
        }
        return documents
    }

    /// The deletion failed: the documents are no longer discarded, and a modified one whose view went away meanwhile
    /// saves at once; a failure of that save is posted with `router`.
    func restore(_ documents: [SkillFileDocument], router: AppBannerRouter) {
        for document in documents {
            document.restore()
            let isShown = openDocuments.values.contains { $0 === document }
            guard !isShown, document.isModified else { continue }
            Task {
                await document.save { error in
                    router.post(Banner(style: .error, message: Banner.message(of: error)))
                }
            }
        }
    }
}

/// A rename sent from this screen: the skill's old and new names, and the file of the skill that was selected
/// (nil for `SKILL.md`, or when another skill was selected).
struct SkillRename {
    let oldName: String
    let newName: String
    let keptPath: String?
}

/// A skill acted on by a sheet or a confirmation.
struct SkillTarget: Identifiable, Hashable {
    let name: String

    var id: String { name }
}

/// `selection.item` of the Skills section: `<skill name>`, or `<skill name>/<file path>` (skill names have no `/`).
struct SkillItem: Equatable {
    static let skillFile = "SKILL.md"

    let name: String
    let path: String?

    init(name: String, path: String?) {
        self.name = name
        self.path = path
    }

    init?(_ item: String?) {
        guard let item, !item.isEmpty else { return nil }
        if let slash = item.firstIndex(of: "/") {
            name = String(item[item.startIndex..<slash])
            let path = String(item[item.index(after: slash)...])
            self.path = path.isEmpty ? nil : path
        } else {
            name = item
            path = nil
        }
        if name.isEmpty {
            return nil
        }
    }

    var item: String {
        guard let path else { return name }
        return "\(name)/\(path)"
    }

    /// The file shown: the path, `SKILL.md` by default.
    var filePath: String {
        path ?? Self.skillFile
    }

    static func key(name: String, path: String) -> String {
        "\(name)/\(path)"
    }
}

/// The levels of the compact stack.
enum SkillRoute: Hashable {
    case detail(String)
    case file(String, String)
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    SkillsView(mainDeviceID: studio)
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, section: .skills))
}
