# Installing Agentsembli SpecForge into another repository

Agentsembli SpecForge ships as a small Node CLI. Run it from the root of the git repository
you want to adopt the operating model.

```bash
cd /path/to/your-repo
npx github:JoMe92/agentsembli-specforge init
```

Pin a release instead of tracking the default branch:

```bash
npx github:JoMe92/agentsembli-specforge#v1.0.0 init
```

`npx` clones this (private) repository over your existing Git credential. If the
clone fails to authenticate, run `gh auth setup-git` once, or use the SSH form
`npx github:JoMe92/agentsembli-specforge init` after adding an SSH key to GitHub.

## What `init` writes

| Class | Paths | Behaviour |
| --- | --- | --- |
| Tool files | `scripts/specforge`, `scripts/install-hooks`, `scripts/test`, `scripts/*.test.sh`, `scripts/hooks/*`, `.agents/skills/**` | copied verbatim, overwritten on every `init` / `update` |
| Reference docs | `docs/specforge/{operating-model,architecture,failure-recovery}.md` | copied verbatim |
| Scaffold | `openspec/config.yaml`, `openspec/project.md`, `.specforge/config.json` | written **only when absent** — never overwritten |
| Merged | `.claude/settings.json`, `.gitignore`, `CLAUDE.md`, `AGENTS.md`, `.codex/hooks.json` | edited idempotently; your other content is preserved (a `bd`-written `.codex/hooks.json` is never clobbered) |
| Codex payload | `.codex/rules/specforge.rules`, `.codex/prompts/{plan,discovery-review,sync-now}.md` | copied verbatim; only relevant if you run the loop from Codex — see [`docs/using-with-codex.md`](using-with-codex.md) |
| Pi payload | `.pi/prompts/{plan,discovery-review,sync-now}.md`, `.pi/extensions/specforge-guard.ts` | copied verbatim; only relevant if you run the loop from Pi — see [`docs/using-with-pi.md`](using-with-pi.md) |
| Rendered | `systemd/specforge-sync-<slug>.service` and `.timer` | generated with this repo's absolute path; `<slug>` is the repo directory name |

`.specforge/config.json` records `name` (your repo's directory name) and
`specforge_version`.

Never touched: `openspec/changes/**`, `.beads/**`,
`.specforge/{state,locks,reports}`, your `README.md`, your `package.json`.

### Flags

- `--dry-run` — print the change list, write nothing
- `--no-hooks` — do not install the Git hooks
- `--no-systemd` — do not render the systemd unit

`init` is idempotent; re-running it is safe.

## After `init`

```bash
bd init                                   # if you do not already use Beads
systemctl --user enable --now "$PWD/systemd/specforge-sync-<slug>.timer"
./scripts/specforge doctor                # check tools and mappings
```

## Updating

```bash
npx github:JoMe92/agentsembli-specforge update
```

`update` refreshes the tool files, reference docs and merged files, and bumps
`specforge_version`. It does **not** run the scaffold step, so
`openspec/project.md`, the config `name`, and everything under
`openspec/changes/` are left exactly as they are.

## Prerequisites in the target repo

- **Node.js ≥ 18** — only to run the installer.
- **python3** — the `scripts/specforge` sync bridge runs under it.
- **bd (Beads)** and, for sync, a reachable **Dolt** — as SpecForge needs anyway.
- For the **Codex agent path only**: the `codex` CLI and a Codex login. See
  [`docs/using-with-codex.md`](using-with-codex.md).
- For the **Pi agent path only**: the `pi` CLI (needs Node.js ≥ 22.19.0 to
  run, separate from the installer's own Node ≥ 18) and a configured model
  provider. See [`docs/using-with-pi.md`](using-with-pi.md).

## Caveat: `core.hooksPath`

The two Git hooks (`pre-commit`, `commit-msg`) only run from `.git/hooks`. If
`core.hooksPath` is set elsewhere — the Beads integration points it at
`.beads/hooks` — Git ignores `.git/hooks` and those two SpecForge hooks do not
fire. `init` detects this and prints a warning; the hook sources stay in
`scripts/hooks/` for you to wire into the active hooks directory. The
`PreToolUse` OpenSpec guard in `.claude/settings.json` is unaffected.
