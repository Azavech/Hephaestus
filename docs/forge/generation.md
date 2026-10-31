# Regeneration

files:
- CLAUDE.md
- scripts/docs-hash.sh
- App/DocsHash.txt
- HephaestusKit/Sources/HephCore/Util/DocsHash.swift

---

The code of the repository is generated from `docs/`. This doc defines the docs hash, which names the documentation a
build was generated from, the procedure Claude follows to bring the code in line with the docs (a **regeneration**),
and the repository's `CLAUDE.md`. The Forge runs the procedure in a `regeneration` session
([pipeline.md](pipeline.md)); anyone can also run it by hand in a Claude session opened in the repository.

## 1. Docs hash

### 1.1 Definition

1. Take every regular file under `docs/`, at any depth, whose name is not `.DS_Store`. Hidden files are included.
   Symbolic links and folders are not files and are ignored.
2. For each file, form one line: `<h>`, two spaces, `<path>`, a line feed. `<h>` is the SHA-256 of the file's bytes
   as 64 lowercase hex characters; `<path>` is the path from the repository root with `/` separators
   (`docs/forge/ci.md`).
3. Sort the lines by `<path>`, comparing the UTF-8 bytes (C locale order; a path that is a prefix of another comes
   first).
4. The docs hash is the SHA-256 of the concatenated lines, as 64 lowercase hex characters.

Doc file names are ASCII and never contain a line feed. No EOL conversion or git filter (`.gitattributes`) may apply
to `docs/`, so a file's bytes are the same in a checkout and in git.

Test vectors:

| Files under `docs/`                                                      | Docs hash                                                          |
|--------------------------------------------------------------------------|--------------------------------------------------------------------|
| none (empty folder)                                                      | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `docs/a.md` = `a\n`, `docs/b/c.md` = `c\n`, `docs/.DS_Store` = `x`       | `bf4d60c2ef59fbdaabdcf5b66d49771430ea42d75cdb231b066cf6f27a777c70` |

The second vector hashes these two lines:

```text
87428fc522803d31065e7bce3cf03fe475096631e5e07bbd7a0fde60c4cf25c7  docs/a.md
a3a5e715f0cc574a73c3f9bebb6bc24f32ffd5b67b387244c2c909da779a1478  docs/b/c.md
```

Three implementations give the same value for the same files:

| Implementation                         | Input                                       | Used by                                                   |
|----------------------------------------|---------------------------------------------|-----------------------------------------------------------|
| `scripts/docs-hash.sh`                 | the working tree                            | step 10 of the procedure, CI `docs-sync` ([ci.md](ci.md)) |
| `DocsHash.compute(repositoryRoot:)`    | the working tree                            | tests ([../testing.md](../testing.md))                    |
| `DocsHash.compute(_:)` on git blobs    | a git revision (`git ls-tree` + `git show`) | the Forge ([pipeline.md](pipeline.md#git-operations))     |

### 1.2 scripts/docs-hash.sh

Exact content (committed with mode `100755`). It prints the docs hash and a line feed; it fails when `docs/` does not
exist. It runs on macOS and on Ubuntu (`shasum` is part of Perl on both).

```bash
#!/bin/bash
# Prints the docs hash: the SHA-256 of one line "<sha256 of the file>  <path>" per file under docs/
# (paths from the repository root, sorted in byte order, .DS_Store files excluded). See docs/forge/generation.md.
set -euo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C
find docs -type f ! -name .DS_Store -print | sort | while IFS= read -r path; do
  printf '%s  %s\n' "$(shasum -a 256 < "$path" | cut -c1-64)" "$path"
done | shasum -a 256 | cut -c1-64
```

### 1.3 DocsHash (HephCore)

`HephaestusKit/Sources/HephCore/Util/DocsHash.swift`, all platforms, exact content:

```swift
import CryptoKit
import Foundation

/// The docs hash of docs/forge/generation.md.
public enum DocsHash {
    /// A documentation file: its path from the repository root ("docs/forge/ci.md") and its bytes.
    public struct File: Sendable {
        public var path: String
        public var content: Data
        public init(path: String, content: Data) {
            self.path = path
            self.content = content
        }
    }

    /// The docs hash of the given files. Files named .DS_Store are left out.
    public static func compute(_ files: [File]) -> String {
        let kept = files.filter { !isExcluded($0.path) }
        let sorted = kept.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        var lines = Data()
        for file in sorted {
            lines.append(Data("\(hex(SHA256.hash(data: file.content)))  \(file.path)\n".utf8))
        }
        return hex(SHA256.hash(data: lines))
    }

    /// The docs hash of the docs/ folder of a working tree. Throws when docs/ is not a folder.
    public static func compute(repositoryRoot: URL) throws -> String {
        let docs = repositoryRoot.appendingPathComponent("docs", isDirectory: true).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: docs.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: docs.path])
        }
        let base = docs.pathComponents.count
        var files: [File] = []
        if let enumerator = FileManager.default.enumerator(at: docs, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(base).joined(separator: "/")
                files.append(File(path: "docs/" + relative, content: try Data(contentsOf: url)))
            }
        }
        return compute(files)
    }

    /// True for a path whose last component is .DS_Store.
    public static func isExcluded(_ path: String) -> Bool {
        path.split(separator: "/").last == ".DS_Store"
    }

    /// The docs hash the running app was generated from: the bundled App/DocsHash.txt, trimmed,
    /// or "unknown" when the resource is missing or empty.
    public static let embedded: String = {
        guard let url = Bundle.main.url(forResource: "DocsHash", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "unknown" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }()

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

### 1.4 App/DocsHash.txt

- Content: the output of `scripts/docs-hash.sh`: 64 lowercase hex characters and a line feed. Readers trim whitespace.
- Written only by step 10 of the procedure. It names the docs the code at that commit was generated from.
- `App/` is a file-system-synchronized folder of the app target ([../architecture.md](../architecture.md)), so the file
  is copied into the app bundle as the resource `DocsHash.txt`. `DocsHash.embedded` reads it.
- `DocsHash.embedded` is shown in About ([../ui/shell.md](../ui/shell.md)) and in the Forge screen
  ([../ui/forge.md](../ui/forge.md)), and sent as `FeedbackContext.docsHash` ([feedback.md](feedback.md)).

## 2. Procedure

Claude follows these steps in order, in the repository root, with `origin` being GitHub, on the branch `<branch>`:
in a Forge regeneration session the branch the Forge follows (the `forge.branch` setting,
[../data/app-storage.md](../data/app-storage.md#settingsjson)), which the session's prompt names
([../claude/prompts.md](../claude/prompts.md#regeneration-part)); `main` when the procedure is run by hand. A
regeneration never edits `docs/`, never force-pushes and never amends or rebases a commit that is on `origin`.

The repository is public: nothing a regeneration writes or commits holds personal data
([../general.md](../general.md#public-repository-no-personal-data)). `.hephaestus/` holds the app's data of the
project; git ignores it ([../architecture.md](../architecture.md#gitignore)), and a regeneration never creates, edits,
stages or deletes anything in it.

1. **Read the rules.** Read `docs/general.md`, `docs/public-repository.md`, then `docs/README.md` (reading order,
   index, how the docs drive the build). Read [`docs/testing.md`](../testing.md) before step 7.
2. **Start clean and current.**
   - `git status --porcelain` prints nothing; otherwise stop (2.3).
   - `git rev-parse --abbrev-ref HEAD` prints `<branch>`; otherwise stop.
   - `git pull --ff-only origin <branch>` succeeds; otherwise stop.
   - Record `START=$(git rev-parse HEAD)`.
3. **Find the base.** `BASE=$(git log -1 --format=%H -- App/DocsHash.txt)`, the last commit that changed
   `App/DocsHash.txt`. When it prints nothing (the code was never generated), `BASE` is the empty tree
   `4b825dc642cb6eb9a060e54bf8d69288fbee4904` and every doc counts as added.
4. **List the doc changes.** `git diff --name-status --find-renames $BASE HEAD -- docs/` lists the added (`A`),
   modified (`M`), deleted (`D`) and renamed (`R`) docs; `git diff $BASE HEAD -- docs/` shows the changes. When
   `scripts/docs-hash.sh` prints the content of `App/DocsHash.txt` and there is no CI failure to fix (2.2), there is
   nothing to do: stop.
5. **Find the governed files.** For each changed doc, read its `files:` block (2.1) at `$BASE` (`git show
   $BASE:<doc>`, when the doc existed there) and at `HEAD`; the union of both lists is the set of source files to bring
   in line with the docs. Read the whole current doc, not only its diff, and the docs it links to when they define
   names it uses. A changed doc without a `files:` block governs no file directly: find the code its change affects
   through the docs that describe that behavior, and their `files:` blocks. Process the docs in the reading order of
   `docs/README.md`.
6. **Change the code.** Make every governed file implement exactly what the docs say: names, types, fields, texts,
   defaults, behaviors, and nothing more.
   - Create the files that are listed and missing.
   - Delete a file that a changed doc listed at `$BASE` and that no doc lists at `HEAD` (check every doc's `files:`
     block, not only the changed ones).
   - Code governed by an unchanged doc changes only when a changed doc requires it (for example a renamed type used
     there), and then still matches its own doc.
   - The Xcode project file changes only as `docs/architecture.md` says; files added under `App/` need no project
     change.
7. **Update the tests.** Tests are governed by `docs/testing.md` only. Update the tests that cover changed behavior and
   add the tests `docs/testing.md` lists for new behavior.
8. **Build and test.** `scripts/build.sh all` and `scripts/test.sh` ([ci.md](ci.md)) both succeed. Fix the code, never
   the docs, until they do.
9. **Check that the docs are untouched.** `git status --porcelain -- docs/` prints nothing.
10. **Record the docs hash.** `scripts/docs-hash.sh > App/DocsHash.txt`.
11. **Commit.** `git add -A`, then `scripts/check-public.sh --staged`
    ([../public-repository.md](../public-repository.md#check-script)). When it reports findings, replace the personal
    data in the files it names with the placeholders of [../general.md](../general.md#placeholders), then `git add -A`
    and run it again, until it ends with `Personal data check: clean.`. A value is never split, encoded, escaped or
    reformatted to get past a finding: it is removed or replaced by a placeholder. A finding the docs require stops
    the regeneration (2.3). Then `git commit` with this message (the summary line is at most 72 characters in all):

    ```text
    regen: <summary of the change>

    Docs <first 8 characters of BASE>..<first 8 characters of HEAD>:
    - M docs/ui/tasks.md
    - A docs/forge/feedback.md
    ```

    one `- <status> <path>` line per line of step 4 (`R` lines as `- R <old path> -> <new path>`). In fix mode (2.2)
    the body ends with the line `Fixes CI run #<run number>: <run URL>`; with no doc change the summary is
    `regen: fix CI run #<run number>: <summary>` and the docs lines are replaced by `Docs: no change.`. By hand, the
    hooks check the commit and its message again. In a Forge session no hook runs
    ([../claude/cli.md](../claude/cli.md#35-sessions-in-the-public-repository)): this step's check comes first, and the
    Forge checks the commits again before pushing them. `--no-verify` is never used.
12. **Push.**
    - In a Forge regeneration session (the tool `mcp__hephaestus__forge_push_regen` exists), never run `git push`: call
      `mcp__hephaestus__forge_push_regen` with no arguments. The Forge checks the commits and pushes them
      ([../public-repository.md](../public-repository.md#forge-push-gate)). When it returns an error, do what the error
      says, then call it again:
      - `origin/<branch>` moved: 12.1 to 12.3;
      - personal data findings: remove the data the findings name, `git reset --soft origin/<branch>`, then steps 10
        and 11 again (one commit); when the docs require that data, stop (2.3);
      - no private term, or suggested private terms pending: stop (2.3); the user acts in Settings ▸ Forge & Updates.
    - By hand: `git push origin <branch>`, with the hooks active (`core.hooksPath` is `.githooks`). When it is rejected
      because `origin/<branch>` moved: 12.1 to 12.3. When the pre-push hook refuses it: as for personal data findings
      above.

    1. `git pull --rebase origin <branch>`; set `NEXT=$(git rev-parse origin/<branch>)`.
    2. When `scripts/docs-hash.sh` now differs from `App/DocsHash.txt`, the pulled commits changed docs: apply the
       changes of `git diff --name-status --find-renames $START $NEXT -- docs/` with steps 5 to 11, reading `$START`
       where they say `$BASE` (a second `regen:` commit).
    3. Set `START=$NEXT` and push again: call `mcp__hephaestus__forge_push_regen` again, or `git push origin <branch>`
       by hand. Repeat until the push succeeds.

    End the turn with a short summary: changed docs, changed files, build and test results, the pushed commit.

### 2.1 files: blocks

A doc that governs code starts with its title, a blank line, the line `files:`, one `- <path>` line per governed file
(path from the repository root), a blank line and a `---` line. A path may hold `*`, which matches any characters
except `/` within one path component (`HephaestusKit/Sources/HephUI/Shell/*`). A source file is listed by exactly one
doc; test files are listed by `docs/testing.md` only.

### 2.2 Fix mode

The first message of a Forge regeneration session can report a failed CI run: its number, URL, conclusion, and the
names, URLs and log excerpts of its failed jobs ([pipeline.md](pipeline.md#regeneration-step)). Then, in
addition to the doc changes of step 4:

- read the logs, reproduce the failure with `scripts/build.sh` or `scripts/test.sh` when possible, and fix the code so
  that it matches the docs and the failing job passes;
- the commit of step 11 includes these fixes; step 10 is still run (the file does not change when the docs did not);
- `gh run view <run id> --log-failed` may be used for more of the log;
- a failed `public-check` or `public-check-terms` job means that personal data reached GitHub: stop (2.3). The user
  removes it by hand ([../public-repository.md](../public-repository.md#if-personal-data-was-pushed)).

### 2.3 Stopping

Stop without committing or pushing, and explain why in the reply, when:

- the working tree is not clean, the branch is not `<branch>`, or `git pull --ff-only` fails (step 2);
- there is nothing to do (step 4);
- a doc is ambiguous, contradicts another doc, or cannot be implemented without inventing something;
- the build or the tests cannot pass without changing a doc;
- the personal data check reports data that a doc requires (steps 11 and 12);
- the Forge refuses the push until the user adds private terms or reviews suggested ones (step 12);
- the failed CI job to fix is `public-check` or `public-check-terms` (2.2).

Never edit `docs/` to get past a problem: docs change through a feedback session ([pipeline.md](pipeline.md)) or by
the user. When files were already changed, first put them aside with
`git stash push --include-untracked -m "regen stopped <yyyy-MM-dd HH:mm>"` so the working tree is clean for the next
attempt. In a Forge session, the Forge marks the regeneration `failed` when the turn ends without a successful
`forge_push_regen`; the user fixes the cause and retries.

## 3. CLAUDE.md

The repository root `CLAUDE.md`, loaded by every Claude session started in the repository, has exactly this content:

````markdown
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

- Documentation changes: `docs: <summary> (<task id>)`, only files under `docs/`.
- Regenerations: `regen: <summary>`, as described in `docs/forge/generation.md`.

## Commands

| Command                            | Does                                                           |
|------------------------------------|----------------------------------------------------------------|
| `scripts/build.sh <target>`        | builds the app; targets `macos`, `macos-release`, `ios`, `all` |
| `scripts/test.sh`                  | runs the HephaestusKit package tests                           |
| `scripts/docs-hash.sh`             | prints the docs hash of `docs/`                                |
| `scripts/check-public.sh --staged` | checks the staged files for personal data                      |
````
