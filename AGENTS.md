# SpecForge agent instructions

Read `README.md`, `docs/operating-model.md`, and the active Bead before work.
This file is the single canonical instruction file for every agent tool.
Anything tool-specific is confined to the **Tool notes** section at the end;
the rest applies to every runtime — Claude Code, Codex, or another.

## Hard rules

1. Execution agents (Main Worker and specialists) must not edit `openspec/`.
2. Work only on a Bead that has been claimed by the Main Worker.
3. Before closing, run relevant validation, commit with a Conventional Commit
   containing the Bead ID, and add a Bead note with the commit SHA and evidence.
4. Record every material discovery on the active Bead with the native Beads
   `discovery` label plus a required human-readable note. Never encode the
   discovery as serialized data (no JSON, no key/value block). An execution
   agent can never change `openspec/` itself, so the discovery waits for the
   next planning session, which lists it with `bd list --label discovery`.

   - **Non-blocking** — the claimed task still finishes as specified. Record the
     discovery and keep working the task normally:

     ```bash
     bd update <id> --add-label discovery \
       --append-notes "Prose summary: what was found, the evidence, and the suggested follow-up."
     ```

   - **Blocking** — the task cannot be finished sensibly as specified. Record the
     discovery, mark the Bead blocked, then switch to the next independent
     ready Bead:

     ```bash
     bd update <id> --status blocked --add-label discovery \
       --append-notes "Prose summary: what was found, the evidence, and why it blocks this task."
     ```

5. Leave an intent breadcrumb. Before an expensive or hard-to-reverse step, and
   before ending a turn with a Bead still `in_progress`, append a one-line
   `progress: <next step>` to the Bead note:

   ```bash
   bd update <id> --append-notes "progress: <what is done, what is next>"
   ```

   The agent's working memory does not survive an interruption; on resume — in
   any tool — this note is the primary "where was I" signal, and it costs
   nothing.

## The write boundary

OpenSpec owns approved product intent, Beads owns executable work, Git owns the
implementation. `openspec/` is **read-only** for every execution agent and is
writable only during a planning session that holds
`.specforge/locks/planning.lock` (`./scripts/specforge plan-begin` …
`plan-end`). The lock toggles a `.specforge/locks/openspec.readonly` sentinel;
the write guard consults it. Each tool also enforces this in its own way — see
*Tool notes*.

## Resuming a run

A planning or development run can stop mid-way — token budget, a crash, an SSH
drop, or a deliberate tool switch (Claude Code ↔ Codex). On session start —
fresh, resumed, or after a tool switch — **before selecting work with
`bd ready`**:

1. Let the `SessionStart` hook prime Beads context (or run `bd prime`).
2. Run `./scripts/specforge recover`.
3. Resolve every item it reports, using the playbook in
   `docs/failure-recovery.md` § "Resuming an interrupted run". A `LIMBO` /
   `resumable` Bead's work is **already done** — verify it (`scripts/test`), add
   the evidence note, and `bd close` it; **never re-implement it** (that
   produces a duplicate commit).
4. Only then select work with `bd ready`.

## Specialist delegation

Isolated implementation or review work may be delegated to a specialist, but
**claiming a Bead, closing it, writing the evidence note, and committing stay
with the Main Worker**, and no delegated context may write `openspec/`. A
specialist works exactly one already-claimed Bead, returns a structured result,
and never claims, closes, re-statuses, or commits. A plan-relevant finding from
a specialist is recorded as a discovery by the Main Worker, not the specialist.

How a specialist run is dispatched depends on the tool (see *Tool notes*): an
in-process subagent where the runtime has one, otherwise a separate supervised
session or inline work under the same constraints.

## Supervised sessions

Lead Agent and specialist sessions that SpecForge starts run inside a named
tmux session on the delivery host, tracked by a durable record under
`.specforge/state/sessions/` and an append-only log. Operators use
`scripts/specforge session list | attach | log | stop | cleanup` from a plain
SSH shell; see `docs/operating-model.md`. `session launch --agent
{claude|codex}` chooses the agent; the `restricted` / `trusted` authority
levels are tool-neutral and resolve per agent.

If you are running inside such a session:

- Being launched is not permission to start a Bead. Do not run `bd ready` and
  self-assign work; claim only the Bead the operator names, only when they
  direct it in this session.
- You have a restricted authority level (no `git push`, no remote Dolt
  sync, no destructive shell). Do not work around it.
- Never echo a credential or token value and never pass one on a command line.

A session the operator launches with `--full-access` (the `trusted` profile +
the `autonomous` prompt) *is* authorised to commit, push its branch, and
fast-forward-merge to `develop` — but only for the single named change it was
started for. Every other hard rule still holds: no `openspec/` edits, no
touching another change's Beads, discoveries recorded, commit-and-note before
closing a Bead. A short command floor (`rm -rf`, `sudo`, `dd`, `mkfs`,
`shutdown`, `reboot`, fork bomb) is denied under every profile and every agent —
with the **single exception** of the Orchestration Agent (below).

## The Orchestration Agent

The **Orchestration Agent** is a fourth persona, above the Planning Agent and
the Main Worker: **Product Owner → Orchestration Agent → {Planning, Lead} →
Specialists**. It runs always-on as the single supervised
`sf-orchestrator-<slug>` session (a systemd user service keeps it alive across
crash and reboot; it is reachable from a phone via Remote Control). It is
**Claude Code only** in this version.

- **Default scope is orchestrate-only.** It reads the whole state and drives
  Planning and Lead sessions through `scripts/specforge` (`session
  launch|attach|log|stop`, `sync --now`, `recover`, `discoveries`), `bd`, and
  `git` (read + local fast-forward integration). It writes **no** file under
  `openspec/` and edits **no** implementation code.
- **The command floor and the `openspec/` boundary are lifted for it** — the
  one documented exception, keyed to `--role orchestrator` under the
  `orchestrator` profile. Nothing mechanical enforces the limits above; the
  discipline lives in `.specforge/launch-prompts/orchestrator.md`. `session
  list` / `doctor` show the session as `FULL-ACCESS`.
- **Explicit takeover only.** On an explicit `/orchestrate takeover
  {plan|code} <description>` it does one task directly — a planning task
  committed with the `SpecForge-Writer: planning` trailer, or a code task
  committed with the `[<bead-id>]` token — then returns to orchestrate-only.
- **Acceptance stays human.** It never completes an acceptance report's
  `Signed-off-by:` line.

See `docs/operating-model.md` *Orchestration* and `docs/architecture.md`.

## Commands

The operator entry points are `/plan`, `/discovery-review` and `/sync-now`
(see the *Commands* table in `docs/operating-model.md`). Each is a thin wrapper
over `scripts/specforge`; a tool without a command mechanism runs the same
steps by hand:

- `/plan` — `scripts/specforge plan-begin` → discovery review → author →
  `validate` → commit as the `planning` writer → `materialize <change>` →
  `plan-end`. The spec is committed **before** `materialize`, so a crash
  between the two never leaves Beads without a committed spec.
- `/discovery-review` — `scripts/specforge discoveries` (+ `--ack`).
- `/sync-now` — `scripts/specforge sync --now`.

Where each tool reads those command files is in *Tool notes*.

## Planning only

The Planning Agent first runs `./scripts/specforge plan-begin`, writes or
revises OpenSpec, runs validation, commits the change as the `planning` writer,
materializes Beads, then runs `./scripts/specforge plan-end`. Committing before
`materialize` keeps a crash in that window recoverable (`materialize` is
idempotent and the committed spec is the source of truth). If an active Bead
loses its task mapping, stop and resolve the orphan explicitly; do not delete
it.

## Tool notes

Everything above is tool-neutral. The specifics below are per runtime — read
the subsection for the tool you are running as, and ignore the others.

### Claude Code

- **Write boundary.** In addition to the per-session authority backstop,
  `openspec/` writes are blocked by a `PreToolUse` hook
  (`scripts/hooks/pre-tool-use-openspec-guard`) wired in `.claude/settings.json`
  — it rejects `Edit`/`Write` under `openspec/` unless the planning lock is
  held.
- **Specialists.** The roster is `.claude/agents/*.md` — `architect`,
  `ui-ux-designer`, `backend-engineer`, `frontend-engineer`, `code-reviewer`,
  `test-runner` — invoked **in process through the Task tool**. The Lead Agent
  delegation model is the *Lead Agent delegation* section of `CLAUDE.md`.
- **Operator entry points.** `.claude/commands/{plan,discovery-review,sync-now}.md`.

### Codex

- **Write boundary.** Codex has no per-tool hook. `openspec/` stays read-only
  through the filesystem write guard (the `.specforge/locks/openspec.readonly`
  sentinel + the commit hooks); `plan-begin` / `plan-end` toggle it. The
  command floor is `.codex/rules/specforge.rules` (execpolicy `prefix_rule`
  lines), loaded once the project's `.codex/` layer is trusted.
- **Specialists.** Codex has no in-process subagent mechanism. A specialist run
  is a **separate supervised session**:
  `scripts/specforge session launch --agent codex --role specialist:<type>
  --bead <id>`, under every specialist boundary rule above. The six
  `.claude/agents/*.md` are Claude-Code-only and are not ported to Codex; there
  is no MCP bridge. Where a separate session is overkill, the Lead Agent does
  the work inline under the same constraints.
- **Operator entry points.** `.codex/prompts/{plan,discovery-review,sync-now}.md`
  (same persona and steps as the Claude commands). On a Codex build that reads
  custom prompts only from `~/.codex/prompts/`, symlink or copy them there, or
  run the `scripts/specforge` steps directly. Codex auto-loads the repo's
  `.agents/skills/**/SKILL.md`, so the OpenSpec skills are available as-is.

### Pi

- **Write boundary.** Pi has no per-tool hook and no execution-policy file.
  `openspec/` writes are blocked by the project-local guard extension
  (`.pi/extensions/specforge-guard.ts`), which intercepts the `tool_call`
  event and rejects a write/edit under `openspec/` unless the
  `.specforge/locks/openspec.readonly` sentinel is absent (a planning session
  is active); `plan-begin` / `plan-end` toggle it. The same extension
  enforces the SpecForge command floor on the shell tool. Pi's `restricted`
  authority level is **floor-only**: unlike Claude and Codex, there is no
  network or filesystem sandbox at either authority level — the guard
  extension and the `openspec/` write boundary are the only enforcement.
- **Specialists.** Pi has no in-process subagent mechanism. A specialist run
  is a **separate supervised session**:
  `scripts/specforge session launch --agent pi --role specialist:<type>
  --bead <id>`, under every specialist boundary rule above. The six
  `.claude/agents/*.md` are Claude-Code-only and are not ported to Pi. Where a
  separate session is overkill, the Lead Agent does the work inline under the
  same constraints.
- **Operator entry points.** `.pi/prompts/{plan,discovery-review,sync-now}.md`
  (same persona and steps as the Claude commands and Codex prompts). Pi reads
  `.pi/prompts/` directly from the repository — no symlink helper is needed
  (unlike Codex, which needs `codex-prompts-link` because it only reads
  custom prompts from `~/.codex/prompts/`).
