# SpecForge agent instructions

Read `README.md`, `docs/operating-model.md`, and the active Bead before work.

## Hard rules

1. Execution agents (Main Worker and specialists) must not edit `openspec/`.
2. Work only on a Bead that has been claimed by the Main Worker.
3. Before closing, run relevant validation, commit with a Conventional Commit
   containing the Bead ID, and add a Bead note with the commit SHA and evidence.
4. Record material discoveries in the active Bead as a fenced JSON block:

```specforge-discovery
{"type":"review","blocking":false,"summary":"...","evidence":"...","suggested_action":"..."}
```

Use `automatic` only for narrow, backward-compatible details. Everything else
is `review` and remains for the next Product Owner planning session.

## Planning only

The Planning Agent first runs `./scripts/specforge plan-begin`, writes or
revises OpenSpec, runs validation, materializes Beads, commits, then runs
`./scripts/specforge plan-end`. If an active Bead loses its task mapping, stop
and resolve the orphan explicitly; do not delete it.
