# Installing Nogging into another repository

This page is for anyone adding Nogging to a repository: it covers the pinned
install, the one-line bootstrap for a fresh machine, what `init` writes, and how
to update, roll back and remove the payload. When the install is done, continue
with [Your first change](first-change.md).

Nogging ships as a small Node CLI. Run it from the root of the git repository
you want to adopt the operating model. The target repository needs a `develop`
branch and an `origin` remote: worktrees are allocated from a freshly fetched
`origin/develop`, and pull requests target `develop`.

```bash
cd /path/to/your-repo
npx github:JoMe92/nogging#v3.2.0 init --no-systemd
```

`--no-systemd` skips the systemd units; leave it off only after reviewing the
safety warning in the README. Always pin a released tag; do not install an
unpinned default branch. The repository is public, so the pinned command needs
no private-repository credential.

## Fresh machine: `scripts/bootstrap`

If the target machine does not yet have Node, the agent CLIs, `bd`, Dolt,
`git`, `tmux`, or `gh`, run the pinned one-line bootstrap installer first. It
provisions the whole stack — pinned to the versions in the
[compatibility matrix](compatibility.md) — and then runs `init` for you:

```bash
curl -fsSL https://raw.githubusercontent.com/JoMe92/nogging/v3.2.0/scripts/bootstrap | bash
```

Always pin a tagged release in that URL, never `main`/`develop`, for the same
reason the `npx` command above is pinned: what you run should be reviewable
and reproducible. This piped form always stays **non-interactive** — stdin is
connected to the pipe, not a terminal, so the fully-automated flow below runs
regardless of what terminal you're typing into. This is unaffected by the
interactive wizard described next.

### Interactive wizard

Download the script first, then run it, to get a guided, Nogging-styled
terminal wizard instead:

```bash
curl -fsSL https://raw.githubusercontent.com/JoMe92/nogging/v3.2.0/scripts/bootstrap -o bootstrap
bash bootstrap
```

With both stdin and stdout attached to a real terminal (true in this
download-then-run form, never true for the piped one-liner above), and
[`whiptail`](https://en.wikipedia.org/wiki/Newt_(programming_library))
available or installable via `apt`, `scripts/bootstrap` shows:

1. A welcome screen with the Nogging wordmark and a confirmation of the
   install target before anything happens.
2. An install-path prompt (default: `--repo` if given, else the current
   directory).
3. A checklist of optional components (Pi agent support, the systemd sync
   timer, git hooks, Beads init) — pre-checked to match today's actual
   install defaults exactly, and mapped onto the same flags documented below;
   the wizard adds no install logic of its own.
4. An authentication step: for each of GitHub, Codex, and Claude Code,
   already-authenticated tools are skipped silently; an unauthenticated one
   offers to log in now, handing the terminal straight to that tool's own
   login command (`gh auth login`, `codex login`, or `claude`). Nogging never
   asks for or handles a credential itself.
5. A closing summary naming what was installed, what was skipped, and the
   next command to run.

Force one mode or the other with `--interactive` / `--non-interactive`
regardless of what's detected. If `whiptail` is missing and can't be
installed (no `apt`, no network, no `sudo`), `scripts/bootstrap` prints a
NOTE and falls back to the fully-automated flow rather than failing the
whole install over a cosmetic layer.

Before it changes anything, `scripts/bootstrap` prints a **plan block**
(`Plan for <repo> (Nogging <tag>):`) with one line per tool: `present`,
`install` or `upgrade`, and the version. Printing the plan has no side effects.
After `init` it runs `./scripts/nogg doctor` itself, once. The terminal shows
only the `FAIL` and `WARN` lines; the full report is saved under
`.nogging/state/bootstrap-doctor.log`. It ends with a plain-text **summary**
that is identical in both modes: what was installed and skipped, a read-only
login status for GitHub, Claude Code and Codex (it never asks for or handles a
credential), and the next steps.

What it does, in order (identically for both invocation shapes — the wizard
only changes how the install target and options are chosen, never what
`init` actually does): checks the host is a supported platform
(Debian/Ubuntu-family Linux, x86_64 or aarch64 — see the
[compatibility matrix](compatibility.md)) and refuses clearly otherwise;
provisions Node via `nvm` if an existing Node does not already satisfy the
baseline; `npm install -g` the pinned Claude Code, Codex, and OpenSpec CLIs;
provisions `bd` and Dolt via each project's own official install script,
pinned to an exact release tag; ensures `git`, `tmux`, and `gh` are present
via the system package manager (prompting for `sudo`, never silently); and
finally runs `init` against the target repository and `./scripts/nogg doctor`.

Flags:

- `--repo <path>` — target repository to initialize Nogging into (default:
  the current directory). Created and `git init`-ed first if it doesn't
  exist yet.
- `--with-pi` — also install the optional Pi coding agent CLI (pinned
  version), after first raising the Node floor to satisfy Pi's stricter
  `>= 22.19` requirement. Not installed by default.
- `--no-beads`, `--no-hooks`, `--no-systemd` — forwarded straight to `init`
  (see below); every flag works identically whether typed directly or chosen
  through the wizard's checklist.
- `--interactive` / `--non-interactive` — force the wizard, or the
  fully-automated flow, regardless of what stdin/stdout detection would
  otherwise choose.

**Idempotent.** Re-running the script checks each tool's installed version
against the pin first and only installs or upgrades what's missing or out of
range, leaving anything already satisfying the baseline alone. This makes it
safe to run again after a partial failure, or periodically to confirm a
machine still matches the baseline.

Already have the whole toolchain? Skip straight to the `npx ... init`
command above.

## What `init` writes

| Class | Paths | Behaviour |
| --- | --- | --- |
| Tool files | `scripts/nogg`, `scripts/session-launch`, `scripts/session-log-writer`, `scripts/install-hooks`, `scripts/test`, shipped `scripts/*.test.sh`, `scripts/hooks/*`, `.agents/skills/**` (Beads and OpenSpec skills) | copied verbatim; tracked in `.nogging/installed-manifest.json`; unmodified files update cleanly, locally modified files preserved as `<file>.nogging-new` (or overwritten to `<file>.orig` with `--force`); runtime helpers installed executable |
| Reference docs | `docs/nogging/{operating-model,architecture,compatibility,failure-recovery,security-model,using-with-codex,using-with-pi,using-with-antigravity,using-with-herdr,worktree-workflow,model-selection,token-usage}.md` (twelve pages) | copied verbatim; tracked in manifest; locally modified files preserved as `<file>.nogging-new` |
| Scaffold | `openspec/config.yaml`, `openspec/project.md`, `.nogging/config.json` | written **only when absent** — never overwritten |
| Merged | `.claude/settings.json`, `.gitignore`, `CLAUDE.md`, `AGENTS.md`, `.codex/hooks.json` | edited idempotently; your other content is preserved (a `bd`-written `.codex/hooks.json` is never clobbered) |
| Codex payload | `.codex/rules/nogging.rules`, `.codex/prompts/{plan,discovery-review,sync-now}.md` | copied verbatim; tracked in manifest; locally modified files preserved as `<file>.nogging-new` (or overwritten with `--force`); only relevant if you run the loop from Codex — see [`docs/using-with-codex.md`](using-with-codex.md) |
| Pi payload | `.pi/prompts/{plan,discovery-review,sync-now}.md`, `.pi/extensions/nogging-guard.ts` | copied verbatim; tracked in manifest; locally modified files preserved as `<file>.nogging-new` (or overwritten with `--force`); only relevant if you run the loop from Pi — see [`docs/using-with-pi.md`](using-with-pi.md) |
| Antigravity payload (experimental) | `.agents/skills/nogging-{plan,discovery-review,sync-now}/`, the `nogging-guard` and `nogging-observability` groups in `.agents/hooks.json`, `scripts/hooks/agy-guard` | skills and guard copied verbatim and tracked in manifest; `.agents/hooks.json` is merged by named group, so your other hooks are kept; only relevant if you run the loop from Antigravity — see [`docs/using-with-antigravity.md`](using-with-antigravity.md) |
| Rendered | `systemd/nogg-sync-<slug>.service` and `.timer`, `systemd/nogg-orchestrator-<slug>.service` | generated with this repo's absolute path; `<slug>` is the sanitized repo directory name |

`.nogging/config.json` records `name` (your repo's directory name) and
`nogging_version`.
`.nogging/installed-manifest.json` tracks SHA-256 digests of all installed verbatim
and doc files for three-way comparison during updates.

Never touched: `openspec/changes/**`, `.beads/**`,
`.nogging/{state,locks,reports}`, your `README.md`, your `package.json`.

### Flags

- `--dry-run` — Show what would change, write nothing
- `--force` — Overwrite locally modified verbatim files on init/update, keeping a
  `<file>.orig` backup (default: keep the file and write upstream to
  `<file>.nogging-new`)
- `--no-beads` — Skip initializing the Beads issue tracker; use this only when
  the tracker is intentionally provisioned separately
- `--no-hooks` — Skip installing the git hooks
- `--no-systemd` — Skip rendering the systemd sync unit
- `--verbose` — List every file under its class (default: counts only)
- `-v`, `--version` — Print the Nogging package version
- `-h`, `--help` — Show this help

`init` and `update` accept all of these. On `update`, `--dry-run`, `--force`,
`--no-hooks` and `--no-systemd` apply to the corresponding writes; `remove`
supports `--dry-run` for a non-mutating preview. `init` is idempotent;
re-running it is safe. `npx github:JoMe92/nogging#<tag> --help` prints the
same list and ends with pointers to this guide and the pinned bootstrap.

## What the installer prints

`init` and `update` print the same blocks, in this order. The wording is the
installer's; only the stable shapes are described here.

1. **Preflight** — a short host check that runs first, also under `--dry-run`.
   It checks the required tools in
   [Prerequisites](#prerequisites-in-the-target-repo) and lists the optional
   ones it found: `Preflight: 7/7 required tools OK; optional: tmux, claude`.
   Each tool that is missing, too old or unreadable gets one line with a
   `fix:` hint, and a missing optional tool gets a `WARN` line. Preflight is
   **advisory**: it never changes the exit status, never blocks or alters a
   write, installs nothing and uses no network. `doctor` stays authoritative.
2. **Changes** — one line per file class with counts (`Tool scripts  34
   created`). `--verbose` lists every file under its class.
3. **Verdict** — the first line is either `Nogging is ready — …` or
   `Nogging is installed but not ready: <gap>; <gap>`. Each gap gets one
   `fix:` line.
4. **Next steps** — a numbered list. After `init`: resolve any gaps, run
   `./scripts/nogg doctor`, then start your first plan with `/plan` in Claude
   Code or `./scripts/nogg worktree plan <planning-id> <description>`. After
   `update`: review each `.nogging-new` file, then check the installation.
   After `remove`: disable the units, review the shared entries left behind,
   commit. Optional steps, such as enabling the sync timer, are marked
   `(optional)`.

`npx github:JoMe92/nogging#<tag> doctor` runs the installed
`./scripts/nogg doctor`, prints its report unchanged, then the same verdict
and next steps, and exits with doctor's status.

## After `init`

Follow the numbered **Next steps** the installer printed. The usual sequence:

```bash
./scripts/nogg doctor
./scripts/nogg validate
systemctl --user enable --now "$PWD/systemd/nogg-sync-<slug>.timer"
```

`init` runs `bd init` automatically unless `--no-beads` was supplied. Replace
`<slug>` with the filenames printed by the installer. Enabling the timer is an
explicit opt-in (marked `(optional)` in the next steps); review the generated
unit before doing so.

Confirm the pinned package version before changing an installation:

```bash
npx github:JoMe92/nogging#<tag> --version
```

The output must equal that tag's semantic version. `version` is an equivalent
subcommand.

### Without systemd

Install with `--no-systemd` and run `./scripts/nogg sync --now` when you want
an immediate reconciliation. A scheduler other than systemd may invoke
`./scripts/nogg sync`, but it must use the repository root as its working
directory and must not overlap another sync process.

## Updating

```bash
npx github:JoMe92/nogging#<new-tag> update
```

`update` refreshes the tool files, reference docs and merged files, and bumps
`nogging_version`. It does **not** run the scaffold step, so
`openspec/project.md`, the config `name`, and everything under
`openspec/changes/` are left exactly as they are.

### Preserving local modifications (`.nogging-new` and `--force`)

When updating, Nogging uses `.nogging/installed-manifest.json` (or bundled release
baselines for upgrades from legacy releases) to perform a three-way comparison
between the currently installed file, the incoming release, and the baseline digest:

- **Unmodified files** update cleanly to the incoming version.
- **Locally customized files** (for example, edited rules in `.codex/rules/nogging.rules`
  or tuned prompt instructions in `.nogging/launch-prompts/orchestrator.md`) are
  **preserved** by default. Nogging retains your modified file, writes the upstream
  version alongside it as `<file>.nogging-new`, and emits a warning in the update report.
- **Doctor warnings**: `./scripts/nogg doctor` inspects the repository and prints a
  warning for each pending update:
  ```text
  WARN  locally modified file has pending upstream update: <path> (review <path>.nogging-new and reconcile)
  ```
  This warning is advisory and does not fail doctor checks. To reconcile, compare
  `<file>` and `<file>.nogging-new`, incorporate desired changes into `<file>`, and
  delete `<file>.nogging-new`.
- **Force overwrite (`--force`)**: If you intentionally wish to overwrite local edits
  with upstream files, pass `--force`:
  ```bash
  npx github:JoMe92/nogging#<new-tag> update --force
  ```
  With `--force`, Nogging backs up your existing file to `<file>.orig` before
  overwriting it with the upstream release file. Review the `<file>.orig` backup
  and delete it when satisfied.

### Updating and rolling back

Update an installation by running the desired pinned successor tag from the
target repository root:

```bash
npx github:JoMe92/nogging#<new-tag> update
```

For rollback, run `update` from the exact preceding supported tag. This restores
that tag's managed payload while retaining OpenSpec changes, Beads data,
`.nogging/` state, the configuration name, service filenames, and unrelated
Claude, Codex, and Pi settings. Do not use an unpinned branch for either step.
Run the pinned package's `--version` first and record both the version being
left and the version selected for update or rollback.

### Repairing session helpers

`scripts/nogg`, `scripts/session-launch`, and `scripts/session-log-writer`
must come from the same distribution. Both wrappers are managed files:
`init` and `update` replace their content and restore executable permissions.
Keep custom launch settings in a separately named profile rather than editing
these wrappers or the shipped profile names.

If `doctor` reports a missing, non-executable, or incompatible session helper,
run `update` from a pinned release containing the helper-contract repair, then
run `./scripts/nogg doctor` again. Repeating an older release that omitted the
helpers cannot repair the omission. Refresh an existing implementation
worktree too if its committed payload still contains the older helpers.

Session launch checks the helper contract and all emitted options before any
tmux call or session record. An incompatible helper therefore leaves no
half-started session to clean up. A runtime that fails after this check has a
failed session record and a redacted diagnostic log; use `session list` and
`session log <name>` to read the original startup error.

The repair preserves OpenSpec changes, Beads, unrelated hooks and configuration,
and profiles outside Nogging's owned names. `remove` deletes the owned wrappers
along with the other managed payload while retaining those user files.

## Removing the installed payload

Run the pinned successor package that is currently installed:

```bash
npx github:JoMe92/nogging#<tag> remove
```

`remove` deletes exact manifest-owned tool, prompt, agent, reference-document,
and generated-unit files. It also removes the managed blocks from `AGENTS.md`
and `CLAUDE.md` and the matching Claude guard entry. It preserves OpenSpec,
Beads, `.nogging/` configuration/state/reports, and unrelated settings.
Shared `.gitignore` entries and Git hooks are left for manual review because
the installer cannot prove whether another tool now owns them.

## Prerequisites in the target repo

The installer's preflight checks exactly these tools; the table is the same
one it uses.

| Tool | Minimum | Required |
| --- | --- | --- |
| Node.js | 18 | required |
| Git | 2.30 | required |
| Bash | 4.4 | required |
| Python 3 | 3.9 | required |
| OpenSpec CLI | 1.11 | required |
| bd (Beads) | 1.2 | required |
| Dolt | 2.3 | required |

`bd` and a reachable Dolt are what executable work and synchronization need;
`init` initializes Beads by default. The OpenSpec CLI validates planning
artifacts. Linux is the supported host.

Optional, reported by the preflight as `optional:` or `WARN`:

- **tmux** (or herdr) — needed for supervised sessions and the orchestrator.
- **systemd** user services — install with `--no-systemd` otherwise.
- An agent CLI. For the **Claude Code path**: the `claude` CLI and
  authentication. For the **Codex agent path only**: the `codex` CLI and a
  Codex login; see [`docs/using-with-codex.md`](using-with-codex.md). For the
  **Pi agent path only**: the `pi` CLI (needs Node.js ≥ 22.19.0 to run,
  separate from the installer's own Node ≥ 18) and a configured model
  provider; see [`docs/using-with-pi.md`](using-with-pi.md). Antigravity's
  `agy` is also detected.

The complete support classification and evidence links are in the
[compatibility matrix](compatibility.md).

## Caveat: `core.hooksPath`

The four Git hooks (`pre-commit`, `commit-msg`, `pre-push`, and `pre-rebase`) only run from `.git/hooks`. If
`core.hooksPath` is set elsewhere — the Beads integration points it at
`.beads/hooks` — Git ignores `.git/hooks` and those Nogging hooks do not
fire. `init` detects this and prints a warning; the hook sources stay in
`scripts/hooks/` for you to wire into the active hooks directory. The
`PreToolUse` OpenSpec guard in `.claude/settings.json` is unaffected.

## Cloud sessions

A Claude Code cloud session's assigned `claude/*` branch is never a valid pull
request source — push the branch `nogg worktree implement` / `worktree plan`
allocated and open the PR from that branch instead; see `AGENTS.md`'s
Claude Code tool notes.

A fresh cloud container also starts from whatever the repository clone
carries, with no locally-configured `core.hooksPath` and no initialized Beads
database. `init` ships `scripts/hooks/session-start-cloud-bootstrap` — guarded
to a no-op outside `CLAUDE_CODE_REMOTE=true` — that installs the pinned
`bd`/Dolt versions from [`docs/nogging/compatibility.md`](compatibility.md),
activates `core.hooksPath`, and runs `bd bootstrap`. It is **not** wired into
`.claude/settings.json` by default: a `SessionStart` hook runs real setup work
with real time cost on every session start, so a repository that uses cloud
sessions opts in deliberately by adding it to the `SessionStart` array:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/hooks/session-start-cloud-bootstrap" }
        ]
      }
    ]
  }
}
```
