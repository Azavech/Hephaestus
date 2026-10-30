import HephClient
import HephCore
import SwiftUI

/// The Overview section of the project held by `store` (docs/ui/overview.md): the project's fields, its location, its
/// task counts, its sub projects, its skills and Claude defaults, and Move to… and Remove Project….
///
/// While the project's Main is not connected or the project is migrating, every control that sends a request is
/// disabled; while `project.parseError` is set, so are the Name, Description, Skills and Claude controls, New Sub
/// Project… and Move to….
public struct OverviewView: View {
    private enum Field: Hashable {
        case name
        case description
    }

    private let store: ProjectStore

    @Environment(Workspace.self) private var workspace
    @Environment(WindowBanners.self) private var banners
    @Environment(\.presentMigrationProgress) private var presentMigrationProgress
    @State private var nameText = ""
    @State private var descriptionText = ""
    /// The values of the requests in flight, so that one commit sends its value once.
    @State private var sendingName: String?
    @State private var sendingDescription: String?
    @State private var skillsLibrary = OverviewSkillsLibrary()
    @State private var isMovePresented = false
    /// The migration id the move sheet handed over; presented once the move sheet is gone.
    @State private var startedMigrationID: UUID?
    @State private var isRemovePresented = false
    @FocusState private var focusedField: Field?

    public init(store: ProjectStore) {
        self.store = store
    }

    public var body: some View {
        if let project = store.project {
            form(project)
        }
    }

    // MARK: - Form

    private func form(_ project: Project) -> some View {
        let isConnected = store.connection?.isConnected ?? false
        let canSend = isConnected && !project.migrating
        let canEdit = canSend && project.parseError == nil
        return Form {
            projectSection(project, canEdit: canEdit)
            locationSection(project)
            tasksSection
            SubProjectsSection(store: store, project: project, isNewSubProjectDisabled: !canEdit)
            OverviewSkillsSection(store: store, project: project, library: skillsLibrary, isDisabled: !canEdit)
            OverviewClaudeSection(store: store, project: project, isDisabled: !canEdit)
            lifecycleSection(project, canSend: canSend, canEdit: canEdit)
        }
        .formStyle(.grouped)
        .onAppear {
            nameText = project.name
            descriptionText = project.description ?? ""
        }
        .onChange(of: store.project?.name) { _, name in
            if focusedField != .name, let name {
                nameText = name
            }
        }
        .onChange(of: store.project?.description) { _, description in
            if focusedField != .description {
                descriptionText = description ?? ""
            }
        }
        .onChange(of: focusedField) { oldField, newField in
            if oldField == .name, newField != .name {
                commitName()
            }
            if oldField == .description, newField != .description {
                commitDescription()
            }
        }
        .onDisappear {
            commitName()
            commitDescription()
        }
        .task {
            await skillsLibrary.run(store: store, workspace: workspace, banners: banners)
        }
        .sheet(isPresented: $isMovePresented, onDismiss: {
            if let migrationID = startedMigrationID {
                startedMigrationID = nil
                presentMigrationProgress(migrationID)
            }
        }) {
            MoveProjectSheet(store: store) { migrationID in
                startedMigrationID = migrationID
            }
        }
        .confirmationDialog(
            Text(verbatim: "Remove “\(project.name)”?"),
            isPresented: $isRemovePresented,
            titleVisibility: .visible
        ) {
            Button("Remove") {
                remove(moveToTrash: false)
            }
            Button("Remove and Move to Trash", role: .destructive) {
                remove(moveToTrash: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: removeMessage(project))
        }
    }

    // MARK: - 1. Project

    private func projectSection(_ project: Project, canEdit: Bool) -> some View {
        Section("Project") {
            if let parseError = project.parseError {
                Text(verbatim: ".hephaestus/project.yml cannot be read: \(parseError)")
                    .foregroundStyle(.red)
            }
            if project.migrating {
                Text("This project is being moved to another Main.")
            }
            TextField("Name", text: $nameText)
                .focused($focusedField, equals: .name)
                .onSubmit(commitName)
                .onKeyPress(.escape) {
                    revertName()
                    return .handled
                }
                #if os(macOS)
                .onExitCommand(perform: revertName)
                #endif
                .disabled(!canEdit)
            LabeledContent("Identifier") {
                Text(project.id)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            TextField("Description", text: $descriptionText, axis: .vertical)
                .lineLimit(1...6)
                .focused($focusedField, equals: .description)
                .disabled(!canEdit)
        }
    }

    private func revertName() {
        nameText = store.project?.name ?? nameText
    }

    /// Sends the trimmed name. A name that breaks the name rule is not sent and the field returns to the stored name; an
    /// unchanged name sends nothing; a failure returns the field to the stored name.
    private func commitName() {
        guard let stored = store.project?.name else { return }
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(where: { $0.isNewline }) else {
            nameText = stored
            return
        }
        nameText = name
        guard name != stored, name != sendingName else { return }
        sendingName = name
        let projectID = store.projectID
        Task {
            let succeeded = await banners.perform {
                let connection = try OverviewScreen.connection(store.mainDeviceID, workspace: workspace)
                _ = try await connection.updateProject(projectID: projectID, patch: ProjectPatch(name: name))
            }
            if sendingName == name {
                sendingName = nil
            }
            if !succeeded {
                nameText = store.project?.name ?? nameText
            }
        }
    }

    /// Sends the description when the field loses focus; `""` removes it. An unchanged description sends nothing; a
    /// failure returns the field to the stored description.
    private func commitDescription() {
        guard let project = store.project else { return }
        let description = descriptionText
        guard description != (project.description ?? ""), description != sendingDescription else { return }
        sendingDescription = description
        let projectID = store.projectID
        Task {
            let succeeded = await banners.perform {
                let connection = try OverviewScreen.connection(store.mainDeviceID, workspace: workspace)
                _ = try await connection.updateProject(projectID: projectID,
                                                       patch: ProjectPatch(description: description))
            }
            if sendingDescription == description {
                sendingDescription = nil
            }
            if !succeeded {
                descriptionText = store.project?.description ?? ""
            }
        }
    }

    // MARK: - 2. Location

    private func locationSection(_ project: Project) -> some View {
        Section("Location") {
            LabeledContent("Main") {
                HStack(spacing: 6) {
                    Text(verbatim: OverviewScreen.mainName(store.mainDeviceID, workspace: workspace))
                    if let presence = workspace.presence[store.mainDeviceID], !presence.online {
                        StatusDot(isOnline: false)
                        TimelineView(.everyMinute) { _ in
                            Text(verbatim: "last seen \(presence.lastSeen.formatted(.relative(presentation: .named)))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            LabeledContent("Folder") {
                Text(verbatim: project.rootPath)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(project.rootPath)
            }
        }
    }

    // MARK: - 3. Tasks

    /// One cell per status, then Broken when the project has broken tasks (counted apart from the statuses).
    private var tasksSection: some View {
        let tasks = store.tasks
        let brokenCount = tasks.filter { $0.parseError != nil }.count
        return Section("Tasks") {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                LabeledContent {
                    Text("\(tasks.filter { $0.parseError == nil && $0.status == status }.count)")
                } label: {
                    TaskStatusBadge(status: status)
                }
            }
            if brokenCount > 0 {
                LabeledContent("Broken") {
                    Text("\(brokenCount)")
                }
            }
        }
    }

    // MARK: - 7. Move and remove

    private func lifecycleSection(_ project: Project, canSend: Bool, canEdit: Bool) -> some View {
        Section {
            if isTopLevel {
                Button("Move to…") {
                    isMovePresented = true
                }
                .disabled(!canEdit)
            }
            Button("Remove Project…", role: .destructive) {
                isRemovePresented = true
            }
            .disabled(!canSend)
        }
    }

    /// Move to… is for top-level projects only.
    private var isTopLevel: Bool {
        workspace.projectPath(of: store.projectID, on: store.mainDeviceID)?.count == 1
    }

    private func removeMessage(_ project: Project) -> String {
        let mainName = OverviewScreen.mainName(store.mainDeviceID, workspace: workspace)
        var message = "The project is removed from Hephaestus. Its folder \(project.rootPath) stays on \(mainName), "
            + "with its tasks and sessions, unless you move it to the Trash."
        let children = workspace.summary(of: store.projectID, on: store.mainDeviceID)?.children ?? []
        if !children.isEmpty {
            message += " Its sub projects are removed with it."
        }
        return message
    }

    /// `removeProject(projectID:moveToTrash:)`. After a successful removal the shell handles the selection.
    private func remove(moveToTrash: Bool) {
        let projectID = store.projectID
        Task {
            await banners.perform {
                let connection = try OverviewScreen.connection(store.mainDeviceID, workspace: workspace)
                try await connection.removeProject(projectID: projectID, moveToTrash: moveToTrash)
            }
        }
    }
}

/// Helpers shared by the views of the Overview and its sheets.
@MainActor
enum OverviewScreen {
    /// The name of a Main: its registry record in `workspace.mains`, else its connection's name, else "Main".
    static func mainName(_ mainDeviceID: UUID, workspace: Workspace) -> String {
        if let record = workspace.mains.first(where: { $0.id == mainDeviceID }) {
            return record.name
        }
        return workspace.connection(mainDeviceID)?.name ?? "Main"
    }

    /// The connection of a Main; without one, the offline error of the request API.
    static func connection(_ mainDeviceID: UUID, workspace: Workspace) throws -> MainConnection {
        if let connection = workspace.connection(mainDeviceID) {
            return connection
        }
        throw ProtocolError(.unavailable, "\(mainName(mainDeviceID, workspace: workspace)) is offline.")
    }

    /// The name rule: not empty after trimming whitespace and line breaks, and no line break.
    static func isValidName(_ trimmedName: String) -> Bool {
        !trimmedName.isEmpty && !trimmedName.contains { $0.isNewline }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    OverviewView(store: appModel.workspace.projectStore(mainDeviceID: studio, projectID: "HEPH"))
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio, projectID: "HEPH", section: .overview))
}
