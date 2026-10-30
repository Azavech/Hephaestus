#!/bin/bash
# Builds Hephaestus. Usage: scripts/build.sh macos|macos-release|ios|all
# BUILD_NUMBER (default 0) becomes CURRENT_PROJECT_VERSION, the app's build number. See docs/forge/ci.md.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${CI:-}" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
  [ "$(git config --local --get core.hooksPath)" != .githooks ]; then
  echo "error: run git config core.hooksPath .githooks first (docs/public-repository.md)" >&2
  exit 2
fi

common=(
  -project Hephaestus.xcodeproj
  -scheme Hephaestus
  -derivedDataPath build/DerivedData
  -quiet
  "CURRENT_PROJECT_VERSION=${BUILD_NUMBER:-0}"
)

build_macos() {
  xcodebuild build "${common[@]}" -configuration Debug -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-
}

build_macos_release() {
  xcodebuild build "${common[@]}" -configuration Release -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-
}

build_ios() {
  xcodebuild build "${common[@]}" -configuration Debug -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO
}

case "${1:-}" in
  macos) build_macos ;;
  macos-release) build_macos_release ;;
  ios) build_ios ;;
  all) build_macos; build_ios; build_macos_release ;;
  *) echo "usage: scripts/build.sh macos|macos-release|ios|all" >&2; exit 2 ;;
esac
