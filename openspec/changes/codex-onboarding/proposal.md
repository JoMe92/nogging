## Why

The `agent-neutral-launch` change lets `scripts/specforge session launch` run
Codex as the agent, and `tool-agnostic-write-boundary` makes the OpenSpec write
guard enforceable without a Claude-Code hook. What is still missing is
everything a fresh repo needs so an operator can *actually* run the SpecForge
loop from Codex: the installer places nothing under `.codex/`, `CLAUDE.md` and
`AGENTS.md` have drifted into two half-overlapping instruction files, the
authority floor and the `/plan` / `/discovery-review` / `/sync-now` entry points
exist only in Claude-Code formats, and `scripts/specforge doctor` does not know
Codex exists.

Codex (v0.148) reads `AGENTS.md` hierarchically, honours a project execpolicy
`.rules` file for command allow/deny, and ships a hooks mechanism that `bd init`
already wires (`.codex/hooks.json`). SpecForge only has to meet it there.

## What Changes

- **Installer wires the Codex side.** A `mergeCodex` step deep-merges into
  `.codex/hooks.json` without dropping the entries `bd init` wrote, ships
  `.codex/rules/specforge.rules` (the execpolicy authority floor) and
  `.codex/prompts/{plan,discovery-review,sync-now}.md` (Codex-format equivalents
  of the workflow commands), and adds the new `.codex/` paths to the package
  `files` list so `npx github:` actually delivers them.
- **`AGENTS.md` becomes the single canonical instruction file.** It carries the
  full operating model plus a *Tool notes* section that states what is
  Claude-Code-specific (the `PreToolUse` guard, `.claude/agents` specialists via
  the Task tool, `.claude/commands`) versus Codex (execpolicy `.rules` +
  sandbox, specialists via an out-of-process `session launch --agent codex`,
  `.codex/prompts`). The `CLAUDE.md` SpecForge marker block shrinks to a pointer
  at `AGENTS.md` and the one genuinely Claude-only line.
- **Codex specialist delegation is defined.** Codex has no in-process subagent
  mechanism, so a Codex specialist run is a separate supervised
  `session launch --agent codex --role specialist:<type> --bead <id>` session
  under every specialist boundary rule. The six `.claude/agents/*.md` stay
  Claude-only; no MCP.
- **`scripts/specforge doctor` learns about Codex.** It reports whether `codex`
  is on `PATH` (its absence does not fail `doctor` — a Claude-only repo is
  fine), and flags a `~/.codex/rules/*.rules` entry whose command pattern points
  outside the current repository (a stale rule from an unrelated project).
- **Codex skill consumption is verified.** A task confirms, on the installed
  Codex version, whether Codex auto-loads `.agents/skills/**/SKILL.md`, a repo
  `.codex/skills/`, or neither, and the repo ships or documents accordingly.
- **`docs/using-with-codex.md`** describes prerequisites, what the installer
  places under `.codex/`, how the commands map, the specialist model, and the
  known limitations (no per-tool hook, so the boundary is the filesystem guard +
  execpolicy + the commit hooks).

## Capabilities

### New Capabilities

- `codex-onboarding`: a SpecForge repo installed with the CLI is usable from
  OpenAI Codex as a first-class agent — the installer places the Codex payload,
  `AGENTS.md` is the tool-neutral source of truth, and the authority floor and
  workflow entry points exist in Codex formats.

### Modified Capabilities

<!-- none -->

## Impact

- New shipped files: `.codex/rules/specforge.rules`,
  `.codex/prompts/{plan,discovery-review,sync-now}.md`,
  `docs/using-with-codex.md`.
- New code: `bin/lib/merge.js` (`mergeCodex`), `bin/lib/manifest.js` (the
  `.codex/` payload), `scripts/specforge` (`doctor` Codex + stale-rule checks).
- Modified: `package.json` (`files`), `AGENTS.md`, `CLAUDE.md`,
  `templates/claude-block.md`, `templates/agents-block.md`, `scripts/cli.test.sh`,
  `docs/operating-model.md`, `docs/installation.md`.
- New target-repo prerequisite for the Codex path: the `codex` CLI and a Codex
  login; `bd`/`python3`/`git` unchanged.
- Depends on `agent-neutral-launch` and `tool-agnostic-write-boundary`. This is
  the capstone of the Codex-support epic.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
