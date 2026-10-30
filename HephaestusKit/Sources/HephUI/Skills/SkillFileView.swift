import HephClient
import HephCore
import HephEditor
import HephMarkdown
import SwiftUI

/// The selected file of a skill, through its `SkillFileDocument` (docs/ui/skills.md, "File view"): Markdown files
/// have Preview and Edit modes, other text files the code editor, other data "Binary file — <size>".
struct SkillFileView: View {
    let mainDeviceID: UUID
    let skillName: String
    let path: String
    let screen: SkillsScreenModel

    @Environment(Workspace.self) private var workspace
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var appModel
    @Environment(WindowBanners.self) private var banners
    @State private var document: SkillFileDocument?
    @State private var mode: SkillFileMode = .preview

    private enum SkillFileMode: Hashable {
        case preview, edit
    }

    private var key: String {
        SkillItem.key(name: skillName, path: path)
    }

    private var isMarkdown: Bool {
        (path as NSString).pathExtension.lowercased() == "md"
    }

    /// The `modified` of the skill in the list: a new value means `skills.changed` changed the skill.
    private var skillModified: Date? {
        screen.summary(of: skillName)?.modified
    }

    var body: some View {
        Group {
            if let document {
                content(document)
            } else {
                Color.clear
            }
        }
        .task {
            await open()
        }
        .onDisappear {
            close()
        }
        .onChange(of: skillModified) { oldValue, newValue in
            guard oldValue != nil, newValue != oldValue, let document else { return }
            Task {
                await document.mainDidChange()
            }
        }
        .focusedSceneValue(\.saveDocumentAction, saveAction)
    }

    // MARK: Content

    @ViewBuilder private func content(_ document: SkillFileDocument) -> some View {
        VStack(spacing: 0) {
            if document.isDeleted {
                SkillFileNotice(text: "This file was deleted.")
            }
            if document.hasMainChange {
                HStack(spacing: 8) {
                    Text("Changed on the Main")
                    Spacer()
                    Button("Reload") {
                        document.reloadFromMain()
                    }
                    Button("Keep Mine") {
                        document.keepMine()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
            if path == SkillItem.skillFile, document.content == .text,
               let problem = SkillFrontMatter.problem(in: Data(document.text.utf8), skillName: skillName) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(problem) Sessions do not get this skill until it is fixed.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            if isMarkdown, document.content == .text {
                Picker("Mode", selection: $mode) {
                    Text("Preview").tag(SkillFileMode.preview)
                    Text("Edit").tag(SkillFileMode.edit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(8)
            }
            fileContent(document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func fileContent(_ document: SkillFileDocument) -> some View {
        switch document.content {
        case .loading:
            if document.isDeleted {
                Color.clear
            } else {
                ProgressView()
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        case .binary(let size):
            Text("Binary file — \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
                .foregroundStyle(.secondary)
        case .text:
            if isMarkdown && mode == .preview {
                ScrollView {
                    MarkdownView(document.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                CodeEditorView(
                    text: Binding(get: { document.text }, set: { document.edit($0) }),
                    language: EditorLanguage(fileName: path),
                    isEditable: document.isEditable
                )
            }
        }
    }

    // MARK: Lifecycle

    private func open() async {
        let isNew = document == nil
        let document = document ?? SkillFileDocument(workspace: workspace, settings: settings,
                                                     autosaveBanners: appModel.banners, mainDeviceID: mainDeviceID,
                                                     skillName: skillName, path: path)
        self.document = document
        screen.openDocuments[key] = document
        guard isNew else { return }
        if screen.editModeRequests.remove(key) != nil {
            mode = .edit
        }
        await document.load()
    }

    /// The view goes away while the document is modified: it saves first, unless it is discarded (its file or its skill
    /// is being deleted).
    private func close() {
        guard let document else { return }
        if screen.openDocuments[key] === document {
            screen.openDocuments[key] = nil
        }
        if document.isModified, !document.isDiscarded {
            let router = appModel.banners
            Task {
                await document.save { error in
                    router.post(Banner(style: .error, message: Banner.message(of: error)))
                }
            }
        }
    }

    /// ⌘S while a text file is shown; a failure shows in the window's banners.
    private var saveAction: (() -> Void)? {
        guard let document, document.isEditable else { return nil }
        let banners = banners
        return {
            Task {
                await document.save { error in
                    banners.showError(error)
                }
            }
        }
    }
}

/// A notice above the content of a file.
private struct SkillFileNotice: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
    }
}
