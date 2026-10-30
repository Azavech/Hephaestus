# Public repository

files:
- scripts/check-public.sh
- .githooks/pre-commit
- .githooks/commit-msg
- .githooks/pre-push

---

The GitHub repository `Azavech/Hephaestus` is public. [general.md](general.md#public-repository-no-personal-data)
states the rule, defines personal data and gives the placeholders. This doc defines how the rule is enforced: the
personal data check `scripts/check-public.sh`, the git hooks that run it, the private terms, what the Forge, Claude's
sessions and CI do with them, the setup of a clone, the first publication, and what to do when personal data reached
GitHub. This doc and general.md are changed only by hand ([Protected paths](#protected-paths)).

## Layers

| Layer              | What                                                                                                                                                                                                                                    | Defined in                                                                                                     |
|--------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| Rule               | what personal data is, the placeholders, where personal data lives instead                                                                                                                                                              | [general.md](general.md#public-repository-no-personal-data)                                                    |
| Check script       | `scripts/check-public.sh`, the only implementation of the check, run by the layers below                                                                                                                                                | [Check script](#check-script)                                                                                  |
| Git hooks          | every `git commit`, its message and every push of a clone whose `core.hooksPath` is `.githooks`, in a checkout that holds that folder                                                                                                   | [Git hooks](#git-hooks)                                                                                        |
| Forge push gate    | Forge sessions never push: the Forge checks their commits, then pushes them                                                                                                                                                             | [Forge push gate](#forge-push-gate), [forge/pipeline.md](forge/pipeline.md)                                    |
| Claude permissions | the sessions working in the repository are denied `git push`, git settings and edits of the guardrail files; code a session runs, and a `project` or `task` session in `bypassPermissions`, can still get past this ([Limits](#limits)) | [Claude permissions](#claude-permissions), [claude/cli.md](claude/cli.md#35-sessions-in-the-public-repository) |
| Commit identity    | commits carry the user's own git identity, checked for private terms, and no signature                                                                                                                                                  | [Commit identity](#commit-identity)                                                                            |
| Private terms      | the user's own words (names, accounts, machines), refused in everything the check reads                                                                                                                                                 | [Private terms](#private-terms)                                                                                |
| CI                 | the `public-check` jobs run first, for every push and pull request that GitHub starts a run for; nothing is built or released without them                                                                                              | [CI](#ci), [forge/ci.md](forge/ci.md)                                                                          |
| Signing            | no team ID in the project file                                                                                                                                                                                                          | [Signing](#signing), [architecture.md](architecture.md#configsigningxcconfig)                                  |
| Protected paths    | the Forge push gate refuses changes to the guardrail; the user pushes them by hand after review                                                                                                                                         | [Protected paths](#protected-paths)                                                                            |

The layers do not depend on each other. `--no-verify` skips the hooks, not the Forge push gate or CI. A hand push that
skipped the hooks is caught by CI once it is on GitHub, and by the Forge when it reaches the branch the Forge follows
([forge/pipeline.md](forge/pipeline.md#checks-and-triggers)). The rule is repeated at the top of the root `README.md`
([architecture.md](architecture.md#readmemd)) and of [README.md](README.md), in the root `CLAUDE.md`
([forge/generation.md](forge/generation.md#3-claudemd)) and in the prompts of the sessions that work in the repository
([claude/prompts.md](claude/prompts.md#forge-common-part)).

## Check script

`scripts/check-public.sh` looks for personal data in what git holds or is about to record, and for the commit messages
that would make GitHub skip CI (`ci skip marker`). The hooks, the Forge push gate, the Forge's check of the commits
pushed outside it and CI run it; nothing else decides what personal data is.

- It needs bash 3.2 or later (macOS `/bin/bash` is 3.2, Linux has bash 5), git, and the POSIX tools `tr`, `wc`, `sed`,
  `sort`, `uniq`, `mktemp`, `rm` and `mkdir`: no perl, no python, no GNU-only flag.
- It runs from any folder of a working tree, moving to its top first, and does not depend on its own location: the
  Forge, the pre-push hook and CI also run copies of it taken from earlier commits.
- It writes nothing into the repository (no index, object or config). Its work files are in a temporary folder of
  `$TMPDIR`, removed when it exits.
- Its git commands run with color, pager, fsmonitor, split index, untracked cache, sparse checkout and submodule
  recursion turned off, and with `GIT_NO_REPLACE_OBJECTS=1`: a replace ref (`refs/replace/`, which `git replace`
  writes) would make them read another commit, tree or file than the one a push sends. Matching runs under `LC_ALL=C`
  with POSIX extended regular expressions.
- It reads no git attributes. The files it checks go into a temporary index of a temporary bare repository that
  borrows the repository's objects (`objects/info/alternates`), and its git commands there run with
  `GIT_ATTR_NOSYSTEM=1`, `core.attributesFile=/dev/null`, `attr.tree` set to the empty tree and no `GIT_ATTR_SOURCE`.
  No `.gitattributes`, `$GIT_DIR/info/attributes`, global or system attributes file can then make a binary file pass
  for text or hide a text file as binary.
- It is committed with mode `100755`. The hooks, the Forge and CI run it with `bash`, so it also works without its exec
  bit.

### Modes

| Arguments                | Checks                                                                                                                                                                    | Run by                                                                                                               |
|--------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| `--staged`               | the files the next commit adds, changes, type-changes or renames, as staged, compared with `HEAD` (the empty tree before the first commit); deleted files are not checked | pre-commit hook; Claude before committing ([forge/generation.md](forge/generation.md#2-procedure), root `CLAUDE.md`) |
| `--message <file>`       | the commit message in `<file>`: every line of a message git does not edit, else its lines up to the scissors line, comment lines aside                                    | commit-msg hook                                                                                                      |
| `--commits <arguments>…` | every commit of `git rev-list --reverse <arguments>`, oldest first: the files it brings, its message and its headers                                                      | pre-push hook, Forge push gate, Forge, CI                                                                            |
| `--tree <rev>`           | every entry of `git ls-tree -r <rev>`                                                                                                                                     | CI; before the first publication                                                                                     |
| `--ref <name>`           | a ref name; repeatable, alone or before a mode: `--ref refs/heads/x --commits A..B` gives one summary for both                                                            | pre-push hook, Forge push gate, CI                                                                                   |

- `--staged` reads the index git gives the hook (`GIT_INDEX_FILE`), so `git commit -a`, `git commit <path>` and commits
  in a linked worktree are checked as they will be committed.
- `--message` checks every line when `GIT_EDITOR` is `:`, which git sets for the hook when it does not edit the
  message (`-m`, `-F`, `--no-edit`; tried with git 2.54): git then keeps comment lines and the lines after a scissors
  line, unless `--cleanup` or `commit.cleanup` says otherwise. For an edited message, whose comment lines git removes,
  it stops at the scissors line, a line that is exactly `<c> ------------------------ >8 ------------------------`,
  and skips the lines starting with the comment string `<c>`: `core.commentString`, else `core.commentChar` unless it
  is `auto`, else `#` ([Limits](#limits)).
- `--commits` passes every argument after it to `git rev-list`: one range (`A..B`) or several arguments
  (`B --not --remotes=origin`). It comes last. The files a commit brings are those of `git diff-tree -c --root -r`:
  every file of a root commit, the files a commit with one parent adds or changes, and for a merge the files that differ
  from every parent (what the merge itself brings: the merged commits are in the range or already on the remote). Its
  message is the raw text after the commit's headers.
- With `--staged` and `--commits`, a file is checked whole, as staged or at that commit, not only its changed lines: a
  commit that touches a file holding personal data is refused until the file is fixed.
- Files go into the temporary index, symbolic links as files so that their target is searched. `git grep --cached`
  searches it once per expression, and `git diff-index --cached --numstat` against the empty tree finds the binary
  files. Paths, messages and names are written to temporary files searched with `git grep --no-index`. The allowlists
  run in bash on the matched text, which is never printed. Case collisions are found with `sort` and `uniq` on the
  lowercased paths and folders of the tree (`git ls-files` for `--staged`, `git ls-tree` otherwise).

### Rules

Each finding names its rule exactly as written here.

| Rule                | Finds                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Allowed                                                                                                                                                                                                                                                                                                                                                                                      |
|---------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `home path`         | a home folder: `/Users/` or `/home/` followed by a name, also JSON-escaped (`\/Users\/`), and `C:\Users\`, `C:\\Users\\` or `C:/Users/` followed by a name. A name starts with a letter, a digit or `_`, goes on with letters, digits, `_`, `.` or `-`, and does not end with `.` or `-`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | the names `user` and `runner`, and `Shared` under `Users`; placeholders in angle brackets (`/Users/<name>`), `$HOME` and `~` are never matched                                                                                                                                                                                                                                               |
| `encoded home path` | `-Users-` followed by a name, after a character that is not a letter or a digit, or at the start of a line; `-home-` followed by a name, after a character that is not a letter, a digit or `-` (so `--home-dir` is not one). The name is letters, digits and `_`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | the names of `home path`                                                                                                                                                                                                                                                                                                                                                                     |
| `e-mail address`    | `<local>@<labels>.<tld>` with a top-level domain of letters only, so `checkout@v7` and `pkg@1.2.3` are not addresses                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | in any case: addresses at `example.com`, `example.org`, `example.net`, their subdomains and any domain under `.example`; `*@users.noreply.github.com`; `noreply@github.com`; `noreply@anthropic.com` (Claude's co-author trailer); `git@github.com` (remote URLs); image names such as `icon@2x.png` (`@1x` to `@9x` followed by `.png`, `.jpg`, `.jpeg`, `.gif`, `.pdf`, `.svg` or `.heic`) |
| `signing identity`  | `<kind>: <holder> (<team>)`, where `<kind>` is Apple Development, Apple Distribution, Developer ID Application, Developer ID Installer, iPhone Developer, iPhone Distribution, Mac Developer, or 3rd Party Mac Developer Application or Installer, `<holder>` has no quote, parenthesis or angle bracket, and `<team>` is 10 characters A–Z or 0–9                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `Jane Appleseed (ABCDE12345)`                                                                                                                                                                                                                                                                                                                                                                |
| `team id`           | a word of 10 characters A–Z or 0–9 right after `team`, `team id`, `team_id`, `team-id`, `teamID`, `TeamIdentifier` or `team identifier`, in any case, so also after `DEVELOPMENT_TEAM`, `DevelopmentTeam` and `DEVELOPMENT_TEAM[sdk=…]`; only characters other than letters and digits stand between them (spaces, `=`, `:`, quotes, backticks, table pipes)                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | `ABCDE12345`                                                                                                                                                                                                                                                                                                                                                                                 |
| `secret`            | a token of a known form: GitHub (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`), Anthropic and OpenAI (`sk-`), AWS (`AKIA`, `ASIA`), Slack (`xoxb-` and the like), Google (`AIza`), Stripe (`sk_live_`, `rk_live_`), GitLab (`glpat-`), npm (`npm_`), JSON Web Tokens; a value of 16 or more characters given with `:` or `=` to a password, passwd, secret, token, API key, PSK, mesh key or pairing code, also at the end of a longer name (`accessToken`), quoted, or unquoted and followed by a space, a quote, a backtick, `;`, `&` or the end of the line (`PASSWORD=…`, `api_key: …`); a `token`, `key`, `secret`, `password`, `sig`, `signature` or `access_token` URL parameter of 16 or more characters; `Bearer` followed by 20 or more characters; a password in a URL (`<scheme>://<user>:<password>@`) | a value given to a name, a URL parameter or a `Bearer` value without both a digit and a letter (`ca.azavech.hephaestus.mesh` passes); a URL password holding `<`, `$`, `{` or `*` (`<token>`, `${GH_TOKEN}`, `***`)                                                                                                                                                                          |
| `private key`       | `-----BEGIN <type> PRIVATE KEY-----` for any type or none, the OpenPGP private key block, and PuTTY key files (`PuTTY-User-Key-File-<n>:`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | none                                                                                                                                                                                                                                                                                                                                                                                         |
| `lan address`       | an IPv4 address, public ones included: 4 numbers of 1 to 3 digits, each up to 255, not glued to a letter on the left (`1.2.3`, `v1.2.3.4` and longer runs are not addresses); a MAC address: 6 hex pairs separated by `:` or `-`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | `192.0.2.*`, `198.51.100.*`, `203.0.113.*` (RFC 5737), `127.0.0.1`, `0.0.0.0`, networks `a.b.c.d/n` with `n` up to 30 whose host bits are zero (`169.254.0.0/16`), a `/31` or `/32` being an address; the MAC addresses of zeros only, `ff:ff:ff:ff:ff:ff` and `00:00:5E:00:53:xx` (RFC 7042)                                                                                                |
| `hidden character`  | an invisible character, which can split a word so that no other rule sees it: the default ignorable code points of Unicode but the variation selectors U+FE00 to U+FE0F, which emoji carry, that is U+00AD, U+034F, U+061C, U+115F, U+1160, U+17B4, U+17B5, U+180B to U+180F, U+200B to U+200F, U+202A to U+202E, U+2060 to U+206F, U+3164, U+FEFF, U+FFA0, U+FFF0 to U+FFF8, U+1BCA0 to U+1BCA3, U+1D173 to U+1D17A and U+E0000 to U+E0FFF                                                                                                                                                                                                                                                                                                                                                                                  | U+FEFF (a byte order mark) at the very start of a file                                                                                                                                                                                                                                                                                                                                       |
| `private term`      | each private term ([Private terms](#private-terms)), as a whole word, and also right after an escape that glues it to a letter: `\n`, `\t` or `\r`, `\u` and 4 hex digits, `%` and 2 hex digits                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | none                                                                                                                                                                                                                                                                                                                                                                                         |
| `forbidden path`    | a folder `.hephaestus`, `.claude` or `xcuserdata` at any depth; a file named `CLAUDE.local.md`, `Signing.local.xcconfig`, `.env`, `.env.*` (`.env.example` too), `.DS_Store`, `.gitattributes`, `.mailmap`, `*.xcuserstate`, `*.p12`, `*.mobileprovision`, `*.provisionprofile`, `*.cer`, `*.pem` or `*.key` in any folder; names in any case                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | none: a force-added file is refused too                                                                                                                                                                                                                                                                                                                                                      |
| `symbolic link`     | an entry of mode `120000`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | none                                                                                                                                                                                                                                                                                                                                                                                         |
| `submodule`         | an entry of mode `160000` (a gitlink), and any `.gitmodules` file                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | none                                                                                                                                                                                                                                                                                                                                                                                         |
| `binary file`       | a file with a NUL byte in its first 8000 bytes, as git decides with no attributes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | the PNG files of the app icon, `App/Assets.xcassets/AppIcon.appiconset/icon-*.png` ([architecture.md](architecture.md#appicon))                                                                                                                                                                                                                                                              |
| `case collision`    | a path, or one of its folders, equal ignoring ASCII case to another path or folder of the same tree (the index for `--staged`, the commit's tree for `--commits`), a file `Notes` and a folder `notes/` too: on a case-insensitive disk, as on a Mac, one replaces the other                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | none                                                                                                                                                                                                                                                                                                                                                                                         |
| `ci skip marker`    | anywhere in a commit message, in any letter case: `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]`, `[actions skip]`, and `skip-checks`, `:` and `true` with or without white space around the `:` (the trailer `skip-checks: true`), the markers of GitHub's "Skipping workflow runs": GitHub starts no `push` or `pull_request` workflow run for a push whose commit message holds one, or for a pull request whose head commit does, so CI would not check them                                                                                                                                                                                                                                                                                                                                                      | none                                                                                                                                                                                                                                                                                                                                                                                         |
| `commit signature`  | a commit with a `gpgsig`, `gpgsig-sha256` or `mergetag` header: a signature names its key, which keyservers resolve to names and e-mail addresses, and a merged tag holds its tagger                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | none                                                                                                                                                                                                                                                                                                                                                                                         |

### Where the rules apply

| Checked                                  | Rules                                                                                                                                                                                   |
|------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| content of text files                    | the 10 text rules, `home path` to `private term`                                                                                                                                        |
| content of binary files                  | `private term` (as a whole word)                                                                                                                                                        |
| target of a symbolic link                | the 10 text rules, reported at `<path>:1`                                                                                                                                               |
| file paths                               | the 10 text rules, `forbidden path`, `symbolic link`, `submodule`, `binary file`, `case collision`                                                                                      |
| commit messages and the `--message` file | the 10 text rules, `ci skip marker`                                                                                                                                                     |
| author and committer names and e-mails   | `private term`                                                                                                                                                                          |
| commit headers                           | `commit signature` in `gpgsig`, `gpgsig-sha256` and `mergetag`; the 10 text rules in every other header but `tree`, `parent`, `author` and `committer`, its continuation lines included |
| ref names (`--ref`)                      | `private term`                                                                                                                                                                          |

### Output

| Finding                                                         | Line                                                                                                                                                                                                           |
|-----------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| in the content of a file                                        | `<path>:<line>: <rule>`                                                                                                                                                                                        |
| a path rule, a structural rule, a private term in a binary file | `<path>: <rule>`                                                                                                                                                                                               |
| in the `--message` file                                         | `message: <rule>`, one line per rule                                                                                                                                                                           |
| in a ref name                                                   | `ref <name>: <rule>`                                                                                                                                                                                           |
| with `--commits`                                                | the forms above after `<sha8> ` (the first 8 characters of the commit), and `<sha8> message: <rule>`, `<sha8> author: <rule>`, `<sha8> committer: <rule>`, `<sha8> header: <rule>`, `<sha8> signature: <rule>` |

- A line equal to the line printed just before it is not printed again.
- The matched text is never printed, and neither is a private term. In printed names (paths and ref names), every part
  that matched a rule and every occurrence of a private term, even inside a longer word, is replaced by `***`, and
  control characters by `?`: a file `docs/<term>-notes.md` is printed `docs/***-notes.md`.
- Without private terms, the first line is `Note: no private terms file; private terms were not checked.`, or
  `Note: the private terms file holds no terms; private terms were not checked.` when the file holds no usable term.
- The last line is `Personal data check: <n> finding(s).` or `Personal data check: clean.`.
- Exit status: `0` clean, `1` findings, `2` usage or git error. On `2` it prints `check-public.sh: <reason>` on stderr.
  git's own messages are dropped, because they can quote a path or an argument: to see why git failed, run the git
  command by hand.

### scripts/check-public.sh

Exact content (mode `100755`):

```bash
#!/bin/bash
# Personal data check of the public repository. Rules, modes and output: docs/public-repository.md.
#
#   scripts/check-public.sh --staged                   the files staged for the next commit (pre-commit hook)
#   scripts/check-public.sh --message <file>           a commit message, comment lines of an edited one ignored
#                                                      (commit-msg hook)
#   scripts/check-public.sh --commits <rev-list args>  every commit of `git rev-list --reverse <args>`: the files it
#                                                      adds or changes, its message and its headers
#                                                      (pre-push hook, Forge, CI)
#   scripts/check-public.sh --tree <rev>               every file of <rev> (CI)
#   --ref <name>                                       a ref name, alone or before a mode, repeatable (pre-push hook)
#
# Prints one line per finding, "<where>: <rule>", then "Personal data check: <n> finding(s)." or "Personal data
# check: clean.". Never prints the matched text or a private term. Exit status: 0 clean, 1 findings, 2 usage or git
# error. bash 3.2 or later, git and POSIX tools only.
set -uo pipefail
export LC_ALL=C
# git reads the objects themselves, as a push sends them, never their replacements (refs/replace/, git replace)
export GIT_NO_REPLACE_OBJECTS=1

die() { printf 'check-public.sh: %s\n' "$*" >&2; exit 2; }
usage() {
  die 'usage: check-public.sh [--ref <name>]...' \
    '[--staged | --message <file> | --tree <rev> | --commits <rev-list arguments>...]'
}

# git without the user settings that change its output or write into the repository. Its messages are dropped:
# they can quote a path or an argument, and CI logs are public.
g() {
  git -c color.ui=false -c core.fsmonitor=false -c core.splitIndex=false -c core.untrackedCache=false \
    -c core.sparseCheckout=false -c index.sparse=false -c submodule.recurse=false --no-pager "$@" 2>/dev/null
}

mode='' msg='' rev='' refs=() range=()
while [ $# -gt 0 ]; do
  case $1 in
    --ref) [ $# -ge 2 ] || usage; refs+=("$2"); shift 2 ;;
    --staged) [ -z "$mode" ] || usage; mode=staged; shift ;;
    --message) [ -z "$mode" ] && [ $# -ge 2 ] || usage; mode=message; msg=$2; shift 2 ;;
    --tree) [ -z "$mode" ] && [ $# -ge 2 ] || usage; mode=tree; rev=$2; shift 2 ;;
    --commits) [ -z "$mode" ] && [ $# -ge 2 ] || usage; mode=commits; shift; range=("$@"); break ;;
    *) usage ;;
  esac
done
[ -n "$mode" ] || [ ${#refs[@]} -gt 0 ] || usage

# Relative paths given by the caller are resolved before moving to the top of the working tree.
if [ "$mode" = message ]; then
  case $msg in /*) ;; *) msg=$PWD/$msg ;; esac
  [ -f "$msg" ] && [ -r "$msg" ] || die 'cannot read the message file.'
fi
case ${GIT_INDEX_FILE:-} in '' | /*) ;; *) GIT_INDEX_FILE=$PWD/$GIT_INDEX_FILE ;; esac
top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] && cd "$top" || die 'not inside a git working tree.'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-public.XXXXXX") || die 'cannot create a temporary directory.'
trap 'rm -rf "$tmp"' EXIT
trap 'exit 2' HUP INT TERM
mkdir "$tmp/v" || die 'cannot create a temporary directory.'
empty_tree=$(g hash-object -t tree /dev/null) || die 'git hash-object failed.'

# The files of a check go into a temporary index, in a temporary bare repository that borrows the objects of this one.
# git reads no attributes there (no work tree, no info/attributes, no global, system or tree source): an attribute can
# neither make a binary file pass for text nor hide a text file as binary.
objects=$(cd "$(g rev-parse --git-path objects)" 2>/dev/null && pwd -P) || die 'cannot find the object directory.'
format=()
[ ${#empty_tree} -eq 64 ] && format=(--object-format=sha256)
(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  g init -q --bare --template= ${format[@]+"${format[@]}"} "$tmp/repo"
) || die 'git init failed.'
printf '%s\n' "$objects" >"$tmp/repo/objects/info/alternates" || die 'cannot write the alternates file.'
ig() { # git on that index and repository
  (
    unset GIT_WORK_TREE GIT_COMMON_DIR GIT_ATTR_SOURCE
    export GIT_DIR=$tmp/repo GIT_INDEX_FILE=$tmp/index GIT_ATTR_NOSYSTEM=1
    g -c core.attributesFile=/dev/null -c attr.tree="$empty_tree" "$@"
  )
}

# ---- Private terms: HEPHAESTUS_PRIVATE_TERMS, else the Application Support file when it exists. UTF-8, one term per
# line, trimmed; empty lines, lines starting with # and terms shorter than 3 characters are skipped.
terms=${HEPHAESTUS_PRIVATE_TERMS:-}
if [ -n "$terms" ]; then
  [ -f "$terms" ] && [ -r "$terms" ] || die 'HEPHAESTUS_PRIVATE_TERMS does not name a readable file.'
elif [ -n "${HOME:-}" ] && [ -f "$HOME/Library/Application Support/Hephaestus/private-terms.txt" ]; then
  terms="$HOME/Library/Application Support/Hephaestus/private-terms.txt"
  [ -r "$terms" ] || die 'the private terms file is not readable.'
fi
nterms=0
: >"$tmp/terms"
if [ -n "$terms" ]; then
  bom=$'\xef\xbb\xbf'
  while IFS= read -r t || [ -n "$t" ]; do
    t=${t#"$bom"}
    t=${t#"${t%%[![:space:]]*}"}
    t=${t%"${t##*[![:space:]]}"}
    case $t in '' | '#'*) continue ;; esac
    n=$(printf '%s' "$t" | tr -d '\200-\277' | wc -c) # characters: UTF-8 continuation bytes not counted
    [ $((n)) -ge 3 ] || continue
    printf '%s\n' "$t" >>"$tmp/terms"
    nterms=$((nterms + 1))
  done <"$terms"
fi
if [ $nterms -eq 0 ]; then
  if [ -z "$terms" ]; then
    echo 'Note: no private terms file; private terms were not checked.'
  else
    echo 'Note: the private terms file holds no terms; private terms were not checked.'
  fi
fi

# ---- Rules: name, extended regular expression (git grep -E), allowlist function (succeeds for an allowed match).
# A rule can have several expressions. any <ERE>...: the alternation of its arguments.
R_NAME=() R_RE=() R_ALLOW=()
rule() { R_NAME+=("$1"); R_RE+=("$2"); R_ALLOW+=("$3"); }
any() { local IFS='|'; printf '%s' "$*"; }

# /Users/<name>, /home/<name>, JSON-escaped \/Users\/<name>, C:\Users\<name>, C:/Users/<name>
home_name='[A-Za-z0-9_]([A-Za-z0-9_.-]*[A-Za-z0-9_])?'
rule 'home path' "($(any '\\?/(Users|home)\\?/' '[A-Za-z]:(\\\\?|/)[Uu]sers(\\\\?|/)'))$home_name" allow_home
# Claude's encoded project folders: -Users-<name>-…, -home-<name>-…
rule 'encoded home path' "$(any '(^|[^A-Za-z0-9])-Users-[A-Za-z0-9_]+' '(^|[^A-Za-z0-9-])-home-[A-Za-z0-9_]+')" \
  allow_encoded
rule 'e-mail address' '[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}' allow_mail
kind=$(any 'Apple (Development|Distribution)' 'Developer ID (Application|Installer)' 'iPhone (Developer|Distribution)' \
  'Mac Developer' '3rd Party Mac Developer (Application|Installer)')
rule 'signing identity' "($kind): [^\"'()<>]+ \\([A-Z0-9]{10}\\)" allow_identity
# a 10-character team id as the next word after DEVELOPMENT_TEAM, DevelopmentTeam, teamID, TeamIdentifier, team id…
team='[Tt][Ee][Aa][Mm]([ _-]?[Ii][Dd]([Ee][Nn][Tt][Ii][Ff][Ii][Ee][Rr])?)?'
rule 'team id' "$team"'(\[[^]]*\])?[^A-Za-z0-9]+[A-Z0-9]{10}([^A-Za-z0-9]|$)' allow_team
# tokens and keys with a known form: GitHub, Anthropic and OpenAI, AWS, Slack, Google, Stripe, GitLab, npm, JWT
rule 'secret' "$(any 'gh[pousr]_[A-Za-z0-9]{36,}' 'github_pat_[A-Za-z0-9_]{22,}' \
  '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}' '(AKIA|ASIA)[A-Z0-9]{16}' 'xox[abposr]-[A-Za-z0-9-]{10,}' \
  'AIza[A-Za-z0-9_-]{35}' '[rs]k_live_[A-Za-z0-9]{20,}' 'glpat-[A-Za-z0-9_-]{20,}' 'npm_[A-Za-z0-9]{36}' \
  'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}')" allow_none
# a value of 16+ characters given with : or = to a password, secret, token, API key, PSK, mesh key or pairing code:
# quoted, or unquoted and followed by a space, a quote, a backtick, ; or & or the end of the line
key=$(any '[Pp]assword|PASSWORD|[Pp]asswd|PASSWD' '[Ss]ecret|SECRET' '[Tt]oken|TOKEN' '[Aa]pi[_-]?[Kk]ey|API[_-]?KEY' \
  '[Pp]sk|PSK' '[Mm]esh[_-]?[Kk]ey|MESH[_-]?KEY' '[Pp]airing[_-]?[Cc]ode|PAIRING[_-]?CODE')
value='[A-Za-z0-9+/=_.-]{16,}'
rule 'secret' "($key)[\"']?[[:space:]]*[:=][[:space:]]*([\"']$value[\"']|$value([[:space:]\"'\`;&]|\$))" allow_value
# a token of 16+ characters in a URL query
rule 'secret' '[?&]([Aa]ccess_?)?([Tt]oken|[Kk]ey|[Ss]ecret|[Pp]assword|[Ss]ig|[Ss]ignature)=[A-Za-z0-9._~%+/-]{16,}' \
  allow_assigned
rule 'secret' '[Bb]earer[[:space:]]+[A-Za-z0-9._~+/-]{20,}=*' allow_bearer
# a password in a URL: <scheme>://<user>:<password>@
rule 'secret' '[A-Za-z][A-Za-z0-9+.-]*://[^/:@[:space:]]+:[^/@[:space:]]+@' allow_url
rule 'private key' "$(any '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----' 'PuTTY-User-Key-File-[0-9]+:')" allow_none
# IPv4 addresses (runs of 4+ dotted numbers, with a /prefix; the allowlist drops versions) and MAC addresses
rule 'lan address' '[A-Za-z]?[0-9]+(\.[0-9]+){3,}(/[0-9]+)?' allow_ipv4
rule 'lan address' '[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}' allow_mac
# invisible characters, which can split a word so that no rule sees it: Unicode's default ignorable code points but the
# variation selectors U+FE00 to U+FE0F, which emoji carry (a byte order mark is allowed at the start of a file)
hidden=$(any $'\xc2\xad' $'\xcd\x8f' $'\xd8\x9c' $'\xe1\x85[\x9f\xa0]' $'\xe1\x9e[\xb4\xb5]' $'\xe1\xa0[\x8b-\x8f]' \
  $'\xe2\x80[\x8b-\x8f\xaa-\xae]' $'\xe2\x81[\xa0-\xaf]' $'\xe3\x85\xa4' $'\xef\xbb\xbf' $'\xef\xbe\xa0' \
  $'\xef\xbf[\xb0-\xb8]' $'\xf0\x9b\xb2[\xa0-\xa3]' $'\xf0\x9d\x85[\xb3-\xba]' $'\xf3\xa0[\x80-\xbf][\x80-\xbf]')
rule 'hidden character' "(^|.)($hidden)" allow_bom
terms_rule=${#R_NAME[@]} # the private term rules, last; with no terms, past the last rule
if [ $nterms -gt 0 ]; then
  rule 'private term' TERMS allow_none
  # a term right after an escape (\n, \t, \r, \uXXXX, %XX), where it is not a whole word
  terms_re=$(sed -e 's/\\/\\\\/g' -e 's/[].[^$*+?(){}|]/\\&/g' "$tmp/terms" | tr '\n' '|')
  terms_re="(\\\\[ntr]|\\\\u[0-9A-Fa-f]{4}|%[0-9A-Fa-f]{2})(${terms_re%|})([^A-Za-z0-9_]|\$)"
  rule 'private term' ESCAPED_TERMS allow_none
fi
# CI skip markers, in commit messages only and in any case: GitHub starts no workflow run for a push or a pull request
# whose commit message holds one (docs.github.com, "Skipping workflow runs"), so CI would not check it
skip_re=$(any '\[(skip ci|ci skip|no ci|skip actions|actions skip)]' 'skip-checks[[:space:]]*:[[:space:]]*true')

allow_none() { return 1; }
allowed_home() { # allowed_home <name> <match>: user, runner, and Shared under Users
  case $1 in user | runner) return 0 ;; Shared) case $2 in *[Uu]sers*) return 0 ;; esac ;; esac
  return 1
}
allow_home() { allowed_home "${1##*[/\\]}" "$1"; }
allow_encoded() {
  local name=${1##*-Users-}
  [ "$name" = "$1" ] && name=${1##*-home-}
  allowed_home "$name" "$1"
}
allow_mail() { # example domains, GitHub no-reply addresses, Claude's co-author trailer, git remote URLs, @2x images
  local r=1
  shopt -s nocasematch
  case $1 in
    *@example.com | *@example.org | *@example.net | *.example.com | *.example.org | *.example.net | *.example) r=0 ;;
    *@users.noreply.github.com | noreply@github.com | noreply@anthropic.com | git@github.com) r=0 ;;
    *@[1-9]x.png | *@[1-9]x.jpg | *@[1-9]x.jpeg | *@[1-9]x.gif | *@[1-9]x.pdf | *@[1-9]x.svg | *@[1-9]x.heic) r=0 ;;
  esac
  shopt -u nocasematch
  return $r
}
allow_identity() { [ "${1#*: }" = 'Jane Appleseed (ABCDE12345)' ]; }
allow_team() { local m=${1%[!A-Za-z0-9]}; [ "${m:${#m}-10}" = ABCDE12345 ]; }
generated() { case $1 in *[0-9]*) case $1 in *[A-Za-z]*) return 0 ;; esac ;; esac; return 1; }
allow_value() { # the value after the first : or =, its spaces and its opening quote
  local v=${1#*[:=]}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v#[\"\']}
  ! generated "${v%%[!A-Za-z0-9+/=_.-]*}"
}
allow_assigned() { ! generated "${1#*=}"; }
allow_bearer() { ! generated "${1##*[[:space:]]}"; }
allow_url() { local p=${1%@}; p=${p##*:}; case $p in *[\<\$\{\*]*) return 0 ;; esac; return 1; }
allow_ipv4() { # an address is 4 numbers up to 255; allowed: RFC 5737 ranges, 127.0.0.1, 0.0.0.0, networks a.b.c.d/n
  case $1 in [A-Za-z]*) return 0 ;; esac # v1.2.3.4 is a version
  local addr=${1%%/*} len=${1#*/} rest n=0 o ip=0
  rest=$addr
  while :; do
    o=${rest%%.*}
    case $o in ???? | ????*) return 0 ;; esac
    [ $((10#$o)) -le 255 ] || return 0
    ip=$((ip * 256 + 10#$o))
    n=$((n + 1))
    [ "$o" = "$rest" ] && break
    rest=${rest#*.}
  done
  [ $n -eq 4 ] || return 0
  case $addr in 127.0.0.1 | 0.0.0.0 | 192.0.2.* | 198.51.100.* | 203.0.113.*) return 0 ;; esac
  case $1 in */?*) # a network: prefix length up to 30 and no host bits (a /31 or /32 is an address)
    case $len in ???*) return 1 ;; esac
    [ $((10#$len)) -le 30 ] && [ $((ip & ((1 << (32 - 10#$len)) - 1))) -eq 0 ] && return 0 ;;
  esac
  return 1
}
allow_mac() { # all zeros, broadcast and the RFC 7042 documentation range 00:00:5E:00:53:xx
  local r=1
  shopt -s nocasematch
  case $1 in 00?00?00?00?00?00 | ff?ff?ff?ff?ff?ff | 00?00?5e?00?53???) r=0 ;; esac
  shopt -u nocasematch
  return $r
}
allow_bom() { [ "$1" = $'\xef\xbb\xbf' ] && [ "${2:-}" = 1 ]; } # allow_bom <match> <line>: at the start of a file

# The pattern arguments of git grep for rule $1, in P.
pattern() {
  case ${R_RE[$1]} in
    TERMS) P=(-i -w -F -f "$tmp/terms") ;;
    ESCAPED_TERMS) P=(-i -E -e "$terms_re") ;;
    *) P=(-E -e "${R_RE[$1]}") ;;
  esac
}

# ---- Findings
count=0 last=''
report() { # report <where> <rule>; a repeated line is printed once
  [ "$1: $2" = "$last" ] && return
  last="$1: $2"
  count=$((count + 1))
  printf '%s\n' "$last"
}
# Names as printed: control characters replaced, the parts that matched a rule masked with ***.
M_KEY=() M_SHOW=()
mask() { # mask <name> <matched text>
  local s=${1//[[:cntrl:]]/?} k=0
  while [ $k -lt ${#M_KEY[@]} ]; do
    if [ "${M_KEY[k]}" = "$s" ]; then M_SHOW[k]=${M_SHOW[k]//"$2"/***}; return; fi
    k=$((k + 1))
  done
  M_KEY+=("$s")
  M_SHOW+=("${s//"$2"/***}")
}
shown() { # shown <name>: sets S
  local k=0
  S=${1//[[:cntrl:]]/?}
  while [ $k -lt ${#M_KEY[@]} ]; do
    if [ "${M_KEY[k]}" = "$S" ]; then S=${M_SHOW[k]}; return; fi
    k=$((k + 1))
  done
}

# ---- Text checks. scan_texts <first rule> <files of $tmp/v>...: the rules from <first rule> to the last one (0: every
# rule; $terms_rule: the private terms only). "paths" holds one checked path per line, in entry order, and "ref" a ref
# name: their findings are recorded (PF, PF_RULE, REF_RULE) and printed once every match is masked. Findings in
# "message", "author" and "committer" are reported at once.
scan_texts() {
  local i=$1 file lno text rc
  shift
  while [ "$i" -lt ${#R_NAME[@]} ]; do
    pattern "$i"
    (
      unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
      cd "$tmp/v" && g grep --no-index -a -n -o -z --no-color --no-column "${P[@]}" -- "$@"
    ) >"$tmp/out"
    rc=$?
    [ $rc -le 1 ] || die 'git grep failed.'
    while IFS= read -r -d '' file && IFS= read -r -d '' lno && IFS= read -r text; do
      "${R_ALLOW[i]}" "$text" && continue
      case $file in
        paths) mask "${E_PATH[lno - 1]}" "$text"; PF+=("$((lno - 1))"); PF_RULE+=("${R_NAME[i]}") ;;
        ref) mask "$REF" "$text"; REF_RULE+=("${R_NAME[i]}") ;;
        *) report "$prefix$file" "${R_NAME[i]}" ;;
      esac
    done <"$tmp/out"
    i=$((i + 1))
  done
}
# mask_terms <paths | ref>: masks every piece of the names that is a private term, even inside a word
mask_terms() {
  local file lno text rc
  [ $nterms -gt 0 ] || return 0
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    cd "$tmp/v" && g grep --no-index -a -n -o -z --no-color --no-column -i -F -f "$tmp/terms" -- "$1"
  ) >"$tmp/out"
  rc=$?
  [ $rc -le 1 ] || die 'git grep failed.'
  while IFS= read -r -d '' file && IFS= read -r -d '' lno && IFS= read -r text; do
    if [ "$file" = paths ]; then mask "${E_PATH[lno - 1]}" "$text"; else mask "$REF" "$text"; fi
  done <"$tmp/out"
}

# ---- File checks. Entries: NUL-terminated "<mode> <sha>\t<path>" records in $tmp/entries.
raw_entries() { # raw diff (-z) on stdin → entries of the files present after the change
  local meta path colons np f
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    colons=${meta%%[!:]*}
    np=${#colons}
    f=(${meta#"$colons"})
    [ "${f[np]}" = 000000 ] && continue
    printf '%s %s\t%s\0' "${f[np]}" "${f[2 * np + 1]}" "$path"
  done
}
forbidden() {
  local r=1
  shopt -s nocasematch
  case /$1 in
    */.hephaestus/* | */.claude/* | */xcuserdata/* | */CLAUDE.local.md | *.xcuserstate) r=0 ;;
    */Signing.local.xcconfig) r=0 ;;
    */.env | */.env.* | *.p12 | *.mobileprovision | *.provisionprofile | *.cer | *.pem | *.key | */.DS_Store) r=0 ;;
    */.gitattributes | */.mailmap) r=0 ;;
  esac
  shopt -u nocasematch
  return $r
}
icon() { # the PNG files of the app icon (docs/architecture.md), the only binary files allowed
  case $1 in
    App/Assets.xcassets/AppIcon.appiconset/*/*) return 1 ;;
    App/Assets.xcassets/AppIcon.appiconset/icon-*.png) return 0 ;;
  esac
  return 1
}
# The entries whose path, or one of its folders, equals ignoring ASCII case another path or folder of their tree, a file
# and a folder included: on a case-insensitive disk one replaces the other. $tmp/tree: the NUL-terminated paths of that
# tree.
case_collisions() {
  local p q k=0 dups
  while IFS= read -r -d '' p; do
    p=${p//[[:cntrl:]]/?}
    printf '%s\n' "$p"
    while [ "${p%/*}" != "$p" ]; do p=${p%/*}; printf '%s\n' "$p"; done
  done <"$tmp/tree" | sort -u | tr 'A-Z' 'a-z' | sort | uniq -d >"$tmp/dups"
  [ -s "$tmp/dups" ] || return 0
  dups=$'\n'$(cat "$tmp/dups")$'\n'
  tr 'A-Z' 'a-z' <"$tmp/v/paths" >"$tmp/lower"
  while IFS= read -r p; do
    q=$p
    while :; do
      case $dups in *$'\n'"$q"$'\n'*) shown "${E_PATH[k]}"; report "$prefix$S" 'case collision'; break ;; esac
      case $p in */*) p=${p%/*}; q=$p ;; *) break ;; esac
    done
    k=$((k + 1))
  done <"$tmp/lower"
}
check_entries() { # check_entries <more files of $tmp/v>...: the entries, their paths, and the given texts
  local rec p k rc file lno text blobs=0
  E_MODE=() E_SHA=() E_PATH=() PF=() PF_RULE=() M_KEY=() M_SHOW=() B=()
  while IFS= read -r -d '' rec; do
    E_MODE+=("${rec%% *}")
    rec=${rec#* }
    E_SHA+=("${rec%%$'\t'*}")
    p=${rec#*$'\t'}
    E_PATH+=("$p")
    printf '%s\n' "${p//[[:cntrl:]]/?}"
  done <"$tmp/entries" >"$tmp/v/paths"

  # Files go into the temporary index: git grep searches it, git diff-index finds its binary files. A symbolic link
  # goes in as a file, so that its target is searched too (git grep skips links).
  rm -f "$tmp/index"
  k=0
  while [ $k -lt ${#E_PATH[@]} ]; do
    case ${E_MODE[k]} in 100* | 120000) printf '100644 %s\t%s\0' "${E_SHA[k]}" "${E_PATH[k]}"; blobs=1 ;; esac
    k=$((k + 1))
  done >"$tmp/index-info"
  if [ $blobs -eq 1 ]; then
    ig update-index -z --index-info <"$tmp/index-info" || die 'git update-index failed.'
  fi

  scan_texts 0 paths "$@"
  mask_terms paths
  k=0
  while [ $k -lt ${#PF[@]} ]; do
    shown "${E_PATH[PF[k]]}"
    report "$prefix$S" "${PF_RULE[k]}"
    k=$((k + 1))
  done
  k=0
  while [ $k -lt ${#E_PATH[@]} ]; do
    p=${E_PATH[k]}
    shown "$p"
    forbidden "$p" && report "$prefix$S" 'forbidden path'
    case ${E_MODE[k]} in 120000) report "$prefix$S" 'symbolic link' ;; 160000) report "$prefix$S" 'submodule' ;; esac
    case /$p in */.gitmodules) report "$prefix$S" 'submodule' ;; esac
    k=$((k + 1))
  done
  case_collisions
  [ $blobs -eq 1 ] || return 0

  ig diff-index --cached --numstat -z "$empty_tree" >"$tmp/numstat" ||
    die 'git diff-index failed.'
  while IFS= read -r -d '' rec; do
    case $rec in -$'\t'-$'\t'*) B+=("${rec#-$'\t'-$'\t'}") ;; esac
  done <"$tmp/numstat"
  k=0
  while [ $k -lt ${#B[@]} ]; do
    icon "${B[k]}" || { shown "${B[k]}"; report "$prefix$S" 'binary file'; }
    k=$((k + 1))
  done
  if [ $nterms -gt 0 ] && [ ${#B[@]} -gt 0 ]; then
    ig --literal-pathspecs grep --cached -l -z -i -w -F -f "$tmp/terms" -- "${B[@]}" \
      >"$tmp/out"
    rc=$?
    [ $rc -le 1 ] || die 'git grep failed.'
    while IFS= read -r -d '' file; do
      shown "$file"
      report "$prefix$S" 'private term'
    done <"$tmp/out"
  fi

  for k in "${!R_NAME[@]}"; do
    pattern "$k"
    ig grep --cached -I -n -o -z --no-color --no-column "${P[@]}" >"$tmp/out"
    rc=$?
    [ $rc -le 1 ] || die 'git grep failed.'
    while IFS= read -r -d '' file && IFS= read -r -d '' lno && IFS= read -r text; do
      "${R_ALLOW[k]}" "$text" "$lno" && continue
      shown "$file"
      report "$prefix$S:$lno" "${R_NAME[k]}"
    done <"$tmp/out"
  done
}

check_ref() {
  REF=$1 REF_RULE=() M_KEY=() M_SHOW=() prefix=''
  printf '%s\n' "$REF" >"$tmp/v/ref"
  scan_texts "$terms_rule" ref
  mask_terms ref
  local k=0
  shown "$REF"
  while [ $k -lt ${#REF_RULE[@]} ]; do
    report "ref $S" "${REF_RULE[k]}"
    k=$((k + 1))
  done
}

# skip_markers: reports a CI skip marker in the file "message" of $tmp/v
skip_markers() {
  local rc
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    cd "$tmp/v" && g grep --no-index -a -q -i -E -e "$skip_re" -- message
  )
  rc=$?
  [ $rc -le 1 ] || die 'git grep failed.'
  [ $rc -eq 1 ] || report "${prefix}message" 'ci skip marker'
}

check_commit() {
  local c=$1 line l e h='' signed=0
  prefix="${c:0:8} "
  g cat-file commit "$c" >"$tmp/commit" || die 'git cat-file failed.'
  : >"$tmp/v/author"
  : >"$tmp/v/committer"
  : >"$tmp/v/header"
  while IFS= read -r line && [ -n "$line" ]; do
    case $line in
      'tree '* | 'parent '*) h=tree ;;
      'author '* | 'committer '*)
        h=${line%% *} l=${line#* } e=${line#*<}
        printf '%s\n%s\n' "${l%% <*}" "${e%%>*}" >>"$tmp/v/$h"
        ;;
      # a signature names its key, a merged tag its tagger
      'gpgsig '* | 'gpgsig-sha256 '* | 'mergetag '*) h=signature signed=1 ;;
      ' '*) [ "$h" = signature ] || printf '%s\n' "$line" >>"$tmp/v/header" ;; # the next line of a header
      *) h=header; printf '%s\n' "$line" >>"$tmp/v/header" ;;
    esac
  done <"$tmp/commit"
  [ $signed -eq 0 ] || report "${prefix}signature" 'commit signature'
  sed '1,/^$/d' "$tmp/commit" >"$tmp/v/message"
  g diff-tree -c --root -r -z --raw --no-abbrev --no-commit-id --no-renames --ignore-submodules=none "$c" >"$tmp/raw" ||
    die 'git diff-tree failed.'
  raw_entries <"$tmp/raw" >"$tmp/entries"
  g ls-tree -r -z --name-only --full-tree "$c" >"$tmp/tree" || die 'git ls-tree failed.'
  scan_texts "$terms_rule" author committer
  skip_markers
  check_entries message header
}

# ---- Modes
for r in ${refs[@]+"${refs[@]}"}; do check_ref "$r"; done
case $mode in
  staged)
    prefix='' base=$empty_tree
    g rev-parse -q --verify 'HEAD^{commit}' >/dev/null && base=HEAD
    g diff-index --cached -z --raw --no-abbrev --no-renames --ignore-submodules=none "$base" >"$tmp/raw" ||
      die 'git diff-index failed.'
    raw_entries <"$tmp/raw" >"$tmp/entries"
    g ls-files -z >"$tmp/tree" || die 'git ls-files failed.'
    check_entries
    ;;
  tree)
    prefix=''
    g ls-tree -r -z --full-tree "$rev" >"$tmp/ls-tree" || die 'cannot read the tree of the given revision.'
    while IFS= read -r -d '' rec; do
      m=${rec%% *}
      rec=${rec#* }
      printf '%s %s\0' "$m" "${rec#* }"
    done <"$tmp/ls-tree" >"$tmp/entries"
    g ls-tree -r -z --name-only --full-tree "$rev" >"$tmp/tree" || die 'cannot read the tree of the given revision.'
    check_entries
    ;;
  message)
    prefix='' M_KEY=() M_SHOW=()
    cc=$(g config core.commentString || g config core.commentChar)
    case $cc in '' | auto) cc='#' ;; esac
    # git runs the hook with GIT_EDITOR=: when it does not edit the message (-m, -F, --no-edit): it then keeps comment
    # lines and the lines after a scissors line, so every line is checked
    edited=1
    [ "${GIT_EDITOR-}" = : ] && edited=0
    while IFS= read -r line || [ -n "$line" ]; do
      if [ $edited -eq 1 ]; then
        case $line in "$cc ------------------------ >8 ------------------------") break ;; "$cc"*) continue ;; esac
      fi
      printf '%s\n' "$line"
    done <"$msg" >"$tmp/v/message"
    skip_markers
    scan_texts 0 message
    ;;
  commits)
    commits=$(g rev-list --reverse "${range[@]}") || die 'git rev-list failed for the given range.'
    for c in $commits; do check_commit "$c"; done
    ;;
esac

if [ $count -eq 0 ]; then
  echo 'Personal data check: clean.'
  exit 0
fi
echo "Personal data check: $count finding(s)."
exit 1
```

The script was tested with bash 3.2 and 5.3 and git 2.54 on macOS only: the expressions of `hidden character` and of a
private term after an escape, and the use of `sort` and `uniq`, have not run on Linux (CI) yet.

## Git hooks

`.githooks/` holds three hooks, committed with mode `100755`. They are active in a clone once
`git config core.hooksPath .githooks` ran in it ([Setting up a clone](#setting-up-a-clone)); the Forge sets it in its
source repository ([Commit identity](#commit-identity)), where only the user's own git commands run them: no hook runs
in the Forge's git commands or in its sessions ([Claude permissions](#claude-permissions)). The path is relative: git
looks for the hooks in the `.githooks/` folder of the checked-out tree, so a checkout without it, such as an orphan
branch or a sparse checkout that leaves it out, runs no hook, and git says nothing ([Limits](#limits)).

| Hook         | Runs                                                                                                        | Refuses                                                                                                                                                                                                               |
|--------------|-------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `pre-commit` | `--staged`                                                                                                  | a commit whose staged files hold personal data                                                                                                                                                                        |
| `commit-msg` | `--message <message file>`                                                                                  | a commit message that holds personal data or a CI skip marker in a line that git keeps ([Modes](#modes))                                                                                                              |
| `pre-push`   | `--ref <remote ref> --commits <range>`, once per pushed ref; again with the remote's script when it differs | a push that would publish personal data in a ref name or in the commits it adds, or a commit message holding a CI skip marker; every tag, every other ref outside `refs/heads/` and every object that is not a commit |

`pre-push` reads the lines `<local ref> <local sha> <remote ref> <remote sha>` git gives it:

- A deletion (a local sha of zeros only, of any length) publishes nothing and is skipped.
- A remote ref under `refs/tags/` is refused with `Tags are created only by CI releases.`: no tag is pushed by hand.
- Any other remote ref outside `refs/heads/` (`refs/notes/`, `refs/replace/`, the refs of `git push --mirror`) is
  refused with `Only branches are pushed: refs/heads/<name>.`, and a local object that is not a commit with
  `Only commits are pushed.`: the check reads commits, and a blob, a tree or the tagger and message of a tag object
  would pass it unread.
- When the remote sha is a commit this clone has, the range is `<remote sha>..<local sha>`. Otherwise (a new branch, or
  a remote commit this clone does not have, as after a force push from elsewhere) it is
  `<local sha> --not <heads>`: the commits that no branch of the remote has. `<heads>` are the commits of the remote's
  branches that this clone has, listed once per push with `git ls-remote --heads <remote URL>`; a branch whose commit
  this clone lacks excludes nothing, so its commits are checked again (`git fetch` first shortens the check).
  Remote-tracking refs are not used: one left by a branch deleted on the remote, which `git fetch` keeps without
  `--prune`, still holds commits the remote no longer has. When the branches cannot be listed, the push is refused with
  `Cannot list the branches of the remote.`
- When the remote sha is a commit this clone has and its `scripts/check-public.sh` differs from the working tree's, the
  hook also runs the remote's script, from a temporary copy, on the same range: the pushed commits cannot weaken the
  check that judges them. A hook changed in the working tree is not judged this way: it is the hook that runs
  ([Protected paths](#protected-paths)).
- The script runs with its input from `/dev/null`, so it cannot consume the hook's input. Each run prints its own
  summary line; the push is refused when any run fails.
- The hook runs git with `GIT_NO_REPLACE_OBJECTS=1`, as the script does: a replace ref cannot choose the remote's
  script or hide a pushed commit.

git runs hooks at the top of the working tree. The hooks run `bash scripts/check-public.sh`, so they work when the
script has lost its exec bit. In a clone without private terms they print the note line on every commit.

`--no-verify` skips the three hooks. It is never used. The Forge push gate and CI do not rely on the hooks.

git runs the pre-commit hook for `git commit` only: a merge without conflicts runs the commit-msg hook but not
pre-commit (it runs `pre-merge-commit`, which `.githooks/` does not hold), and `git am`, `git cherry-pick`,
`git rebase` and `git revert` run neither (tried with git 2.54). The pre-push hook checks the commits they make.

### .githooks/pre-commit

Exact content (mode `100755`):

```bash
#!/bin/bash
# Refuses a commit whose staged files hold personal data. See docs/public-repository.md.
exec bash scripts/check-public.sh --staged
```

### .githooks/commit-msg

Exact content (mode `100755`):

```bash
#!/bin/bash
# Refuses a commit message that holds personal data or a CI skip marker. See docs/public-repository.md.
exec bash scripts/check-public.sh --message "$1"
```

### .githooks/pre-push

Exact content (mode `100755`):

```bash
#!/bin/bash
# Refuses a push that would publish personal data: checks the name of each pushed ref and every commit the push
# adds to the remote, with this clone's check and, when the remote's commit holds another one, with that one too.
# Pushes only commits to branches: refuses every tag (tags are created only by CI releases), every other ref outside
# refs/heads/ and every object that is not a commit. See docs/public-repository.md.
# Arguments: <remote name> <remote URL>. Standard input, one line per pushed ref:
# <local ref> <local sha> <remote ref> <remote sha>
export GIT_NO_REPLACE_OBJECTS=1 # the objects as git pushes them, never their replacements (git replace)
url=$2
status=0 listed=0 heads=''
while read -r local_ref local_sha remote_ref remote_sha; do
  case $local_sha in *[!0]*) ;; *) continue ;; esac # a deletion publishes nothing
  case $remote_ref in
    refs/heads/*) ;;
    refs/tags/*) echo 'Tags are created only by CI releases.'; status=1; continue ;;
    *) echo 'Only branches are pushed: refs/heads/<name>.'; status=1; continue ;;
  esac
  if [ "$(git cat-file -t "$local_sha" 2>/dev/null)" != commit ]; then
    echo 'Only commits are pushed.'; status=1; continue
  fi
  base=''
  if git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
    range=("$remote_sha..$local_sha")
    base=$remote_sha
  else
    # A new branch, or a remote commit this clone does not have: the commits that no branch of the remote has now.
    # Remote-tracking refs are not trusted: one left by a branch deleted on the remote still holds its commits.
    if [ $listed -eq 0 ]; then
      heads=$(git ls-remote --heads "$url" </dev/null 2>/dev/null) || {
        echo 'Cannot list the branches of the remote.'
        exit 1
      }
      listed=1
    fi
    range=("$local_sha" --not)
    for sha in $heads; do # "<sha> <ref>" pairs; a branch whose commit this clone does not have excludes nothing
      case $sha in refs/*) continue ;; esac
      git cat-file -e "$sha^{commit}" 2>/dev/null && range+=("$sha")
    done
  fi
  bash scripts/check-public.sh --ref "$remote_ref" --commits "${range[@]}" </dev/null || status=1
  # The pushed commits cannot weaken the check that judges them: the remote's check runs too when it differs.
  if [ -n "$base" ] && published=$(git rev-parse -q --verify "$base:scripts/check-public.sh") &&
    [ "$published" != "$(git hash-object scripts/check-public.sh 2>/dev/null)" ]; then
    copy=$(mktemp "${TMPDIR:-/tmp}/check-public.XXXXXX") || exit 1
    git cat-file blob "$published" >"$copy" &&
      bash "$copy" --ref "$remote_ref" --commits "${range[@]}" </dev/null || status=1
    rm -f "$copy"
  fi
done
exit $status
```

## Forge push gate

Forge feedback and regeneration sessions never push ([Claude permissions](#claude-permissions)). After committing,
Claude calls the MCP tool of its session, with no arguments: `forge_push_docs` in a feedback session, `forge_push_regen`
in a regeneration session ([claude/mcp.md](claude/mcp.md)). The Forge then checks and pushes, in this order; the first
failure ends the call with a text that tells Claude what to do next
([forge/pipeline.md](forge/pipeline.md#mcp-tools)):

1. The calling session may use the tool; the configuration checks of the Forge pass; the private terms file holds at
   least one term and every term Hephaestus suggests is added or dismissed ([Private terms](#private-terms)).
2. `git fetch --quiet origin <branch>`; the repository is on `<branch>`; the commit to push is `HEAD` and the base is
   `refs/remotes/origin/<branch>`, both resolved once.
3. The commits between the base and the commit: there is at least one, the base is an ancestor of the commit, and none
   is a merge.
4. Paths, compared ignoring ASCII case: `forge_push_docs` pushes only changes under `docs/`, `forge_push_regen` none
   under `docs/`; neither pushes a change to a [protected path](#protected-paths), a binary file, a `.gitattributes` or
   `.mailmap` file, a path holding a character outside ASCII, which a Mac's disk can store as another path (it folds
   U+212A KELVIN SIGN onto `k` and U+017F LONG S onto `s`), or a path that differs only in case from another path of
   its commit.
5. `forge_push_regen` only: `App/DocsHash.txt` at the commit equals the docs hash of the commit.
6. The personal data check as it is on GitHub: the Forge takes `scripts/check-public.sh` from the last head of the
   branch it trusts (`git show`; from the base before its first check), so that neither the commits being pushed nor
   commits that reached the branch outside the gate unreviewed can change the script that judges them, and runs it
   with `bash`, `--ref refs/heads/<branch> --commits <base>..<commit>` and `HEPHAESTUS_PRIVATE_TERMS` set to the
   private terms file. A missing script refuses the push; findings refuse it with the finding lines.
7. `git push --no-follow-tags origin <commit>:refs/heads/<branch>`, never forced.

The Forge's own git commands, and the check it runs in step 6, run with `core.hooksPath=/dev/null` and
`core.fsmonitor=false`: a session can change the files of the working tree, so no hook of it ever runs in the app's
process; step 6 runs the published check instead. They also run with `GIT_NO_REPLACE_OBJECTS=1` in their environment, so
that a replace ref in the repository cannot make steps 3 to 6 read another commit, tree or file than the one step 7
pushes. Then, when the base is the last head it trusts, the Forge records the pushed commit as the last one it trusts
([forge/pipeline.md](forge/pipeline.md#mcp-tools) step 8). At each of its checks, the Forge runs the published check of
the last head it trusts, with the private terms, on the commits that reached its branch without going through the gate,
and looks among the paths they change for those step 4 leaves to the user by name: a protected path, a `.gitattributes`
or `.mailmap` file, a path outside ASCII ([forge/pipeline.md](forge/pipeline.md#checks-and-triggers)). It reports what
it finds and starts no automatic regeneration until a later head passes. A `ci skip marker` alone passes there: the
Forge has just checked those commits, as the CI run that GitHub skipped would have. It trusts a change of the guardrail
only when the user, having reviewed it, presses Regenerate Now or Retry on the Forge screen; until then step 6 keeps
the script it trusted before.

## Claude permissions

The sessions that work in the repository on the Forge host get deny rules, a changed environment and a prompt that
states the rule ([claude/cli.md](claude/cli.md#35-sessions-in-the-public-repository),
[claude/prompts.md](claude/prompts.md#forge-common-part)): the Forge's feedback and regeneration sessions, and every
other session of the Forge source project and its sub projects. Feedback and regeneration sessions also get explicit
allow rules. As tried with Claude CLI 2.1.309:

- Allowed without a request, in feedback and regeneration sessions: the session's own Hephaestus tools; the git commands
  that read the repository and record commits (`status`, `diff`, `log`, `show`, `add`, `rm`, `commit`, `stash`,
  `rev-parse`, `ls-files`, `branch`); `git reset --soft origin/<branch>`, `git fetch` and `git pull` of the Forge's
  branch from `origin`, and `scripts/check-public.sh --staged`, exactly as the procedures write them; in regeneration
  sessions also `xcodebuild`, `swift` and the scripts of `scripts/`.
- Denied: `git push`, `git config`, `git -c`, `git remote`, `git update-ref`, `git filter-branch`, `git replace`,
  `git notes`, the git options that run a command or write a file (`--upload-pack`, and `--output` of `git diff`,
  `git log`, `git show` and `git stash`); edits of the protected paths, of Claude Code's own settings (`.claude/`,
  `.mcp.json`) and of `.hephaestus/` folders, also when the path is written in another letter case. The protected
  paths are named by their absolute path, so the sessions of sub projects, which work in a folder of the repository,
  are denied them too. A deny rule wins over every allow rule. Every session of any project is denied edits of
  `.hephaestus/` folders: the app's project data, run configurations included, changes only through the app.
- Their environment runs no git hook, rewrites every push URL to a scheme that has no remote helper, so that a plain
  `git push` from a hook, script, test or build fails, and keeps commits on the identity of git's configuration, with
  UTC dates.
- Anything else shows the user a permission card: a fetch or pull from another repository or of another ref,
  `git restore` and `git reset` in another form, which can copy any file of a commit, one the session wrote in another
  folder for example, over a protected path, `scripts/check-public.sh` with other arguments in a feedback session (its
  `--commits` passes them to `git rev-list`, whose `--output` empties a file), `git mv`, a command with an environment
  assignment before it, `git -C <folder> …`, `bash -c "…"`. These cards offer no "Always Allow", and the permission
  mode of feedback and regeneration sessions cannot be changed. A `project` or `task` session keeps its own mode; in
  `bypassPermissions` it shows no card.
- No Hephaestus tool lets a session define a command: run configurations are changed only by the user, in the app
  ([claude/mcp.md](claude/mcp.md#65-update_project)). Feedback and regeneration sessions get no tool that reads the
  mesh's devices, projects or runs.

These rules do not hold code that a session runs. Regeneration sessions run code they write (tests, builds, the scripts
of `scripts/`), and that code can drop the environment's variables (`GIT_CONFIG_COUNT=0 git push …` pushes), push from
the `--upload-pack` command of a fetch (git clears the variables for it), or call the GitHub API with the `gh` login,
which `gh` reads from its keyring. Nor do they hold a `project` or `task` session of the source project in the mode
`bypassPermissions`, which shows no card, a command the user approves that overrides the environment's git settings
(`git -C <folder> -c url.<url>.pushInsteadOf=<url> push …` pushes: git uses the longest matching `pushInsteadOf`), or
a run configuration that a `project` or `task` session starts (`start_run`): its command runs in the login environment
and can run a file the session changed. The Forge push gate checks only what goes through it; the rest is reported once
it is on GitHub ([Limits](#limits)).

Allow rules of the user's own Claude Code settings (`~/.claude/settings.json`) add to these: a broad rule such as
`Bash(git *)` there lets such commands run without a card, and none may exist on the Forge host. The repository's own
`.claude/settings.json`, `.claude/settings.local.json` and `.mcp.json` would apply to the sessions too: the Forge
refuses to work while one of them exists ([forge/pipeline.md](forge/pipeline.md#configuration-checks)).

## Commit identity

Commits carry the user's own git identity, the name and e-mail of git's configuration, which every commit publishes,
and no signature. The rule allows that e-mail ([general.md](general.md#public-repository-no-personal-data)); the name
is one that is not personal, such as the user's GitHub login. In the commits that `--commits` checks (pre-push hook,
Forge push gate, CI), `private term` refuses an author or committer name or e-mail that holds a private term, and
`commit signature` refuses a signed commit. The pre-commit hook does not check them: such a commit is refused when it
is pushed, and is made again once the identity or the signing is fixed (`git reset --soft origin/<branch>`, then
`git commit`). An e-mail address in a file or a commit message, the user's own included (the `Signed-off-by` trailer
of `git commit -s`), is still refused by `e-mail address`.

- The Forge sets no identity in its source repository: the commits made there, by the user or by the sessions that
  work in the repository, carry the identity of git's configuration on the Forge host. It sets `core.hooksPath` to
  `.githooks` and `commit.gpgsign` to `false` there ([forge/pipeline.md](forge/pipeline.md#configuration-checks)).
  The sessions' environment has no `GIT_AUTHOR_*`, `GIT_COMMITTER_*` or `EMAIL` variable and none of the git settings
  the login environment gives (`GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_<n>`,
  `GIT_CONFIG_VALUE_<n>`), which can set another identity, and `TZ` is `UTC`
  ([claude/cli.md](claude/cli.md#35-sessions-in-the-public-repository)): they commit with the configured identity.
- Every other clone is set up by hand ([Setting up a clone](#setting-up-a-clone)).

Author and committer names and e-mails are checked only against the private terms ([Limits](#limits)).

## Private terms

The private terms are the user's own words, which no generic rule can know: their names, account names, machine and
device names and the like. The check refuses each of them in everything it reads
([Where the rules apply](#where-the-rules-apply)).

- File: `<Application Support>/Hephaestus/private-terms.txt` on a Mac, that is
  `~/Library/Application Support/Hephaestus/private-terms.txt` ([data/app-storage.md](data/app-storage.md)). It never
  enters a repository.
- Format: UTF-8, one term per line, a line ending at a line feed (LF) only: a CR alone or U+2028 ends no line. A byte
  order mark at the start of a line is ignored, each line is trimmed of ASCII white space (space, tab, LF, vertical
  tab, form feed, CR), and empty lines, lines starting with `#` and terms shorter than 3 characters are skipped. A line
  `# not private: <term>` records a suggestion the user dismissed. The Forge reads the file the same way when it counts
  the terms and looks for pending suggestions ([forge/pipeline.md](forge/pipeline.md#private-terms)).
- Matching: each term as a fixed string, in any case (ASCII letters only), as a whole word as `git grep -w` defines it
  (word characters: ASCII letters, digits and `_`), and also right after an escape that glues it to a letter (`\n`,
  `\t`, `\r`, `\u` and 4 hex digits, `%` and 2 hex digits). A term glued to letters, digits or `_` (camelCase,
  snake_case) is not a finding, but it is still masked in printed names.
- The script reads the file named by `HEPHAESTUS_PRIVATE_TERMS` (an empty value counts as unset), else the default file
  when it exists. A named file that is missing or unreadable, or an unreadable default file, is an error (exit status
  `2`). Without terms only the generic rules run, and the first line of the output says so.
- The Forge host writes the file when it is missing, with a header comment and the terms it suggests from the Mac's
  account, names and serial number, the mesh's devices, the other projects of this Mac, the names of git's global
  identity, the code-signing identities and their team IDs, and the GitHub logins of `gh`. It never suggests the
  GitHub owner of the repository, `Azavech` (the constant `ForgeConfig.publicRepository`,
  [protocol/types.md](protocol/types.md#forgeconfig)), the placeholders, default device names or terms shorter than 3
  characters ([forge/pipeline.md](forge/pipeline.md#private-terms)). It does not read the e-mails of git's global
  identity: every commit publishes them, and as terms they would refuse the user's own commits. A suggested term that is
  a whole word of one of these e-mails, such as an account name an address starts with, would refuse the user's commits
  too: the user dismisses it, with the line `# not private: <term>` in place of the term.
- Later, at enabling and at each push, the Forge computes again the terms it would suggest. While one of them is neither
  a term nor dismissed in the file (a device paired or a project registered since), the push tools refuse to push until
  the user adds or dismisses it in Settings ▸ Forge & Updates ([ui/settings.md](ui/settings.md)). Apart from creating
  the file, the app changes it only when the user adds or dismisses a suggestion there.
- The user edits the file from Settings ▸ Forge & Updates. A private term that is a false positive is narrowed or
  removed there; a file without terms stops the Forge from pushing.
- The Forge push gate passes the file with `HEPHAESTUS_PRIVATE_TERMS`; the hooks find it at its default place.
- The app never sends the file anywhere. The copies on the user's other Macs ([Setting up a clone](#setting-up-a-clone))
  and in the `PRIVATE_TERMS` secret of CI are made by the user, by hand.
- CI reads the same terms from the secret `PRIVATE_TERMS` of the GitHub environment `private-terms`, which only `main`
  may use ([CI](#ci)). Once, in the repository's Settings ▸ Environments, the user creates `private-terms` with
  Deployment branches set to the selected branch `main`; then, from the Forge host and after each edit of the file:

  ```sh
  gh secret set PRIVATE_TERMS --env private-terms --repo Azavech/Hephaestus < "$HOME/Library/Application Support/Hephaestus/private-terms.txt"
  ```

## CI

The `public-check` jobs of the workflow check every push, of any branch or tag, every pull request and every manual run
that GitHub starts a run for ([forge/ci.md](forge/ci.md#personal-data-check), [Limits](#limits)):

- `public-check` checks out the whole history and runs `--tree HEAD` (with `--ref <pushed ref>` on a push), then
  `--commits` on the pushed commits or on the commits of the pull request, with the generic rules. The pushed commits of
  a new branch or tag, or of a force push whose old commit is gone, are those that no `build-<N>` tag has: the other
  branches are not trusted, since one push can create several branches that bring the same commits. It runs both again
  with the script of the base revision when that script differs (the commit before the push, the pull request's base,
  else the newest `build-<N>` tag), so a push cannot weaken the check that judges it. It also fails on a pushed tag
  and when the check or a hook is not committed with mode `100755`.
- `public-check-terms` runs the same checks with the private terms, for pushes to `main` only: its secret belongs to an
  environment that only `main` may use, so a workflow pushed on another branch cannot read it. It fails when the secret
  is missing or holds no term.
- `docs-sync` and `build` need both. When one fails, its job summary says "Personal data check failed" with the finding
  lines, and nothing is tested, built or released.
- The jobs' token can only read, except in `build`, which creates the release; no checkout keeps the token. The
  repository code that `build` tests and builds runs before its Release step, on the same runner ([Limits](#limits)).

CI does not depend on the hooks or on the Forge, so it also catches what a hand push without hooks published, when
GitHub starts a run for it; by then the data is on GitHub ([If personal data was pushed](#if-personal-data-was-pushed)).
The hooks and the Forge push gate refuse a commit message that would make GitHub start no run (`ci skip marker`). A
workflow file pushed with the data runs instead of the published one: the Forge's own check of its branch does not
depend on it.

## Signing

The project file holds no team ID. The target's Debug and Release configurations are based on the committed
`Config/Signing.xcconfig`, which includes `Config/Signing.local.xcconfig` when it exists. That file holds the user's
`DEVELOPMENT_TEAM`, exists only on the user's Macs, is ignored by git and refused by `forbidden path`
([architecture.md](architecture.md#configsigningxcconfig)). CI builds without a team. If Xcode's Signing &
Capabilities writes a team into `project.pbxproj`, `team id` refuses the commit;
`git restore Hephaestus.xcodeproj/project.pbxproj` undoes it.

## Protected paths

The guardrail is changed only by hand. These paths are protected:

| Path                                                            | Governed by                                                                                 |
|-----------------------------------------------------------------|---------------------------------------------------------------------------------------------|
| `docs/general.md`                                               | itself                                                                                      |
| `docs/public-repository.md`                                     | itself                                                                                      |
| `scripts/check-public.sh`                                       | this doc                                                                                    |
| `.githooks/`                                                    | this doc                                                                                    |
| `.github/`                                                      | [forge/ci.md](forge/ci.md), whose `.github/workflows/ci.yml` is the only file of the folder |
| `.gitignore`                                                    | [architecture.md](architecture.md#gitignore)                                                |
| `CLAUDE.md`                                                     | [forge/generation.md](forge/generation.md#3-claudemd)                                       |
| `HephaestusKit/Sources/HephHost/Forge/ForgePushGate.swift`      | [forge/pipeline.md](forge/pipeline.md)                                                      |
| `HephaestusKit/Sources/HephHost/Forge/ForgeGit.swift`           | [forge/pipeline.md](forge/pipeline.md)                                                      |
| `HephaestusKit/Sources/HephHost/Forge/ForgeChecks.swift`        | [forge/pipeline.md](forge/pipeline.md)                                                      |
| `HephaestusKit/Sources/HephHost/Forge/PrivateTerms.swift`       | [forge/pipeline.md](forge/pipeline.md)                                                      |
| `HephaestusKit/Sources/HephHost/Claude/ForgeSessionRules.swift` | [claude/cli.md](claude/cli.md)                                                              |
| `HephaestusKit/Sources/HephHost/Claude/ForgePrompts.swift`      | [claude/prompts.md](claude/prompts.md)                                                      |
| `HephaestusKit/Sources/HephHost/MCP/MCPToolKinds.swift`         | [claude/mcp.md](claude/mcp.md)                                                              |
| `HephaestusKit/Tests/HephHostTests/PublicCheckTests.swift`      | [testing.md](testing.md)                                                                    |
| `HephaestusKit/Tests/HephHostTests/ForgePushTests.swift`        | [testing.md](testing.md)                                                                    |

They hold the check, the hooks, CI, the rule Claude reads in every session of the repository, the Forge push gate with
its git commands, configuration checks and private terms, the rules and prompts of the sessions that work in the
repository, the tools each session kind gets, and the tests of the check and of the gate. A feedback session can still
change the docs that describe them, and the Forge pushes that doc change; the code change it requires is then made,
reviewed and pushed by hand, so no automatic loop weakens the guardrail.

- The Forge push gate refuses a commit range that changes any of them, compared ignoring ASCII case, with
  `Changes to the personal-data guardrail are pushed by hand after review: <paths>.`
  ([forge/pipeline.md](forge/pipeline.md#mcp-tools)).
- The sessions that work in the repository, those of its sub projects included, are denied edits of them with the Write
  and Edit tools and shell redirection, also when the path is written in another letter case; without the user's
  approval, their allowed git commands were found to do no more than delete one, take away its exec bit or give it the
  content it has in a commit of the repository ([claude/cli.md](claude/cli.md#35-sessions-in-the-public-repository)). A
  configuration check of the Forge reports every difference between these paths in its source repository and on `origin`
  ([forge/pipeline.md](forge/pipeline.md#configuration-checks)). When a doc change requires a change to a protected
  path, a regeneration stops ([forge/generation.md](forge/generation.md#23-stopping)) and the user makes that change by
  hand, outside the Forge.
- The user reviews such a change, runs the `PublicCheckTests` and `ForgePushTests` ([testing.md](testing.md)) and
  `scripts/check-public.sh --tree HEAD`, then checks the commits with the script as it is on GitHub, since they may
  change the check that judges them, and pushes them with the hooks active:

  ```sh
  git fetch origin
  git --no-replace-objects show origin/main:scripts/check-public.sh > "$TMPDIR/check-public.sh"
  bash "$TMPDIR/check-public.sh" --commits origin/main..HEAD
  git push origin main
  ```

- A change that relaxes a rule is pushed alone, before the files that need it: the pre-push hook and CI also judge a
  push with the check it replaces.
- The Forge's next check reports a change of these paths pushed by hand, and its push gate keeps judging with the
  script it trusted before until the user presses Regenerate Now or Retry on the Forge screen
  ([Forge push gate](#forge-push-gate)).

## Setting up a clone

Every clone is set up once, before its first commit:

```sh
git config core.hooksPath .githooks
git config commit.gpgsign false
```

- No identity is set in the clone: its commits carry the user's git identity ([Commit identity](#commit-identity)). A
  `user.*`, `author.*` or `committer.*` setting in the clone's own configuration would replace it:
  `git config --local --unset <key>` removes it.
- `commit.gpgsign false`: a signature carries the id of its key, which keyservers resolve to the key's names and
  e-mail addresses.
- Private terms: copy `private-terms.txt` from the Forge host to `~/Library/Application Support/Hephaestus/` on this
  Mac, or set `HEPHAESTUS_PRIVATE_TERMS` to its path. Without it the hooks run the generic rules only.
- On github.com ▸ Settings ▸ Emails, "Block command line pushes that expose my email" must be off: when it is on,
  GitHub refuses a push whose last commit has, as its author e-mail, an address the account keeps private.
- `scripts/build.sh` and `scripts/test.sh` refuse to run, outside CI, in a clone whose hooks path is not `.githooks`
  ([forge/ci.md](forge/ci.md)).
- The hooks run from the checked-out `.githooks/` ([Git hooks](#git-hooks)): commit and push only in a checkout that
  has it, never on an orphan branch or in a sparse checkout that leaves it out.

On the Forge host, the Forge sets the hooks path and the signing of its source repository itself
([Commit identity](#commit-identity)). There the repository folder is registered once as the project `HEPH`: the
Forge registers the clone in the projects folder itself (`~/Developer/Hephaestus` by default,
[forge/pipeline.md](forge/pipeline.md#registering-the-source-project)), or the user adds the clone with Add Existing
Folder… ([ui/overview.md](ui/overview.md)); its `.hephaestus/` folder is ignored by git.

## First publication

The repository is published once, from a clone set up as above, before anything else reaches GitHub:

1. Create `Azavech/Hephaestus` on GitHub empty: no README, license or `.gitignore`, so that the commit of step 2 is its
   first commit.
2. Squash the local history into one commit made with the user's git identity. With the private terms, both
   `bash scripts/check-public.sh --tree HEAD` and `bash scripts/check-public.sh --commits HEAD` end with
   `Personal data check: clean.`.
3. Create the environment `private-terms` and its secret ([Private terms](#private-terms)).
4. Push that single commit with the hooks active: `git push origin main`.

## Examples in the repository

The placeholders are those of [general.md](general.md#placeholders). The repository passes its own check:
`scripts/check-public.sh --tree HEAD` is clean at every commit, this doc and the script included. Docs, code, tests and
fixtures write the forms the rules look for only in forms they do not match:

| Instead of                 | Write                                                                                                                   |
|----------------------------|-------------------------------------------------------------------------------------------------------------------------|
| a home folder              | `/Users/user`, `/Users/<name>`                                                                                          |
| an encoded home folder     | `-Users-user-…`, `-Users-<name>-…`                                                                                      |
| an e-mail address          | `user@example.com`                                                                                                      |
| a signing identity         | `Apple Development: Jane Appleseed (ABCDE12345)`, `Apple Development: <name> (<id>)`                                    |
| a team ID                  | `ABCDE12345`, `DEVELOPMENT_TEAM = <team>`                                                                               |
| a private key              | `-----BEGIN <type> PRIVATE KEY-----`                                                                                    |
| a secret                   | `token = "<value>"`, `?token=<value>`, `Bearer <token>`, `"meshKey":"<base64 key>"`, `https://<user>:<password>@<host>` |
| an IP address              | `192.0.2.x`, `192.0.2.10`, `198.51.100.x`, `203.0.113.x`, `127.0.0.1`, `169.254.0.0/16`                                 |
| a MAC address              | `xx:xx:xx:xx:xx:xx`                                                                                                     |
| a four-part version number | `v1.2.3.4`                                                                                                              |
| an invisible character     | its escape, such as `\u{200B}` in Swift                                                                                 |

Tests build the fictional values they plant (a path, an address, a key to be refused) at run time from pieces, so that
their sources stay clean; [testing.md](testing.md) lists them and quotes them the same way. Pieces are only for these
fictional values: a real value is never split, encoded, escaped or reformatted to get past a finding; it is removed or
replaced by a placeholder.

## If personal data was pushed

What a push publishes is public at once and can be copied before it is removed. The Forge never rewrites history,
force-pushes or deletes anything on GitHub; the user acts by hand:

1. Revoke and replace every secret that was published.
2. Rewrite the history without the data, in a clone with the hooks active, until
   `scripts/check-public.sh --commits HEAD` (every commit) is clean. Force-push the branch, and rewrite or delete
   (`git push origin --delete <branch>`) every other branch that holds the data.
3. Delete every release whose tag is in the removed history, with its tag: after `git fetch --tags origin`, for each
   tag that `git tag --no-merged origin/<branch>` lists,
   `gh release delete <tag> --cleanup-tag --yes --repo Azavech/Hephaestus`, or `git push origin --delete <tag>` for a
   tag without a release. A `build-<N>` tag keeps its commit and the commits before it public, its release offers
   their source archives, and its `Hephaestus-macOS.zip` was built from them.
4. Delete the workflow runs of the removed commits, which keep their logs and artifacts and show the head commit's
   message as their title: for each commit, `gh run list --commit <sha> --repo Azavech/Hephaestus`, then
   `gh run delete <run id> --repo Azavech/Hephaestus` for each run listed.
5. Close the pull requests that hold the data: their refs stay on GitHub, and only GitHub Support removes them.
6. Reset the Forge host's clone and the other clones to the rewritten branch (`git fetch --prune origin`, which also
   drops the remote-tracking refs of the deleted branches, then `git reset --hard origin/<branch>`).
7. Ask GitHub Support to remove the cached views of the removed commits and the refs of those pull requests.
8. Add the published words to `private-terms.txt` and to the `PRIVATE_TERMS` secret.

## Limits

The check finds known forms and the private terms. It does not find:

- personal data of no known form that is not a private term: names, places, project names. On a Mac or in CI without
  private terms, only the generic rules run;
- personal data in author and committer names and e-mails, except private terms: the check does not know which
  identity is the user's, so a commit made with another one passes;
- personal data of a known form in a ref name, such as an e-mail address or a home path: ref names are checked for
  private terms only, since a branch named after a four-part version would read as an address;
- the message and the tagger of an annotated tag pushed without the hooks: the pre-push hook and CI refuse pushed tags,
  and only CI creates tags (`build-<N>`);
- the UTC offset of commits made by hand (the sessions that work in the repository commit in UTC);
- IPv6 addresses, `<name>.local` host names and `/Volumes/<name>` paths, unless they hold a private term;
- a team ID on the line after its key (a plist `<key>` followed by its `<string>`), unless it is a private term;
- text inside the app icon's PNG files, where only private terms are looked for;
- text encoded with NUL bytes, such as UTF-16, after the first 8000 bytes of a file: git reads the file as text, so it
  is no `binary file`, and no rule matches that encoding;
- a private term written in another form: decomposed (NFD, as in macOS file names), with a non-ASCII letter in another
  case, with lookalike letters of another script, or split across strings or lines. The Forge adds the precomposed,
  decomposed, lowercase, uppercase and unaccented forms of the terms it suggests
  ([forge/pipeline.md](forge/pipeline.md#private-terms));
- a word split by a variation selector, U+FE00 to U+FE0F: `hidden character` allows them, since emoji carry them;
- a path holding a character outside ASCII that a Mac's disk folds onto another path (U+212A KELVIN SIGN onto `k`,
  U+017F LONG S onto `s`): `case collision` compares ASCII case only; the Forge push gate leaves such paths to the
  user, and the Forge reports those pushed outside it;
- data encoded in text, such as base64 or `data:` URIs;
- a value derived from personal data, such as a hash of a home-folder path: the workspace `Package.resolved` holds the
  `originHash` of the CI checkout, never one written on a Mac
  ([architecture.md](architecture.md#hephaestusxcodeprojprojectxcworkspace));
- a key, token or password of an unknown form, unless it holds a digit and a letter and is given with `:` or `=` to a
  known name, quoted or followed by a space, a quote, a backtick, `;`, `&` or the end of the line, or passed in a URL;
- in a commit message that git edits, a comment line that it keeps (`--cleanup=verbatim` or `whitespace`) and the
  lines after a scissors line typed without `-v`, which it keeps too: the commit-msg hook skips them, and the pre-push
  hook, which reads the recorded message, finds them;
- a commit or push made in a checkout without `.githooks/`, such as an orphan branch or a sparse checkout that leaves it
  out: git runs no hook there ([Git hooks](#git-hooks)), and a pushed commit without `.github/workflows/ci.yml` starts
  no CI run;
- a ref that is neither a branch nor a tag (`refs/notes/…`, any other `refs/…`) pushed without the hooks: the Forge
  reads only its branch, and GitHub documents the push event of its workflows for branches and tags;
- a push or pull request that GitHub starts no workflow run for: more than three tags pushed at once, a pull request
  with a merge conflict, and a push or pull request whose commit message holds a CI skip marker that neither the hooks
  nor the Forge push gate checked, such as a commit pushed with `--no-verify`, from a checkout without `.githooks/` or
  by code a session runs, a commit made on github.com (a pull request merged there, a file edited there), or a pull
  request whose commits were made in a clone without the hooks. `ci skip marker` matches the markers as GitHub
  documents them; other spellings, such as more spaces inside the brackets, were not tried on GitHub. The Forge
  checks what reaches its branch;
- a push made with the token of the `build` job: its Test and Build steps run the repository's code, which can change
  what the later Release step runs (the runner's files, `$GITHUB_PATH`, `$GITHUB_ENV`) and so use that step's token,
  which can write the repository's contents. What that token pushes starts no workflow run; on `main` the Forge's
  check of its branch reports it;
- a push made by code that a session runs, by a `project` or `task` session of the source project in the mode
  `bypassPermissions` or through a run configuration it starts, or by a command the user approves that overrides the
  sessions' git settings ([Claude permissions](#claude-permissions)): it passes through no gate. Once it is on GitHub,
  the Forge reports its personal data and its changes of the guardrail, which it trusts only once the user has reviewed
  them, and CI reports its personal data; a weaker check it brings judges the later pushes in CI;
- the work of a session of another project, to which [Claude permissions](#claude-permissions) does not apply even when
  it works in the repository through its path, such as a task session that a session of the repository starts for a
  task of another project (`start_task_session`).

The author of a commit reviews it for what the check cannot see.
