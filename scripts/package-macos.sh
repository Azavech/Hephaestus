#!/bin/bash
# Zips the macOS release build into build/Hephaestus-macOS.zip (the release asset). Run scripts/build.sh macos-release
# first. See docs/forge/ci.md.
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/DerivedData/Build/Products/Release/Hephaestus.app"
zip="build/Hephaestus-macOS.zip"
if [ ! -d "$app" ]; then
  echo "error: $app not found; run scripts/build.sh macos-release first" >&2
  exit 1
fi
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip"
