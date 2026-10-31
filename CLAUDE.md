# Hephaestus

Hephaestus is a SwiftUI app for macOS, iPadOS and iOS. Its code is generated from its documentation in `docs/`.

## Public repository

This repository is public. Nothing personal ever goes into it, in files, file names or commit messages: no real
names, account names, home-folder paths, e-mail addresses, computer, device or host names, network addresses, signing
identities or team IDs, tokens or keys, names or paths of the user's other projects, and nothing copied from a
screenshot, a comment, a transcript or a log of the user's machines. Use the placeholders of `docs/general.md`
(`Jane Appleseed`, `/Users/user`, `user@example.com`, `Sam's iPad`, `192.0.2.10`). When in doubt, leave it out.

- Before committing, run `scripts/check-public.sh --staged` and fix every finding. Never use `--no-verify`.
- Never split, encode, escape or reformat a value to get past a finding: remove it or use a placeholder.
- In a Forge session, never run `git push`: push with the session's Forge tool, `forge_push_docs` or `forge_push_regen`.
- Notes about the user or their machines never go into this file or any other file of the repository.

## Rules

- `docs/` is the source of truth. Read `docs/general.md`, `docs/public-repository.md` and `docs/README.md` before
  changing anything.
- Never invent anything: no behavior, name, text, setting, file or dependency that is not in `docs/`. When something
  is unclear or missing, the documentation is changed first, then the code follows.
- Every doc that governs code starts with a `files:` list. Each source file is governed by exactly one doc and
  changes only to match it.
- `App/DocsHash.txt` records the docs hash (`scripts/docs-hash.sh`) of the documentation the code was generated
  from. Only a regeneration writes it, as its last step before committing.
- Markdown tables in `docs/` are aligned: in each column every cell has the width of the widest cell.

## Regenerating the code

To bring the code in line with the docs, follow `docs/forge/generation.md` step by step.

## Commits

- Documentation changes: `docs: <summary> (<ticket id>)`, only files under `docs/`.
- Regenerations: `regen: <summary>`, as described in `docs/forge/generation.md`.

## Commands

| Command                            | Does                                                           |
|------------------------------------|----------------------------------------------------------------|
| `scripts/build.sh <target>`        | builds the app; targets `macos`, `macos-release`, `ios`, `all` |
| `scripts/test.sh`                  | runs the HephaestusKit package tests                           |
| `scripts/docs-hash.sh`             | prints the docs hash of `docs/`                                |
| `scripts/check-public.sh --staged` | checks the staged files for personal data                      |
