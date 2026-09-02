---
description: Triage pending discoveries without entering a planning session.
---

# /discovery-review — triage pending discoveries

Show the operator every pending discovery and help them decide what to do with
each one. This is the standalone triage view; it is **not** a planning session.

## Steps

1. Run `scripts/specforge discoveries`.
2. Render its output **unchanged**. The command already sorts blocking
   discoveries first, then open ones, then closed-but-unreviewed ones, and
   prints each discovery's id, status, title, and human-readable note. Do not
   re-sort, summarise, truncate, or reformat it — present it as-is.
3. If it prints `no pending discoveries`, say so and stop.

## Boundaries

- **Do not acquire the planning lock.** Never run `scripts/specforge
  plan-begin`. This command holds no lock.
- **Do not write `openspec/`.** Never create or modify any file under
  `openspec/`. Carrying a discovery into a spec change is a `/plan` session's
  job, not this one's.
- The only state this command may write is the acknowledgement ledger, via
  `scripts/specforge discoveries --ack <bead-id>...` (see the per-discovery
  prompt).
