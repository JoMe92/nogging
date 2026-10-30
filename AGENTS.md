# Nogging agent instructions

Read `README.md`, `docs/operating-model.md`, and the active Bead before work.
This file is the single canonical instruction file for every agent tool.
Anything tool-specific is confined to the **Tool notes** section at the end;
the rest applies to every runtime — Claude Code, Codex, or another.

## Hard rules

1. Execution agents (Main Worker and specialists) must not edit `openspec/`.
2. Work only on a Bead that has been claimed by the Main Worker.
3. Commit a Bead in several coherent steps, not as one commit at the end. Each
   commit stays within the configured commit range (`task_sizing.commit_lines`
   in `.nogging/config.json`; `./scripts/nogg task-sizing` prints it), is a
   Conventional Commit containing the Bead ID (e.g. `[SPEC-abc]`), and holds
   the tests for the code it changes. Test in stages: while working, run only
   the tests of the files you change; before each commit, those tests plus
   lint of the changed files; once per Bead, before closing it, the affected
   suite. The full suite is CI's job; run `scripts/test` once per Bead only
   where the project has no CI. Run a long command (a suite, a build) as one
   blocking call with a timeout long enough for it to finish —
   `./scripts/nogg run-quiet -- <command>` prints one line on success and
   only the tail on failure — and never poll a running command (*Tool notes*
   has the per-runtime detail). Then close the Bead (`bd close <id>`) and
   immediately run `./scripts/nogg task-done <id>` to tick its mapped
   `tasks.md` line (it refuses unless the Bead is already closed), bundling
   that tick into the Bead's last commit, and add a Bead note listing every
   commit SHA and the evidence.
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

6. End every supervised run with a signal: a pushed pull request and
   `./scripts/nogg session signal done "PR #<n> open"`, or
   `./scripts/nogg session signal blocked "<why>"`. A Bead note alone is not a
   signal, because nobody reads it. A refused step means signal blocked at
   once: never route around a refusal by switching runtime or retrying.

## The write boundary

OpenSpec owns approved product intent, Beads owns executable work, Git owns the
implementation. `openspec/` is **read-only** for every execution agent and is
writable only during a planning session that holds the canonical
`.nogging/locks/planning.lock` in the main checkout (`./scripts/nogg
plan-begin` … `plan-end`). The lock toggles a `.nogging/locks/openspec.readonly` sentinel;
the write guard consults it. Each tool also enforces this in its own way — see
*Tool notes*.

## Resuming a run

A planning or development run can stop mid-way — token budget, a crash, an SSH
drop, or a deliberate tool switch (Claude Code ↔ Codex). On session start —
fresh, resumed, or after a tool switch — **before selecting work with
`bd ready`**:

1. Let the `SessionStart` hook prime Beads context (or run `bd prime`).
2. Run `./scripts/nogg recover`.
3. Resolve every item it reports, using the playbook in
   `docs/failure-recovery.md` § "Resuming an interrupted run". A `LIMBO` /
   `resumable` Bead has **committed work**, complete or only its first steps:
   compare its commits (`git log --oneline --grep '\[<id>\]'`) with the task
   slice and finish what is missing; once complete, verify it (the affected
   suite, as in hard rule 3), add the evidence note with every commit SHA, and `bd close` it. **Never
   re-implement committed work** (that produces duplicate commits). A Bead
   `recover` marks `owned by session <name>` is not yours to adopt, even when it
   looks unfinished: leave its worktree, branch, commits and notes alone.
4. Only then select work with `bd ready`.

A session launched with `--bead` works only that Bead, starting from its kickoff,
not from being launched. It skips step 4, and whatever `recover` reports about any
other Bead it reports to the operator instead of resolving; `recover` says so at
the end of its output. Only `session kickoff --change` widens that scope to the
change, and the Lead then holds the change's open Beads until it signals `done`;
a custom kickoff message does neither.

## Specialist delegation

Isolated implementation or review work may be delegated to a specialist, but
**claiming a Bead, closing it, writing the evidence note, and committing stay
with the Main Worker**, and no delegated context may write `openspec/`. A
specialist works exactly one already-claimed Bead, returns a structured result,
and never claims, closes, re-statuses, or commits. A plan-relevant finding from
a specialist is recorded as a discovery by the Main Worker, not the specialist.

When a specialist's delegated, incorporated work contributes to a commit, the
Main Worker adds a `Co-authored-by: <specialist persona name> <specialist
persona email>` trailer naming that specialist (roster in
`.nogging/config.json`'s `personas` key), in addition to the Bead-ID token and
evidence note above.

How a specialist run is dispatched depends on the tool (see *Tool notes*): an
in-process subagent where the runtime has one, otherwise a separate supervised
session or inline work under the same constraints.

## Supervised sessions

Lead Agent and specialist sessions that Nogging starts run inside a named
session on the delivery host (hosted on tmux by default, or herdr; see
`docs/using-with-herdr.md`), tracked by a durable record under
`.nogging/state/sessions/` and an append-only log. Operators use
`scripts/nogg session list | attach | log | stop | cleanup` from a plain
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
`nogg-orchestrator-<slug>` session (pinned to tmux; a systemd user service keeps it alive across
crash and reboot; it is reachable from a phone via Remote Control). It is
**Claude Code only** in this version.

- **Default scope is orchestrate-only.** It reads the whole state and drives
  Planning and Lead sessions through `scripts/nogg` (`session
  launch|attach|log|stop`, `sync --now`, `recover`, `discoveries`), `bd`, and
  `git` (read + local fast-forward integration). It writes **no** file under
  `openspec/` and edits **no** implementation code.
- **The command floor and the `openspec/` boundary are lifted for it** — the
  one documented exception, keyed to `--role orchestrator` under the
  `orchestrator` profile. Nothing mechanical enforces the limits above; the
  discipline lives in `.nogging/launch-prompts/orchestrator.md`. `session
  list` / `doctor` show the session as `FULL-ACCESS`.
- **Explicit takeover only.** On an explicit `/orchestrate takeover
  {plan|code} <description>` it does one task directly — a planning task
  committed with the `Nogging-Writer: planning` trailer, or a code task
  committed with the `[<bead-id>]` token — then returns to orchestrate-only.
- **Acceptance stays human.** It never completes an acceptance report's
  `Signed-off-by:` line.

See `docs/operating-model.md` *Orchestration* and `docs/architecture.md`.

## Multi-machine mode

When `.nogging/config.json` sets `"multi_machine": true` (default `false`), a
`trusted` or orchestrator session runs `bd dolt pull` once at session start —
before reading any Beads state — and `bd dolt push` before the session ends,
if it made any Bead write (create, update, claim, close). This keeps Beads
state synchronized across machines that share one Dolt remote.

`restricted` sessions are unaffected and need no change: they already cannot
run `bd dolt push`/`pull` (no remote Dolt sync in their authority level, see
*Supervised sessions* above), and a `restricted` session's local Bead writes
land in Dolt history exactly as before — they reach the remote via the same
machine's next `trusted`/orchestrator session push, which pushes every
pending local commit, not only its own.

`./scripts/nogg doctor` separately prints a NOTE (never a failure) when
local Dolt is ahead of its configured remote. See
`docs/failure-recovery.md` for the recovery path if two machines write
before either has pulled.

## Commands

The operator entry points are `/plan`, `/discovery-review` and `/sync-now`
(see the *Commands* table in `docs/operating-model.md`). Each is a thin wrapper
over `scripts/nogg`; a tool without a command mechanism runs the same
steps by hand:

- `/plan` — allocate `scripts/nogg worktree plan <planning-id>
  <description>` from updated `origin/develop`, then in that worktree run
  `plan-begin` → discovery review → author → `validate` → commit as the `planning` writer
  → `materialize <change>` → wire dependencies → integrate into `develop` →
  `plan-end` from the planning worktree → `worktree cleanup` from the surviving
  canonical checkout (`plan-end` always precedes worktree retirement). The spec is
  committed **before** `materialize`, so a crash between the two never leaves
  Beads without a committed spec.
- `/discovery-review` — `scripts/nogg discoveries` (+ `--ack`).
- `/sync-now` — `scripts/nogg sync --now`.

Where each tool reads those command files is in *Tool notes*.

## Planning only

The Planning Agent first allocates `./scripts/nogg worktree plan
<planning-id> <description>` from updated `origin/develop` and works only in
that dedicated worktree. A supervised planner gets its worktree at launch:
`./scripts/nogg session launch --role planning --planning-id <planning-id>
--description <description>`. A bare launch stays idle; an optional `--bead`
is context only and is never claimed. After kickoff the planner runs
`plan-begin` itself. That takes the canonical planning lock in the main
checkout, owned by that session. Nobody acquires the lock on its behalf, and
a second planner reports the named owner and stops. It then writes or revises
OpenSpec, runs validation, commits the change as the `planning` writer, and
materializes Beads. It wires Beads dependencies explicitly and does not infer
them from task order. It fast-forward integrates the planning branch into
`develop`, then runs `./scripts/nogg plan-end` from the planning worktree
(`plan-end` always precedes worktree retirement) and, as the very last command,
retires the clean, integrated worktree with `./scripts/nogg worktree cleanup
<record>` from the surviving canonical checkout. If cleanup refuses, it does
not retry, force it or delete files: it reports the hand-off, `./scripts/nogg
session stop <name>`, then `./scripts/nogg worktree cleanup <record>` from the
canonical checkout, and stops. Validation names the change: `./scripts/nogg
validate` plus `openspec validate <change> --strict --no-interactive`, never a
bare `openspec validate`. Committing before `materialize`
keeps a crash in that window recoverable (`materialize` is idempotent and the
committed spec is the source of truth). Stop, cleanup and recovery never
release another session's planning lock. A held planning lock never makes
`openspec/` writable for an execution role. If an active Bead loses its task
mapping, stop and resolve the orphan explicitly; do not delete it.

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
- **Long commands.** Give `Bash` a `timeout` that covers the whole run (up to
  10 minutes). For a longer run use `run_in_background` and wait for its
  completion notification; never re-read its output or `sleep` in between.
- **Cloud sessions.** The assigned `claude/*` branch is never a PR source:
  push the branch `nogg worktree implement` / `worktree plan` allocated, and
  open the pull request from that branch instead.

### Codex

- **Write boundary.** Codex has no per-tool hook. `openspec/` stays read-only
  through the filesystem write guard (the `.nogging/locks/openspec.readonly`
  sentinel + the commit hooks); `plan-begin` / `plan-end` toggle it. The
  command floor is `.codex/rules/nogging.rules` (execpolicy `prefix_rule`
  lines), loaded once the project's `.codex/` layer is trusted.
- **Specialists.** Codex has no in-process subagent mechanism. A specialist run
  is a **separate supervised session**:
  `scripts/nogg session launch --agent codex --role specialist:<type>
  --bead <id>`, under every specialist boundary rule above. The six
  `.claude/agents/*.md` are Claude-Code-only and are not ported to Codex; there
  is no MCP bridge. Where a separate session is overkill, the Lead Agent does
  the work inline under the same constraints.
- **Operator entry points.** `.codex/prompts/{plan,discovery-review,sync-now}.md`
  (same persona and steps as the Claude commands). On a Codex build that reads
  custom prompts only from `~/.codex/prompts/`, symlink or copy them there, or
  run the `scripts/nogg` steps directly. Codex auto-loads the repo's
  `.agents/skills/**/SKILL.md`, so the OpenSpec skills are available as-is.
- **Long commands.** Give `exec_command` a `yield_time_ms` that covers the
  run. If it still returns before the command ends, wait with one
  `write_stdin` call with empty input and a yield of several minutes — never
  a loop of one-second polls. Every poll re-sends the whole context: in one
  consumer project half of all Codex tool calls were such polls.

### Pi

- **Write boundary.** Pi has no per-tool hook and no execution-policy file.
  `openspec/` writes are blocked by the project-local guard extension
  (`.pi/extensions/nogging-guard.ts`), which intercepts the `tool_call`
  event and rejects a write/edit under `openspec/` unless the
  `.nogging/locks/openspec.readonly` sentinel is absent (a planning session
  is active); `plan-begin` / `plan-end` toggle it. The same extension
  enforces the Nogging command floor on the shell tool. A second extension,
  `.pi/extensions/nogging-lifecycle.ts`, loaded beside it in every supervised
  session, reports `agent_start`, `agent_settled`, prompts and shutdown through
  `session emit` (never `agent_end`), so `session watch` classifies Pi; it is
  inert outside a supervised session and a missing file only warns. Pi's `restricted`
  authority level is **floor-only**: unlike Claude and Codex, there is no
  network or filesystem sandbox at either authority level — the guard
  extension and the `openspec/` write boundary are the only enforcement.
- **Specialists.** Pi has no in-process subagent mechanism. A specialist run
  is a **separate supervised session**:
  `scripts/nogg session launch --agent pi --role specialist:<type>
  --bead <id>`, under every specialist boundary rule above. The six
  `.claude/agents/*.md` are Claude-Code-only and are not ported to Pi. Where a
  separate session is overkill, the Lead Agent does the work inline under the
  same constraints.
- **Operator entry points.** `.pi/prompts/{plan,discovery-review,sync-now}.md`
  (same persona and steps as the Claude commands and Codex prompts). Pi reads
  `.pi/prompts/` directly from the repository — no symlink helper is needed
  (unlike Codex, which needs `codex-prompts-link` because it only reads
  custom prompts from `~/.codex/prompts/`).
- **Long commands.** Run a suite or build in one shell call that waits for it
  to finish, with a timeout that covers the run; do not re-check a running
  command.

### Antigravity

`--agent antigravity` (alias `agy`) uses `.agy.toml` profiles and the Python
`scripts/hooks/agy-guard` PreToolUse hook from `.agents/hooks.json`. Both levels
retain the command floor and canonical planning-lock OpenSpec boundary.
Restricted requires verified ask permissions; global always-proceed is refused.
No filesystem/network isolation is validated; requested sandbox mode refuses.
Launch prepares trust only for the selected worktree and refuses missing guards
or failed trust writes. Workflow skills are `.agents/skills/nogging-{plan,discovery-review,sync-now}`.
Specialists run separately with `scripts/nogg session launch --agent agy
--role specialist:<type> --bead <id>` on exactly one already-claimed Bead;
never claim, re-status, close, commit or write OpenSpec. Return structured
results and discoveries to the Main Worker. See [the Antigravity guide](docs/using-with-antigravity.md)
for exact resume, lifecycle and pending acceptance/quota limitations.
