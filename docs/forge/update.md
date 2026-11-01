# Self-update (macOS)

files:
- HephaestusKit/Sources/HephHost/Update/UpdateService.swift
- HephaestusKit/Sources/HephHost/Update/UpdateModel.swift
- HephaestusKit/Sources/HephHost/Update/UpdateInstaller.swift
- HephaestusKit/Sources/HephHost/Update/CodeSigning.swift

---

Every Mac running Hephaestus, Main or not, installs the newest release `build-<N>` published by CI ([ci.md](ci.md))
and restarts itself: on its own, or, while `updates.enabled` is false, when the user chooses Install. iOS and iPadOS
never update themselves. Every file of this doc is macOS only and wrapped in `#if os(macOS)`. Logging uses `Log.host`
([../architecture.md](../architecture.md#logging)).

## Settings

Read from `settings.json` when used (`JSONFile.read(DeviceSettings.self, from: AppSupport.standard().settingsFile)`,
`DeviceSettings()` when missing, [../data/app-storage.md](../data/app-storage.md)); edited in Settings ▸ Forge &
Updates ([../ui/settings.md](../ui/settings.md)):

| Key                       | Used for                                                                                                                                                                                                                                                                                                     |
|---------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `updates.enabled`         | `true` (default), "Update automatically": a check that finds a newer build downloads, verifies and re-signs it, then Installing follows; `false`: a check only records the latest build (Check step 5), and the update status view offers Install (`install()`); an update already `ready` installs as usual |
| `updates.signingIdentity` | `""` (default): automatic identity (Re-signing); `-`: keep the ad-hoc signature of the release; any other value: the identity given to `codesign --sign` (a SHA-1 or a certificate name)                                                                                                                     |

The GitHub repository whose releases are checked is not a setting: it is the constant `ForgeConfig.publicRepository`,
`Azavech/Hephaestus` ([../protocol/types.md](../protocol/types.md#forgeconfig)).

## Values

- Current build: `CFBundleVersion` of the running app as an integer (`0` when it is not one). Local builds are `0`
  ([ci.md](ci.md#scriptsbuildsh)), CI builds carry the run number.
- Installed app: `Bundle.main.bundleURL` with symlinks resolved.
- **Can install**: the installed app's parent folder is `/Applications` or `<home>/Applications`. Copies run from
  elsewhere (Xcode's derived data, `build/`, a translocated download) never update themselves; they still check and
  show the available build.
- Updates folder: `AppSupport.standard().updatesFolder` (`~/Library/Application Support/Hephaestus/Updates/`), created
  when needed.

## Schedule

- At `start()`: the steps of After a restart, then the first check 10 s later.
- Every 15 minutes, counted from the end of the previous check.
- At once when `releaseNoticed(build:)` gets a build greater than the current build and greater than the latest build
  of the last check. The shell calls it from `workspace.forge.releaseObserver` for every `ForgeState` received with a
  `latestRelease` ([../ui/forge.md](../ui/forge.md#inputs)), so a `forge.changed` announcing a release (cycle
  `released`, [pipeline.md](pipeline.md#completion)) starts a check on every Mac.
- `checkNow()` (Check Now in the update status view).
- `install()` (Install in the update status view, offered while `updates.enabled` is false): when the status is
  `idle`, a check at once that does not stop at step 5 for `updates.enabled`; a newer build then goes through steps 6
  and 7 and Installing as an automatic update does.
- No check starts while the status is `checking`, `downloading` or `installing`. While rate limited, checks are skipped
  until the reset time.

## Check

1. Status `checking`, except while `ready`: a `ready` status stays during the check.
2. `GitHubClient(repository: ForgeConfig.publicRepository, token: await GitHubClient.readToken())`
   ([pipeline.md](pipeline.md#swift-api)), `latestRelease()` (`GET /repos/Azavech/Hephaestus/releases/latest`).
3. Fields used: `tag_name`, `html_url`, `published_at`, `assets[].name`, `assets[].browser_download_url`,
   `assets[].size`.
4. `latestBuild` = `N` when `tag_name` is `build-<N>` (`N` decimal), else nil; `latestReleaseURL` = `html_url`;
   `lastChecked` = now.
5. When the status is `ready(build: M)` and there is no release, the tag does not match, or `M` ≥ `N`, nothing more
   happens: the ready update stays. Otherwise the status becomes `idle` and the check ends when there is no release,
   the tag does not match, `N` ≤ the current build, the app cannot install, or `updates.enabled` is false and the check
   was not started by `install()`.
6. The asset named `Hephaestus-macOS.zip` must exist, else `failed` `Release build-<N> has no Hephaestus-macOS.zip.`.
7. Download and unpack, verification, re-signing, then `ready`.

A failed request gives `failed` `Could not check for updates: <error message>` (a `ready` status stays `ready`); the
next check runs as scheduled.

## Download and unpack

1. Status `downloading(build: N)`. Every `Updates/build-*` folder is deleted (a `ready` update of an older build is
   discarded).
2. `URLSession` downloads `browser_download_url` (no `Authorization` header; request timeout 60 s, resource timeout
   10 minutes) and the file is moved to `Updates/build-<N>/Hephaestus-macOS.zip`. A download that fails deletes
   `Updates/build-<N>` and sets `failed` `The download of build <N> failed: <reason>.`: `<reason>` is `HTTP <status>`
   for a status other than 2xx, `Invalid download URL` when `browser_download_url` is not a URL, else the error's
   `localizedDescription` (a request error, a file that cannot be moved) without its final period. The file's size
   must equal the asset's `size`: a file whose size differs deletes `Updates/build-<N>` and sets `failed`
   `The download of build <N> is incomplete.`.
3. `/usr/bin/ditto -x -k Updates/build-<N>/Hephaestus-macOS.zip Updates/build-<N>` (timeout 120 s), then the zip is
   deleted. The app is `Updates/build-<N>/Hephaestus.app`. The exit status of `ditto` is not checked: an archive it
   could not unpack fails Verification.

## Verification

| Check                                                                                             | Failure message                                               |
|---------------------------------------------------------------------------------------------------|---------------------------------------------------------------|
| `Updates/build-<N>/Hephaestus.app` is a folder                                                    | `The update archive does not contain Hephaestus.app.`         |
| its `Contents/Info.plist` `CFBundleIdentifier` equals the running app's (`ca.azavech.hephaestus`) | `The update has the bundle identifier <id>.`                  |
| its `CFBundleVersion` is `N`                                                                      | `The update is build <value>, not <N>.`                       |
| `/usr/bin/codesign --verify --deep --strict <app>` exits 0 (timeout 120 s)                        | `The signature of build <N> is not valid: <last stderr line>` |

A failure deletes `Updates/build-<N>` and sets `failed` with the message.

## Re-signing

Releases are ad-hoc signed by CI. Signing every installed build with the same identity keeps macOS privacy
permissions and Keychain access across updates.

- The mesh credentials item ([../data/app-storage.md](../data/app-storage.md#keychain)) can be read without a prompt
  only by a build whose signature matches the build that created it, or by a build allowed with "Always Allow". The
  first re-signed build after an ad-hoc one (such as the release installed by hand as the README says) and, when no
  identity is used, every update (each ad-hoc build has a new signature) make macOS ask for the login keychain
  password at each Keychain call on the `ca.azavech.hephaestus.mesh` item, from their first launch until the user
  answers "Always Allow". The credential store keeps the item's value once it has read it
  ([../data/app-storage.md](../data/app-storage.md#value-in-memory)), so a launch asks at most once; after "Deny"
  the read fails, and the next read asks again. Until the prompt is answered the Keychain call waits: the Mac does not
  connect to the mesh and, as a Main, does not serve its devices.
- The first re-signing with an identity (for example the user's Apple Development identity) may show a macOS Keychain
  prompt asking to let `codesign` use the identity's key; "Always Allow" stops it from appearing again. A prompt left
  unanswered ends with the 120 s timeout of step 2 and the failure of step 3.

Steps:

1. Identity: `updates.signingIdentity` when not empty. When empty: the first identity of `signingIdentities()`. No
   identity, or the setting `-`: no re-signing (the ad-hoc signature stays).
   - `signingIdentities()` runs `/usr/bin/security find-identity -v -p codesigning` (timeout 30 s), whose lines look
     like `  1) <40 hex> "Apple Development: Jane Appleseed (ABCDE12345)"`, and returns, in output order, a
     `SigningIdentity {sha1, name}` for each line whose quoted name starts with `Apple Development:` or
     `Developer ID Application:`; a failing command gives an empty list. The Settings picker lists them by `name` and
     stores `sha1` in `updates.signingIdentity` ([../ui/settings.md](../ui/settings.md)).
2. `/usr/bin/codesign --force --deep --preserve-metadata=entitlements,flags,runtime --sign <identity> <app>`
   (timeout 120 s), then `/usr/bin/codesign --verify --deep --strict <app>`.
3. A failure deletes `Updates/build-<N>` and sets `failed` `Re-signing build <N> with <identity> failed: <last stderr
   line>`.
4. Status `ready(build: N)`; then Installing.

Commands run with `ChildProcess.capture` ([../claude/cli.md](../claude/cli.md)), the login environment
(`LoginEnvironment.shared.environment()`), working directory the Updates folder.

## Installing

### When

- **Busy**: `isBusy()` returns true. The shell wires it to `await host.hasActiveWork()` while this Mac is a Main (a
  Claude session of this Main is `starting`, `running` or `waitingPermission`, or a project move runs;
  [../services/host.md](../services/host.md#125-hasactivework)) and to `false` otherwise
  ([../ui/shell.md](../ui/shell.md)).
- On entering `ready`, and every 10 s while `ready`: when not busy, install.
- `restartNow()` (Restart Now) installs at once, busy or not; quitting stops sessions as any quit does.

### Steps

1. Status `installing(build: N)`.
2. The installed app's parent folder must be writable (`FileManager.isWritableFile(atPath:)`), else `failed`
   `Cannot replace <path>: the folder is not writable.`.
3. Write `Updates/install-update.sh` (content below) and `Updates/pending.json` = `{"build": <N>}`.
4. Run, with `ChildProcess.capture` (timeout 10 s; it returns as soon as the script is in the background):

   ```text
   /bin/sh -c 'nohup /bin/sh "$0" "$@" >/dev/null 2>&1 &' <Updates>/install-update.sh <pid> <installed app> <Updates>/build-<N>/Hephaestus.app <Updates>/previous/Hephaestus.app <Updates>/install.log
   ```

   `<pid>` is the app's process id; paths are absolute.
5. On the main actor, `NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)`: a timer of
   the main run loop calls `terminate` once the current main-actor job has returned. Called inside that job,
   `terminate` waits for the shell's reply in a nested event loop that never returns, because the main-actor task that
   sends the reply never starts. The shell's termination handling stops the host first
   ([../ui/shell.md](../ui/shell.md#21-hephaestusappdelegate-macos)).

The script waits for the app to exit, moves the installed app to `Updates/previous/`, moves the new app into its
place (restoring the old one when that fails) and opens the result with `open`.

### install-update.sh

Exact content:

```sh
#!/bin/sh
# Installs a downloaded Hephaestus update once the running app has quit. Written by UpdateService.
# Arguments: <app pid> <installed app> <new app> <previous app> <log file>
pid="$1"
target="$2"
new="$3"
previous="$4"
log="$5"
exec >>"$log" 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') waiting for $pid to quit"
while kill -0 "$pid" 2>/dev/null; do
  sleep 0.5
done
rm -rf "$previous"
mkdir -p "$(dirname "$previous")"
if mv "$target" "$previous"; then
  if mv "$new" "$target"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') installed $target"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') could not move $new; restoring the previous app"
    mv "$previous" "$target"
  fi
else
  echo "$(date '+%Y-%m-%d %H:%M:%S') could not move $target aside"
fi
open "$target"
```

## After a restart

Run by `start()` before anything else:

1. When `Updates/previous/Hephaestus.app` exists, it is moved to the Trash with
   `FileManager.trashItem(at:resultingItemURL:)`; a failure is logged.
2. When `Updates/pending.json` exists: when its `build` differs from the current build, the status is `failed`
   `The update to build <N> was not installed. See ~/Library/Application Support/Hephaestus/Updates/install.log.`.
   The file is deleted.
3. Every `Updates/build-*` folder is deleted.

## Statuses

Shown by `UpdateStatusView` in the Forge screen and in Settings ▸ Forge & Updates
([../ui/forge.md](../ui/forge.md#updatestatusview)):

| Status                | Text                                                                                                                                                                                                                                                                                                                     | Action                                                                                                                |
|-----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| `idle`                | `Build <current>.` then `Up to date.`, or `Build <N> is available.` (latest build > current); when the app cannot install and a newer build exists: `Hephaestus updates itself only when it runs from /Applications or ~/Applications. This copy runs from <folder>.`; then `Last checked <relative date>.` when checked | Check Now; Install (`install()`) when `updates.enabled` is false, `canInstall` is true and the latest build > current |
| `checking`            | `Checking for updates…` with a spinner                                                                                                                                                                                                                                                                                   | —                                                                                                                     |
| `downloading(build:)` | `Downloading build <N>…` with a spinner                                                                                                                                                                                                                                                                                  | —                                                                                                                     |
| `ready(build:)`       | `Update ready — restarting when idle` and `Build <N> is installed when no Claude session or move is active.`                                                                                                                                                                                                             | Restart Now                                                                                                           |
| `installing(build:)`  | `Installing build <N>. Hephaestus restarts.`                                                                                                                                                                                                                                                                             | —                                                                                                                     |
| `failed(message:)`    | the message, in red                                                                                                                                                                                                                                                                                                      | Check Now                                                                                                             |

## iOS and iPadOS

No `UpdateService`. The Forge screen shows `Build <N> is available` when the Forge's `latestRelease.build` is greater
than the app's build ([../ui/forge.md](../ui/forge.md#updatestatusview)). Builds are installed on devices from Xcode.

## Swift API

```swift
// HephHost/Update — macOS only.

public enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case downloading(build: Int)
    case ready(build: Int)
    case installing(build: Int)
    case failed(message: String)
}

/// What UpdateStatusView shows; the shell puts it in the environment. Changed only by UpdateService.
@MainActor @Observable public final class UpdateModel {
    public init()
    public internal(set) var status: UpdateStatus           // .idle
    public internal(set) var currentBuild: Int
    public internal(set) var latestBuild: Int?
    public internal(set) var latestReleaseURL: String?
    public internal(set) var lastChecked: Date?
    public internal(set) var canInstall: Bool
    public internal(set) var installedAppPath: String
    /// Forward to the attached UpdateService.
    public func checkNow()
    public func install()
    public func restartNow()
}

public actor UpdateService {
    /// Attaches itself to `model`. `isBusy` is the busy condition of Installing.
    public init(model: UpdateModel, isBusy: @escaping @Sendable () async -> Bool)
    /// After-restart steps, first check in 10 s, 15-minute schedule. Called once by the shell at launch.
    public func start()
    public func checkNow()
    /// Install (Schedule): a check that does not stop at step 5 for updates.enabled.
    public func install()
    public func restartNow()
    /// A release build seen in a ForgeState (ForgeModel.releaseObserver, ../ui/forge.md).
    public func releaseNoticed(build: Int)
    /// The code signing identities offered in Settings (Re-signing).
    public func signingIdentities() async -> [SigningIdentity]
    /// Cancels the schedule (app termination).
    public func stop()
}

public struct SigningIdentity: Sendable, Hashable, Identifiable {
    public let sha1: String                                 // 40 uppercase hex characters
    public let name: String                                 // "Apple Development: Jane Appleseed (ABCDE12345)"
    public var id: String { sha1 }
}

/// The security and codesign calls of Re-signing and Verification.
public enum CodeSigning {
    public static func identities() async -> [SigningIdentity]
    public static func verify(_ app: URL) async throws
    public static func sign(_ app: URL, identity: String) async throws
}

/// The script, pending.json and the after-restart steps.
public enum UpdateInstaller {
    public static let script: String                        // install-update.sh, exact content above
    /// Installing steps 2 to 4; step 5 (terminate) is UpdateService's.
    public static func install(newApp: URL, build: Int, updatesFolder: URL) async throws
    /// The steps of After a restart; returns the failure message of step 2, if any.
    public static func afterRestart(currentBuild: Int, updatesFolder: URL) -> String?
}
```

## Depends on

| Name                                                                                                                    | Defined in                                               |
|-------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------|
| `GitHubClient`                                                                                                          | [pipeline.md](pipeline.md#swift-api)                     |
| `ForgeConfig.publicRepository`                                                                                          | [../protocol/types.md](../protocol/types.md#forgeconfig) |
| `ChildProcess`, `LoginEnvironment`                                                                                      | [../claude/cli.md](../claude/cli.md)                     |
| `HostService.hasActiveWork()`                                                                                           | [../services/host.md](../services/host.md)               |
| `AppSupport`, `JSONFile`, `DeviceSettings` (`updates`), the mesh credentials Keychain item                              | [../data/app-storage.md](../data/app-storage.md)         |
| `AppModel.updateModel`, `AppModel.updater`, `isBusy` wiring, `releaseObserver` wiring, `start()` at launch, termination | [../ui/shell.md](../ui/shell.md)                         |
| the "Update automatically" toggle, the signing identity picker, `UpdateStatusView` in Settings ▸ Forge & Updates        | [../ui/settings.md](../ui/settings.md)                   |
| `ForgeModel.releaseObserver`                                                                                            | [../ui/forge.md](../ui/forge.md)                         |
| `Log.host`                                                                                                              | [../architecture.md](../architecture.md#logging)         |
