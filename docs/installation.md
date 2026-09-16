# Installing Nogging into another repository

Nogging ships as a small Node CLI. Run it from the root of the git repository
you want to adopt the operating model.

```bash
cd /path/to/your-repo
npx github:JoMe92/nogging#v2.0.2 init
```

Always pin a released tag; do not install an unpinned default branch. Until the
owner completes public-release acceptance, the repository remains private and
the command requires GitHub access. Once public, the same pinned command needs
no private-repository credential.

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
