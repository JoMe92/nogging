## Why

The SpecForge operating model — the OpenSpec scaffold, the `scripts/specforge`
sync bridge, the three write-boundary hooks, the systemd sync timer, the
`.agents/skills` set and `AGENTS.md` — currently exists only inside this
repository. Adopting SpecForge in another project means copying files by hand
and editing hard-coded paths. There is no single command to install the
structure and no way to pull later fixes.

## What Changes

- Add a zero-dependency Node CLI (`bin/cli.js`) published from this repository,
  runnable in any target repository as `npx github:JoMe92/specforge init`.
- `init` writes the SpecForge structure into the current git repository:
  tool files copied verbatim, scaffold files written only when absent, foreign
  files (`.claude/settings.json`, `.gitignore`, `CLAUDE.md`, `AGENTS.md`)
  merged idempotently, and the systemd unit rendered with the target's absolute
  path and a per-repository slug.
- `init` initializes the Beads tracker (`bd init`, opt out with `--no-beads`)
  and both `init` and `update` end with a readiness verdict — "ready" or the
  list of missing prerequisites — so one command leaves the repo ready to plan.
- `update` refreshes the tool files and re-applies the idempotent merges without
  touching `openspec/changes/**`, `openspec/project.md` or the local
  `.specforge/config.json` name, and records the installed version.
- `doctor` delegates to the installed `scripts/specforge doctor`.
- Add a Node-guarded script test (`scripts/cli.test.sh`) and a CI job covering
  `init`, idempotent re-`init`, and `update`.
- Add `docs/installation.md` and a README section describing the one-line
  install, what it touches, the update flow and the `core.hooksPath` caveat.
- Add a `python3` availability check to `scripts/specforge doctor` (the bridge
  runs under `python3` but never checked for it).

## Capabilities

### New Capabilities

- `installer`: installs and updates the SpecForge structure in a target git
  repository from a single command, with a verbatim / scaffold-if-absent /
  idempotent-merge / rendered-template strategy per file class, and preserves
  all target-owned planning and execution state.

### Modified Capabilities

<!-- none -->

## Impact

- New code: `bin/cli.js`, `bin/lib/*.js`, `templates/*`, `scripts/cli.test.sh`.
- Modified: `package.json` (`bin`, `files`, `engines`, `main`, `description`),
  `.github/workflows/specforge-validate.yml` (new job), `scripts/specforge`
  (`python3` doctor check), `README.md`, `docs/`.
- New dependency in target repositories: Node.js >= 18 to run the installer
  (one-off); `python3` and `bd` to run SpecForge itself, as today.
- Distribution: the private GitHub repository `JoMe92/specforge` becomes the
  install source via `npx github:`; no npm-registry publish.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
