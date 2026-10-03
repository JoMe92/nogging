# Installing Nogging into another repository

Nogging ships as a small Node CLI. Run it from the root of the git repository
you want to adopt the operating model.

```bash
cd /path/to/your-repo
npx github:JoMe92/nogging#v2.1.0 init
```

Always pin a released tag; do not install an unpinned default branch. Until the
owner completes public-release acceptance, the repository remains private and
the command requires GitHub access. Once public, the same pinned command needs
no private-repository credential.

## Fresh machine: `scripts/bootstrap`

If the target machine does not yet have Node, the agent CLIs, `bd`, Dolt,
`git`, `tmux`, or `gh`, run the pinned one-line bootstrap installer first. It
provisions the whole stack — pinned to the versions in the
[compatibility matrix](compatibility.md) — and then runs `init` for you:

```bash
curl -fsSL https://raw.githubusercontent.com/JoMe92/nogging/v2.1.0/scripts/bootstrap | bash
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
curl -fsSL https://raw.githubusercontent.com/JoMe92/nogging/v2.1.0/scripts/bootstrap -o bootstrap
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
| Tool files | `scripts/nogg`, `scripts/install-hooks`, `scripts/test`, `scripts/*.test.sh`, `scripts/hooks/*`, `.agents/skills/**` | copied verbatim, overwritten on every `init` / `update` |
| Reference docs | `docs/nogging/{operating-model,architecture,compatibility,failure-recovery,security-model,using-with-codex,using-with-pi,worktree-workflow}.md` | copied verbatim |
| Scaffold | `openspec/config.yaml`, `openspec/project.md`, `.nogging/config.json` | written **only when absent** — never overwritten |
| Merged | `.claude/settings.json`, `.gitignore`, `CLAUDE.md`, `AGENTS.md`, `.codex/hooks.json` | edited idempotently; your other content is preserved (a `bd`-written `.codex/hooks.json` is never clobbered) |
| Codex payload | `.codex/rules/nogging.rules`, `.codex/prompts/{plan,discovery-review,sync-now}.md` | copied verbatim; only relevant if you run the loop from Codex — see [`docs/using-with-codex.md`](using-with-codex.md) |
| Pi payload | `.pi/prompts/{plan,discovery-review,sync-now}.md`, `.pi/extensions/nogging-guard.ts` | copied verbatim; only relevant if you run the loop from Pi — see [`docs/using-with-pi.md`](using-with-pi.md) |
| Rendered | `systemd/nogg-sync-<slug>.service` and `.timer`, `systemd/nogg-orchestrator-<slug>.service` | generated with this repo's absolute path; `<slug>` is the sanitized repo directory name |

`.nogging/config.json` records `name` (your repo's directory name) and
`nogging_version`.

Never touched: `openspec/changes/**`, `.beads/**`,
`.nogging/{state,locks,reports}`, your `README.md`, your `package.json`.

### Flags

- `--dry-run` — print the change list, write nothing
- `--no-beads` — skip the default `bd init`; use this only when the tracker is
  intentionally provisioned separately
- `--no-hooks` — do not install the Git hooks
- `--no-systemd` — do not render the systemd unit

All four flags apply to `init`. On `update`, `--dry-run`, `--no-hooks`, and
`--no-systemd` suppress the corresponding writes; `remove` supports
`--dry-run` for a non-mutating preview.
`init` is idempotent; re-running it is safe.

## After `init`

```bash
./scripts/nogg doctor
./scripts/nogg validate
systemctl --user enable --now "$PWD/systemd/nogg-sync-<slug>.timer"
```

`init` runs `bd init` automatically unless `--no-beads` was supplied. Replace
`<slug>` with the filenames printed by the installer. Enabling the timer is an
explicit opt-in; review the generated unit before doing so.

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

- **Linux**, **Git**, and **Bash** — the supported host and script environment.
- **Node.js ≥ 18** — to run the installer and package checks.
- **Python ≥ 3.9**, **Git ≥ 2.30**, and **GNU Bash ≥ 4.4**.
- **OpenSpec CLI 1.11.x** — required for planning-artifact validation.
- **bd (Beads) 1.2.x** and a reachable **Dolt 2.3.x** — required for executable work and
  synchronization. `init` initializes Beads by default.
- **systemd user services** are optional; install with `--no-systemd` otherwise.
- **tmux** is optional unless supervised sessions or the orchestrator are used.
- For the **Claude Code path**: the `claude` CLI and authentication.
- For the **Codex agent path only**: the `codex` CLI and a Codex login. See
  [`docs/using-with-codex.md`](using-with-codex.md).
- For the **Pi agent path only**: the `pi` CLI (needs Node.js ≥ 22.19.0 to
  run, separate from the installer's own Node ≥ 18) and a configured model
  provider. See [`docs/using-with-pi.md`](using-with-pi.md).

The complete support classification and evidence links are in the
[compatibility matrix](compatibility.md).

## Caveat: `core.hooksPath`

The three Git hooks (`pre-commit`, `commit-msg`, and `pre-push`) only run from `.git/hooks`. If
`core.hooksPath` is set elsewhere — the Beads integration points it at
`.beads/hooks` — Git ignores `.git/hooks` and those two Nogging hooks do not
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
