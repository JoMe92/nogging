# Design

## Context

`scripts/specforge` is the deterministic bridge. It already exposes the
subcommands the three operator commands need:

- `plan-begin` / `plan-end` — acquire and release `.specforge/locks/planning.lock`.
  The `PreToolUse` guard (`scripts/hooks/pre-tool-use-openspec-guard`) blocks any
  Edit/Write under `openspec/` unless that lock exists, so the lock *is* the
  Planning Agent's write authority.
- `discoveries` — prints every pending discovery, blocking ones first, with the
  human-readable note. Sorting is already implemented.
- `validate` / `materialize <change>` — the invariant audit and Bead creation.
- `sync` — one reconciliation pass under an exclusive sync lock.

What does not exist: any `.claude/commands/*.md` file, and any mechanism that
puts the session into the "Planning Agent" persona. `CLAUDE.md` defines the
default (Main Worker / Lead Agent) behaviour; `docs/operating-model.md` describes
the Planning Agent in prose and already refers to `/discovery-review` by name.
The Planning Agent and Lead Agent are session personas of the top-level session,
not subagents (conversation §9).

The sync unit shipped by `specforge-installer` is a systemd **oneshot** service
fired by a timer every 30 seconds. There is no resident daemon process, so the
`SIGUSR1`-to-a-PID-file trigger from conversation §3 has nothing to signal in the
current design.

## Goals / Non-goals

- Goal: `/plan` runs a complete planning session against the existing
  `scripts/specforge` subcommands, with the discovery review as its first step.
- Goal: `/discovery-review` gives the same triage view standalone, without
  acquiring the planning lock or authoring OpenSpec.
- Goal: `/sync-now` forces a reconciliation now instead of at the next timer tick,
  and degrades cleanly when the timer already holds the sync lock.
- Goal: the commands are thin and declarative — they orchestrate existing
  primitives and carry persona instructions, they do not reimplement logic.
- Non-goal: re-implementing the planning lock, the guard, or discovery sorting —
  all already done.
- Non-goal: defining the acknowledgement-ledger file format or semantics — that
  is `reliable-beads-sync` (TASK-SYNC-006); this change only invokes it.
- Non-goal: building a long-lived sync daemon or a live channel between the
  Planning Agent and the Lead Agent (§9: they communicate only through the shared
  OpenSpec/Beads state).
- Non-goal: materializing Beads or editing implementation files in this planning
  session.

## Decisions

### `/plan` drives a full planning session

`.claude/commands/plan.md` injects the Planning Agent persona and prescribes the
fixed sequence:

1. `scripts/specforge plan-begin` (or report and stop if the lock is already
   held by another session).
2. Run the discovery review (the same step as `/discovery-review`) and fold any
   acknowledged or actionable discovery into the dialogue.
3. Hold the design dialogue with the Product Owner; resolve ambiguities before
   writing.
4. Author or revise the change folder (`proposal.md`, `design.md`, `tasks.md`,
   `specs/<capability>/spec.md`).
5. `scripts/specforge validate`.
6. `scripts/specforge materialize <change>`.
7. Commit the `openspec/` changes with `SPECFORGE_WRITER=planning` set (the
   `commit-msg` and `pre-commit` hooks require that writer for `openspec/` paths).
8. `scripts/specforge plan-end` to release the lock.

The command file states the hard rules already in `AGENTS.md`: an orphaned Bead
(lost task mapping) stops the session for explicit resolution; the Planning Agent
may consult the `architect` specialist but performs no execution work.

### `/discovery-review` is the triage view without the lock

`.claude/commands/discovery-review.md` runs `scripts/specforge discoveries` and
renders the output as-is (blocking first). For each discovery it prompts the
operator with three outcomes: **carry into a `/plan` session** (needs an OpenSpec
change), **acknowledge** (no spec change needed — record it so it stops
resurfacing), or **leave pending**. Acknowledgement is performed through the
mechanism `reliable-beads-sync` adds; until that lands, `/discovery-review`
records the decision only by leaving the discovery pending and noting it in the
dialogue. The command never calls `plan-begin` and never writes `openspec/`.

### `/sync-now` runs the pass directly, signals a daemon only if one exists

`.claude/commands/sync-now.md`:

1. If a sync daemon PID file exists at a documented path
   (`.specforge/state/sync.pid`) and the process is alive, send `SIGUSR1` and
   report that the running daemon was asked to reconcile now.
2. Otherwise run `scripts/specforge sync` directly.
3. If `scripts/specforge sync` reports the sync lock is held (the 30-second timer
   is mid-pass), surface that message and exit without retrying — the timer will
   finish on its own.

No PID file is produced by the current oneshot timer, so path 2 is the normal
case today. Path 1 is specified now so a future resident daemon needs no command
change. Optionally, execution may add a `scripts/specforge sync --now` alias that
encapsulates steps 1–3 so the command file stays a one-liner.

### Command files are declarative and tool-portable where possible

The three files live under `.claude/commands/` because slash commands are a
Claude Code feature. Their *content* — the step sequences and the persona rules —
duplicates nothing: it points at `scripts/specforge`, `AGENTS.md`, and
`docs/operating-model.md`. `AGENTS.md` keeps a one-line pointer to the commands so
a non-Claude tool can run the same `scripts/specforge` sequence by hand.

## Risks / open questions

- The Planning Agent persona is prose injected by a command, not an enforced
  mode. The only hard enforcement is the write-boundary guard on the lock; a
  session that never runs `/plan` still cannot write `openspec/`. That is
  acceptable and matches §9.
- `/sync-now`'s daemon path is speculative. If no resident daemon is ever built,
  the PID-file branch is dead code; keeping it is cheap and documents intent.
- Ordering against `reliable-beads-sync`: `/discovery-review`'s acknowledge
  action is fully useful only once the ledger exists. This change can land first
  with acknowledgement degraded to "leave pending and note it", then gain the
  ledger call when TASK-SYNC-006 completes.
- Slash-command file format may evolve; the files must stay thin so a format
  change is a mechanical edit, not a redesign.
