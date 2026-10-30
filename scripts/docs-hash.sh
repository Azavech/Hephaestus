#!/bin/bash
# Prints the docs hash: the SHA-256 of one line "<sha256 of the file>  <path>" per file under docs/
# (paths from the repository root, sorted in byte order, .DS_Store files excluded). See docs/forge/generation.md.
set -euo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C
find docs -type f ! -name .DS_Store -print | sort | while IFS= read -r path; do
  printf '%s  %s\n' "$(shasum -a 256 < "$path" | cut -c1-64)" "$path"
done | shasum -a 256 | cut -c1-64
