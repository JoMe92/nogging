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

## Supervised sessions

Lead Agent and specialist sessions that SpecForge starts run inside a named
tmux session on the delivery host, tracked by a durable record under
`.specforge/state/sessions/` and an append-only log. Operators use
`scripts/specforge session list | attach | log | stop | cleanup` from a plain
SSH shell; see `docs/operating-model.md`.

If you are running inside such a session:

- Being launched is not permission to start a Bead. Do not run `bd ready` and
  self-assign work; claim only the Bead the operator names, only when they
  direct it in this session.
- You have a restricted permission profile (no `git push`, no remote Dolt
  sync, no destructive shell). Do not work around it.
- Never echo a credential or token value and never pass one on a command line.

A session the operator launches with `--full-access` (the `trusted` profile +
the `autonomous` prompt) *is* authorised to commit, push its branch, and
fast-forward-merge to `develop` — but only for the single named change it was
started for. Every other hard rule still holds: no `openspec/` edits, no
touching another change's Beads, discoveries recorded, commit-and-note before
closing a Bead. A short command floor (`rm -rf`, `sudo`, `dd`, `mkfs`,
`shutdown`, `reboot`, fork bomb) is denied under every profile.

A specialist delegated **in process** through the Task tool runs inside the
Lead Agent's session and shares these constraints. A specialist gets its own
supervised session only when the operator launches one explicitly for isolated
long-running work; it still works exactly one already-claimed Bead and never
claims, closes, or commits.

## Planning only

The Planning Agent first runs `./scripts/specforge plan-begin`, writes or
revises OpenSpec, runs validation, materializes Beads, commits, then runs
`./scripts/specforge plan-end`. If an active Bead loses its task mapping, stop
and resolve the orphan explicitly; do not delete it.
