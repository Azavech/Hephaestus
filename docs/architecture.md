# Architecture

files:
- HephaestusKit/Package.swift
- HephaestusKit/Package.resolved
- Hephaestus.xcodeproj/project.pbxproj
- Hephaestus.xcodeproj/project.xcworkspace/contents.xcworkspacedata
- Hephaestus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
- Hephaestus.xcodeproj/xcshareddata/xcschemes/Hephaestus.xcscheme
- Hephaestus.xcodeproj/xcshareddata/IDETemplateMacros.plist
- Config/Signing.xcconfig
- App/Info.plist
- App/Assets.xcassets/Contents.json
- App/Assets.xcassets/AccentColor.colorset/Contents.json
- App/Assets.xcassets/AppIcon.appiconset/Contents.json
- App/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png
- App/Assets.xcassets/AppIcon.appiconset/icon-mac-16@1x.png
- App/Assets.xcassets/AppIcon.appiconset/icon-mac-16@2x.png
- App/Assets.xcassets/AppIcon.appiconset/icon-mac-32@1x.png
- App/Assets.xcassets/AppIcon.appiconset/icon-mac-32@2x.png
- App/Assets.xcassets/AppIcon.appiconset/icon-mac-128@1x.png
- App/Assets.xcassets/AppIcon.appiconset/icon-mac-128@2x.png
- App/Assets.xcassets/AppIcon.appiconset/icon-mac-256@1x.png
- App/Assets.xcassets/AppIcon.appiconset/icon-mac-256@2x.png
- App/Assets.xcassets/AppIcon.appiconset/icon-mac-512@1x.png
- App/Assets.xcassets/AppIcon.appiconset/icon-mac-512@2x.png
- README.md
- .gitignore
- HephaestusKit/Sources/HephCore/Util/Log.swift

---

## Repository layout

```
Hephaestus/
  README.md                     what the app is, how to build and install, pointer to docs/   (this doc)
  CLAUDE.md                     rules for Claude working in this repository                    (forge/generation.md)
  .gitignore                                                                                   (this doc)
  .githooks/                    pre-commit, commit-msg, pre-push: the personal data check      (public-repository.md)
  .github/workflows/ci.yml      CI: personal data and docs-sync checks, tests, builds, release (forge/ci.md)
  docs/                         the specification
  scripts/check-public.sh       the personal data check                                        (public-repository.md)
  scripts/docs-hash.sh          prints the docs hash                                           (forge/generation.md)
  scripts/build.sh              builds: macos | macos-release | ios | all                     (forge/ci.md)
  scripts/test.sh               runs the package tests                                         (forge/ci.md)
  scripts/package-macos.sh      zips the built app for a release                               (forge/ci.md)
  Hephaestus.xcodeproj/         hand-maintained, objectVersion 77                              (this doc)
  Config/                       signing settings of the app target
    Signing.xcconfig            committed; includes Signing.local.xcconfig when it exists      (this doc)
    Signing.local.xcconfig      the user's DEVELOPMENT_TEAM; ignored by git, never committed   (this doc)
  App/                          app target, a file-system-synchronized folder
    HephaestusApp.swift         @main entry point                                              (ui/shell.md)
    Info.plist                  partial Info.plist                                             (this doc)
    Assets.xcassets             app icon and accent color                                      (this doc)
    DocsHash.txt                docs hash the code was generated from                          (forge/generation.md)
  HephaestusKit/                local Swift package: all the code except the entry point
    Package.swift
    Package.resolved
    Sources/HephCore/           models, YAML files, identifiers, wire protocol types, hashing, logging
    Sources/HephNet/            mesh crypto, TLS-PSK WebSocket transport, Bonjour, pairing, RPC peer, loopback
    Sources/HephHost/           macOS-only services: the Main side and the updater
    Sources/HephClient/         client state mirrored from the Mains
    Sources/HephEditor/         code editor view and syntax highlighting
    Sources/HephMarkdown/       Markdown rendering view
    Sources/HephUI/             all SwiftUI screens and the app wiring
    Tests/                      test targets                                                   (testing.md)
```

The repository folder is registered once, by the user, as the project `HEPH` on the Forge host. The app keeps the
project's data in its `.hephaestus/` folder, which git ignores and which is never committed
([general.md](general.md#where-personal-data-lives-instead)).

Every Swift source file lives in the folder of its module. File names are UpperCamelCase and name the main type they
hold. Which doc governs each file is given by the `files:` lists of the docs ([README.md](README.md)).

## Modules

| Module                  | Platforms           | Depends on                                                                    | Responsibility                                                                                                                                                                                          |
|-------------------------|---------------------|-------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `HephCore`              | all                 | Yams                                                                          | Models and YAML files, identifiers and validation, skill names and SKILL.md front matter, wire protocol types (envelope, methods, events, errors), hashing, search matcher, `Log`                       |
| `HephNet`               | all                 | `HephCore`                                                                    | Mesh crypto, TLS-PSK WebSocket channel and listener, Bonjour advertising and browsing, pairing, `RPCPeer`, `MessageChannel`, `LoopbackChannel`                                                          |
| `HephHost`              | macOS; empty on iOS | `HephCore`, `HephNet`                                                         | The Main side: `HostService` (listener, routing, projects, tasks, files, tabs, file watching, peer links), Claude CLI sessions, MCP server, runs, search, skills library, migration, Forge, self-update |
| `HephClient`            | all                 | `HephCore`, `HephNet`                                                         | Client state mirrored from the Mains: `Workspace`, `MainConnection`, `ProjectStore`, `Selection`, device identity, session, run output, Forge, file and search models                                   |
| `HephEditor`            | all                 | `HephCore`                                                                    | Code editor view (TextKit 1) and syntax highlighting                                                                                                                                                    |
| `HephMarkdown`          | all                 | `HephCore`, `HephEditor`, swift-markdown (`Markdown`)                         | Markdown rendering view; fenced code uses the highlighter of `HephEditor`                                                                                                                               |
| `HephUI`                | all                 | `HephCore`, `HephNet`, `HephHost`, `HephClient`, `HephEditor`, `HephMarkdown` | All SwiftUI screens and the app wiring (`AppModel`, `RootView`, [ui/shell.md](ui/shell.md))                                                                                                             |
| App target `Hephaestus` | macOS, iPadOS, iOS  | `HephUI`, `HephHost`                                                          | The `@main` entry point `App/HephaestusApp.swift` ([ui/shell.md](ui/shell.md))                                                                                                                          |

Rules:

- A module imports only the modules of its row. `HephClient` never imports `HephHost`; `HephHost` never imports
  `HephClient` or `HephUI`. On a Main, every request and event between the UI and the host goes through the protocol
  over a `LoopbackChannel` (see [Process model](#process-model)). Only the app wiring (`AppModel`,
  [ui/shell.md](ui/shell.md)) calls `HostService` directly, for its lifecycle and state: `makeShared`, `shared`, `init`
  (previews), `start`, `stop`, `restartListener`, `makeLoopbackChannel`, `listenerError`, `projectsFileWasReset`,
  `hasActiveWork`, `mesh.resignMain`, `migration.isActive`, `forge.privateTermsCount`, `forge.preparePrivateTerms`,
  `forge.privateTermSuggestions`, `forge.addPrivateTerm` and `forge.dismissPrivateTerm`
  ([devices/roles.md](devices/roles.md), [forge/update.md](forge/update.md),
  [forge/pipeline.md](forge/pipeline.md#private-terms)).
- `HephHost` holds macOS-only code. The whole content of every file of `HephHost`, imports included, is wrapped in
  `#if os(macOS)` … `#endif`; on iOS the module compiles to an empty module. Code of other modules that uses
  `HephHost` wraps the `import HephHost` and the uses in `#if os(macOS)`.
- Platform-specific code elsewhere uses `#if os(macOS)` and `#if os(iOS)` (iPadOS is `os(iOS)`).
- The App target imports only SwiftUI and `HephUI`, plus `HephHost` inside `#if os(macOS)` when the entry point needs
  it; everything the entry point needs is public API of `HephUI` ([ui/shell.md](ui/shell.md)).

## HephaestusKit/Package.swift

Exact content:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HephaestusKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "HephUI", targets: ["HephUI"]),
        .library(name: "HephHost", targets: ["HephHost"]),
        .library(name: "HephCore", targets: ["HephCore"]),
        .library(name: "HephNet", targets: ["HephNet"]),
        .library(name: "HephClient", targets: ["HephClient"]),
        .library(name: "HephEditor", targets: ["HephEditor"]),
        .library(name: "HephMarkdown", targets: ["HephMarkdown"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "HephCore",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .target(name: "HephNet", dependencies: ["HephCore"]),
        .target(name: "HephHost", dependencies: ["HephCore", "HephNet"]),
        .target(name: "HephClient", dependencies: ["HephCore", "HephNet"]),
        .target(name: "HephEditor", dependencies: ["HephCore"]),
        .target(
            name: "HephMarkdown",
            dependencies: ["HephCore", "HephEditor", .product(name: "Markdown", package: "swift-markdown")]
        ),
        .target(
            name: "HephUI",
            dependencies: ["HephCore", "HephNet", "HephHost", "HephClient", "HephEditor", "HephMarkdown"]
        ),
        .testTarget(name: "HephCoreTests", dependencies: ["HephCore"]),
        .testTarget(name: "HephNetTests", dependencies: ["HephNet", "HephCore"]),
        .testTarget(
            name: "HephHostTests",
            dependencies: ["HephHost", "HephClient", "HephNet", "HephCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "HephEditorTests", dependencies: ["HephEditor", "HephCore"]),
        .testTarget(name: "HephClientTests", dependencies: ["HephClient", "HephNet", "HephCore"]),
        .testTarget(name: "HephUISnapshotTests", dependencies: ["HephUI", "HephHost", "HephClient", "HephCore"]),
    ],
    swiftLanguageModes: [.v5]
)
```

`HephaestusKit/Package.resolved` is produced by SwiftPM resolution and committed; it pins the versions CI builds with
(verified: Yams 5.4.0, swift-markdown 0.9.0 with swift-cmark 0.9.0). Its content is that of the workspace
`Package.resolved` ([below](#hephaestusxcodeprojprojectxcworkspace)) with another `originHash`: SwiftPM writes the
SHA-256 of the bytes of `Package.swift`, `28a9b07b1cd6ac5d328cf9bfb8762cd667e2b4f683b9758e5b6ec0d6b83c0533` for the
content above. SwiftPM does not rewrite an `originHash` that no longer matches while the pins still satisfy
`Package.swift`, so a change of `Package.swift` also changes this value (`shasum -a 256 HephaestusKit/Package.swift`).
A change of the dependencies of `Package.swift` changes the pins; then
`swift package resolve --package-path HephaestusKit` rewrites them.

## Xcode project

`Hephaestus.xcodeproj` is written by hand (objectVersion 77) and contains:

- One native application target `Hephaestus`, multiplatform: macOS, iOS and iPadOS from the same target.
- A file-system-synchronized root group for `App/`: every file added to `App/` joins the target without editing the
  project file (Swift files are compiled, other files are bundle resources, so `App/DocsHash.txt` is bundled). An
  exception set removes `Info.plist` from the target's membership, because it is the `INFOPLIST_FILE`.
- A group `Config` with the file reference `Config/Signing.xcconfig`, the base configuration of the target's Debug and
  Release configurations. It is in no build phase and outside `App/`, so it is not part of the app. The project file
  has no `DEVELOPMENT_TEAM` ([Config/Signing.xcconfig](#configsigningxcconfig)).
- A local package reference to `HephaestusKit` (`relativePath = HephaestusKit`) and the package products `HephUI` and
  `HephHost` linked into the target, with no platform filter (on iOS `HephHost` is the empty module).
- The shared scheme `Hephaestus`.

Target build settings (identical in Debug and Release unless noted):

| Setting                                                  | Value                                                                  | Note                                                           |
|----------------------------------------------------------|------------------------------------------------------------------------|----------------------------------------------------------------|
| `SUPPORTED_PLATFORMS`                                    | `macosx iphoneos iphonesimulator`                                      | one target for every platform                                  |
| `SDKROOT`                                                | `auto`                                                                 |                                                                |
| `TARGETED_DEVICE_FAMILY`                                 | `1,2`                                                                  | iPhone and iPad                                                |
| `SUPPORTS_MACCATALYST`                                   | `NO`                                                                   | the Mac build is a native macOS build                          |
| `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD`                  | `NO`                                                                   |                                                                |
| `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD`                   | `NO`                                                                   |                                                                |
| `MACOSX_DEPLOYMENT_TARGET`                               | `15.0`                                                                 | project level                                                  |
| `IPHONEOS_DEPLOYMENT_TARGET`                             | `18.0`                                                                 | project level                                                  |
| `SWIFT_VERSION`                                          | `5.0`                                                                  | Swift language mode 5, project level                           |
| `PRODUCT_NAME`                                           | `Hephaestus`                                                           |                                                                |
| `PRODUCT_BUNDLE_IDENTIFIER`                              | `ca.azavech.hephaestus`                                                |                                                                |
| `DEVELOPMENT_TEAM`                                       | none in the project file; set by `Config/Signing.local.xcconfig`       | the user's team, only on the user's Macs (file ignored by git) |
| `CODE_SIGN_STYLE`                                        | `Automatic`                                                            | CI overrides signing on the command line (forge/ci.md)         |
| `MARKETING_VERSION`                                      | `1.0`                                                                  |                                                                |
| `CURRENT_PROJECT_VERSION`                                | `0`                                                                    | build number; CI passes `CURRENT_PROJECT_VERSION=<run number>` |
| `ENABLE_APP_SANDBOX`                                     | `NO`                                                                   | a Main runs `claude`, `git`, `gh` and the user's toolchains    |
| `ENABLE_HARDENED_RUNTIME`                                | `NO`                                                                   |                                                                |
| `GENERATE_INFOPLIST_FILE`                                | `YES`                                                                  | merged with `INFOPLIST_FILE`                                   |
| `INFOPLIST_FILE`                                         | `App/Info.plist`                                                       |                                                                |
| `INFOPLIST_KEY_CFBundleDisplayName`                      | `Hephaestus`                                                           |                                                                |
| `INFOPLIST_KEY_LSApplicationCategoryType`                | `public.app-category.developer-tools`                                  |                                                                |
| `INFOPLIST_KEY_UIApplicationSceneManifest_Generation`    | `YES` (iphoneos, iphonesimulator SDKs)                                 | generates multiple-scene support on iPad                       |
| `INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents` | `YES` (iphoneos, iphonesimulator SDKs)                                 |                                                                |
| `INFOPLIST_KEY_UILaunchScreen_Generation`                | `YES` (iphoneos, iphonesimulator SDKs)                                 |                                                                |
| `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad`    | all four orientations                                                  |                                                                |
| `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`  | portrait, landscape left, landscape right                              |                                                                |
| `INFOPLIST_KEY_UIRequiresFullScreen`                     | `NO`                                                                   | iPad multitasking and several windows                          |
| `ASSETCATALOG_COMPILER_APPICON_NAME`                     | `AppIcon`                                                              |                                                                |
| `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`         | `AccentColor`                                                          |                                                                |
| `LD_RUNPATH_SEARCH_PATHS`                                | `@executable_path/Frameworks`; macOS: `@executable_path/../Frameworks` |                                                                |

There is no entitlements file. Verified with Xcode 27.1 and no `Config/Signing.local.xcconfig`: the project builds for
`generic/platform=macOS` and `generic/platform=iOS` with the signing settings of `scripts/build.sh` and with
`CODE_SIGNING_ALLOWED=NO`, without warnings, and `xcodebuild -showBuildSettings` has no `DEVELOPMENT_TEAM`; with a
local file it has the file's team.

### Hephaestus.xcodeproj/project.pbxproj

Exact content (object identifiers are fixed; tabs are significant):

```
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXBuildFile section */
		E10000000000000000000051 /* HephUI in Frameworks */ = {isa = PBXBuildFile; productRef = E10000000000000000000061 /* HephUI */; };
		E10000000000000000000052 /* HephHost in Frameworks */ = {isa = PBXBuildFile; productRef = E10000000000000000000062 /* HephHost */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		E10000000000000000000020 /* Hephaestus.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Hephaestus.app; sourceTree = BUILT_PRODUCTS_DIR; };
		E10000000000000000000021 /* Signing.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Signing.xcconfig; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
		E10000000000000000000031 /* Exceptions for "App" folder in "Hephaestus" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				Info.plist,
			);
			target = E10000000000000000000010 /* Hephaestus */;
		};
/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		E10000000000000000000030 /* App */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			exceptions = (
				E10000000000000000000031 /* Exceptions for "App" folder in "Hephaestus" target */,
			);
			path = App;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		E10000000000000000000041 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				E10000000000000000000051 /* HephUI in Frameworks */,
				E10000000000000000000052 /* HephHost in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		E10000000000000000000002 = {
			isa = PBXGroup;
			children = (
				E10000000000000000000030 /* App */,
				E10000000000000000000004 /* Config */,
				E10000000000000000000003 /* Products */,
			);
			sourceTree = "<group>";
		};
		E10000000000000000000003 /* Products */ = {
			isa = PBXGroup;
			children = (
				E10000000000000000000020 /* Hephaestus.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
		E10000000000000000000004 /* Config */ = {
			isa = PBXGroup;
			children = (
				E10000000000000000000021 /* Signing.xcconfig */,
			);
			path = Config;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		E10000000000000000000010 /* Hephaestus */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = E10000000000000000000073 /* Build configuration list for PBXNativeTarget "Hephaestus" */;
			buildPhases = (
				E10000000000000000000040 /* Sources */,
				E10000000000000000000041 /* Frameworks */,
				E10000000000000000000042 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				E10000000000000000000030 /* App */,
			);
			name = Hephaestus;
			packageProductDependencies = (
				E10000000000000000000061 /* HephUI */,
				E10000000000000000000062 /* HephHost */,
			);
			productName = Hephaestus;
			productReference = E10000000000000000000020 /* Hephaestus.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		E10000000000000000000001 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2710;
				LastUpgradeCheck = 2710;
				TargetAttributes = {
					E10000000000000000000010 = {
						CreatedOnToolsVersion = 27.1;
					};
				};
			};
			buildConfigurationList = E10000000000000000000070 /* Build configuration list for PBXProject "Hephaestus" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = E10000000000000000000002;
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				E10000000000000000000060 /* XCLocalSwiftPackageReference "HephaestusKit" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = E10000000000000000000003 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				E10000000000000000000010 /* Hephaestus */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		E10000000000000000000042 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		E10000000000000000000040 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		E10000000000000000000071 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				IPHONEOS_DEPLOYMENT_TARGET = 18.0;
				MACOSX_DEPLOYMENT_TARGET = 15.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		E10000000000000000000072 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 18.0;
				MACOSX_DEPLOYMENT_TARGET = 15.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
		E10000000000000000000074 /* Debug */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = E10000000000000000000021 /* Signing.xcconfig */;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 0;
				ENABLE_APP_SANDBOX = NO;
				ENABLE_HARDENED_RUNTIME = NO;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = App/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = Hephaestus;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
				"INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphoneos*]" = YES;
				"INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphonesimulator*]" = YES;
				"INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents[sdk=iphoneos*]" = YES;
				"INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents[sdk=iphonesimulator*]" = YES;
				"INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphoneos*]" = YES;
				"INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphonesimulator*]" = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UIRequiresFullScreen = NO;
				LD_RUNPATH_SEARCH_PATHS = "@executable_path/Frameworks";
				"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = "@executable_path/../Frameworks";
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = ca.azavech.hephaestus;
				PRODUCT_NAME = Hephaestus;
				SDKROOT = auto;
				SUPPORTED_PLATFORMS = "macosx iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;
				SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = NO;
				SWIFT_EMIT_LOC_STRINGS = YES;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Debug;
		};
		E10000000000000000000075 /* Release */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = E10000000000000000000021 /* Signing.xcconfig */;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 0;
				ENABLE_APP_SANDBOX = NO;
				ENABLE_HARDENED_RUNTIME = NO;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_FILE = App/Info.plist;
				INFOPLIST_KEY_CFBundleDisplayName = Hephaestus;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
				"INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphoneos*]" = YES;
				"INFOPLIST_KEY_UIApplicationSceneManifest_Generation[sdk=iphonesimulator*]" = YES;
				"INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents[sdk=iphoneos*]" = YES;
				"INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents[sdk=iphonesimulator*]" = YES;
				"INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphoneos*]" = YES;
				"INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphonesimulator*]" = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
				INFOPLIST_KEY_UIRequiresFullScreen = NO;
				LD_RUNPATH_SEARCH_PATHS = "@executable_path/Frameworks";
				"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = "@executable_path/../Frameworks";
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = ca.azavech.hephaestus;
				PRODUCT_NAME = Hephaestus;
				SDKROOT = auto;
				SUPPORTED_PLATFORMS = "macosx iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;
				SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = NO;
				SWIFT_EMIT_LOC_STRINGS = YES;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		E10000000000000000000070 /* Build configuration list for PBXProject "Hephaestus" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				E10000000000000000000071 /* Debug */,
				E10000000000000000000072 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		E10000000000000000000073 /* Build configuration list for PBXNativeTarget "Hephaestus" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				E10000000000000000000074 /* Debug */,
				E10000000000000000000075 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		E10000000000000000000060 /* XCLocalSwiftPackageReference "HephaestusKit" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = HephaestusKit;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		E10000000000000000000061 /* HephUI */ = {
			isa = XCSwiftPackageProductDependency;
			package = E10000000000000000000060 /* XCLocalSwiftPackageReference "HephaestusKit" */;
			productName = HephUI;
		};
		E10000000000000000000062 /* HephHost */ = {
			isa = XCSwiftPackageProductDependency;
			package = E10000000000000000000060 /* XCLocalSwiftPackageReference "HephaestusKit" */;
			productName = HephHost;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = E10000000000000000000001 /* Project object */;
}
```

### Hephaestus.xcodeproj/xcshareddata/xcschemes/Hephaestus.xcscheme

Exact content. The test action has no test targets: the tests are package tests run by `scripts/test.sh`
([testing.md](testing.md)).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2710"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "E10000000000000000000010"
               BuildableName = "Hephaestus.app"
               BlueprintName = "Hephaestus"
               ReferencedContainer = "container:Hephaestus.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "E10000000000000000000010"
            BuildableName = "Hephaestus.app"
            BlueprintName = "Hephaestus"
            ReferencedContainer = "container:Hephaestus.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "E10000000000000000000010"
            BuildableName = "Hephaestus.app"
            BlueprintName = "Hephaestus"
            ReferencedContainer = "container:Hephaestus.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

### Hephaestus.xcodeproj/project.xcworkspace

`contents.xcworkspacedata`, exact content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
```

`xcshareddata/swiftpm/Package.resolved` has the same pins as `HephaestusKit/Package.resolved`. Xcode writes its
`originHash` as the SHA-256 of the absolute path of the `HephaestusKit` folder, so a value written on a Mac is derived
from the path of the user's home folder. The committed file holds instead the value of the CI checkout,
`/Users/runner/work/Hephaestus/Hephaestus/HephaestusKit`; `xcodebuild -resolvePackageDependencies` in a checkout at
another path leaves the file unchanged (verified with Xcode 27.1). Exact content:

```json
{
  "originHash" : "489bc9aedb8361e67531c57a3d3c6d4b2907de4eb47e4b5e863883bef8a2c140",
  "pins" : [
    {
      "identity" : "swift-cmark",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/swiftlang/swift-cmark.git",
      "state" : {
        "revision" : "08ddb528923cc1a6527e02b7a1aee9e516ca749a",
        "version" : "0.9.0"
      }
    },
    {
      "identity" : "swift-markdown",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/swiftlang/swift-markdown.git",
      "state" : {
        "revision" : "25cb61d3482054b09ae76ca4f281b1bfe7fe5a43",
        "version" : "0.9.0"
      }
    },
    {
      "identity" : "yams",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/jpsim/Yams.git",
      "state" : {
        "revision" : "3d6871d5b4a5cd519adf233fbb576e0a2af71c17",
        "version" : "5.4.0"
      }
    }
  ],
  "version" : 3
}
```

When Xcode rewrites the file with another `originHash`, `git restore` undoes it; a new pin changes only the `pins`.

### Hephaestus.xcodeproj/xcshareddata/IDETemplateMacros.plist

The text macros of the files Xcode creates from its templates. Exact content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>FILEHEADER</key>
	<string> See docs/README.md.</string>
</dict>
</plist>
```

Xcode's default header of a new file names the account's full name (`Created by <name> on <date>.`), which is personal
data ([general.md](general.md#personal-data)). `FILEHEADER` replaces that header: Xcode writes each of its lines after
`//`, so a new Swift file starts with `// See docs/README.md.`. This was not tried with Xcode 27.1. A new file is
checked by the hooks like any other, and the private terms hold the account's full name.

### Config/Signing.xcconfig

The base configuration of the target's Debug and Release configurations. Exact content:

```xcconfig
// Signing of the Hephaestus target (docs/architecture.md). This file is public: never put a team ID in it.
// Your team ID goes in Config/Signing.local.xcconfig, ignored by git, for example DEVELOPMENT_TEAM = ABCDE12345
#include? "Signing.local.xcconfig"
```

`#include?` includes `Config/Signing.local.xcconfig` only when it exists, so a missing file is no error. That file is
never committed: the user creates it on each Mac that signs the app with their team, with the single line
`DEVELOPMENT_TEAM = ABCDE12345`, their team ID in place of `ABCDE12345`. Xcode also reads it from the repository root,
so `.gitignore` ignores `Signing.local.xcconfig` in every folder, and the personal data check refuses it
([public-repository.md](public-repository.md)). A `DEVELOPMENT_TEAM` in `project.pbxproj` would override the local
file; the personal data check refuses it too. The user chooses no team in Xcode's Signing & Capabilities: if Xcode
writes one into `project.pbxproj`, `git restore Hephaestus.xcodeproj/project.pbxproj` undoes it.

Without the local file, `scripts/build.sh` and CI build, a macOS build with the project's own signing settings is
signed to run locally (ad hoc, no team), and an iOS build that signs fails with "Signing for "Hephaestus" requires a
development team." (verified with Xcode 27.1).

## App/Info.plist

The partial Info.plist, merged with the keys generated from the build settings above. Exact content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoadsInWebContent</key>
		<true/>
	</dict>
	<key>NSBonjourServices</key>
	<array>
		<string>_hephaestus._tcp</string>
	</array>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Hephaestus connects to your other devices on the local network.</string>
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key>
		<true/>
	</dict>
</dict>
</plist>
```

| Key                              | Purpose                                                                           |
|----------------------------------|-----------------------------------------------------------------------------------|
| `NSAppTransportSecurity`         | `NSAllowsArbitraryLoadsInWebContent`: web tabs may load `http://` pages           |
| `NSBonjourServices`              | `_hephaestus._tcp`, browsed and advertised ([devices/mesh.md](devices/mesh.md))   |
| `NSLocalNetworkUsageDescription` | Text of the local network permission prompt                                       |
| `UIApplicationSceneManifest`     | `UIApplicationSupportsMultipleScenes`: several windows on iPad (ignored on macOS) |

Verified: the built iOS app's Info.plist contains `UIApplicationSceneManifest` with
`UIApplicationSupportsMultipleScenes = true`.

## App/Assets.xcassets

`Contents.json`, exact content:

```json
{ "info" : { "author" : "xcode", "version" : 1 } }
```

### AccentColor

`AccentColor.colorset/Contents.json`, exact content (sRGB red 0.950, green 0.420, blue 0.180, ember orange, the same
in light and dark appearance):

```json
{ "colors" : [ { "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "0.180", "green" : "0.420", "red" : "0.950" } }, "idiom" : "universal" } ], "info" : { "author" : "xcode", "version" : 1 } }
```

### AppIcon

The icon is a white hammer (SF Symbol `hammer.fill`) on an ember-orange gradient. The PNG files are rendered once with
AppKit and CoreGraphics by a script that is not part of the repository, and committed. They are rendered again only when
this section changes.

Drawing, in a square canvas of side `s` pixels (all lengths below scale with `s / 1024`; CoreGraphics coordinates,
y up):

| Element    | iOS image (`icon-ios-1024.png`)                                                                                                                                                                           | macOS images (`icon-mac-*.png`)                                                                                                                               |
|------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Canvas     | 1024 × 1024 pixels, 8-bit RGBA PNG                                                                                                                                                                        | the pixel size of the entry, 8-bit RGBA PNG, transparent outside the body                                                                                     |
| Body       | the whole square (the system applies the mask)                                                                                                                                                            | rounded rectangle x 100, y 100, width 824, height 824, corner radius 185, drawn first in black with a shadow: offset (0, −10), blur 24, black at 35 % opacity |
| Background | inside the body: linear gradient from the body's top-left corner to its bottom-right corner, sRGB stops (0.98, 0.62, 0.20) at 0, (0.86, 0.27, 0.10) at 0.55, (0.45, 0.09, 0.07) at 1                      | same                                                                                                                                                          |
| Hammer     | SF Symbol `hammer.fill`, weight semibold, point size 0.52 × body width, filled white, centered on the body, with a shadow: offset (0, −0.012 × body width), blur 0.03 × body width, black at 30 % opacity | same                                                                                                                                                          |

`AppIcon.appiconset/Contents.json`, exact content:

```json
{
  "images" : [
    { "filename" : "icon-ios-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "filename" : "icon-mac-16@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon-mac-16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon-mac-32@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon-mac-32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon-mac-128@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon-mac-128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon-mac-256@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon-mac-256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon-mac-512@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon-mac-512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

| File                  | Pixels      | Use              |
|-----------------------|-------------|------------------|
| `icon-ios-1024.png`   | 1024 × 1024 | iOS and iPadOS   |
| `icon-mac-16@1x.png`  | 16 × 16     | macOS 16 pt @1x  |
| `icon-mac-16@2x.png`  | 32 × 32     | macOS 16 pt @2x  |
| `icon-mac-32@1x.png`  | 32 × 32     | macOS 32 pt @1x  |
| `icon-mac-32@2x.png`  | 64 × 64     | macOS 32 pt @2x  |
| `icon-mac-128@1x.png` | 128 × 128   | macOS 128 pt @1x |
| `icon-mac-128@2x.png` | 256 × 256   | macOS 128 pt @2x |
| `icon-mac-256@1x.png` | 256 × 256   | macOS 256 pt @1x |
| `icon-mac-256@2x.png` | 512 × 512   | macOS 256 pt @2x |
| `icon-mac-512@1x.png` | 512 × 512   | macOS 512 pt @1x |
| `icon-mac-512@2x.png` | 1024 × 1024 | macOS 512 pt @2x |

## Process model

Hephaestus is one process per device. There is no helper process and no daemon.

```
Mac that is a Main (one process)
+-----------------------------------------------------------------------------------------------+
|  HephUI windows (each with its Selection)  <--observes--  HephClient Workspace (one)          |
|        AppModel ---- starts / stops ---------------------+    |                               |
|                                                          |    +-- MainConnection (this Mac)   |
|                                                          v    |      = LoopbackChannel ====+  |
|  HephHost HostService (actors) <=== accepts the loopback end like a network connection <===+  |
|        |  WebSocketListener :47100 <=== TLS-PSK WebSocket === remotes and peer Mains          |
|        +-- child processes: claude, runs (/bin/zsh -lc), git, gh, ditto, codesign, security    |
|                                                               +-- MainConnection (other Main) |
|                                                                      = WebSocketChannel ======+==> other Main
+-----------------------------------------------------------------------------------------------+

iPad, iPhone, or a Mac that is not a Main (one process)
  HephUI windows  <--observes--  Workspace --+-- MainConnection = WebSocketChannel ==> Main 1
                                             +-- MainConnection = WebSocketChannel ==> Main 2
```

- Every device runs a `Workspace` ([client/workspace.md](client/workspace.md)) with one `MainConnection` per Main of
  the mesh. Every window observes the same `Workspace` and keeps its own `Selection`.
- On a Main, the same process also runs the `HostService` ([services/host.md](services/host.md)). The app wiring
  (`AppModel`, [ui/shell.md](ui/shell.md)) starts it at launch when the device is a Main, and starts or stops it when
  "Use this Mac as a Main" changes.
- The Main's own UI talks to its `HostService` through a `LoopbackChannel`
  ([protocol/envelope.md](protocol/envelope.md)) exactly like a remote does over the network: the same `hello`
  handshake, the same requests, responses and events, the same subscriptions. The only differences are the transport: no
  TLS, no keep-alive pings, no addresses. The `Workspace` receives the loopback through `LocalHostLink`, which the app
  wiring implements with the `HostService` ([client/workspace.md](client/workspace.md#dependencies)).
- The `HostService` also connects to every other Main as a client (peer links, [devices/mesh.md](devices/mesh.md)).
  Peer links belong to the `HostService`; they are separate from the `Workspace`'s connections.
- A Main's network endpoints: TCP 47100 (mesh listener, setting), TCP 47101 while a pairing window is open, and
  `127.0.0.1:<random port>` for the MCP server used by its Claude sessions ([claude/mcp.md](claude/mcp.md)).
- Child processes of a Main (Claude CLI sessions, runs, git, gh, update tools) are spawned by `HephHost`
  ([claude/cli.md](claude/cli.md)). This is why the macOS app has no App Sandbox.

## Concurrency model

| Kind                                 | Used for                                                                                                                                                           | Rules                                                                                               |
|--------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| `@MainActor @Observable final class` | Client and UI state: `Workspace`, `MainConnection`, `ProjectStore`, `SessionModel`, `FileTreeModel`, `EditorDocument`, `SearchModel`, `RunOutputModel`, `AppModel` | Mutated only on the main actor. Work that waits awaits an actor; nothing blocks the main actor.     |
| `actor`                              | Services: `HostService` and the services it owns, `RPCPeer`, process supervisors, the MCP server, the Forge, the updater                                           | Each actor owns its mutable state. No mutable state is shared outside actors and the main actor.    |
| Private serial `DispatchQueue`       | Network.framework objects (`NWListener`, `NWConnection`, `NWBrowser`), FSEvents streams                                                                            | One queue per object, label `ca.azavech.hephaestus.<component>`. Callbacks hop to the owning actor. |
| `ChildProcess` with pipes            | Child process output ([claude/cli.md](claude/cli.md#12-childprocess))                                                                                              | The pipe's `readabilityHandler` yields data into an `AsyncStream` consumed by the owning actor.     |

- **Order.** Data whose order matters (inbound frames of a connection, FSEvents batches, process output, events of a
  `MainConnection`) goes through an `AsyncStream` filled by the callback and consumed by a single task. Callbacks never
  spawn one unstructured `Task` per item for ordered data.
- **Sendable.** Values crossing isolation domains are `Sendable` structs and enums; every wire type is `Sendable`.
  Reference types crossing isolation domains are actors or main-actor classes. `@unchecked Sendable` is used only for
  a wrapper whose state is confined to its own serial queue, with a comment saying so.
- **Timers.** Periodic and delayed work (keep-alive, reconnect backoff, idle timeouts, polling) is a `Task` running
  `Task.sleep(for:)` in a loop, owned by an actor or a main-actor object and cancelled when its owner stops.
- **Blocking work.** File reads and writes, hashing and YAML parsing of many files run inside actors, never on the
  main actor. Each `ChildProcess` waits for its exit (`waitpid`) on a `Thread` of its own; its callers await
  `waitForExit()` ([claude/cli.md](claude/cli.md#12-childprocess)).
- **Cancellation.** An object that starts tasks keeps their handles and cancels them in its `stop()` or `close()`.

## Data flow

### A task edit on an iPad reaching the Mac

The iPad shows task `HEPH-12` of project `HEPH`, hosted by the Mac; a window on the Mac shows the same task.

1. On the iPad, the status picker of the task detail ([ui/tasks.md](ui/tasks.md)) calls
   `MainConnection.updateTask(projectID: "HEPH", taskID: "HEPH-12", patch:)` with status `review`
   ([client/workspace.md](client/workspace.md#request-api)); a failure shows in the window's error banner.
2. The `MainConnection` of the Mac sends the request through its `RPCPeer` as a text frame over the TLS-PSK WebSocket:
   `{"id":57,"kind":"request","method":"tasks.update","params":{"patch":{"status":"review"},"projectID":"HEPH","taskID":"HEPH-12"}}`.
3. On the Mac, the `WebSocketListener` hands the frame to the connection's `RPCPeer`; the `HostService` routes
   `tasks.update` to the task service ([services/host.md](services/host.md)), which applies the patch, sets `updated`
   and writes `.hephaestus/tasks/HEPH-12.yml` atomically ([data/task-yml.md](data/task-yml.md)).
4. The `HostService` answers the request with the updated `TaskItem` and emits
   `task.changed {projectID: "HEPH", task}` to every authenticated connection: the iPad, the other remotes, and the
   Mac's own `Workspace` over the `LoopbackChannel` ([protocol/events.md](protocol/events.md)).
5. Each `Workspace` upserts the task into its `ProjectStore` of `HEPH`; the views observing the store update. The Mac's
   window and the iPad show the new status at the same time.
6. The file watcher later reports the write ([services/host.md](services/host.md)). Applying a `task.changed` with the
   same task again changes nothing: upserts are idempotent.

### Claude editing a file, seen live on an iPhone

The iPhone shows `Sources/App.swift` of `HEPH` in the code editor ([ui/code.md](ui/code.md)), unmodified, and the
transcript of the session working on it ([ui/sessions.md](ui/sessions.md)).

1. The iPhone's `SessionModel` subscribed to the topic `session:<sessionID>` through the `Workspace`, so the Mac sends
   it the high-volume events of that session.
2. On the Mac, the session's Claude CLI process streams. The session service turns partial output into
   `session.delta` events (text as it is generated) and complete blocks into `session.event` events (`toolUse` for the
   `Edit` tool) ([claude/cli.md](claude/cli.md)); the iPhone's transcript shows them as they arrive.
3. Claude writes `Sources/App.swift`. FSEvents reports it; after 300 ms of coalescing the `HostService` emits
   `files.changed {projectID: "HEPH", paths: ["Sources/App.swift"]}` to every connection.
4. The iPhone's `Workspace` passes the event to its observers. The `EditorDocument` of that path is unmodified, so it
   sends `files.read` and replaces its text and revision ([ui/code.md](ui/code.md)). A modified document shows the
   "Changed on the Main" banner instead.
5. The tool result and the end of the turn arrive as `session.event` events, and `session.changed` reports the session
   back to `idle`.

## Logging

`HephaestusKit/Sources/HephCore/Util/Log.swift`, exact content:

```swift
import os

/// The loggers of Hephaestus: subsystem `ca.azavech.hephaestus`, one category per module.
public enum Log {
    public static let subsystem = "ca.azavech.hephaestus"

    public static let core = Logger(subsystem: subsystem, category: "HephCore")
    public static let net = Logger(subsystem: subsystem, category: "HephNet")
    public static let host = Logger(subsystem: subsystem, category: "HephHost")
    public static let client = Logger(subsystem: subsystem, category: "HephClient")
    public static let editor = Logger(subsystem: subsystem, category: "HephEditor")
    public static let markdown = Logger(subsystem: subsystem, category: "HephMarkdown")
    public static let ui = Logger(subsystem: subsystem, category: "HephUI")
}
```

- Each module logs with its own logger; the App target uses `Log.ui`. Nothing uses `print`.
- Levels: `debug` for per-request and per-frame detail, `info` for lifecycle (listener started, connection
  established, session started), `notice` for state changes the user would care about (Main online or offline,
  migration finished), `error` for failures, `fault` for broken invariants.
- Privacy: identifiers (device, project, task, session, run ids), method and event names, states, error codes, counts,
  durations and paths relative to a project root are logged with `privacy: .public`. Everything else keeps the
  default (private). Mesh keys, PSKs, pairing codes, bearer tokens, credentials, file contents, message texts and
  comment bodies are never logged.
- Reading the logs: `log stream --level debug --predicate 'subsystem == "ca.azavech.hephaestus"'`.

## Root files

### README.md

Exact content:

````markdown
# Hephaestus

Hephaestus coordinates the work on all your projects from any of your devices. Projects live on Macs set as Mains;
every Mac, iPad and iPhone connects to every Main and sees and controls everything on it in real time: tasks, code,
docs, web tabs, Claude sessions and runs.

The app is generated from its specification in [docs/](docs/README.md). The docs are the source of truth: the code
follows them.

## Public repository

This repository is public. Nothing personal goes into it: no names, e-mail addresses, home-folder paths, computer,
device or host names, network addresses, signing identities or team IDs, in files, file names, commit messages,
commit author and committer names or branch names. The rules and the checks:
[docs/public-repository.md](docs/public-repository.md).

Set up every clone before its first commit:

```sh
git config core.hooksPath .githooks
git config commit.gpgsign false
```

The hooks then check every commit and every push; never skip them with `--no-verify`. To have them refuse your own
names too, copy `private-terms.txt` from the Forge host to `~/Library/Application Support/Hephaestus/`
([docs/public-repository.md](docs/public-repository.md#setting-up-a-clone)).

## Requirements

- macOS 15 or later; iPadOS and iOS 18 or later.
- Xcode 27.1 to build.
- On a Main: the Claude CLI (`claude`) and git.

## Build and test

```sh
scripts/build.sh macos          # macOS
scripts/build.sh macos-release  # macOS, release configuration
scripts/build.sh ios            # iOS and iPadOS
scripts/build.sh all            # all of the above
scripts/test.sh                 # package tests
```

Or open `Hephaestus.xcodeproj` in Xcode and run the `Hephaestus` scheme.

## Install

- Mac: download `Hephaestus-macOS.zip` from the latest release of
  [Azavech/Hephaestus](https://github.com/Azavech/Hephaestus/releases), unzip it and move `Hephaestus.app` to
  `/Applications`. If macOS refuses to open it, run `xattr -dr com.apple.quarantine /Applications/Hephaestus.app` once.
  From then on the app updates itself when a new release is published.
- iPhone and iPad: create `Config/Signing.local.xcconfig` with the line `DEVELOPMENT_TEAM = ABCDE12345`, your team ID in
  place of `ABCDE12345` (git ignores this file; never put a team ID in a committed file). Then open
  `Hephaestus.xcodeproj` in Xcode, select the `Hephaestus` scheme and the device, and run. Choose no team in Xcode's
  Signing & Capabilities; if Xcode wrote one into the project file, run
  `git restore Hephaestus.xcodeproj/project.pbxproj`.
- Forge host, the Mac that turns feedback into new builds: a clone of this repository, set up as above, added in the
  app with Add Existing Folder… as the project `HEPH`; then "This Main is the Forge" in Settings ▸ Forge & Updates.

## Documentation

Start with [docs/README.md](docs/README.md).
````

### .gitignore

Exact content:

```gitignore
# Build products
build/
.build/
DerivedData/

# Xcode and SwiftPM user state
xcuserdata/
*.xcuserstate
.swiftpm/

# macOS
.DS_Store

# Personal and machine data: never in this public repository (docs/public-repository.md)
.hephaestus/
.claude/
CLAUDE.local.md
.mcp.json
Signing.local.xcconfig
.env
.env.*
*.p12
*.mobileprovision
*.provisionprofile
*.cer
*.pem
*.key
```

The patterns have no leading `/`, so they apply in every folder: a sub project's `.hephaestus/` and a
`Signing.local.xcconfig` at the repository root, where Xcode also looks for it, are ignored too. Ignoring is a
convenience: the personal data check refuses `xcuserdata/`, `*.xcuserstate`, `.DS_Store` and every path of the last
block except `.mcp.json` even when they are force-added ([public-repository.md](public-repository.md#rules)).
