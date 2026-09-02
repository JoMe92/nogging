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
