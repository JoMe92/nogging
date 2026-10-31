## Why

Source: the live acceptance of `session-wake` on the delivery host,
`docs/acceptance/2026-10-31-session-wake.md`, recorded as discoveries on Bead
`SPEC-qzau` (TASK-SWK-008). Real Claude, Codex and Pi sessions proved the core
path, and three behaviours failed. Each root cause was verified in code and, where
the host allowed, against the real rollout and event files:

1. **A Codex usage limit is read as idle.** The rollout's `task_complete` carries
   `error.codex_error_info: "usage_limit_exceeded"` and a message ending in `try again
   at 12:51 PM`. The pane prints `You've hit your usage limit`. Neither is read: the
   Codex pane adapter has no `limit` pattern, and `last_turn` drops the `error`
   field. The state was `idle`, two `no-pr` nudges (each an instantly failed turn)
   went out a minute apart, `stuck` was queued with the wrong reason, and no resume
   was sent after the limit lifted.
2. **Pi lifecycle events are lost under load.** `.pi/extensions/nogging-lifecycle.ts`
   kills `scripts/nogg session emit` after `EMIT_TIMEOUT_MS = 3000`. On this host
   `scripts/nogg` alone takes 1.3 s idle and 2.2 to 3.5 s at load 16. The guard fired
   in the pane but `guard_continue` and `turn_end` never reached the event file, so
   the dispatcher read `working` for five minutes and sent no nudge.
3. **A superseded failed check still counts as red.** GitHub's `statusCheckRollup`
   keeps every run on a commit. `_observe_checks` reports any failed entry, so a
   later success on the same commit does not clear it. This produced a false
   `ci_stuck` on PR #350 and false nudges on PR #355. `_pr_state_for_branch` reads
   the same rollup and treats any non-passing entry as unresolved.

## What Changes

- **Codex limit.** The rollout turn reader exposes the terminal error. A Codex last
  turn that ended in `usage_limit_exceeded` classifies as `limit`, as does a Codex
  pane that shows the usage-limit message while idle. The reset time comes from the
  message, resolved against the event's own timestamp. The dispatcher sends no nudge
  while the limit stands, resumes once after the reset, and treats a resume that hits
  the limit again as a new limit with its own reset. With no readable reset time it
  sends nothing and queues one `stuck` item naming the limit.
- **Pi emit.** The Pi lifecycle extension waits longer for `session emit` before it
  gives up, still never blocking Pi, and a test drives it with a slow `scripts/nogg`.
- **Latest run per check.** One shared helper reduces a rollup to the newest entry
  per check name before `_observe_checks` and `_pr_state_for_branch` classify it.
  An older failure of the same check no longer counts, a newer failure still does,
  and the fingerprint is computed over the reduced list.
- **Re-acceptance.** One short report on the delivery host re-runs the failed rows.

**Not changed:** the dispatcher's budgets, digest rules and quiet hours; the Claude
`rate_limit` path and the Antigravity limit path; the usage gate (Codex usage still
reads as unknown at launch); the Claude and Codex hooks.

**Finding 4 is a practice gap, not code, and is noted here only.** `retire_merged`
has no live candidate on this host, because the orchestrator's merge routine stops a
session within seconds of the merge, before the dispatcher's step runs. The feature
stays unproven live. Letting the dispatcher retire first, or dropping the
orchestrator's own stop, is a working-practice decision for the Product Owner and
the Orchestration Agent. Two further notes on `SPEC-qzau` are not planned here
either: `scripts/nogg worktree rebase` refusing a Lead that allocated its own
worktree from the main checkout ("requester session does not own this checkout"),
and the unproven rows (keep-warm, pause, quiet hours, native compaction), which need
the operator and are listed in the acceptance report.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-observability`: Codex usage-limit evidence from the rollout and the
  pane; the Pi lifecycle emit tolerates a slow `scripts/nogg`.
- `session-wake`: the limit wait and one resume; the latest run per check decides
  red, green and merged-state checks.

Both capabilities' base requirements are still carried by the unarchived
`session-wake` change, so this change only ADDS requirements with new names and
modifies none; archive it after `session-wake`.

## Impact

- `scripts/lib/session_codex_delivery.py` (`last_turn` terminal error),
  `scripts/lib/session_signals.py` (`resolve_state` and state mapping for a rollout
  `limit`), `scripts/lib/session_dispatch.py` (`_limit_step`), `scripts/nogg`
  (`CODEX_ADAPTER`, `classify_session_detail`, `_dispatch_evidence`, watch `until`,
  `_observe_checks`, `_pr_state_for_branch`).
- `.pi/extensions/nogging-lifecycle.ts`.
- Suites: `session-codex-*`, `session-signals`, `session-dispatch` (and the Python
  unit tests beside them), `pi-lifecycle`, `session-sweep-checks`.
- Docs: `docs/session-wake.md`, `docs/using-with-codex.md`,
  `docs/using-with-pi.md`, `CHANGELOG.md` [Unreleased]. No new config key, no
  authority change, no dependency.
