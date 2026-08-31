# SpecForge agent instructions

Read `README.md`, `docs/operating-model.md`, and the active Bead before work.

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

## Planning only

The Planning Agent first runs `./scripts/specforge plan-begin`, writes or
revises OpenSpec, runs validation, materializes Beads, commits, then runs
`./scripts/specforge plan-end`. If an active Bead loses its task mapping, stop
and resolve the orphan explicitly; do not delete it.
