# Feedback

files:
- HephaestusKit/Sources/HephUI/Feedback/FeedbackController.swift
- HephaestusKit/Sources/HephUI/Feedback/FeedbackSupport.swift
- HephaestusKit/Sources/HephUI/Feedback/FeedbackCommands.swift
- HephaestusKit/Sources/HephUI/Feedback/FeedbackToolbarButton.swift
- HephaestusKit/Sources/HephUI/Feedback/FeedbackSheet.swift
- HephaestusKit/Sources/HephUI/Feedback/ScreenshotCapture.swift
- HephaestusKit/Sources/HephUI/Feedback/ShakeDetection.swift

---

Feedback can be started from anywhere in the app. The window is captured before anything appears, the user writes a
comment, and the feedback goes to the Forge host, which creates a task with the screenshot and starts a feedback
session on it ([pipeline.md](pipeline.md#feedback-intake)). The sending device then opens that session: the Claude
discussion pops up.

The screenshot, the comment and the context are personal data ([../general.md](../general.md#personal-data)).
They stay in the feedback task, under the source project's `.hephaestus/` folder, which git ignores, and the prompt of
the feedback session forbids copying anything of them into the public repository
([../claude/prompts.md](../claude/prompts.md#forge-common-part)).

## Entry points

| Entry point                    | Platforms                              | Defined by                                                                                                                                                                                                                           |
|--------------------------------|----------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Toolbar button                 | all                                    | `FeedbackToolbarButton`, placed by the shell in every window's toolbar ([../ui/shell.md](../ui/shell.md)): label `Send Feedback`, system image `exclamationmark.bubble`, help `Send Feedback (⇧⌘F)`; no keyboard shortcut of its own |
| Help ▸ Send Feedback… (⇧⌘F)    | macOS; iPadOS with a hardware keyboard | `FeedbackCommands`, added to the window scene's commands by the shell: `CommandGroup(replacing: .help)` holding the button `Send Feedback…` with `.keyboardShortcut("f", modifiers: [.command, .shift])`                             |
| Shaking the device             | iOS, iPadOS                            | Shake detection below                                                                                                                                                                                                                |

Each entry point calls `begin()` on the `FeedbackController` of the window concerned: the toolbar button on its
window's controller (from the environment), the menu item on `FeedbackController.forKeyWindow()` (nothing happens when
it is nil), a shake on the controller of the window that received it.

## Window binding

The shell applies `.feedbackSupport()` to the root view of every window, inside the environment that provides the
`Workspace` and the window's `WindowContext`, and `.feedbackSupport(section: "settings")` to the root of the macOS
Settings scene, which has no `WindowContext` ([../ui/shell.md](../ui/shell.md)). The modifier:

- creates the window's `FeedbackController` (`@State`) and puts it in the environment;
- passes it the `Workspace` and, when the environment has one, the window's `WindowContext`
  ([../ui/shell.md](../ui/shell.md#52-windowcontext)), whose `selection` is the window's `Selection`
  ([../client/workspace.md](../client/workspace.md#selection)), plus `section`; the controller uses `workspace.forge`
  (`ForgeModel`, [../ui/forge.md](../ui/forge.md#forgemodel));
- adds a zero-size background `NSViewRepresentable` / `UIViewRepresentable` whose view reports its window from
  `viewDidMoveToWindow()` / `didMoveToWindow()`; the controller keeps that window weakly and registers itself for it;
- on iOS and iPadOS, observes `Notification.Name.deviceDidShake`.

The registry (a `@MainActor` static map from window to controller, weak on both sides) also records the last
controller with a `WindowContext` whose window became key (`NSWindow.didBecomeKeyNotification`,
`UIWindow.didBecomeKeyNotification`), or was already key when the controller registered for it or got its
environment.

`forKeyWindow()`:

- macOS: `NSApp.keyWindow`, followed through `sheetParent` up to its top-level window; that window's controller, else
  the controller of `NSApp.mainWindow`, else nil.
- iPadOS: the key window of the first `UIWindowScene` whose `activationState` is `foregroundActive`; its controller,
  else nil.

## Shake detection

`ShakeDetection.swift` (iOS and iPadOS only, `#if os(iOS)`):

```swift
extension Notification.Name {
    /// Posted when the device is shaken; the object is the UIWindow that received the motion event.
    public static let deviceDidShake = Notification.Name("HephaestusDeviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: self)
        }
        super.motionEnded(motion, with: event)
    }
}
```

A controller handles the notification only when its object is the controller's window. A shake handled by a text
view first (shake to undo while typing) does not reach the window and starts nothing.

## Capture

`begin()` does nothing when the controller has no window, or while a capture or a sheet of this controller is in
progress. Otherwise:

1. The window is captured (below). The sheet is not shown yet, so it is not in the image.
2. The context is built (Context).
3. The sheet is presented (Sheet).

### macOS

1. The frame view is `window.contentView?.superview` (title bar and toolbar included). No frame view: no screenshot.
2. `rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)`, then
   `frameView.cacheDisplay(in: frameView.bounds, to: rep)`.
3. Web views are drawn by WebKit in another process and are blank in that image. Every `WKWebView` of the frame view's
   subtree (depth first) with `isHiddenOrHasHiddenAncestor` false and a non-empty `visibleRect` is snapshotted with
   `try await webView.takeSnapshot(configuration: nil)` and drawn into `rep` through `NSGraphicsContext(bitmapImageRep:
   rep)` (point coordinates, origin bottom left): clipped to `webView.convert(webView.visibleRect, to: frameView)`,
   the image drawn in `webView.convert(webView.bounds, to: frameView)`. When `frameView.isFlipped`, a rect's `y` is
   `frameView.bounds.height - rect.maxY`. A failing snapshot leaves its area as captured.
4. Attached sheets: when `window.attachedSheet` is set, it is captured the same way (its own attached sheet included)
   and drawn at `(sheet.frame.minX - window.frame.minX, sheet.frame.minY - window.frame.minY)`.
5. PNG: `rep.representation(using: .png, properties: [:])`.

### iOS and iPadOS

1. `format = UIGraphicsImageRendererFormat()`, `format.scale = window.traitCollection.displayScale`,
   `format.opaque = true`.
2. `UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
   window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }`. The image includes presented sheets and web
   views.
3. PNG: `image.pngData()`.

### Size

The PNG is sent as it is, whatever its size: it is uploaded in chunks ([Sending](#sending)). A capture that fails
gives no screenshot; the feedback can still be sent.

## Context

`FeedbackContext` ([../protocol/types.md](../protocol/types.md)), built when the capture ends:

| Field        | Value                                                                                                         |
|--------------|---------------------------------------------------------------------------------------------------------------|
| `deviceID`   | `workspace.device.id`                                                                                         |
| `deviceName` | `workspace.device.name`                                                                                       |
| `platform`   | `workspace.device.platform`                                                                                   |
| `appVersion` | `CFBundleShortVersionString` of the running app                                                               |
| `build`      | `CFBundleVersion` of the running app as an integer (`0` when it is not one)                                   |
| `docsHash`   | `DocsHash.embedded` ([generation.md](generation.md#13-docshash-hephcore))                                     |
| `selection`  | `context.selection.feedbackSelection` (the window's `Selection`); with the modifier's `section`, that section |

Without a `WindowContext` (Settings window), `selection` has only `section` (`settings`).

## Sheet

### Presentation

The sheet is presented by the platform so that it also appears over another sheet:

- macOS: an `NSWindow(contentViewController: NSHostingController(rootView: FeedbackSheet(controller:)))` with style
  `.titled`, content size 560 × 600 pt, presented with `beginSheet(_:)` on the deepest attached sheet of the
  controller's window (`attachedSheet` followed), closed with `endSheet(_:)`.
- iOS and iPadOS: a `UIHostingController(rootView: FeedbackSheet(controller:))` presented by the topmost view
  controller of `window.rootViewController` (`presentedViewController` followed); `.formSheet` on iPad, `.pageSheet`
  with the `.large()` detent on iPhone; `isModalInPresentation = true`.

The sheet's view gets the controller explicitly; it does not rely on the window's environment.

### Content

A `VStack(alignment: .leading, spacing: 12)` with 20 pt padding:

| Element            | Content                                                                                                                                                                                                                                                                                                  |
|--------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| title              | `Send Feedback` (headline)                                                                                                                                                                                                                                                                               |
| screenshot preview | the image, aspect fit, at most 240 pt high (200 pt on iPhone), 1 pt separator-colored border, corner radius 6; without a screenshot a box of the same height with `No screenshot` (secondary)                                                                                                            |
| comment            | `TextEditor`, at least 120 pt high, focused when the sheet appears; placeholder `Describe the problem or the change you want.` while empty                                                                                                                                                               |
| context            | caption, secondary: `<deviceName> · Hephaestus <appVersion> (<build>) · docs <first 12 characters of docsHash>`; when the selection has a Main, a second line `<Main name> ▸ <projectID> ▸ <section> ▸ <item>` with the parts it has                                                                     |
| Forge              | caption: `Sent to the Forge on <Forge host name>.`, or `No Forge online.` in orange when `workspace.forge.forgeHostID` is nil                                                                                                                                                                            |
| upload             | while the screenshot uploads, from Send until a report of every byte (`completed` = `total`): `Uploading the screenshot…` (caption), a `ProgressView(value: progress.fraction)` (indeterminate before the first report) and `<completed> of <total>` (`ByteCountFormatter`, `.file`, caption, secondary) |
| error              | when set: the message in a red banner (`exclamationmark.triangle.fill`, white text on red, corner radius 8)                                                                                                                                                                                              |
| buttons            | trailing: `Cancel` (`.cancelAction`) and `Send` (`.borderedProminent`, `.keyboardShortcut(.return, modifiers: .command)`)                                                                                                                                                                                |

- A Main's name, in the context and Forge lines, is the name of its connection, else its registry name, else its id's
  `uuidString`. `<section>` and `<item>` are the selection's strings as they are.
- `Send` is disabled while the comment, trimmed, is empty, and while sending (a `ProgressView` replaces its label).
  `Cancel` is disabled while sending.
- `Cancel` closes the sheet and discards the draft.
- Errors show inside the sheet because the window's error banner is behind it.

## Sending

1. The target is `workspace.forge.forgeHostID` ([../ui/forge.md](../ui/forge.md#forgemodel)), the connected Main whose
   `host.info` reports `forge`. None: the error is `No Forge is online. Feedback goes to the Main where “This Main is
   the Forge” is on (Settings ▸ Forge & Updates).` and the sheet stays.
2. `workspace.forge.sendFeedback(screenshot:comment:context:progress:)` ([../ui/forge.md](../ui/forge.md#requests)):
   with a screenshot, it first uploads the PNG to that Main for the Forge's source project, in chunks, and the sheet
   shows the upload's progress (the upload row); then it sends `forge.feedback {screenshot, comment, context}` to that
   Main: `screenshot` = the upload's `UploadRef` (nil when there is no screenshot), `comment` = the comment trimmed.
3. Failure (of the upload or of `forge.feedback`): the error is the error's message, as the window banners give it
   ([../ui/shell.md](../ui/shell.md#81-windowbanners)); the sheet and the comment stay, so Send can be pressed again,
   which uploads the screenshot again.
4. Success `{projectID, taskID, sessionID}`: the sheet closes and the session opens with
   `context.navigate(mainDeviceID: <the Forge host>, projectID: projectID, section: .claude, item:
   sessionID.uuidString)` on the controller's `WindowContext` ([../ui/shell.md](../ui/shell.md#52-windowcontext)),
   which also closes a search palette or search sheet that was open; the Claude section shows the session
   ([../ui/sessions.md](../ui/sessions.md)). A controller without a `WindowContext` (Settings) makes the same call on
   the `WindowContext` of the registry's last active window, which is brought to the front
   (`makeKeyAndOrderFront(nil)`); when there is none, nothing opens.

## Swift API

```swift
// HephUI/Feedback — @MainActor.

@MainActor @Observable public final class FeedbackController {
    public init()
    /// Captures the window, builds the context and presents the sheet; does nothing while busy or without a window.
    public func begin()
    /// The controller of the key window (of its top-level window when the key window is a sheet), else of the main
    /// window (macOS); of the key window of the foreground scene (iOS, iPadOS).
    public static func forKeyWindow() -> FeedbackController?
}

extension View {
    /// Applied by the shell to every window root, and to the macOS Settings root with section "settings".
    public func feedbackSupport(section: String? = nil) -> some View
}

/// Toolbar item of every window; reads the window's FeedbackController from the environment.
public struct FeedbackToolbarButton: View { public init() }

/// Help ▸ Send Feedback… (⇧⌘F).
public struct FeedbackCommands: Commands { public init() }
```

Internal types: `FeedbackDraft` (screenshot PNG data, preview image, context, comment, sending flag, upload progress
(`TransferProgress?`), error message),
`FeedbackSheet`, `ScreenshotCapture` (`static func capture(_ window:) async -> Data?` per platform).

## Depends on

| Name                                                                                              | Defined in                                                        |
|---------------------------------------------------------------------------------------------------|-------------------------------------------------------------------|
| `FeedbackContext`, `FeedbackSelection`, `ForgeFeedbackResult`                                     | [../protocol/types.md](../protocol/types.md)                      |
| `forge.feedback` on the Forge host                                                                | [pipeline.md](pipeline.md#feedback-intake)                        |
| `ForgeModel` (`workspace.forge`: `forgeHostID`, `sendFeedback`)                                   | [../ui/forge.md](../ui/forge.md#forgemodel)                       |
| `TransferProgress`, uploads                                                                       | [../client/workspace.md](../client/workspace.md#transfers)        |
| `Workspace` (`device`, `forge`), `Selection` (`feedbackSelection`)                                | [../client/workspace.md](../client/workspace.md)                  |
| toolbar placement, commands, window and Settings roots, `WindowContext` (`selection`, `navigate`) | [../ui/shell.md](../ui/shell.md)                                  |
| the Claude section showing a selected session                                                     | [../ui/sessions.md](../ui/sessions.md)                            |
| `DocsHash.embedded`                                                                               | [generation.md](generation.md)                                    |
| personal data, the public repository rule                                                         | [../general.md](../general.md#public-repository-no-personal-data) |
| the feedback session's prompt                                                                     | [../claude/prompts.md](../claude/prompts.md)                      |
