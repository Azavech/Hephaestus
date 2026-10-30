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
