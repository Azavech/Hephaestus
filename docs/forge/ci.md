# CI and build scripts

files:
- .github/workflows/ci.yml
- scripts/build.sh
- scripts/test.sh
- scripts/package-macos.sh

---

GitHub Actions runs for every push, of any branch or tag, every pull request and every manual run of the repository
`Azavech/Hephaestus`, except those GitHub skips ([../public-repository.md](../public-repository.md#limits)). The
repository is public: every run first checks it for personal data
([../public-repository.md](../public-repository.md)), and only pushes to `main`, pull requests and manual runs go on to
test and build. It builds only code whose recorded docs hash matches `docs/`
([generation.md](generation.md#1-docs-hash)), and every successful push build of `main` becomes the release
`build-<run number>` that Macs update to ([update.md](update.md)). The scripts are the same locally, in regeneration
sessions and in CI. `scripts/docs-hash.sh` is defined in [generation.md](generation.md#12-scriptsdocs-hashsh).

## Workflow

`.github/workflows/ci.yml`, exact content:

```yaml
name: CI

on:
  push:
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  public-check:
    if: ${{ github.event_name != 'push' || !github.event.deleted }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Check for personal data
        env:
          EVENT: ${{ github.event_name }}
          BRANCH: ${{ github.ref_name }}
          BEFORE: ${{ github.event.before }}
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          if [ -f "$RUNNER_TEMP/private-terms.txt" ]; then
            export HEPHAESTUS_PRIVATE_TERMS="$RUNNER_TEMP/private-terms.txt"
          fi
          out="$RUNNER_TEMP/public-check.txt"
          status=0
          : > "$out"
          if git ls-tree -r HEAD -- scripts/check-public.sh .githooks/ | grep -v '^100755 ' | grep -q .; then
            echo 'scripts/check-public.sh and the files of .githooks/ must have mode 100755.' >> "$out"
            status=1
          fi
          refs=() range=() base=''
          if [ "$EVENT" = push ]; then
            case $GITHUB_REF in refs/tags/*) echo 'Tags are created only by CI releases.' >> "$out"; status=1 ;; esac
            refs=(--ref "$GITHUB_REF")
            if git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
              range=("$BEFORE..$GITHUB_SHA")
              base=$BEFORE
            else
              range=("$GITHUB_SHA" --not "--exclude=$BRANCH" --tags='build-*')
            fi
          elif [ "$EVENT" = pull_request ]; then
            range=("$BASE_SHA..$HEAD_SHA")
            base=$BASE_SHA
          fi
          if [ -z "$base" ]; then
            base=$(git tag --list 'build-*' --sort=-v:refname | head -n 1)
          fi
          check() {
            bash "$1" "${refs[@]}" --tree HEAD >> "$out" 2>&1 || status=1
            if [ ${#range[@]} -gt 0 ]; then
              bash "$1" --commits "${range[@]}" >> "$out" 2>&1 || status=1
            fi
          }
          check scripts/check-public.sh
          if [ -n "$base" ] && git cat-file -e "$base:scripts/check-public.sh" 2>/dev/null &&
            [ "$(git rev-parse "$base:scripts/check-public.sh")" != "$(git rev-parse HEAD:scripts/check-public.sh 2>/dev/null)" ]; then
            git show "$base:scripts/check-public.sh" > "$RUNNER_TEMP/check-public-base.sh"
            check "$RUNNER_TEMP/check-public-base.sh"
          fi
          if [ -n "${HEPHAESTUS_PRIVATE_TERMS:-}" ] && grep -q '^Note: ' "$out"; then
            echo 'The secret PRIVATE_TERMS is missing or holds no private terms.' >> "$out"
            status=1
          fi
          cat "$out"
          if [ "$status" -ne 0 ]; then
            {
              echo "## Personal data check failed"
              echo ""
              sed 's/^/    /' "$out"
            } >> "$GITHUB_STEP_SUMMARY"
          fi
          exit "$status"

  public-check-terms:
    if: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.deleted }}
    runs-on: ubuntu-latest
    environment: private-terms
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Write the private terms
        env:
          PRIVATE_TERMS: ${{ secrets.PRIVATE_TERMS }}
        run: |
          printf '%s\n' "$PRIVATE_TERMS" > "$RUNNER_TEMP/private-terms.txt"
      - name: Check for personal data
        env:
          EVENT: ${{ github.event_name }}
          BRANCH: ${{ github.ref_name }}
          BEFORE: ${{ github.event.before }}
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          if [ -f "$RUNNER_TEMP/private-terms.txt" ]; then
            export HEPHAESTUS_PRIVATE_TERMS="$RUNNER_TEMP/private-terms.txt"
          fi
          out="$RUNNER_TEMP/public-check.txt"
          status=0
          : > "$out"
          if git ls-tree -r HEAD -- scripts/check-public.sh .githooks/ | grep -v '^100755 ' | grep -q .; then
            echo 'scripts/check-public.sh and the files of .githooks/ must have mode 100755.' >> "$out"
            status=1
          fi
          refs=() range=() base=''
          if [ "$EVENT" = push ]; then
            case $GITHUB_REF in refs/tags/*) echo 'Tags are created only by CI releases.' >> "$out"; status=1 ;; esac
            refs=(--ref "$GITHUB_REF")
            if git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
              range=("$BEFORE..$GITHUB_SHA")
              base=$BEFORE
            else
              range=("$GITHUB_SHA" --not "--exclude=$BRANCH" --tags='build-*')
            fi
          elif [ "$EVENT" = pull_request ]; then
            range=("$BASE_SHA..$HEAD_SHA")
            base=$BASE_SHA
          fi
          if [ -z "$base" ]; then
            base=$(git tag --list 'build-*' --sort=-v:refname | head -n 1)
          fi
          check() {
            bash "$1" "${refs[@]}" --tree HEAD >> "$out" 2>&1 || status=1
            if [ ${#range[@]} -gt 0 ]; then
              bash "$1" --commits "${range[@]}" >> "$out" 2>&1 || status=1
            fi
          }
          check scripts/check-public.sh
          if [ -n "$base" ] && git cat-file -e "$base:scripts/check-public.sh" 2>/dev/null &&
            [ "$(git rev-parse "$base:scripts/check-public.sh")" != "$(git rev-parse HEAD:scripts/check-public.sh 2>/dev/null)" ]; then
            git show "$base:scripts/check-public.sh" > "$RUNNER_TEMP/check-public-base.sh"
            check "$RUNNER_TEMP/check-public-base.sh"
          fi
          if [ -n "${HEPHAESTUS_PRIVATE_TERMS:-}" ] && grep -q '^Note: ' "$out"; then
            echo 'The secret PRIVATE_TERMS is missing or holds no private terms.' >> "$out"
            status=1
          fi
          cat "$out"
          if [ "$status" -ne 0 ]; then
            {
              echo "## Personal data check failed"
              echo ""
              sed 's/^/    /' "$out"
            } >> "$GITHUB_STEP_SUMMARY"
          fi
          exit "$status"

  docs-sync:
    needs: [public-check, public-check-terms]
    if: ${{ !cancelled() && needs.public-check.result == 'success' && (needs.public-check-terms.result == 'success' || needs.public-check-terms.result == 'skipped') && (github.event_name != 'push' || github.ref == 'refs/heads/main') }}
    runs-on: ubuntu-latest
    outputs:
      in_sync: ${{ steps.check.outputs.in_sync }}
      docs_hash: ${{ steps.check.outputs.docs_hash }}
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - id: check
        name: Compare the docs hash with App/DocsHash.txt
        run: |
          actual="$(scripts/docs-hash.sh)"
          recorded="$(tr -d '[:space:]' < App/DocsHash.txt 2>/dev/null || true)"
          echo "docs_hash=$actual" >> "$GITHUB_OUTPUT"
          if [ "$actual" = "$recorded" ]; then
            echo "in_sync=true" >> "$GITHUB_OUTPUT"
          else
            echo "in_sync=false" >> "$GITHUB_OUTPUT"
            {
              echo "## Docs are ahead of the code — waiting for regeneration"
              echo ""
              echo "- Docs hash of \`docs/\`: \`$actual\`"
              echo "- \`App/DocsHash.txt\`: \`${recorded:-missing}\`"
            } >> "$GITHUB_STEP_SUMMARY"
          fi

  build:
    needs: [public-check, public-check-terms, docs-sync]
    if: ${{ !cancelled() && needs.docs-sync.result == 'success' && needs.docs-sync.outputs.in_sync == 'true' }}
    runs-on: xcode-27
    timeout-minutes: 60
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false
      - name: Test
        run: scripts/test.sh
      - name: Build iOS
        run: scripts/build.sh ios
      - name: Build macOS release
        env:
          BUILD_NUMBER: ${{ github.run_number }}
        run: scripts/build.sh macos-release
      - name: Package
        run: scripts/package-macos.sh
      - uses: actions/upload-artifact@v7
        with:
          name: Hephaestus-macOS
          path: build/Hephaestus-macOS.zip
          if-no-files-found: error
      - name: Release
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        env:
          GH_TOKEN: ${{ github.token }}
          DOCS_HASH: ${{ needs.docs-sync.outputs.docs_hash }}
        run: |
          printf 'Commit: %s\nDocs hash: %s\n' "$GITHUB_SHA" "$DOCS_HASH" > build/release-notes.md
          gh release create "build-$GITHUB_RUN_NUMBER" build/Hephaestus-macOS.zip \
            --target "$GITHUB_SHA" \
            --title "Hephaestus 1.0 ($GITHUB_RUN_NUMBER)" \
            --notes-file build/release-notes.md
```

| Job                  | Runner                                       | Runs when                                                                                                        | Does                                                                                                                                                                                                        |
|----------------------|----------------------------------------------|------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `public-check`       | `ubuntu-latest`                              | every event but the deletion of a branch or tag                                                                  | the personal data check with the generic rules ([Personal data check](#personal-data-check)); on findings it fails and writes the job summary "Personal data check failed" with the finding lines           |
| `public-check-terms` | `ubuntu-latest`, environment `private-terms` | a push to `main`                                                                                                 | the same check with the private terms of the environment's secret `PRIVATE_TERMS`; it fails when the secret is missing or holds no term                                                                     |
| `docs-sync`          | `ubuntu-latest`                              | both checks succeeded (`public-check-terms` may be skipped), on a push to `main`, a pull request or a manual run | sets `in_sync` (`true` when `scripts/docs-hash.sh` equals the trimmed `App/DocsHash.txt`) and `docs_hash`; when not in sync, writes the job summary "Docs are ahead of the code — waiting for regeneration" |
| `build`              | `xcode-27`                                   | `docs-sync` succeeded and `in_sync` is `true`                                                                    | tests, iOS build, macOS release build (build number = run number), zip, workflow artifact, and on a push to `main` the release                                                                              |

- When a check fails, `docs-sync` and `build` are skipped and the run fails: nothing is tested, built or
  released.
- When the docs are ahead of the code, `build` is skipped, not failed, and the run's conclusion is `success` with no
  release. The Forge only waits for runs of commits whose `App/DocsHash.txt` matches their docs
  ([pipeline.md](pipeline.md#mcp-tools)).
- The release: tag `build-<run number>` on the built commit, title `Hephaestus 1.0 (<run number>)`, one asset
  `Hephaestus-macOS.zip`, notes `Commit: <sha>` and `Docs hash: <hash>` on two lines. It is a normal release (not a
  draft, not a prerelease), so it is what `releases/latest` returns.
- Pull requests and manual runs test and build but never release. A push to another branch, or of a tag, runs the
  personal data check only.
- The release is created through the API with the job's token, and so is its tag `build-<N>`: what the job's token
  creates starts no workflow, so the tag is not checked as a pushed tag.
- Every job's token can only read (`permissions: contents: read`), except in `build`, which creates the release; every
  checkout drops the token afterwards (`persist-credentials: false`), so code that a job runs cannot push with the
  checkout's credentials. In `build`, the Release step holds the job's token, which can write the repository's
  contents, after the Test and Build steps ran the repository's code on the same runner: that code can change what the
  Release step runs ([../public-repository.md](../public-repository.md#limits)).
- `xcode-27` is GitHub's macOS 27 runner whose default Xcode is 27.1; nothing selects an Xcode version.
- Fallback, if GitHub removes the `xcode-27` label: this doc changes the `build` job to `runs-on: macos-26` with
  Xcode 26.6; the code must then build with that toolchain.

## Personal data check

The `public-check` and `public-check-terms` jobs run `scripts/check-public.sh`
([../public-repository.md](../public-repository.md#check-script)) on the checked-out commit and on the commits the run
is for. Their "Check for personal data" steps are the same.

- The checkout has the whole history and the tags (`fetch-depth: 0`) and keeps no credentials.
- `public-check` runs with the generic rules only: its first output line says that private terms were not checked.
- `public-check-terms` runs in the environment `private-terms`, whose deployment branch is `main` only
  ([../public-repository.md](../public-repository.md#private-terms)). "Write the private terms" is the only step that
  reads its secret `PRIVATE_TERMS`, in its `env:`; it writes it to `$RUNNER_TEMP/private-terms.txt`, an empty line
  when the secret is missing or empty. A workflow pushed on another branch cannot read the secret: the environment
  refuses every branch but `main`.
- "Check for personal data" sets `HEPHAESTUS_PRIVATE_TERMS` to that file when it exists. The values of the event reach
  the script through `env:`, never inside its text. In this order, every failure making the step fail:
  1. `scripts/check-public.sh` and the files of `.githooks/` are committed with mode `100755`
     (`git ls-tree -r HEAD`), else `scripts/check-public.sh and the files of .githooks/ must have mode 100755.`;
  2. on a push, the pushed ref is not a tag, else `Tags are created only by CI releases.`;
  3. `bash scripts/check-public.sh --tree HEAD`, after `--ref <pushed ref>` on a push, then `--commits` with the
     arguments below;
  4. the same two runs with the script of the base revision, written to `$RUNNER_TEMP/check-public-base.sh` with
     `git show`, when that script exists and differs from the checked-out one: a push or a pull request cannot weaken
     the check that judges it. The base is `<before>` on a push when it is a commit of the clone, the base commit of a
     pull request, else the newest `build-<N>` tag (`git tag --list 'build-*' --sort=-v:refname`);
  5. when `HEPHAESTUS_PRIVATE_TERMS` is set (in `public-check-terms`), no output line starts with `Note: `, which the
     script prints when the file holds no term, else `The secret PRIVATE_TERMS is missing or holds no private terms.`
- The step prints every output, and when it fails it writes the job summary `## Personal data check failed` followed
  by them, indented as a code block.

| Event               | `--commits` arguments                                                                                                                                                                                                                                                                    |
|---------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `push`              | `<before>..<sha>` when `git cat-file -e <before>^{commit}` succeeds; otherwise (a new branch or tag, or a force push whose old commit is not in the clone) `<sha> --not --exclude=<ref name> --tags='build-*'`: the commits of `<sha>` that no `build-<N>` tag has, the pushed tag aside |
| `pull_request`      | `<base sha>..<head sha>` of the pull request                                                                                                                                                                                                                                             |
| `workflow_dispatch` | none: `--tree HEAD` only                                                                                                                                                                                                                                                                 |

The other branches of `origin` are not excluded: one push can create several branches (`git push origin a b`,
`git push --all`), and each run would leave out the commits that the others bring, so that a commit adding personal
data and a later one removing it were checked by none. A `build-<N>` tag marks a commit that passed both checks before
its release. `--exclude=<ref name>` keeps a pushed tag named `build-<N>` from excluding its own commits. The step
itself, read from the workflow with a YAML parser, was run with git 2.54 on local repositories for a clean push, a push
replacing the script, a tag, a new branch, a new branch at a `build-<N>` tag, two new branches pushed at once, a
script of mode `100644`, a pull request, a manual run, and an empty secret, a secret without a term and a secret with
terms, not on Actions.

The finding lines carry no matched text and no private term ([../public-repository.md](../public-repository.md#output)),
so the log and the summary can be public.

## Public repository rules

The workflow, its logs and its releases are public. Every change to `.github/` keeps these rules, and is pushed by hand
after review ([../public-repository.md](../public-repository.md#protected-paths)):

- `PRIVATE_TERMS` is a secret of the environment `private-terms`, never a repository secret, and is read only in the
  `env:` of "Write the private terms" of `public-check-terms`. No step prints a secret or the environment.
- No workflow runs on `pull_request_target` or `workflow_run`: they run with the repository's secrets on behalf of
  code from outside it.
- Jobs run on GitHub-hosted runners only, never on self-hosted ones: a self-hosted runner would put its machine's
  paths and names in the public logs, and pull requests from forks could run code on it.
- Every job's token can only read, except in `build`, and no checkout keeps it.
- The workflow artifact and the release asset are `Hephaestus-macOS.zip` only. Release titles and notes hold only the
  run number, the commit SHA and the docs hash, never a commit message, a task title or feedback text.
- The Forge finds the check jobs by their names `public-check` and `public-check-terms`
  ([pipeline.md](pipeline.md#polling)): they have no `name:` key.

## scripts/build.sh

Exact content (mode `100755`):

```bash
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
```

| Target          | Configuration | Destination                | Signing                              | Product                                                    |
|-----------------|---------------|----------------------------|--------------------------------------|------------------------------------------------------------|
| `macos`         | Debug         | `generic/platform=macOS`   | ad-hoc (`CODE_SIGN_IDENTITY=-`)      | `build/DerivedData/Build/Products/Debug/Hephaestus.app`    |
| `macos-release` | Release       | `generic/platform=macOS`   | ad-hoc (`CODE_SIGN_IDENTITY=-`)      | `build/DerivedData/Build/Products/Release/Hephaestus.app`  |
| `ios`           | Debug         | `generic/platform=iOS`     | none (`CODE_SIGNING_ALLOWED=NO`)     | compile check only                                         |
| `all`           | —             | —                          | —                                    | `macos`, then `ios`, then `macos-release`                  |

- Every target uses `-project Hephaestus.xcodeproj -scheme Hephaestus`, derived data in `build/DerivedData` and
  `CURRENT_PROJECT_VERSION` = `BUILD_NUMBER` (default `0`). The app's `CFBundleVersion` is `$(CURRENT_PROJECT_VERSION)`
  ([../architecture.md](../architecture.md)), so local builds are build `0` and CI builds carry the run number.
- The script needs no signing identity and no team, so it runs the same in CI, on any Mac and in regeneration
  sessions. Installing on an iOS device is done from Xcode, with the team of `Config/Signing.local.xcconfig`
  ([../architecture.md](../architecture.md#configsigningxcconfig)).
- `-quiet` prints only warnings and errors. The exit code is `xcodebuild`'s.
- Outside CI (`CI` unset), in a git working tree whose `core.hooksPath` is not `.githooks` in its own configuration, the
  script stops with exit code 2 and `error: run git config core.hooksPath .githooks first
  (docs/public-repository.md)`, so that no clone works without the hooks
  ([../public-repository.md](../public-repository.md#setting-up-a-clone)). GitHub Actions sets `CI`; the Forge sets the
  hooks path of its source repository, which its sessions keep in the repository's configuration while their
  environment turns hooks off ([../claude/cli.md](../claude/cli.md#35-sessions-in-the-public-repository)).

## scripts/test.sh

Exact content (mode `100755`):

```bash
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
```

The scratch path keeps SwiftPM's build products under the ignored `build/` folder, so a test run leaves the working
tree clean (step 2 of the regeneration procedure depends on it). It refuses to run without the hooks path, as
`scripts/build.sh` does.

## scripts/package-macos.sh

Exact content (mode `100755`):

```bash
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
```

The archive holds `Hephaestus.app` at its top level; [update.md](update.md) unpacks it with `ditto -x -k`.

## Repository requirements

These belong to other docs and are listed here because CI and the procedure depend on them:

| Requirement                                                                                                                         | Defined in                                                                    |
|-------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------|
| `scripts/build.sh`, `scripts/test.sh`, `scripts/package-macos.sh` and `scripts/docs-hash.sh` are committed with mode `100755`       | this doc, [generation.md](generation.md)                                      |
| `.gitignore` ignores `build/`; nothing a build or test run writes outside `build/` is left untracked                                | [../architecture.md](../architecture.md)                                      |
| The shared scheme `Hephaestus` is committed; `CFBundleVersion` = `$(CURRENT_PROJECT_VERSION)`, `CFBundleShortVersionString` = `1.0` | [../architecture.md](../architecture.md)                                      |
| The `Package.resolved` files written by `xcodebuild` and `swift test` are committed                                                 | [../architecture.md](../architecture.md)                                      |
| `App/DocsHash.txt` exists and matches `docs/` at every regeneration commit                                                          | [generation.md](generation.md)                                                |
| `scripts/check-public.sh`, `.githooks/pre-commit`, `.githooks/commit-msg` and `.githooks/pre-push` are committed with mode `100755` | [../public-repository.md](../public-repository.md)                            |
| `scripts/check-public.sh --tree HEAD` is clean at every commit                                                                      | [../public-repository.md](../public-repository.md#examples-in-the-repository) |
| The secret `PRIVATE_TERMS` of the environment `private-terms`, whose only deployment branch is `main`, holds the private terms      | [../public-repository.md](../public-repository.md#private-terms)              |
| The project file has no `DEVELOPMENT_TEAM`; `Config/Signing.xcconfig` is committed, `Config/Signing.local.xcconfig` never is        | [../architecture.md](../architecture.md#configsigningxcconfig)                |
