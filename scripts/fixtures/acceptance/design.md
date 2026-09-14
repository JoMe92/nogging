# Design

## Context

This is a fixture change for the Nogging acceptance runbook. It must be a
structurally complete OpenSpec change (`proposal` / `design` / `tasks` /
`specs`) with stable task IDs so `scripts/nogg validate` and
`scripts/nogg materialize` act on it exactly as they would a real change.

## Goals / Non-goals

- Goal: two tasks with stable IDs (`TASK-ACCEPTX-001`, `TASK-ACCEPTX-002`) that
  materialize to exactly two Beads.
- Goal: nothing here resembles real Nogging product intent.
- Non-goal: shipping an `echo-note` feature. The tasks are placeholders an
  acceptance run satisfies with a stub closure, not real implementation.

## Decisions

### Task ID prefix is `ACCEPTX`, not `ACCEPT`

The `end-to-end-acceptance` change owns `TASK-ACCEPT-001..010`. The fixture uses
the distinct `ACCEPTX` prefix so a `task_map()` scan that ever sees both trees
at once cannot collide the fixture's IDs with the real change's IDs.

### The capability is deliberately trivial

`echo-note` writes a line back verbatim to an append-only file. One requirement,
one scenario. No options, no state machine, no external surface — so no reader
mistakes the fixture for a real capability.
