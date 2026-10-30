import HephClient
import HephCore
import HephMarkdown
import SwiftUI
import UniformTypeIdentifiers

/// One skill: its header and actions, its files and the selected file (docs/ui/skills.md, "Skill detail").
struct SkillDetailView: View {
    let mainDeviceID: UUID
    let name: String
    let screen: SkillsScreenModel
    let isCompact: Bool

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(WindowBanners.self) private var banners
    @Environment(AppModel.self) private var appModel
    @State private var files: [SkillFile]?
    /// Compact width: the text of `SKILL.md`, rendered as in Preview.
    @State private var skillText: String?
    @State private var isNewFilePresented = false
    @State private var isImporterPresented = false
    @State private var fileToDelete: String?

    private var summary: SkillSummary? {
        screen.summary(of: name)
    }

    /// The selected file: the path of `selection.item`, `SKILL.md` by default.
    private var selectedPath: String {
        guard let selected = SkillItem(context.selection.item), selected.name == name else {
            return SkillItem.skillFile
        }
        return selected.filePath
    }

    var body: some View {
        Group {
            if isCompact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .task {
            await refreshFiles()
            if isCompact {
                await loadSkillText()
            }
        }
        .onChange(of: summary?.modified) { oldValue, newValue in
            // A skills.changed that gives this skill a new `modified`.
            guard oldValue != nil, newValue != oldValue else { return }
            Task {
                await refreshFiles()
                if isCompact {
                    await loadSkillText()
                }
            }
        }
        .sheet(isPresented: $isNewFilePresented) {
            NewSkillFileSheet(mainDeviceID: mainDeviceID, skillName: name,
                              existingPaths: Set((files ?? []).map(\.path))) { path in
                fileCreated(path)
            }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                importFiles(urls)
            case .failure(let error):
                banners.showError(error)
            }
        }
        .confirmationDialog("Delete \(fileToDelete ?? "")?", isPresented: isDeleteFilePresented,
                            titleVisibility: .visible, presenting: fileToDelete) { path in
            Button("Delete", role: .destructive) {
                deleteFile(path)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    // MARK: Layouts

    private var regularLayout: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            HStack(spacing: 0) {
                Group {
                    if let files {
                        SkillFileList(files: files, style: .list, selectedPath: selectedPath,
                                      modifiedPaths: modifiedPaths, onSelect: select,
                                      onDelete: { fileToDelete = $0 })
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 220)
                Divider()
                SkillFileView(mainDeviceID: mainDeviceID, skillName: name, path: selectedPath, screen: screen)
                    .id(SkillItem.key(name: name, path: selectedPath))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Text("Files")
                    .font(.headline)
                if let files {
                    SkillFileList(files: files, style: .rows, selectedPath: nil, modifiedPaths: modifiedPaths,
                                  onSelect: select, onDelete: { fileToDelete = $0 })
                } else {
                    ProgressView()
                }
                if let skillText {
                    Divider()
                    MarkdownView(skillText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                Text("hephaestus:\(name)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let description = summary?.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Menu("Add File") {
                    Button("New File…") {
                        isNewFilePresented = true
                    }
                    Button("Import Files…") {
                        isImporterPresented = true
                    }
                }
                Button("Rename…") {
                    screen.renameTarget = SkillTarget(name: name)
                }
                Button("Delete Skill…") {
                    screen.deleteTarget = SkillTarget(name: name)
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: Files

    private var modifiedPaths: Set<String> {
        var paths: Set<String> = []
        for (key, document) in screen.openDocuments where document.isModified && document.skillName == name {
            if let path = SkillItem(key)?.path {
                paths.insert(path)
            }
        }
        return paths
    }

    /// Choosing a row selects the file: `selection.item` = `<name>/<path>`.
    private func select(_ path: String) {
        context.selection.item = SkillItem(name: name, path: path).item
    }

    /// `skillFiles(name:)`.
    private func refreshFiles() async {
        guard let connection = workspace.connection(mainDeviceID) else { return }
        do {
            files = try await connection.skillFiles(name: name)
        } catch {
            appModel.banners.post(Banner(style: .error, message: Banner.message(of: error)))
        }
    }

    private func loadSkillText() async {
        guard let connection = workspace.connection(mainDeviceID) else { return }
        do {
            let data = try await connection.readSkillFile(name: name, path: SkillItem.skillFile)
            skillText = String(data: data, encoding: .utf8)
        } catch {
            appModel.banners.post(Banner(style: .error, message: Banner.message(of: error)))
        }
    }

    /// New File: the list is refreshed and the file selected; `.md` files open in Edit mode.
    private func fileCreated(_ path: String) {
        if (path as NSString).pathExtension.lowercased() == "md" {
            screen.editModeRequests.insert(SkillItem.key(name: name, path: path))
        }
        select(path)
        Task {
            await refreshFiles()
        }
    }

    /// Delete: the open document of the file is discarded without saving, then `deleteSkillFile(name:path:)` and the
    /// list is refreshed; when the file was selected, `SKILL.md` becomes selected. When the deletion fails, the
    /// document is no longer discarded, and saves at once when its view went away meanwhile.
    private func deleteFile(_ path: String) {
        let name = name
        let workspace = workspace
        let mainDeviceID = mainDeviceID
        let screen = screen
        let router = appModel.banners
        let discarded = screen.discardDocuments { $0.skillName == name && $0.path == path }
        Task {
            let deleted = await banners.perform {
                let connection = try SkillNameRules.connection(mainDeviceID, in: workspace)
                try await connection.deleteSkillFile(name: name, path: path)
            }
            if !deleted {
                screen.restore(discarded, router: router)
            }
            if deleted, SkillItem(context.selection.item) == SkillItem(name: name, path: path) {
                context.selection.item = name
            }
            await refreshFiles()
        }
    }

    /// Import Files: each file at the skill's root under its own name; a file whose name is already a file of the skill,
    /// or larger than `MethodLimits.maxFileSize`, is skipped with an error banner. The list is refreshed at the end.
    private func importFiles(_ urls: [URL]) {
        let name = name
        let workspace = workspace
        let mainDeviceID = mainDeviceID
        let banners = banners
        var existing = Set((files ?? []).map(\.path))
        Task {
            for url in urls {
                let fileName = url.lastPathComponent
                if existing.contains(fileName) {
                    banners.showError("\(fileName) already exists in the skill.")
                    continue
                }
                let data: Data
                do {
                    guard let read = try await Self.read(url) else {
                        banners.showError("\(fileName) is larger than 10 MiB.")
                        continue
                    }
                    data = read
                } catch {
                    banners.showError(error)
                    continue
                }
                let written = await banners.perform {
                    let connection = try SkillNameRules.connection(mainDeviceID, in: workspace)
                    try await connection.writeSkillFile(name: name, path: fileName, data: data)
                }
                if written {
                    existing.insert(fileName)
                }
            }
            await refreshFiles()
        }
    }

    /// The content of a chosen file, read off the main actor inside its security-scoped access; nil when it is larger
    /// than `MethodLimits.maxFileSize`.
    private static func read(_ url: URL) async throws -> Data? {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= MethodLimits.maxFileSize else { return nil }
            let data = try Data(contentsOf: url)
            guard data.count <= MethodLimits.maxFileSize else { return nil }
            return data
        }.value
    }

    private var isDeleteFilePresented: Binding<Bool> {
        Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } })
    }
}
