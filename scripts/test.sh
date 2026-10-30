#!/bin/bash
# Runs the HephaestusKit package tests on macOS. Extra arguments go to swift test (for example --filter).
# See docs/forge/ci.md and docs/testing.md.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${CI:-}" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
  [ "$(git config --local --get core.hooksPath)" != .githooks ]; then
  echo "error: run git config core.hooksPath .githooks first (docs/public-repository.md)" >&2
  exit 2
fi
swift test --package-path HephaestusKit --scratch-path build/SwiftPM "$@"
