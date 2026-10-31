import HephCore
import SwiftUI

/// A menu-style picker of the permission mode (docs/ui/sessions.md, "Labels"). With a default label, its first choice
/// is nil with that label; then the five modes in the order of the table. Its own label is hidden: the caller labels
/// it (for example with `LabeledContent`).
public struct PermissionModePicker: View {
    @Binding private var selection: PermissionMode?
    private let defaultLabel: String?

    public init(selection: Binding<PermissionMode?>, defaultLabel: String?) {
        _selection = selection
        self.defaultLabel = defaultLabel
    }

    public var body: some View {
        Picker("Permission Mode", selection: $selection) {
            if let defaultLabel {
                Text(defaultLabel)
                    .tag(PermissionMode?.none)
            }
            ForEach(ClaudeLabels.permissionModes, id: \.self) { mode in
                Text(ClaudeLabels.title(mode))
                    .tag(PermissionMode?.some(mode))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

/// A model text field with a trailing menu of the aliases and "Clear" (docs/ui/sessions.md, "Labels"). Choosing an
/// item sets the text and commits; the field also commits on Return and when it loses focus. Its own label is hidden:
/// the caller labels it.
public struct ClaudeModelField: View {
    @Binding private var model: String
    private let placeholder: String
    private let onCommit: () -> Void
    @FocusState private var isFocused: Bool

    public init(model: Binding<String>, placeholder: String, onCommit: @escaping () -> Void) {
        _model = model
        self.placeholder = placeholder
        self.onCommit = onCommit
    }

    public var body: some View {
        HStack(spacing: 4) {
            TextField("Model", text: $model, prompt: Text(placeholder))
                .labelsHidden()
                .focused($isFocused)
                .onSubmit(onCommit)
                .onChange(of: isFocused) { wasFocused, focused in
                    if wasFocused && !focused {
                        onCommit()
                    }
                }
            Menu {
                ForEach(ClaudeLabels.modelAliases, id: \.self) { alias in
                    Button(alias) {
                        model = alias
                        onCommit()
                    }
                }
                Button("Clear") {
                    model = ""
                    onCommit()
                }
            } label: {
                Label("Model", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// The Permission Mode and Model submenus of the options menu, the session context menu and the new chat, with Allow
/// All Tools between them for a session (docs/ui/sessions.md, "Options menu", "Session context menu", "New chat"); the
/// current choices are checked.
struct SessionOptionMenus: View {
    /// The current permission mode; nil is the default choice.
    let permissionMode: PermissionMode?
    /// The current model; nil or empty is the default choice.
    let model: String?
    /// The first choice of Permission Mode, nil for none (the five modes only).
    let permissionModeDefaultTitle: String?
    /// The first choice of Model.
    let modelDefaultTitle: String
    /// A session's Allow All Tools, checked when true; nil leaves the item out (new chat).
    var allowsAllTools: Bool? = nil
    let onPermissionMode: (PermissionMode?) -> Void
    /// Called with the opposite of `allowsAllTools`.
    var onAllowAllTools: (Bool) -> Void = { _ in }
    /// Called with nil for the default choice, else the alias.
    let onModel: (String?) -> Void
    let onOtherModel: () -> Void

    var body: some View {
        Menu("Permission Mode") {
            if let permissionModeDefaultTitle {
                SessionCheckedItem(title: permissionModeDefaultTitle, isChecked: permissionMode == nil) {
                    onPermissionMode(nil)
                }
            }
            ForEach(ClaudeLabels.permissionModes, id: \.self) { mode in
                SessionCheckedItem(title: ClaudeLabels.title(mode), isChecked: permissionMode == mode) {
                    onPermissionMode(mode)
                }
            }
        }
        if let allowsAllTools {
            SessionCheckedItem(title: "Allow All Tools", isChecked: allowsAllTools) {
                onAllowAllTools(!allowsAllTools)
            }
        }
        Menu("Model") {
            SessionCheckedItem(title: modelDefaultTitle, isChecked: (model ?? "").isEmpty) {
                onModel(nil)
            }
            ForEach(ClaudeLabels.modelAliases, id: \.self) { alias in
                SessionCheckedItem(title: alias, isChecked: model == alias) {
                    onModel(alias)
                }
            }
            Button("Other…", action: onOtherModel)
        }
    }
}

/// A menu item with a checkmark when it is the current choice.
struct SessionCheckedItem: View {
    let title: String
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { isChecked }, set: { _ in action() }))
    }
}
