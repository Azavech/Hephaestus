import HephClient
import HephCore
import SwiftUI

/// Creates a project on the Main `mainDeviceID`: top-level when `parentID` is nil, else a sub project of `parentID`.
/// Dismisses itself and selects the new project on success.
///
/// Opened from the path bar's project menu (top-level) or from the Sub Projects section of the Overview (sub project)
/// (docs/ui/overview.md, "New Project sheet").
public struct NewProjectSheet: View {
    private let mainDeviceID: UUID
    private let parentID: String?

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var identifier = ""
    @State private var isIdentifierValid = false
    @State private var folderName = ""
    @State private var description = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    public init(mainDeviceID: UUID, parentID: String? = nil) {
        self.mainDeviceID = mainDeviceID
        self.parentID = parentID
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("On") {
                        Text(verbatim: onText)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $name)
                        if nameHasLineBreak {
                            Text("Use a single line.")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    ProjectIdentifierField(text: $identifier, isValid: $isIdentifierValid)
                    LabeledContent("Folder name") {
                        TextField("Folder name", text: $folderName, prompt: Text(verbatim: defaultFolder))
                            .labelsHidden()
                    }
                    LabeledContent("Location") {
                        Text(verbatim: location)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(action: create) {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 420)
        #endif
        .task {
            if parentID == nil, let connection, connection.hostInfo == nil {
                await connection.refreshHostInfo()
            }
        }
    }

    private var connection: MainConnection? {
        workspace.connection(mainDeviceID)
    }

    // MARK: - Fields

    /// "<Main name>"; for a sub project "Inside <parent name> on <Main name>".
    private var onText: String {
        let mainName = OverviewScreen.mainName(mainDeviceID, workspace: workspace)
        guard let parentID else { return mainName }
        let parentName = workspace.summary(of: parentID, on: mainDeviceID)?.name ?? parentID
        return "Inside \(parentName) on \(mainName)"
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameHasLineBreak: Bool {
        trimmedName.contains { $0.isNewline }
    }

    /// The folder used when the folder name is empty: the trimmed name with `/` and `:` replaced by `-`.
    private var defaultFolder: String {
        trimmedName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private var trimmedFolderName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Relative to the projects folder or the parent's root; `/` makes nested folders; it does not start with `/` and
    /// has no empty, `.` or `..` component. Empty: the default folder.
    private var isFolderNameValid: Bool {
        let folder = trimmedFolderName
        guard !folder.isEmpty else { return true }
        guard !folder.hasPrefix("/") else { return false }
        return folder.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    /// `<base>/<folder name, or the default folder>`: the base is the Main's projects folder for a top-level project,
    /// the parent's root for a sub project.
    private var location: String {
        let base: String?
        if let parentID {
            base = workspace.summary(of: parentID, on: mainDeviceID)?.rootPath
        } else {
            base = connection?.hostInfo?.projectsFolder
        }
        guard let base else { return "" }
        let folder = trimmedFolderName.isEmpty ? defaultFolder : trimmedFolderName
        return base.hasSuffix("/") ? base + folder : base + "/" + folder
    }

    /// Every rule passes, the Main is connected and no request is in flight.
    private var canCreate: Bool {
        OverviewScreen.isValidName(trimmedName) && isIdentifierValid && isFolderNameValid
            && (connection?.isConnected ?? false) && !isCreating
    }

    // MARK: - Create

    /// `createProject(name:identifier:parentID:folderName:description:)`; the folder name and the description are passed
    /// only when they are not empty after trimming.
    private func create() {
        guard canCreate else { return }
        let name = trimmedName
        let identifier = self.identifier
        let parentID = self.parentID
        let folder = trimmedFolderName
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let mainDeviceID = self.mainDeviceID
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let connection = try OverviewScreen.connection(mainDeviceID, workspace: workspace)
                let project = try await connection.createProject(
                    name: name,
                    identifier: identifier,
                    parentID: parentID,
                    folderName: folder.isEmpty ? nil : folder,
                    description: trimmedDescription.isEmpty ? nil : trimmedDescription
                )
                isCreating = false
                dismiss()
                context.navigate(mainDeviceID: mainDeviceID, projectID: project.id, section: .overview, item: nil)
            } catch is CancellationError {
                isCreating = false
            } catch {
                isCreating = false
                errorMessage = Banner.message(of: error)
            }
        }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    NewProjectSheet(mainDeviceID: studio)
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
