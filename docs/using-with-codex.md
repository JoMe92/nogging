# Using SpecForge with OpenAI Codex

SpecForge is tool-neutral. `AGENTS.md` is the canonical instruction file for
every agent runtime, and the mechanical bridge (`scripts/specforge`) is the same
whichever agent runs it. This page covers what is specific to running the
SpecForge loop from **OpenAI Codex** instead of Claude Code.

Everything verified below was checked against **codex-cli 0.148.0**. Codex moves
fast; where a detail is version-dependent it is called out so you can re-check.

## Prerequisites

In addition to the usual target-repo prerequisites (`bd`/Beads, `python3`,
`git`, and a reachable Dolt for sync):

- **The `codex` CLI on `PATH`.** `scripts/specforge doctor` reports it as
  `NOTE  codex available` / `NOTE  codex not installed; only needed for the
  Codex agent path` — its absence never fails `doctor`, because a Claude-only
  repo is perfectly valid.
- **A Codex login.** Run `codex login` once. `codex` must be able to start a
  session non-interactively for `scripts/specforge session launch --agent
  codex` to work.
- **Trust the repo's `.codex/` layer.** Codex only loads project-local
  `.codex/` configuration — hooks and the execpolicy rules floor — once you
  have marked the directory trusted (Codex prompts for this on first run in a
  new directory).

## What the installer places under `.codex/`

`npx github:JoMe92/specforge init` (or `update`) runs a `mergeCodex` step that:

| Path | Behaviour |
| --- | --- |
| `.codex/hooks.json` | **Preserved, never clobbered.** If `bd init` wrote it (the `SessionStart` / `UserPromptSubmit` / `PreCompact` / `PostCompact` → `bd codex-hook` entries), those entries are kept exactly. SpecForge adds no hook of its own; `mergeCodex` is an append-only merge seam for a future need. |
| `.codex/rules/specforge.rules` | The **execpolicy command floor** (shipped verbatim, refreshed on every `init`/`update`). |
| `.codex/prompts/{plan,discovery-review,sync-now}.md` | The **workflow prompts** — Codex-format equivalents of the Claude `.claude/commands/` files. |

A user's own `.codex/AGENTS.md` or `.codex/config.toml` is never touched.

### The execpolicy floor — `.codex/rules/specforge.rules`

Codex loads every `*.rules` file under `<repo>/.codex/rules/` (once the
`.codex/` layer is trusted) and evaluates model-generated shell commands
against them. SpecForge's floor mirrors the Claude launch floor — it forbids:

- writing to a git remote (`git push`, `git remote`, `git config`);
- remote Dolt / Beads sync (`bd sync`, `bd dolt push|pull|clone`,
  `dolt push|pull|remote`);
- destructive host commands (`sudo`, `rm -rf`/`rm -fr`, `dd`, `mkfs` and its
  `mkfs.*` variants, `shutdown`, `reboot`, `systemctl`, `chown`);
- outbound network fetch (`curl`, `wget`).

Check any command against the floor:

```bash
codex execpolicy check --rules .codex/rules/specforge.rules -- git push
# => {"decision":"forbidden"}
```

Grammar note: on codex-cli 0.148 a rule is
`prefix_rule(pattern=[<tokens>], decision="forbidden" | "prompt" | "allow")`.
`decision="deny"` is rejected, and there is no `regex_rule`, so `mkfs.*` is
written as a literal union. If a future Codex changes the grammar, the floor
requirement is behavioural — the file can be rewritten without a spec change.

**Known gap.** A `trusted` / `--full-access` Codex session that must `git push`
and `git push origin develop` to finish integration is still blocked by this
base floor (it *can* `git merge --ff-only` locally — `git merge` is not
forbidden). Relaxing `git push` for a trusted Codex session belongs to the
launch authority-level mapping, not this floor; until that lands, run the final
`git push` steps from a plain shell.

## How the commands map

| SpecForge command | Claude Code | Codex |
| --- | --- | --- |
| `/plan` | `.claude/commands/plan.md` | `.codex/prompts/plan.md` |
| `/discovery-review` | `.claude/commands/discovery-review.md` | `.codex/prompts/discovery-review.md` |
| `/sync-now` | `.claude/commands/sync-now.md` | `.codex/prompts/sync-now.md` |

The persona and step text are identical; only the invocation surface differs.
Each is a thin wrapper over `scripts/specforge` — the mechanical steps
(`plan-begin` → discovery review → author → `validate` → `materialize` →
commit as the `planning` writer → `plan-end`; `discoveries` / `--ack`;
`sync --now`) are agent-neutral.

**Custom-prompt discovery is version-dependent.** codex-cli 0.148 loads custom
prompts only from `~/.codex/prompts/` (user-scoped); repo-scoped
`<repo>/.codex/prompts/` is a pending upstream feature. SpecForge ships the
files repo-scoped and version-controlled anyway. Until Codex reads them from the
repo, either:

- symlink them into your user prompts dir —
  `mkdir -p ~/.codex/prompts && ln -sfn "$PWD"/.codex/prompts/*.md ~/.codex/prompts/`; or
- run the `scripts/specforge` steps directly (the prompt files are just the
  script sequence plus a persona); or
- use the auto-loaded `.agents/skills/` OpenSpec skills (see *Skills*).

## Specialists

Codex has **no in-process subagent mechanism** — there is no Codex equivalent
of Claude Code's Task tool, the six `.claude/agents/*.md` specialists are not
ported, and there is no MCP bridge. A Codex Lead Agent therefore either:

- does the isolated implementation or review slice **inline**, under the same
  specialist constraints; or
- when the operator wants a separate observable process, starts one with:

  ```bash
  scripts/specforge session launch --agent codex \
    --role specialist:<type> --bead <id>
  ```

Either way every specialist boundary rule holds: exactly one already-claimed
Bead, no `openspec/` writes, no claim/close/commit, and plan-relevant findings
are reported back to the Lead Agent as discoveries.

## Skills

Codex auto-loads agent skills, and — verified against codex-cli 0.148.0 — it
scans **`.agents/skills/**/SKILL.md` from the working directory up to the repo
root** (as well as `.codex/skills/`, `$CODEX_HOME/skills/`, `/etc/codex/skills`,
and its bundled system skills).

SpecForge already ships its skills under `.agents/skills/` — the same directory
Claude Code reads — so **nothing extra is installed for Codex and no
`.codex/skills/` mirror is needed**. The OpenSpec helper skills
(`openspec-propose`, `openspec-apply-change`, `openspec-explore`,
`openspec-archive-change`, `openspec-sync-specs`, `openspec-update-change`) and
the `beads` skill are available in a Codex session exactly as in Claude Code,
discovered automatically or invoked by name (`$openspec-propose`).

## Known limitations

- **No per-tool write hook.** Claude Code has a `PreToolUse` hook that rejects
  `Edit`/`Write` under `openspec/`. Codex has no equivalent. For Codex the
  OpenSpec write boundary is held by:
  1. the **filesystem write guard** (`tool-agnostic-write-boundary`) — the
     `.specforge/locks/openspec.readonly` sentinel that `plan-begin`/`plan-end`
     toggle;
  2. the **execpolicy floor** (`.codex/rules/specforge.rules`);
  3. the **commit hooks** (`pre-commit` refuses an `openspec/` change from a
     non-planning writer; `commit-msg` requires the Beads ID token).
- **`git push` for a trusted session** — see *Known gap* above.
- **Repo-scoped custom prompts** — see *How the commands map* above.
- **Codex CI job** — there is none, and none is needed: the mechanical CI
  subset (`invariants`, `acceptance`) is already agent-neutral.

## See also

- `AGENTS.md` — the canonical, tool-neutral instruction file (its *Tool notes*
  section has the Claude-vs-Codex summary).
- `docs/operating-model.md` — roles, the delegation model, session supervision.
- `docs/installation.md` — the installer and what it writes.
