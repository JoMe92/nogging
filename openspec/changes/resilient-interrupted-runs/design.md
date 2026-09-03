# Design

## Context

`docs/source/crash-resilience-handoff.md` is the full analysis and the source
for this change; §5 lists every proposed item with its rationale. This design
restates the mechanism decisions and the sequencing. W5 (sync-timer rails, §5.5)
is out of scope — `sync-timer-branch-safety` shipped it.

Relevant existing shape in `scripts/specforge`:

- `validate()` returns `(tasks, issues, problems)`; `sync()` raises
  `AuditError` on any `problems`. `doctor()` prints the problems as `FAIL` lines.
- `materialize(change)` loops `bd create` after `validate()`; it is idempotent
  (the "already mapped" set is built from the full-status Beads read).
- `lock()` / `fresh_lock()` handle lock TTL. `session_records()` /
  `reconciled_state()` know a record whose tmux is gone is `failed` for display
  but do not persist that.
- `last-success.json` now carries `{"at", "branch"}` (from
  `sync-timer-branch-safety`).

## Goals / Non-goals

- Goal: one read-only command answers "what was in flight, what is safe to
  resume, what must not be redone".
- Goal: a crash in the planning flow never leaves Beads without a committed
  spec.
- Goal: a committed-but-open Bead is detected, not silently re-implemented.
- Goal: the resume decision is guided by a documented playbook, tool-neutrally.
- Non-goal: auto-resuming a turn — `recover` + the playbook make resume *safe
  and fast*; a human or the next agent still decides *what* to resume.
- Non-goal: a distributed lease/lock manager; power-loss / disk-corruption
  resilience.
- Non-goal: the sync-timer rails (done in `sync-timer-branch-safety`).
- Non-goal: materializing Beads or editing implementation files in this planning
  session.

## Decisions

### `recover` — read-only, one report, exit code

`scripts/specforge recover` (and `doctor` calls the same checks). Sections, each
skipped when empty:

- **Locks** — `planning.lock` / `sync.lock`: age vs TTL, `pid`/`host`, `pid`
  alive on this host; `held (fresh)` vs `STALE`.
- **LIMBO** — for every non-merge commit in `git rev-list --no-merges
  <base>..HEAD` (base = the configured integration branch, from
  `sync_protected_branches` or a `recover_base_branch` key), extract the
  `\[[A-Z][A-Z0-9]*-[0-9a-z]+\]` token; if that Bead's status is not `closed`:
  `LIMBO: SPEC-x committed in <sha> "<subject>" but status=<status>`.
- **`in_progress` Beads** — id, mapped task, assignee, `updated_at` age, whether
  a `[id]` commit exists: `resumable` (commit exists), `stale`
  (`updated_at` older than `claim_stale_seconds`, no commit), `active`.
- **Materialized-but-uncommitted** — a live change whose `tasks.md` is
  `git`-dirty and has mapped Beads, or whose change dir is absent from
  `git log`; cross-check a `materialize-<change>.json` journal if present.
- **Orphan Beads** — the `validate()` "maps missing task" set.
- **Crashed sessions** — `session_records()` in an active state with no live
  tmux.
- **Working tree** — `git status --porcelain` one-liner; note a merge/rebase/
  cherry-pick in progress.
- **Last sync** — `last-success.json` age + branch; the active
  `sync-failure.json` / `last-skip.json` if any.

Exit non-zero if any LIMBO, stale lock, orphan, materialized-but-uncommitted, or
crashed session is present; zero otherwise. Strictly read-only — no `bd`
mutation, no file writes.

### `validate()` grows a `warnings` list

`validate()` returns `(tasks, issues, problems, warnings)`. The committed-but-
open check populates `warnings`, not `problems`, so `sync()`'s `AuditError`
path is unchanged and the timer keeps mirroring closed Beads. `doctor` prints
warnings as `WARN` lines; `recover` folds them into its LIMBO section. Every
current caller of `validate()` is updated for the new arity.

### Commit-before-materialize

The canonical order becomes:
`plan-begin` → author → `validate` → **commit (`SPECFORGE_WRITER=planning`)** →
**`materialize <change>`** → `bd dep add …` → `plan-end`.

Safe because `materialize` is idempotent and the committed spec is the source of
truth; Bead deps live in Dolt, not git. Update every surface that states the
order: `docs/operating-model.md`, `AGENTS.md` + `templates/agents-block.md` +
`templates/claude-block.md`, `.claude/commands/plan.md`, `.codex/prompts/plan.md`,
and any string `scripts/specforge` prints.

`materialize()` writes `.specforge/state/materialize-<change>.json` =
`{started_at, tasks_planned: [...], tasks_created: [...]}`, updated per
`bd create`, deleted on clean completion. `recover` reads it: a journal present
after a crash tells exactly which tasks still need a Bead.

### Resumption protocol + playbook

`AGENTS.md` gains a **"Resuming a run"** section: on session start (fresh,
resumed, tool switch) — prime Beads context, run `./scripts/specforge recover`,
resolve every item via the playbook, *then* `bd ready`. The playbook is a new
`docs/failure-recovery.md` section, one row per `recover` finding (see handoff
§5.2 for the exact table). Key rule: a `LIMBO` / `resumable` Bead's work is
**done** — verify with `scripts/test`, add the evidence note, `bd close`; **do
not re-implement**.

### Intent breadcrumbs (no code)

`AGENTS.md` hard rules gain: before an expensive or hard-to-reverse step, and
before ending a turn with a Bead still `in_progress`, append a one-line
`progress: <next step>` to the Bead note. This is the primary "where was I"
signal on resume, for any tool.

### `session reap`

`scripts/specforge session reap` (and `session cleanup --reap`): for each record
in `starting`/`running`/`idle` whose tmux session is gone, `transition(...
"failed", exit_reason="tmux session vanished during a reap")`. `session cleanup`
(no name) then retires it. `docs/failure-recovery.md` "A crashed or stuck
supervised session" leads with `session reap`.

### Stale-claim labelling

`.specforge/config.json` gains `"claim_stale_seconds"` (default e.g. 14400 = 4 h).
`recover` labels an `in_progress` Bead older than that, with no `[id]` commit,
as `stale`. No lease/heartbeat mechanism — `updated_at` + the breadcrumb rule
are enough.

### Dolt durability checkpoint — verify first

A task runs `bd dolt status` / checks the `--dolt-auto-commit` policy after a few
`bd` writes to see whether bead state sits uncommitted in the working set. If it
does for long stretches, add a `bd dolt commit` (or the documented equivalent)
at the end of `sync()` and `materialize()`. If the shared server's disk
persistence already covers process-crash / token-exhaustion (the in-scope
cases), document that and ship nothing.

## Risks / open questions

- `validate()` arity change touches several call sites (`sync`, `doctor`,
  `materialize`, `audit`, the tests). Do it in one task with the tests.
- The `recover` base-branch resolution must not assume `develop`; take it from
  config with a sensible default and cover a detached-HEAD / no-base case.
- The commit-before-materialize reorder changes documented behaviour in five
  places at once; a single task keeps them consistent and a test asserts the
  `/plan` command text matches `docs/operating-model.md`.
- `bd dolt commit` semantics are version-dependent — the verify-first task must
  record what it found before any code is written.
