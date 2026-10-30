# General rules

## Public repository: no personal data

The GitHub repository `Azavech/Hephaestus` is public. Nothing personal ever enters it: not in files, file names,
commit messages, commit author and committer names, branch or tag names, release notes or CI output. The one exception
is the e-mail address of the user's own git identity, which each of their commits publishes as its author and
committer e-mail. This rule comes before every other rule: it holds for every doc, every file generated from the docs,
every commit and every verbatim copy. When in doubt, leave it out.

`Azavech` is the owner's public GitHub handle: the repository path `Azavech/Hephaestus`, the `forge.repository` setting
and the bundle identifier `ca.azavech.hephaestus` are public by nature and allowed.

### Personal data

Anything that identifies the user, their people, machines, accounts or activity:

- real names of people; account (user) names; home-folder paths (`/Users/<name>`, `/home/<name>`, `C:\Users\<name>`)
  and paths derived from them, such as Claude's encoded project folders (`-Users-<name>-…`);
- e-mail addresses, phone numbers, postal addresses;
- names of the user's computers and devices (computer name, local host name `<name>.local`, mesh device names), serial
  numbers, MAC addresses, LAN IP addresses;
- Apple developer identifiers: signing-certificate names, team IDs, provisioning profiles, Apple IDs;
- names and paths of the user's other projects, repositories, folders and files; URLs and titles of the pages they
  visit;
- screenshots, recordings, Claude transcripts, run output and logs from the user's machines;
- credentials and secrets: tokens, API keys, passwords, private keys, mesh keys, PSKs, pairing codes, MCP tokens;
- anything copied from a feedback comment, screenshot or context that identifies the user or their environment.

### Placeholders

Docs, code, tests and fixtures use only these stand-ins:

| Kind                    | Placeholder                                                                                       |
|-------------------------|---------------------------------------------------------------------------------------------------|
| person                  | `Jane Appleseed`                                                                                  |
| account / home folder   | `user`, `/Users/user`; Claude's encoded folder `-Users-user-…`                                    |
| e-mail                  | `user@example.com` (any address at `example.com`, `example.org`, `example.net`)                   |
| devices                 | `Sam's iPad`, `Sam's MacBook Pro`, `Studio`                                                       |
| local host name         | `Sams-Mac-mini.local`                                                                             |
| IP addresses            | `192.0.2.x`, `198.51.100.x`, `203.0.113.x` (RFC 5737), `127.0.0.1`                                |
| MAC address             | `xx:xx:xx:xx:xx:xx`                                                                               |
| signing identity / team | `Apple Development: Jane Appleseed (ABCDE12345)`, team `ABCDE12345`                               |
| projects / folders      | fictional names (`Atlas`, `API`, `Fixture`), under `/Users/user/…`                                |
| tokens, keys, passwords | a description in angle brackets (`<token>`, `<base64 key>`); tests build their values at run time |

Where a doc has to show a form of personal data, it writes a placeholder or angle brackets (`/Users/<name>`), so that
the repository passes its own check ([public-repository.md](public-repository.md#examples-in-the-repository)).

### Where personal data lives instead

- `.hephaestus/`, where the app keeps a project's data (`project.yml`, tasks, sessions, attachments): the whole folder
  is ignored by git and never committed. The repository folder is registered once, by the user, as the project `HEPH` on
  the Forge host.
- `.claude/` (Claude Code's local settings, with paths and permission rules) and `CLAUDE.local.md`: ignored.
- `Config/Signing.local.xcconfig`, the user's team ID ([architecture.md](architecture.md#configsigningxcconfig)):
  ignored.
- Application Support, Caches and the Keychain of each device ([data/app-storage.md](data/app-storage.md)), with the
  private terms file `private-terms.txt`.

`.gitignore` ([architecture.md](architecture.md#gitignore)) ignores these paths, as a convenience. The personal data
check is the enforcement: it refuses them even when they are force-added.

### Enforcement

Layers that do not depend on each other keep personal data out ([public-repository.md](public-repository.md)):

- the personal data check `scripts/check-public.sh`, the one implementation every other layer runs
  ([public-repository.md](public-repository.md#check-script));
- git hooks on every `git commit`, its message and every push, in a checkout that holds `.githooks/`
  ([public-repository.md](public-repository.md#git-hooks));
- the Forge push gate: Forge sessions never push; the Forge checks their commits, then pushes them itself, and checks
  the commits that reach its branch another way ([public-repository.md](public-repository.md#forge-push-gate),
  [forge/pipeline.md](forge/pipeline.md));
- Claude's permissions in the sessions that work in the repository: `git push`, git settings and edits of the
  guardrail are denied, no hook runs and no permission is remembered; code a session runs, and a `project` or `task`
  session in `bypassPermissions`, can still get past them
  ([public-repository.md](public-repository.md#claude-permissions), [claude/cli.md](claude/cli.md));
- the commit identity: commits carry the user's own git identity, checked for private terms, and no signature
  ([public-repository.md](public-repository.md#commit-identity));
- the private terms: the user's own words (names, accounts, machines), refused everywhere
  ([public-repository.md](public-repository.md#private-terms));
- CI: the `public-check` jobs run first, for every push and pull request that GitHub starts a run for, and nothing is
  built or released without them ([forge/ci.md](forge/ci.md)); the check refuses the commit messages that would make
  GitHub start none;
- signing out of the repository: no team ID in the project file
  ([architecture.md](architecture.md#configsigningxcconfig));
- protected paths: this doc, [public-repository.md](public-repository.md), the check script, the hooks, `.github/`,
  `.gitignore`, the root `CLAUDE.md`, and the Swift files and tests of the Forge push gate, its checks and the rules
  and prompts of its sessions are changed only by hand, after review
  ([public-repository.md](public-repository.md#protected-paths)).

## Documentation rules

- Never invent anything. The documentation is the source of truth: if something is not clear, the documentation is
  edited to say it, then the code follows. Nothing that is not in the documentation goes into the code.
- [prompt.md](prompt.md) is the original request, verbatim. The other files refine it; when they differ from it, they
  win. The public repository rule comes first there too: personal data in it, if any, is replaced by the placeholders.
- Every file of `docs/` that governs code starts with a `files:` list: the source files it governs, as paths from the
  repository root, followed by a `---` line. A source file is governed by exactly one doc file.
- The code is regenerated from the documentation by the procedure of [forge/generation.md](forge/generation.md). The
  docs hash recorded in `App/DocsHash.txt` names the documentation the code was generated from; CI builds only code
  whose recorded hash matches `docs/` ([forge/ci.md](forge/ci.md)).
- Markdown tables are aligned: in each column every cell has the width of the widest cell.
