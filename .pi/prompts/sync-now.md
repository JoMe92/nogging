---
description: Force an immediate Nogging reconciliation instead of waiting for the timer.
---

# /sync-now — reconcile now

Trigger a reconciliation pass immediately rather than waiting for the
30-second `nogg-sync.timer` tick.

## Step

Run:

```bash
scripts/nogg sync --now
```

That single command encapsulates all three cases:

- **Resident daemon running** — if `.nogging/state/sync.pid` names a live
  process it is sent `SIGUSR1` and asked to reconcile now. No daemon exists
  under the current oneshot timer; this path is kept for a future one.
- **No daemon** — a reconciliation pass runs directly (the normal path today).
- **Sync lock held by the timer** — the command prints that the lock is held
  and exits without retrying. The timer finishes its pass within a few seconds
  and the next tick reconciles anything left. Surface that message to the
  operator and stop; do not loop and do not pass `--force`.

Report the command's output to the operator.
