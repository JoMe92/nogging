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

## Per-discovery prompt

After rendering the list, walk the operator through the discoveries one at a
time (blocking ones first). For each, offer exactly three outcomes:

1. **Carry into a `/plan` session** — the discovery needs an OpenSpec change.
   Note which discovery the operator wants carried; it is picked up in step 2
   of the next `/plan` session. This command does not author anything.
2. **Acknowledge** — no spec change is needed and it should stop being
   surfaced. Record it with:

   ```bash
   scripts/specforge discoveries --ack <bead-id> [<bead-id>...]
   ```

   This writes the acknowledgement ledger (`.specforge/state/acknowledged-discoveries.json`);
   a later `/discovery-review` no longer lists an acknowledged discovery. If
   `--ack` is unavailable (an older `scripts/specforge` without the ledger),
   degrade to *leave pending* and note the operator's acknowledgement decision
   in this dialogue so it is not lost.
3. **Leave pending** — no decision yet. Do nothing; it surfaces again next
   time.

## Boundaries

- Do not acquire the planning lock — never run `scripts/specforge plan-begin`.
- Do not write `openspec/` — never create or modify any file under `openspec/`.
- Carrying a discovery into a spec change is a `/plan` session's job, not this
  one's.
- The only state this command may write is the acknowledgement ledger, via
  `scripts/specforge discoveries --ack` (see the per-discovery prompt).
