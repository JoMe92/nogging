# Tasks

## Phase 1 — make interruptions safe to resume (P0)

- [x] TASK-RIR-001 Add a `warnings` list to `validate()` (return `(tasks, issues, problems, warnings)`) and update every caller (`sync`, `doctor`, `materialize`, `audit`, the tests). `sync()`'s `AuditError` path stays keyed on `problems` only.
- [x] TASK-RIR-002 Add the committed-but-open-Bead check: for each Bead with a `[<id>]` token commit on the current branch and `status != "closed"`, add a `warnings` entry `LIMBO: <id> committed in <sha> but status=<status>`. `doctor` prints it as `WARN`.
- [x] TASK-RIR-003 Add `scripts/specforge recover` per the design "recover" decision: read-only (no `bd` mutation, no writes), the eight sections it lists (locks, LIMBO from `git rev-list --no-merges <base>..HEAD` with `<base>` from a new `recover_base_branch` config key, `in_progress` classification, materialized-but-uncommitted, orphans, crashed sessions, working-tree/mid-op, last-sync), and the non-zero exit condition it specifies.
- [x] TASK-RIR-004 Have `doctor` run `recover`'s checks (or accept `doctor --recover`); keep `doctor` read-only and its existing exit semantics for tool availability.
- [x] TASK-RIR-005 Reorder the canonical planning flow to commit-before-materialize everywhere it is stated: `docs/operating-model.md`, `AGENTS.md`, `templates/agents-block.md`, `templates/claude-block.md`, `.claude/commands/plan.md`, `.codex/prompts/plan.md`, and any string `scripts/specforge` prints. Add a test that the `/plan` step list matches `docs/operating-model.md`.
- [x] TASK-RIR-006 Have `materialize()` write `.specforge/state/materialize-<change>.json` (`{started_at, tasks_planned, tasks_created}`), update it per `bd create`, and delete it on clean completion; `recover` reads a leftover journal to report exactly which tasks still need a Bead.
- [x] TASK-RIR-007 Add a "Resuming a run" section to `AGENTS.md` (prime context → `./scripts/specforge recover` → resolve every item via the playbook → then `bd ready`) and the per-finding playbook to `docs/failure-recovery.md` (handoff §5.2 table; the LIMBO/resumable rule: the work is done, verify + note + close, never re-implement).

## Phase 2 — reduce the ways a run goes wrong (P1)

- [x] TASK-RIR-008 Add the intent-breadcrumb rule to `AGENTS.md` hard rules (and the marker-block templates): before an expensive or hard-to-reverse step, and before ending a turn with a Bead still `in_progress`, append a one-line `progress: <next step>` to the Bead note.
- [x] TASK-RIR-009 Update `docs/operating-model.md` with the reordered flow and a one-paragraph pointer to `recover`; make sure `docs/using-with-codex.md` and `docs/running-work-in-sessions.md` reference the resumption protocol where relevant.

## Phase 3 — polish (P2)

- [x] TASK-RIR-010 Add `.specforge/config.json` `claim_stale_seconds` (default 14400) and have `recover` label an `in_progress` Bead older than that, with no `[id]` commit, as `stale`.
- [x] TASK-RIR-011 Add `scripts/specforge session reap` (and `session cleanup --reap`): move every `starting`/`running`/`idle` record whose tmux session is gone to `failed` (`exit_reason="tmux session vanished during a reap"`) so `session cleanup` retires it; update `docs/failure-recovery.md` "A crashed or stuck supervised session" to lead with `session reap`.
- [x] TASK-RIR-012 Verify the Dolt commit cadence (`bd dolt status` / `--dolt-auto-commit` after several `bd` writes); if bead state can sit uncommitted for long stretches, add a `bd dolt commit` (or the documented equivalent) at the end of `sync()` and `materialize()`; otherwise record the finding in `docs/failure-recovery.md` and ship no code. Record what was found on the Bead before any code.

## Tests

- [x] TASK-RIR-013 `scripts/specforge.test.sh` (stub `bd`, `SPECFORGE_ROOT` scratch repo): `recover` reports a committed-but-open Bead as LIMBO and exits non-zero; a stale lock; an `in_progress` Bead with a commit as `resumable`; a change dir with mapped Beads but a dirty `tasks.md` as materialized-but-uncommitted; a leftover `materialize-<change>.json` naming the missing task; a clean repo exits zero. `validate()` returns the LIMBO warning without reddening `sync`.
- [x] TASK-RIR-014 `scripts/session.test.sh`: `session reap` moves a `running` record with no tmux to `failed`; `session cleanup` then retires it; a live record is untouched.
