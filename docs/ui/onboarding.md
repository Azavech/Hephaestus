# Onboarding

files:
- HephaestusKit/Sources/HephUI/Onboarding/OnboardingView.swift
- HephaestusKit/Sources/HephUI/Onboarding/OnboardingChoiceButton.swift

---

Onboarding is what a device shows while it belongs to no mesh and is not a Main: on first launch, and again after it
left its mesh ([devices.md](devices.md#leave-mesh)). `RootView` shows `OnboardingView` while `AppModel.phase` is
`.onboarding` ([shell.md](shell.md#51-rootview)). Every window of the app shows it; finishing it in one window
switches every window to the shell.

| Platform       | Choices                                                                              |
|----------------|--------------------------------------------------------------------------------------|
| macOS          | "Use this Mac as a Main" (creates the mesh and is its Forge) or "Join a Mesh"        |
| iOS and iPadOS | "Join a Mesh" (only a Mac can be a Main, [../devices/roles.md](../devices/roles.md)) |

## Welcome screen

`OnboardingView` is a `NavigationStack` whose root is the welcome screen: a vertical `ScrollView` whose content is
centered, at most 520 pt wide, with 32 pt padding, top to bottom:

1. `Image(systemName: "hammer.fill")`, 56 pt, accent color.
2. "Welcome to Hephaestus" (`.largeTitle`, bold).
3. "Your projects live on Macs set as Mains. Every device of your mesh can see and control them." (secondary,
   centered).
4. A text field labeled "Device name", prefilled with `identity.name` (on first launch the default name of
   [../devices/roles.md](../devices/roles.md#default-name)). While the trimmed text is empty, "Enter a device name."
   shows under it in red, while it is `Claude` in any letter case "Claude is a reserved name." does, and in both cases the choices are
   disabled.
5. The choices, one `OnboardingChoiceButton` each, full width, 12 pt apart:

| Choice                 | Platforms | Symbol            | Text                                                                                                                                                               |
|------------------------|-----------|-------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Use this Mac as a Main | macOS     | `desktopcomputer` | "Projects live on this Mac and Claude runs here. Creates a new mesh that your other devices join."                                                                 |
| Join a Mesh            | all       | `link`            | macOS: "Connect this Mac to the Mains you already use." iOS and iPadOS: "Connect to the Mains of your mesh. On a Main, open Devices and choose Pair a New Device." |

`OnboardingChoiceButton(symbol:title:text:isBusy:action:)` is a `Button` with `.buttonStyle(.plain)`: an
`HStack(spacing: 14)` with the symbol (28 pt, accent color, 36 pt wide), a `VStack(alignment: .leading)` with the
title (headline) and the text (secondary, multi-line), a `Spacer`, then a small `ProgressView` while `isBusy`, else
`chevron.right` (secondary). Padding 14; background `.quaternary` in a rounded rectangle of corner radius 12.

Both choices first save the name with `try appModel.setLocalName(<field text>)` ([shell.md](shell.md#32-device-names));
when it throws, its message shows in red under the field and nothing else happens.

## Use this Mac as a Main

macOS only. While it runs, its button shows the `ProgressView` and every control of the screen is disabled.

1. The name is saved (above).
2. This Mac becomes the Forge of the mesh it creates: the stored value of `forge.enabled` is remembered, then
   `try appModel.settings.update { $0.forge.enabled = true }`
   ([../data/app-storage.md](../data/app-storage.md#settingsjson),
   [../forge/pipeline.md](../forge/pipeline.md#forge-host-configuration)). When it throws, its message shows in red
   under the field, as when saving the name fails, and nothing else happens.
3. `try await appModel.becomeMain()` ([shell.md](shell.md#33-main-toggle)): the host starts, creates the
   mesh ([../devices/roles.md](../devices/roles.md#turning-main-on-macos)) and, `forge.enabled` being on, enables the
   Forge ([../forge/pipeline.md](../forge/pipeline.md#startup-and-shutdown)). `AppModel.phase` stays `.onboarding`
   while it runs ([shell.md](shell.md#3-appmodel)), so this screen stays with its progress indicator.
4. Success: `AppModel.phase` becomes `.ready`; every window shows the shell. A listener that could not start does not
   stop onboarding: the Main runs and Settings shows the error ([settings.md](settings.md#general)).
5. Failure: `try? appModel.settings.update { $0.forge.enabled = <the value remembered in step 2> }`, so a Mac that
   then joins a mesh, or turns Main on later in Settings, is not made the Forge; then an alert titled "This Mac could
   not become a Main" with the error's message and an OK button; the screen stays.

## Join a Mesh

1. The name is saved (above).
2. The stack pushes `JoinMeshView()` ([devices.md](devices.md#join-flow)), titled "Join a Mesh", with the system back
   button.
3. When the join succeeds, `AppModel.phase` becomes `.ready` and every window shows the shell.

The device name can still be changed on the code step of the join flow.

## Swift API

```swift
// HephUI/Onboarding — @MainActor; reads AppModel from the environment.
public struct OnboardingView: View { public init() }

struct OnboardingChoiceButton: View {
    init(symbol: String, title: String, text: String, isBusy: Bool, action: @escaping () -> Void)
}
```

`OnboardingView` ends its file with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

| Name                                                                                                                                        | Defined in                                       |
|---------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------|
| `AppModel` (`phase`, `identity`, `settings`, `setLocalName`, `becomeMain`), `RootView`, `AppModel.preview()`, `previewWindow(_:selection:)` | [shell.md](shell.md)                             |
| `JoinMeshView`                                                                                                                              | [devices.md](devices.md)                         |
| default device names, name rule, turning Main on                                                                                            | [../devices/roles.md](../devices/roles.md)       |
| `SettingsStore.update`, `forge.enabled`                                                                                                     | [../data/app-storage.md](../data/app-storage.md) |
| the Forge, enabled while `forge.enabled` is on                                                                                              | [../forge/pipeline.md](../forge/pipeline.md)     |
