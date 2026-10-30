#if os(macOS)
import Foundation
import HephClient
import HephCore
import HephHost
import SwiftUI

/// Settings ▸ Forge & Updates: the Forge settings of this Main, its private terms, and the self-update of this Mac
/// (docs/ui/settings.md, "Forge & Updates").
struct ForgeSettingsPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(Workspace.self) private var workspace
    @Environment(SettingsStore.self) private var settings
    @Environment(\.controlActiveState) private var controlActiveState
    /// The error message under each control, from its last write.
    @State private var errors: [Control: String] = [:]
    @State private var repository = ""
    @State private var branch = ""
    @FocusState private var focusedField: Control?
    /// The number of private terms (`n`).
    @State private var termsCount = 0
    /// The pending suggestions; their count is `k`.
    @State private var suggestions: [String] = []
    @State private var suggestionsTask: Task<Void, Never>?
    @State private var isEditingTerms = false
    @State private var termsError: String?
    @State private var showsSuggestions = false
    /// The signing identities of this Mac; nil while they load.
    @State private var identities: [SigningIdentity]?

    private enum Control: Hashable {
        case enabled, sourceProject, repository, branch, autoRegenerate, updatesEnabled, signingIdentity
    }

    init() {}

    var body: some View {
        Form {
            forgeSection
            updatesSection
        }
        .formStyle(.grouped)
        .onChange(of: settings.settings.forge.repository, initial: true) {
            repository = settings.settings.forge.repository
        }
        .onChange(of: settings.settings.forge.branch, initial: true) {
            branch = settings.settings.forge.branch
        }
        .onChange(of: focusedField) { previous, current in
            if previous == .repository, current != .repository {
                commitRepository()
            }
            if previous == .branch, current != .branch {
                commitBranch()
            }
        }
        .onAppear {
            refreshTerms()
        }
        .onChange(of: controlActiveState) {
            if controlActiveState == .key {
                refreshTerms()
            }
        }
        .onChange(of: settings.settings.forge.enabled) {
            refreshTerms()
        }
        .onChange(of: appModel.identity.isMain) {
            refreshTerms()
        }
        .task {
            identities = await appModel.updater.signingIdentities()
        }
        .sheet(isPresented: $showsSuggestions) {
            PrivateTermsSheet(suggestions: suggestions) { term, isAdded in
                if isAdded {
                    try await appModel.addPrivateTerm(term)
                } else {
                    try await appModel.dismissPrivateTerm(term)
                }
            } reload: {
                termsCount = appModel.privateTermsCount()
                suggestions = await appModel.privateTermSuggestions()
            }
        }
    }

    // MARK: - Forge

    private var forgeSection: some View {
        Section {
            if appModel.identity.isMain {
                Toggle("This Main is the Forge", isOn: forgeEnabled)
                errorText(.enabled)
                Group {
                    sourceProjectPicker
                    errorText(.sourceProject)
                    TextField("Repository", text: $repository, prompt: Text("owner/name"))
                        .focused($focusedField, equals: .repository)
                        .onSubmit {
                            commitRepository()
                        }
                    errorText(.repository)
                    TextField("Branch", text: $branch)
                        .focused($focusedField, equals: .branch)
                        .onSubmit {
                            commitBranch()
                        }
                    errorText(.branch)
                    Toggle("Regenerate automatically", isOn: autoRegenerate)
                    errorText(.autoRegenerate)
                }
                .disabled(!settings.settings.forge.enabled)
                if settings.settings.forge.enabled {
                    privateTermsRow
                }
            } else {
                Text("Available when this Mac is a Main.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Forge")
        } footer: {
            if appModel.identity.isMain {
                Text("The Forge turns feedback into documentation changes, regenerates the app and follows its CI "
                    + "build.")
            }
        }
    }

    /// The projects of this Mac's tree, depth first, and the stored identifier when it is not among them.
    private var sourceProjectPicker: some View {
        let projects = Self.depthFirst(workspace.localConnection?.projects ?? [])
        let stored = settings.settings.forge.sourceProjectID
        return Picker("Source project", selection: sourceProject) {
            ForEach(projects, id: \.id) { project in
                Text(project.name + " — " + project.id)
                    .tag(project.id)
            }
            if !projects.contains(where: { $0.id == stored }) {
                Text(stored + " (not on this Mac)")
                    .tag(stored)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var privateTermsRow: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Text(termsCount == 1 ? "1 term" : String(termsCount) + " terms")
                    Button("Edit…") {
                        editPrivateTerms()
                    }
                    .disabled(isEditingTerms)
                }
                if !suggestions.isEmpty {
                    HStack(spacing: 8) {
                        Text(suggestions.count == 1 ? "1 new suggestion" : String(suggestions.count) + " new suggestions")
                            .foregroundStyle(.orange)
                        Button("Review…") {
                            showsSuggestions = true
                        }
                    }
                }
            }
        } label: {
            Text("Private terms")
            Text("Words the personal-data check refuses in the public repository. Hephaestus never sends this file "
                + "anywhere.")
        }
        if let termsError {
            Text(termsError)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section("Updates") {
            Toggle(isOn: updatesEnabled) {
                Text("Update automatically")
                Text("When off, Hephaestus checks for new builds and offers Install instead of installing them by "
                    + "itself.")
            }
            errorText(.updatesEnabled)
            LabeledContent("Status") {
                UpdateStatusView()
            }
            LabeledContent {
                HStack(spacing: 8) {
                    if identities == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                    signingIdentityPicker
                }
            } label: {
                Text("Signing identity")
                Text("Automatic: the first Apple Development or Developer ID Application identity of this Mac.")
            }
            errorText(.signingIdentity)
        }
    }

    /// "Automatic", "Keep the ad-hoc signature", the identities of this Mac, then the stored value when it is none
    /// of these.
    private var signingIdentityPicker: some View {
        let stored = settings.settings.updates.signingIdentity
        let loaded = identities ?? []
        let isKnown = stored.isEmpty || stored == "-" || loaded.contains { $0.sha1 == stored }
        return Picker("Signing identity", selection: signingIdentity) {
            Text("Automatic")
                .tag("")
            Text("Keep the ad-hoc signature")
                .tag("-")
            ForEach(loaded) { identity in
                Text(identity.name)
                    .tag(identity.sha1)
            }
            if !isKnown {
                Text(stored)
                    .tag(stored)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    @ViewBuilder
    private func errorText(_ control: Control) -> some View {
        if let message = errors[control] {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Bindings

    private var forgeEnabled: Binding<Bool> {
        Binding {
            settings.settings.forge.enabled
        } set: { value in
            write(.enabled) { $0.forge.enabled = value }
        }
    }

    private var sourceProject: Binding<String> {
        Binding {
            settings.settings.forge.sourceProjectID
        } set: { identifier in
            guard identifier != settings.settings.forge.sourceProjectID else { return }
            write(.sourceProject) { $0.forge.sourceProjectID = identifier }
        }
    }

    private var autoRegenerate: Binding<Bool> {
        Binding {
            settings.settings.forge.autoRegenerate
        } set: { value in
            write(.autoRegenerate) { $0.forge.autoRegenerate = value }
        }
    }

    private var updatesEnabled: Binding<Bool> {
        Binding {
            settings.settings.updates.enabled
        } set: { value in
            write(.updatesEnabled) { $0.updates.enabled = value }
        }
    }

    private var signingIdentity: Binding<String> {
        Binding {
            settings.settings.updates.signingIdentity
        } set: { value in
            guard value != settings.settings.updates.signingIdentity else { return }
            write(.signingIdentity) { $0.updates.signingIdentity = value }
        }
    }

    // MARK: - Writes

    /// Writes a key; a failure shows its message under the control, which returns to the stored value.
    @discardableResult
    private func write(_ control: Control, _ change: (inout DeviceSettings) -> Void) -> Bool {
        do {
            try settings.update(change)
            errors[control] = nil
            return true
        } catch {
            errors[control] = Banner.message(of: error)
            return false
        }
    }

    private func commitRepository() {
        let stored = settings.settings.forge.repository
        let value = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != stored else {
            repository = stored
            return
        }
        if !write(.repository, { $0.forge.repository = value }) {
            repository = stored
        }
    }

    private func commitBranch() {
        let stored = settings.settings.forge.branch
        let value = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != stored else {
            branch = stored
            return
        }
        if !write(.branch, { $0.forge.branch = value }) {
            branch = stored
        }
    }

    // MARK: - Private terms

    /// Reads `n` and the suggestions again while the row is shown.
    private func refreshTerms() {
        guard appModel.identity.isMain, settings.settings.forge.enabled else { return }
        termsCount = appModel.privateTermsCount()
        suggestionsTask?.cancel()
        suggestionsTask = Task {
            let found = await appModel.privateTermSuggestions()
            guard !Task.isCancelled else { return }
            suggestions = found
        }
    }

    private func editPrivateTerms() {
        isEditingTerms = true
        termsError = nil
        Task {
            do {
                try await appModel.editPrivateTerms()
            } catch {
                termsError = Banner.message(of: error)
            }
            isEditingTerms = false
            refreshTerms()
        }
    }

    // MARK: - Helpers

    /// Every project of a tree, each followed by its sub projects.
    private static func depthFirst(_ projects: [ProjectSummary]) -> [ProjectSummary] {
        projects.flatMap { project in [project] + depthFirst(project.children) }
    }
}

/// The sheet "New Private Terms": each pending suggestion with Add and Dismiss.
private struct PrivateTermsSheet: View {
    let suggestions: [String]
    /// Adds (true) or dismisses (false) a term.
    let decide: @MainActor (String, Bool) async throws -> Void
    /// Reads the suggestions and the number of terms again.
    let reload: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isRunning = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Hephaestus found these words on this Mac since the file was written. Add a word the check "
                        + "must refuse; dismiss a word that is not private. The Forge pushes nothing until each one is "
                        + "added or dismissed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if suggestions.isEmpty {
                        Text("No new suggestions")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(suggestions, id: \.self) { term in
                            HStack(spacing: 8) {
                                Text(term)
                                    .font(.body.monospaced())
                                Spacer(minLength: 0)
                                Button("Add") {
                                    run(term, isAdded: true)
                                }
                                Button("Dismiss") {
                                    run(term, isAdded: false)
                                }
                            }
                            .disabled(isRunning)
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Private Terms")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func run(_ term: String, isAdded: Bool) {
        isRunning = true
        errorMessage = nil
        Task {
            do {
                try await decide(term, isAdded)
            } catch {
                errorMessage = Banner.message(of: error)
            }
            await reload()
            isRunning = false
        }
    }
}
#endif
