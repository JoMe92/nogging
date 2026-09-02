---
description: Force an immediate SpecForge reconciliation instead of waiting for the timer.
---

# /sync-now — reconcile now

Trigger a reconciliation pass immediately rather than waiting for the
30-second `specforge-sync.timer` tick.

## Steps

1. **If a resident sync daemon is running, signal it.** If
   `.specforge/state/sync.pid` exists and names a live process, send it
   `SIGUSR1` and report that the running daemon was asked to reconcile now:

   ```bash
   kill -USR1 "$(cat .specforge/state/sync.pid)"
   ```

2. **Otherwise run a pass directly.** Run `scripts/specforge sync` and report
   its result. The installed sync unit is a systemd **oneshot** timer, not a
   resident daemon, so no PID file exists today — this is the normal path.
   Step 1 is kept so a future resident daemon needs no command change.

## Sync-lock contention

`scripts/specforge sync` takes an exclusive sync lock. If the 30-second timer
is mid-pass it already holds that lock, and the command exits non-zero with a
message like:

```
specforge: sync lock held by <host> pid <pid>; use --force only after verifying it is stale
```

When that happens, **surface the message to the operator and stop.** Do not
retry, do not loop, do not pass `--force`. The timer finishes its pass on its
own within a few seconds and the next tick reconciles anything left. Retrying
here only races the timer.
