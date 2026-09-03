## Context

SpecForge's install manifest (`bin/lib/manifest.js`) has `verbatim`,
`verbatimDirs`, `docs`, `scaffold`, `executable`, `gitignore`, `markerBegin/End`
and `systemd` classes. `bin/lib/merge.js` `applyMerges(ctx)` runs
`mergeClaudeSettings`, `mergeGitignore`, and two `mergeMarkerBlock` calls
(`CLAUDE.md` from `templates/claude-block.md`, `AGENTS.md` from
`templates/agents-block.md`). Nothing touches `.codex/`.

`bd init` writes `.codex/hooks.json` with `SessionStart`, `UserPromptSubmit`,
`PreCompact`, `PostCompact` entries calling `bd codex-hook <event>`. Codex reads
`AGENTS.md` (root and per-directory, precedence `AGENTS.override.md` >
`AGENTS.md` > configured fallbacks; a global `~/.codex/AGENTS.md` also applies)
and a project execpolicy `.rules` file — lines of the form
`prefix_rule(pattern=["cmd", "arg", ...], decision="allow" | "deny")` — disabled
only by `codex --ignore-rules`.

`AGENTS.md` today already carries: Hard rules 1–4, *Specialist delegation (Claude
Code)*, *Supervised sessions*, *Commands*, *Planning only*. `CLAUDE.md` carries a
SpecForge marker block (`templates/claude-block.md`) plus a separate
Beads-managed block. `.claude/commands/{plan,discovery-review,sync-now}.md` and
`.claude/agents/{architect,ui-ux-designer,backend-engineer,frontend-engineer,code-reviewer,test-runner}.md`
exist and are Claude-Code formats.

`scripts/specforge doctor` checks `git`, `python3`, `bd`, `dolt` (any missing →
exit 1) plus the invariant audit and the sync failure record.

## Goals / Non-goals

- Goal: `npx github:JoMe92/specforge init` into a repo whose operator uses Codex
  leaves that repo ready to run the SpecForge loop from Codex.
- Goal: one instruction file — `AGENTS.md` — is authoritative for both tools;
  `CLAUDE.md` is a thin pointer plus the one Claude-only detail.
- Goal: the Codex authority floor denies exactly the command classes the Claude
  floor denies.
- Goal: `mergeCodex` never drops a `bd`-written `.codex/hooks.json` entry and is
  idempotent.
- Non-goal: the `session launch --agent` dispatch (owned by
  `agent-neutral-launch`) and the filesystem write guard (owned by
  `tool-agnostic-write-boundary`).
- Non-goal: porting the six specialists to Codex-native subagents, or exposing
  them over MCP.
- Non-goal: changing the content `bd` puts in `.codex/hooks.json`.
- Non-goal: a Codex CI job (the mechanical CI subset is agent-neutral already).
- Non-goal: materializing Beads or editing implementation files in this planning
  session.

## Decisions

### `mergeCodex` — deep-merge, never clobber

`applyMerges` gains a `mergeCodex(ctx)` call. It:

1. Reads `.codex/hooks.json` if present (`bd init` may have written it), parses
   it, and — for now — writes it back unchanged. SpecForge adds no hook of its
   own: `bd codex-hook SessionStart` already primes Beads context, which is all
   the Claude `SessionStart: bd prime` hook does. The function exists so a later
   need can deep-merge into `hooks.<event>[]` by matching on `command`, exactly
   as `mergeClaudeSettings` matches the guard entry — it must never overwrite the
   file or drop a `bd` entry.
2. Ensures the shipped `.codex/rules/specforge.rules` and
   `.codex/prompts/*.md` are in place (these are `verbatimDirs`, so the copy is
   already done; `mergeCodex` only asserts and logs).

`.codex/rules/` and `.codex/prompts/` are added to `manifest.verbatimDirs` and
to `package.json` `files`. A stray user `.codex/AGENTS.md` or `config.toml` is
never touched.

### The execpolicy floor: `.codex/rules/specforge.rules`

A shipped file with `prefix_rule(... decision="deny")` lines mirroring the
Claude `FLOOR_DENY` and the `trusted.json` deny list:

```
prefix_rule(pattern=["git", "push"], decision="deny")
prefix_rule(pattern=["git", "remote"], decision="deny")
prefix_rule(pattern=["bd", "dolt", "push"], decision="deny")
prefix_rule(pattern=["bd", "dolt", "pull"], decision="deny")
prefix_rule(pattern=["dolt", "push"], decision="deny")
prefix_rule(pattern=["sudo"], decision="deny")
prefix_rule(pattern=["rm", "-rf"], decision="deny")
prefix_rule(pattern=["rm", "-fr"], decision="deny")
prefix_rule(pattern=["dd"], decision="deny")
prefix_rule(pattern=["mkfs"], decision="deny")
prefix_rule(pattern=["shutdown"], decision="deny")
prefix_rule(pattern=["reboot"], decision="deny")
prefix_rule(pattern=["systemctl"], decision="deny")
prefix_rule(pattern=["curl"], decision="deny")
prefix_rule(pattern=["wget"], decision="deny")
```

Implementation verifies the exact `prefix_rule` grammar against the installed
Codex and adjusts (some versions want `regex_rule` or a `program=` key); the
requirement is behavioural — those commands are denied. `git push` / `git merge`
for a `--full-access` Codex session are handled the same way the Claude side
handles it: the `trusted` authority level, applied by `agent-neutral-launch`,
selects a rules variant or passes an `--ignore-rules`-scoped override, not this
base floor.

### `.codex/prompts/` — command equivalents

`plan.md`, `discovery-review.md`, `sync-now.md` under `.codex/prompts/` carrying
the same persona and step text as the `.claude/commands/` files, adjusted only
for the invocation surface (Codex custom prompts are invoked as `/plan` etc.
from a Codex session the same way). They stay thin wrappers over
`scripts/specforge`; the mechanical steps are identical because the bridge is
agent-neutral.

### `AGENTS.md` as the single source of truth

Restructure so `AGENTS.md` is complete on its own and tool-neutral by default,
with one new section:

> ## Tool notes
>
> **Claude Code.** OpenSpec writes are also blocked by a `PreToolUse` hook
> (`scripts/hooks/pre-tool-use-openspec-guard`). Specialists are the
> `.claude/agents/*.md` roster, invoked in process through the Task tool.
> Operator entry points are `.claude/commands/{plan,discovery-review,sync-now}.md`.
>
> **Codex.** OpenSpec writes are blocked by the filesystem write guard
> (`tool-agnostic-write-boundary`); the command floor is
> `.codex/rules/specforge.rules` (execpolicy). Codex has no in-process subagent
> mechanism — a specialist run is a separate supervised session,
> `scripts/specforge session launch --agent codex --role specialist:<type>
> --bead <id>`, under every specialist boundary rule. Operator entry points are
> `.codex/prompts/{plan,discovery-review,sync-now}.md`.

The `templates/agents-block.md` marker block gains the same tool-neutral
framing. `templates/claude-block.md` shrinks: it keeps only the pointer
("this repo uses SpecForge — read `AGENTS.md`") and the one Claude-only line
(the `PreToolUse` hook), and drops the duplicated hard-rule text.

### `doctor` — Codex awareness

- Add `codex` to a *reported-but-not-required* tier: `doctor` prints
  `OK codex` / `-- codex (not installed; only needed for the Codex agent path)`
  and its absence alone does not make `doctor` exit non-zero.
- Add an informational check: scan `~/.codex/rules/*.rules` (and any project
  `.rules`) for a `prefix_rule` whose `pattern` first element is an absolute
  path, or contains a path, that does not resolve under `ROOT`; print it as
  `INFO  stale external Codex rule: <line> (<file>)`. Never a failure — it is a
  hygiene hint (the `~/.codex/rules/default.rules` `mkdir -p /srv/repos/...`
  leftover is the motivating example).

### Codex skills — verify then ship or document

Codex has a skills system (`~/.codex/skills/`, system skills like `review-agent`,
`skill-installer`). Whether it auto-loads a repo `.agents/skills/**/SKILL.md` or
a repo `.codex/skills/` is version-dependent and unverified. TASK-COB-008
verifies it on the installed Codex and takes one of:

- Codex reads `.agents/skills/` → nothing to ship, note it in
  `docs/using-with-codex.md`.
- Codex reads a repo `.codex/skills/` → the installer ships a `.codex/skills/`
  that mirrors `.agents/skills/` (copy or, if the format differs, a generated
  index).
- Codex reads neither → document that a Codex operator invokes the
  `scripts/specforge` steps directly (the skills are guidance, not required).

If the answer needs follow-up work beyond a doc line, it is filed as a discovery
on the task's Bead, not expanded here.

## Risks / open questions

- The exact execpolicy `.rules` grammar and file-discovery rules
  (`~/.codex/rules/` vs a repo `.codex/rules/` vs `.rules` at the repo root) must
  be confirmed against the installed Codex; the floor requirement is behavioural
  so the file can move without a spec change.
- `mergeCodex` is a near-no-op today. It is specified now so the seam exists and
  the `.codex/` payload has an owner; if it stays trivial that is fine.
- `AGENTS.md` growing a Codex section risks Claude-Code sessions reading Codex
  instructions. The *Tool notes* framing (explicitly labelled subsections) keeps
  each tool's specifics scoped; the shared body stays tool-neutral.
- A Codex `--full-access` session that can `git push` needs the floor relaxed
  for `git push`/`git merge` — that relaxation belongs to `agent-neutral-launch`'s
  authority-level mapping, not this base floor; the two must be sequenced so the
  `trusted` Codex path is not left unable to merge.
- Codex custom-prompt discovery (`.codex/prompts/` vs `~/.codex/prompts/`) is
  unverified; TASK-COB-003 confirms it and the file location follows.
