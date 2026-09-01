# Add the planning and discovery slash commands

## Why

The concept conversation of 2026-08-31 (`docs/source/konversation-export.md`,
sections 3, 5 and 9) describes three operator entry points that drive the
existing `scripts/specforge` bridge:

- `/plan` switches the top-level session into the Planning Agent persona: review
  discoveries, hold the design dialogue, then author OpenSpec, validate, and
  materialize Beads — all inside one planning-lock session.
- `/discovery-review` runs the same discovery review on its own, without
  entering full planning mode, so an operator can triage what is waiting.
- `/sync-now` forces an immediate reconciliation instead of waiting for the
  30-second timer.

None of these exist. `scripts/specforge` already provides every mechanical
primitive they need — `plan-begin`, `plan-end`, `discoveries` (already sorted
blocking-first), `sync`, `validate`, `materialize` — and the write-boundary
guard already gates `openspec/` writes on `.specforge/locks/planning.lock`. What
is missing is the operator-facing surface: there are no `.claude/commands/*.md`
files, and `docs/operating-model.md` already names `/discovery-review` as if it
were real. The Planning Agent persona is described in prose but not injected by
any command.

## What changes

- **`/plan` command:** a `.claude/commands/plan.md` that injects the Planning
  Agent persona and walks one planning session end to end — acquire the lock via
  `scripts/specforge plan-begin`, run the discovery review first, hold the
  design dialogue, author or revise the change, `scripts/specforge validate`,
  `scripts/specforge materialize <change>`, commit with `SPECFORGE_WRITER=planning`,
  then `scripts/specforge plan-end`.
- **`/discovery-review` command:** a `.claude/commands/discovery-review.md` that
  runs `scripts/specforge discoveries` and presents the result blocking-first,
  then guides the operator through acknowledging the ones that need no further
  action. It does not acquire the planning lock and does not author OpenSpec.
- **`/sync-now` command:** a `.claude/commands/sync-now.md` that triggers an
  immediate reconciliation. Because the installed sync unit is a systemd oneshot
  timer and not a long-lived daemon, `/sync-now` runs `scripts/specforge sync`
  directly; if a future long-lived daemon publishes a PID file it also signals
  it. A `scripts/specforge sync` invoked while the timer holds the sync lock
  reports the contention rather than corrupting state.
- **Documentation:** `docs/operating-model.md` gains a short "Commands" section
  describing the three entry points and what each is and is not allowed to do.

## Impact

- Affected specs: `workflow-commands` (new capability).
- Affected code (implementation deferred to execution): new
  `.claude/commands/plan.md`, `.claude/commands/discovery-review.md`,
  `.claude/commands/sync-now.md`; possibly a thin `scripts/specforge sync`
  invocation path for the on-demand case; `docs/operating-model.md`.
- Depends on `reliable-beads-sync`: `/discovery-review` acknowledges discoveries
  through the acknowledgement ledger that `reliable-beads-sync` (TASK-SYNC-006)
  specifies. This change defines the command surface; the ledger storage and
  semantics belong to that change.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
