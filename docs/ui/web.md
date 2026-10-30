# Web screen

files:
- HephaestusKit/Sources/HephUI/Web/WebTabsView.swift
- HephaestusKit/Sources/HephUI/Web/WebSectionModel.swift
- HephaestusKit/Sources/HephUI/Web/WebTabController.swift
- HephaestusKit/Sources/HephUI/Web/WebViewHost.swift
- HephaestusKit/Sources/HephUI/Web/WebTabStrip.swift
- HephaestusKit/Sources/HephUI/Web/WebTabList.swift
- HephaestusKit/Sources/HephUI/Web/AddressBar.swift
- HephaestusKit/Sources/HephUI/Web/WebAddress.swift

---

The Web section (⌘5) is the project's integrated browser. The tabs are stored in `project.yml` `webTabs`
([../data/project-yml.md](../data/project-yml.md)), so every device sees the same tabs, titles, URLs and locks in real
time. Each device renders the tabs with its own `WKWebView`: cookies, history and caches stay on the device.

- Requests use the request functions of `store.connection`
  ([../client/workspace.md](../client/workspace.md#request-api)); while it is nil, a user action that sends a request
  fails with `ProtocolError(.unavailable, "The Main of <projectID> is not available.")`, the text of `ProjectFiles`
  ([code.md](code.md#projectfiles)). User actions run through the window's `WindowBanners` (`banners.perform`,
  [shell.md](shell.md#81-windowbanners)), which shows their failures.
- The shell keeps the section shown while the project's Main reconnects, with its offline bar
  ([shell.md](shell.md#63-detail)). While the Main is not connected, every control that sends a request is disabled
  (New Tab and ⌘T, Lock and Unlock, Close, reordering) and write-back sends nothing ([Write-back](#write-back)). ⌘W
  stays published, since without it ⌘W closes the window on macOS ([shell.md](shell.md#112-menus)): closing an unlocked
  tab then fails with an error banner. The section model keeps its web views while the view is gone.

## Swift API

```swift
/// The Web section of the project held by `store`. @MainActor; reads the Workspace, the window's Selection and
/// WindowBanners from the environment.
public struct WebTabsView: View {
    public init(store: ProjectStore)
}

/// Turns what was typed in the address field into the URL to load.
public enum WebAddress {
    public static func resolve(_ input: String) -> URL?
}
```

The section publishes, with `.focusedSceneValue` ([shell.md](shell.md#113-focused-values)):

| Focused value     | Published while                             | Action                                                                                 |
|-------------------|---------------------------------------------|----------------------------------------------------------------------------------------|
| `newWebTabAction` | the view is shown and the Main is connected | New Tab ([Tabs](#tabs))                                                                |
| `closeTabAction`  | a tab is active                             | closes the active tab, or shows "This tab is locked" ([Locking](#locking-and-closing)) |

## Tabs

The tabs are `store.project.webTabs`, in strip order (`WebTab {id, title, url, locked}`,
[../protocol/types.md](../protocol/types.md#webtab)). The view never keeps its own copy: every change is a request, and
the new state arrives with `project.changed` ([../protocol/events.md](../protocol/events.md#projectchanged)).

| Action               | Request function                                                                        | Method        |
|----------------------|-----------------------------------------------------------------------------------------|---------------|
| New Tab              | `openTab(projectID:url: "about:blank", title: "New Tab", locked: nil)`                  | `tabs.open`   |
| Write-back           | `updateTab(projectID:tabID:patch: WebTabPatch(url:title:))` ([Write-back](#write-back)) | `tabs.update` |
| Lock, Unlock         | `updateTab(projectID:tabID:patch: WebTabPatch(locked:))`                                | `tabs.update` |
| Close                | `closeTab(projectID:tabID:)`                                                            | `tabs.close`  |
| Reorder              | `moveTab(projectID:tabID:toIndex:)`: `toIndex` is the tab's index after the move        | `tabs.move`   |

- New Tab: on success the new tab is shown when listed: at once when `project.changed` already listed it before the
  response, else it becomes `pendingTabID`. Its address field takes the focus when it is shown.
- Display title: the stored `title` when not empty, else the URL's host, else "New Tab".
- Each tab shows `globe` (no favicons) and, when locked, `lock.fill`.

## Section model

`WebSectionModel` (internal, `@MainActor @Observable`), one per project identifier for the life of the process
(`WebSectionModel.shared(store:workspace:)`), shared by every window showing the Web section of that project. Each call
sets its `mainDeviceID` to `store.mainDeviceID`; requests of the model go to `workspace.connection(mainDeviceID)`.

| Member                                       | Meaning                                                                                 |
|----------------------------------------------|-----------------------------------------------------------------------------------------|
| `activeTabID: UUID?`                         | The shown tab; when nil or no longer listed, the first tab                              |
| `pendingTabID: UUID?`                        | A tab to show as soon as it is listed; cleared when shown or when the user picks a tab  |
| `controllers: [UUID: WebTabController]`      | The live web views, by tab id                                                           |
| `recent: [UUID]`                             | Tab ids, most recently shown first                                                      |
| `storedURLs: [UUID: String]`                 | The stored URL of each tab as last seen, to detect changes                              |

- `apply(_ tabs: [WebTab])`, called with the tabs when the view appears and on every change of `store.project?.webTabs`:
  1. Controllers of tabs no longer listed are released. When the active tab is gone, the tab that followed it in the
     previous order becomes active, else the one before it, else none.
  2. `pendingTabID` listed: it becomes `activeTabID`.
  3. For each listed tab whose URL differs from `storedURLs[id]` (a tab seen before), the controller, when live, gets
     `storedURLChanged(_:)` ([Remote updates](#remote-updates)). Then `storedURLs` is updated.
- `controller(for tab:)` returns the live controller, or creates one (it starts the initial load); the tab moves to the
  front of `recent`. When more than 8 controllers are live, the least recently shown controllers that are not displayed
  ([Display](#display)) are released until 8 remain.
- On iOS and iPadOS, `UIApplication.didReceiveMemoryWarningNotification` releases every controller that is not
  displayed.
- Releasing a controller: `stopLoading()`, the web view removed from its container, its delegates cleared, its pending
  write-back cancelled. A released tab gets a new web view, loading the stored URL, the next time it is shown.

## Layout

The width class is the `horizontalSizeClass`, as in the other sections.

Regular width (Mac, iPad), top to bottom:

1. Tab strip ([WebTabStrip](#webtabstrip)), 30 pt high on macOS, 36 pt on iPadOS.
2. Navigation row: Back (`chevron.left`), Forward (`chevron.right`), Reload (`arrow.clockwise`) or, while loading,
   Stop (`xmark`), the address field (fills the row), Lock (`lock` when the tab is locked, `lock.open` when it is not;
   toggles), Open in Default Browser (`safari`).
3. A 2 pt accent-colored line showing `estimatedProgress` while loading.
4. The web content (`WebViewHost`), covered by the load error state when there is one ([Load errors](#load-errors)).

Compact width (iPhone, narrow iPad), the screen pushed by the shell:

1. Navigation bar: the address field is its `.principal` item and Reload / Stop its `.topBarTrailing` item.
2. The progress line, then the web content (as in regular width).
3. Bottom toolbar (`.bottomBar`): Back, Forward, Tabs (`square.on.square` with the tab count) →
   [WebTabList](#webtablist), Lock (toggles), More (`ellipsis.circle`): New Tab, Open in Default Browser, Close Tab.

No tab: `EmptyStateView(symbol: "globe", title: "No web tabs")` ([shell.md](shell.md#13-swift-api)) with a "New Tab"
button as its action.

### WebTabStrip

- A horizontal `ScrollView` of tabs followed by a "+" button (`plus`, New Tab); the active tab is scrolled into view
  when it changes.
- Tab: `globe`, the display title (one line, tail truncation), `lock.fill` when locked, and a close button (`xmark`)
  when not locked: shown on macOS while the pointer is over the tab, always on iPadOS. Width from 120 to 220 pt. The
  active tab has the selected background.
- Choosing a tab makes it active and clears `pendingTabID`.
- Context menu: Lock Tab or Unlock Tab, Open in Default Browser, Close Tab.
- Reorder: each tab is `.draggable(tab.id.uuidString)` and a `.dropDestination(for: String.self)`; dropping tab A on tab
  B sends `moveTab` for A with `toIndex` = the index of B.

### WebTabList

A sheet, compact width only, with a `NavigationStack` titled "Tabs":

- A `List` of the tabs: `globe`, the display title, the URL (secondary, one line), `lock.fill` when locked; a checkmark
  on the active tab. Choosing a row makes it active and dismisses the sheet.
- Swipe to delete closes the tab; it is not offered for locked tabs.
- `EditButton` and `.onMove`: moving the tab at index `s` to the offset `d` sends `moveTab` with
  `toIndex = d > s ? d − 1 : d`.
- Toolbar: New Tab (`plus`, which also dismisses the sheet) and Done.

## Address field

`AddressBar`:

- Shows the active web view's URL (`absoluteString`), or the stored URL when the tab has no live web view; empty for
  `about:blank`. Placeholder "Search or enter address".
- `TextField` with `.autocorrectionDisabled()`, `.submitLabel(.go)`, and on iOS `.textInputAutocapitalization(.never)`
  and `.keyboardType(.webSearch)`.
- Return resolves the text with `WebAddress.resolve(_:)` and loads the result in the active tab as a user navigation;
  nil does nothing. Escape, or leaving the field without Return, restores the shown URL.

`WebAddress.resolve(_:)`:

1. `s` = the input without leading and trailing white space and line breaks; empty → nil.
2. `s` contains white space → search.
3. `s` starts with `http://` or `https://` (ignoring case) → `URL(string: s)`; search when that is nil.
4. `s` starts with another scheme followed by `//` (`^[A-Za-z][A-Za-z0-9+.-]*://`) → search.
5. The host is `s` up to the first `/`, `?` or `#`, without a final `:<digits>` port:
   - `localhost`, an IPv4 address (four dot-separated numbers 0–255), or a name ending with `.local` →
     `URL(string: "http://" + s)`;
   - a name made of dot-separated labels, at least two, each non-empty and made of letters, digits and `-`, the last
     label being at least 2 letters → `URL(string: "https://" + s)`;
   - a failed `URL(string:)` → search.
6. Otherwise search.

Search: `URLComponents(string: "https://duckduckgo.com/")` with `queryItems = [URLQueryItem(name: "q", value: s)]`, then
`percentEncodedQuery` with every `+` replaced by `%2B`; the result is `components.url`.

| Input                           | URL                                                    |
|---------------------------------|--------------------------------------------------------|
| `github.com/Azavech/Hephaestus` | `https://github.com/Azavech/Hephaestus`                |
| `HTTPS://Example.com/a`         | `HTTPS://Example.com/a`                                |
| `localhost:8080/api`            | `http://localhost:8080/api`                            |
| `192.0.2.10`                    | `http://192.0.2.10`                                    |
| `Sams-Mac-mini.local:47100`     | `http://Sams-Mac-mini.local:47100`                     |
| `swift observable macro`        | `https://duckduckgo.com/?q=swift%20observable%20macro` |
| `c++`                           | `https://duckduckgo.com/?q=c%2B%2B`                    |
| `ftp://host/file`               | `https://duckduckgo.com/?q=ftp://host/file`            |

## Navigation controls

- Back and Forward call `goBack()` and `goForward()`, enabled from `canGoBack` and `canGoForward`. Reload calls
  `reload()`, Stop `stopLoading()`. All are user navigations.
- Open in Default Browser: the environment's `openURL` with the web view's URL, else the stored URL; disabled for
  `about:blank`.

## Locking and closing

- Lock and the context menu items send the lock change ([Tabs](#tabs)).
- Close (the tab's close button, the context menu, More ▸ Close Tab, swipe to delete, ⌘W through `closeTabAction`) on a
  locked tab sends nothing: `banners.showInfo("This tab is locked")`. A `locked` error from `tabs.close` shows the same
  info banner instead of an error banner.

## Web views

### WebTabController

`WebTabController` (internal, `@MainActor @Observable`, an `NSObject` that is the web view's `WKNavigationDelegate` and
`WKUIDelegate`) owns one `WKWebView` for one tab.

| Setting                                   | Value                                                               |
|-------------------------------------------|---------------------------------------------------------------------|
| `configuration.websiteDataStore`          | `.default()`: this device's persistent data, shared by all projects |
| `allowsBackForwardNavigationGestures`     | `true`                                                              |
| `allowsMagnification`                     | `true` (macOS)                                                      |
| `configuration.allowsInlineMediaPlayback` | `true` (iOS, iPadOS)                                                |

- Key-value observation of `url`, `title`, `canGoBack`, `canGoForward`, `isLoading` and `estimatedProgress` updates the
  controller's observable properties of the same names.
- Creating the controller loads the stored URL with origin `initial`; `about:blank` loads nothing.

| Situation                                                                                                     | Behavior                                                                                                                                                                                                                                                                               |
|---------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| A main-frame navigation to a scheme other than `http`, `https`, `about`, `data`, `blob`                       | cancelled; the URL is opened by the system (`NSWorkspace.shared.open` / `UIApplication.shared.open`)                                                                                                                                                                                   |
| A page opens a new window (`webView(_:createWebViewWith:for:windowFeatures:)`) for an `http` or `https` URL   | returns nil; `openTab` with that URL and title nil; the new tab is shown when listed, as after New Tab ([Tabs](#tabs)); a failure is logged (`Log.ui`) and posted with `AppModel.shared.banners.post(Banner(style: .error, message:))`, or only logged when the Main has no connection |
| A main-frame response the web view cannot show (`canShowMIMEType == false`)                                   | cancelled; the URL is opened with the system's default browser, which downloads it                                                                                                                                                                                                     |
| A file input (macOS, `runOpenPanelWith`)                                                                      | an `NSOpenPanel` with `allowsMultipleSelection` and `canChooseDirectories` from the parameters; the chosen URLs, or nil when cancelled                                                                                                                                                 |
| JavaScript `alert`, `confirm`, `prompt`                                                                       | not handled (WebKit's default without a UI delegate method)                                                                                                                                                                                                                            |

### Display

A web view can be in one view hierarchy at a time, and two windows can show the same tab.

- `WebViewHost` (`NSViewRepresentable` / `UIViewRepresentable`) is a container view that holds the controller's web
  view pinned to its edges. Each host has a token (`@State` UUID).
- When a host appears or its tab changes, it claims the controller: `displayHost = token`, and the web view moves into
  its container. When a host disappears while it holds the web view, `displayHost = nil`.
- A host whose token is not the controller's `displayHost` shows "Shown in another window" and a "Show Here" button
  that claims the controller.
- A tab is displayed while its controller's `displayHost` is not nil.

### Load errors

- `webView(_:didFailProvisionalNavigation:withError:)` and `webView(_:didFail:withError:)` set the controller's
  `loadError` (`WebLoadError`: `message` = the error's `localizedDescription`; `url` = the `URL` under
  `NSURLErrorFailingURLErrorKey` in its `userInfo`, else nil). Two errors set nothing: `NSURLErrorCancelled` (a
  navigation stopped or replaced) and code 102 of the domain `"WebKitErrorDomain"` (frame load interrupted: the
  navigations that the [WebTabController](#webtabcontroller) table cancels or hands to the system).
- `webView(_:didStartProvisionalNavigation:)` sets `loadError` to nil.
- While the active tab's controller has a `loadError`, the web content is covered by
  `EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't open the page", message: <message>)`
  ([shell.md](shell.md#13-swift-api)) on the system background (`.background(.background)`), with a "Reload" button:
  it loads `url` as a user navigation, or calls `reload()` when `url` is nil.

## Sync rules

User navigations and same-document navigations (`pushState`) write the URL and title back to the stored tab
(debounced 1 s, only when the URL differs from the stored URL). A device showing a tab whose stored URL changes from
elsewhere navigates to it unless its current URL already equals it. Navigations that apply a remote update, and those a
page starts by itself, are never written back.

### Navigation origins

| Origin    | Main-frame navigations                                                                                                                                                                                                                                                         |
|-----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `initial` | the first load of a new controller                                                                                                                                                                                                                                             |
| `remote`  | a load caused by a change of the stored URL made elsewhere                                                                                                                                                                                                                     |
| `user`    | an address typed in the field and the Reload of a load error (loads by the controller); the navigation types `linkActivated` (link click), `formSubmitted`, `formResubmitted`, `backForward` (the Back and Forward controls, swipe gestures) and `reload` (the Reload control) |
| `page`    | any other: the navigation type `other` without a load by the controller (script and `<meta>` refresh redirects, `location` changes)                                                                                                                                            |

- The controller sets `pendingOrigin` (`initial`, `remote` or `user`) right before each `load(_:)` it calls.
- `webView(_:decidePolicyFor:decisionHandler:)`, for a navigation action whose `targetFrame` is the main frame, takes
  the origin `pendingOrigin` when it is set (and clears it), else `user` for the navigation types of the table, else
  `page`. When it allows the action, it keeps that origin in `actionOrigin`;
  `webView(_:didStartProvisionalNavigation:)` records `actionOrigin` for that `WKNavigation`.
- Redirects keep the origin of their navigation. A navigation ends at `didFinish`, `didFail` or
  `didFailProvisionalNavigation`.
- Quiet period: changes of the web view's URL during an `initial` or `remote` navigation, and within 2 s after it
  ends, are never written back. A same-document `initial` or `remote` navigation, which starts no provisional
  navigation, ends at its change of the web view's URL.

### Write-back

- Triggers, outside the quiet period: `didCommit` and `didFinish` of a `user` navigation, and a change of the web
  view's `url` while its `isLoading` is false (same-document navigations: `pushState`, `replaceState`, anchors).
  `initial`, `remote` and `page` navigations trigger nothing.
- Each trigger restarts a 1 s timer. When it fires, `url` = the web view's URL (`absoluteString`). Nothing is sent when
  `url` is not an absolute `http` or `https` URL with a host (empty, `about:blank`, `data:`, `blob:`, `file:`…, which
  `tabs.update` refuses, [../protocol/methods.md](../protocol/methods.md#web-tabs)), when it equals the stored URL, or
  when the Main is not connected. Otherwise the request is
  `updateTab` with `WebTabPatch(url: url, title: <the web view's title, "" when nil>)`, and `lastWrittenURL` takes
  `url`. The Main replaces an empty title with the URL's host
  ([../protocol/methods.md](../protocol/methods.md#tabsupdate)).
- A title is never written alone: a change of the title triggers nothing.
- A failed write-back is logged (`Log.ui`) and not shown.

### Remote updates

`storedURLChanged(_ url: String)`:

1. `url == lastWrittenURL`: nothing (the echo of this device's own write). Otherwise `lastWrittenURL` is cleared: an
   older write of this device no longer counts as an echo.
2. The tab is displayed and the web view's URL (`absoluteString`) differs from `url`: `load(URLRequest(url:))` with
   origin `remote`.
3. The tab is not displayed: the change is remembered; when the tab becomes displayed, step 2 runs.

## Navigation and selection

- While the Web section is shown, `selection.item` is the active tab's id as a UUID string (`uuidString`,
  [../client/workspace.md](../client/workspace.md#selection)).
- When the view appears, and whenever the item changes while it is shown: an item naming a listed tab makes it active;
  an item naming a tab not listed yet (just opened from the Docs section, a task or a message) becomes `pendingTabID`.
- When `activeTabID` changes, `selection.item` is set to it (nil when there is no tab).
- Search results of kind `webTabs` ([search.md](search.md)) arrive through the item.

`WebTabsView` ends its file with a `#Preview` ([shell.md](shell.md#54-previews)).

## Depends on

- [../client/workspace.md](../client/workspace.md): `Workspace` (`connection(_:)`), `ProjectStore` (`project`,
  `connection`, `mainDeviceID`), `MainConnection` (`openTab`, `updateTab`, `closeTab`, `moveTab`), `Selection`.
- [../protocol/types.md](../protocol/types.md): `WebTab`, `WebTabPatch`.
  [../protocol/methods.md](../protocol/methods.md): `tabs.*`. [../protocol/events.md](../protocol/events.md):
  `project.changed`.
- [shell.md](shell.md): `WindowBanners`, `EmptyStateView`, the focused values `newWebTabAction` and `closeTabAction`.
