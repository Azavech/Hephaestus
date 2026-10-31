import HephClient
import HephCore
import SwiftUI

/// The identifier field of New Project and Add Existing Folder (docs/ui/overview.md, "Identifier field").
///
/// Each change of the text is replaced by `ProjectIdentifier.normalize` of it. The identifier is valid when it is 2 to 8
/// letters A–Z and no project or sub project of the connected Mains has it (the Main checks again). The message under
/// the field is the first that applies.
struct ProjectIdentifierField: View {
    @Binding var text: String
    @Binding var isValid: Bool

    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Identifier", text: normalizedText)
            if let message {
                Text(verbatim: message.text)
                    .font(.caption)
                    .foregroundStyle(message.isError ? Color.red : Color.secondary)
            }
        }
        .onAppear(perform: updateValidity)
        .onChange(of: text) {
            updateValidity()
        }
        .onChange(of: workspace.topologyRevision) {
            updateValidity()
        }
    }

    private var normalizedText: Binding<String> {
        Binding(
            get: { text },
            set: { text = ProjectIdentifier.normalize($0) }
        )
    }

    /// Shown when the text is not empty, the first matching condition only.
    private var message: (text: String, isError: Bool)? {
        guard !text.isEmpty else { return nil }
        if !text.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) {
            return ("Use letters A to Z only.", true)
        }
        if !(2...8).contains(text.unicodeScalars.count) {
            return ("Use 2 to 8 letters.", true)
        }
        if let usage = usage(of: text) {
            return ("\(text) is already used by “\(usage.projectName)” on \(usage.mainName).", true)
        }
        return ("Tickets will be numbered \(text)-1, \(text)-2, …", false)
    }

    private func updateValidity() {
        isValid = ProjectIdentifier.isValid(text) && usage(of: text) == nil
    }

    /// The project with this identifier in the trees of the connected Mains, with its Main's name.
    private func usage(of identifier: String) -> (projectName: String, mainName: String)? {
        let connections = workspace.connections.values
            .filter(\.isConnected)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for connection in connections {
            if let project = Self.project(identifier, in: connection.projects) {
                return (project.name, connection.name)
            }
        }
        return nil
    }

    private static func project(_ identifier: String, in tree: [ProjectSummary]) -> ProjectSummary? {
        for project in tree {
            if project.id == identifier {
                return project
            }
            if let child = Self.project(identifier, in: project.children) {
                return child
            }
        }
        return nil
    }
}
