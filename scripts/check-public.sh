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
