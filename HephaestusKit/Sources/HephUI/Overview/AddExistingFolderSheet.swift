import HephClient
import HephCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Registers an existing folder of the Main `mainDeviceID` (projects.import).
/// Dismisses itself and selects the project on success.
///
/// Step 1 chooses the folder; when it is not a Hephaestus project yet (`badRequest`), step 3 names it
/// (docs/ui/overview.md, "Add Existing Folder").
public struct AddExistingFolderSheet: View {
    private enum Step {
        case chooseFolder
        case nameProject
    }

    private let mainDeviceID: UUID

    @Environment(Workspace.self) private var workspace
    @Environment(WindowContext.self) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.chooseFolder
    @State private var path: String?
    @State private var name = ""
    @State private var identifier = ""
    @State private var isIdentifierValid = false
    /// The message of the `badRequest` that led to step 3, shown above its fields.
    @State private var stepMessage: String?
    @State private var errorMessage: String?
    @State private var isAdding = false

    public init(mainDeviceID: UUID) {
        self.mainDeviceID = mainDeviceID
    }

    public var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .chooseFolder:
                chooseFolder
            case .nameProject:
                nameProject
            }
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            buttons
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 400)
        #endif
    }

    private var connection: MainConnection? {
        workspace.connection(mainDeviceID)
    }

    // MARK: - Step 1: choose the folder

    @ViewBuilder
    private var chooseFolder: some View {
        #if os(macOS)
        if mainDeviceID == workspace.device.id {
            Form {
                LabeledContent("Folder") {
                    Text(verbatim: path ?? "None")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("Choose…", action: chooseLocalFolder)
            }
            .formStyle(.grouped)
            .disabled(isAdding)
        } else {
            remoteBrowser
        }
        #else
        remoteBrowser
        #endif
    }

    private var remoteBrowser: some View {
        RemoteFolderBrowser(mainDeviceID: mainDeviceID, path: $path)
            .padding(20)
            .disabled(isAdding)
    }

    #if os(macOS)
    /// The Main is this Mac: an open panel for one folder, starting in the Main's projects folder.
    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        if let projectsFolder = connection?.hostInfo?.projectsFolder {
            panel.directoryURL = URL(fileURLWithPath: projectsFolder, isDirectory: true)
        }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            path = url.standardizedFileURL.path
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
    #endif

    // MARK: - Step 3: name the project

    private var nameProject: some View {
        Form {
            Section {
                Text("This folder is not a Hephaestus project yet. Name it to create its .hephaestus/project.yml.")
                if let stepMessage {
                    Text(verbatim: stepMessage)
                        .foregroundStyle(.secondary)
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
            }
        }
        .formStyle(.grouped)
        .disabled(isAdding)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameHasLineBreak: Bool {
        trimmedName.contains { $0.isNewline }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            if step == .nameProject {
                Button("Back") {
                    step = .chooseFolder
                    stepMessage = nil
                    errorMessage = nil
                }
                .disabled(isAdding)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(action: add) {
                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Add")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canAdd)
        }
        .padding(20)
    }

    /// Step 1: a folder is chosen; step 3: the name and the identifier are valid. The Main is connected and no request
    /// is in flight.
    private var canAdd: Bool {
        guard path != nil, !isAdding, connection?.isConnected ?? false else { return false }
        switch step {
        case .chooseFolder:
            return true
        case .nameProject:
            return OverviewScreen.isValidName(trimmedName) && isIdentifierValid
        }
    }

    /// Step 1: `importProject(path:name: nil, identifier: nil)`; step 3: with the name and the identifier. Success
    /// dismisses and selects the project; `badRequest` goes to (or stays on) step 3 with its message; any other error
    /// shows in red.
    private func add() {
        guard canAdd, let path else { return }
        let isNaming = step == .nameProject
        let name = isNaming ? trimmedName : nil
        let identifier = isNaming ? self.identifier : nil
        let mainDeviceID = self.mainDeviceID
        isAdding = true
        errorMessage = nil
        Task {
            do {
                let connection = try OverviewScreen.connection(mainDeviceID, workspace: workspace)
                let project = try await connection.importProject(path: path, name: name, identifier: identifier)
                isAdding = false
                dismiss()
                context.navigate(mainDeviceID: mainDeviceID, projectID: project.id, section: .overview, item: nil)
            } catch let error as ProtocolError where error.code == .badRequest {
                isAdding = false
                if !isNaming {
                    self.name = (path as NSString).lastPathComponent
                    step = .nameProject
                }
                stepMessage = error.message
            } catch is CancellationError {
                isAdding = false
            } catch {
                isAdding = false
                errorMessage = Banner.message(of: error)
            }
        }
    }
}

#Preview {
    let appModel = AppModel.preview()
    let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    AddExistingFolderSheet(mainDeviceID: studio)
        .previewWindow(appModel, selection: Selection(mainDeviceID: studio))
}
