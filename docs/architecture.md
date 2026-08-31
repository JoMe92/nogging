# Architecture

SpecForge deliberately separates semantic decisions from mechanical state
reconciliation. It is not a general-purpose ALM system.

## Data contracts

Every OpenSpec task has one immutable identifier (`TASK-<AREA>-<NNN>`). Every
materialized Bead has exactly two labels:

```text
openspec:change:<change-id>
openspec:task:<task-id>
```

Labels are used because Beads does not provide arbitrary per-issue custom
fields. An execution agent adds a note before closing a Bead containing a Git
commit SHA and validation evidence. Discoveries use a fenced `specforge-discovery`
JSON block in a Bead note.

Materialization is idempotent: rerunning it creates only missing mapped Beads
and never duplicates work. The planner creates dependencies deliberately with
`bd dep add <child> <blocking-parent>` after materialization; this keeps their
meaning explicit rather than guessing from Markdown order.

## State and safety

Changes are `open`, `done`, or `archived`. `done` requires every mapped Bead to
be closed. `archived` is an explicit Product Owner operation. The sync process
does not archive, push, close Beads, create requirements, or interpret a
discovery.

`scripts/specforge` takes a short exclusive file lock for each sync. Planning
takes a separate lock. A stale lock has a PID, host, timestamp and TTL, so it
can be inspected and removed deliberately with `plan-end --force` after a
crash. A sync failure is recorded in `.specforge/state/last-error.json` and is
safe to retry: execution-log entries have stable event keys.

The sync process sets its own narrowly scoped `SPECFORGE_WRITER=sync` commit
environment, allowing the repository hook to accept only its execution mirror.

If a planner removes a task whose Bead is active, audit fails closed. The Bead
is retained and reported as orphaned; nothing is deleted or silently closed.

## Invariants

1. Task IDs are unique.
2. Every mapped Bead points to one existing task.
3. A task is checked only when its mapped Bead is closed.
4. A change cannot be done while a mapped Bead is not closed.
5. Execution agents do not alter `openspec/`.

Invariant 5 is enforced by the repository hook. Requirement-to-code fidelity is
not claimed to be automatically decidable; tests, review and Product Owner
acceptance remain the evidence for that judgement.
