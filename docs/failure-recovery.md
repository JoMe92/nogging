# Failure recovery

Run `./scripts/specforge doctor` first. It reports tool availability, locks,
mapping errors and the last sync failure without modifying data. Run
`./scripts/specforge audit` for the same invariant checks plus a timestamped
local report.

For a failed sync, inspect `.specforge/state/last-error.json`, resolve the
underlying Beads, Git or lock issue, then rerun `./scripts/specforge sync`.
Sync is idempotent. Do not edit its cursor by hand. For a stale planning lock,
confirm its process is gone and run `./scripts/specforge plan-end --force`.

If an active Bead is orphaned, the planner must either restore/relink its task
or cancel the Bead with a recorded reason. Never delete a closed Bead. Roll back
an incorrect execution-log update with a normal Git revert and then rerun sync.
