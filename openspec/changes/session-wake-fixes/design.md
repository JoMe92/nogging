## Context

The three fixes touch separate code and share no state, so they are separate tasks.
Design Decision 1 of `session-wake` (offline suites, injected clocks, no real agent,
Dolt, `bd` or network) holds for all of them. Every claim below was read from the
code or measured on the delivery host on 2026-10-31.

## Decisions

### 1. The rollout is the primary evidence of a Codex limit

`session_codex_delivery.last_turn` already walks the rollout's `event_msg` records and
describes the last turn. A limit lives in the terminal `task_complete` record:

```json
{"timestamp":"2026-10-31T07:46:19.094Z","type":"event_msg","payload":{"type":"task_complete",
 "last_agent_message":null,"error":{"message":"You’ve hit your usage limit. ... or try again at 12:51 PM.",
 "codex_error_info":"usage_limit_exceeded"}}}
```

`last_turn` gains `error`: `{"kind": <codex_error_info when it is a string, else
None>, "message": <message cut to 200 characters>, "at": <record timestamp>}`, or
`None` for a clean turn. A non-string `codex_error_info` (Codex uses objects for
other errors) yields `kind: None`, never a guess. The reader stays bounded and
tolerant: an unknown shape is `None`.

`classify_session_detail` maps a Codex last turn that ended in `kind ==
"usage_limit_exceeded"` to the rollout state `limit`, in `resolve_state`'s existing
slot (event, rollout, herdr, pane). A `working` rollout still wins, so a resumed
turn is seen at once; an `idle` event or pane never hides a rollout `limit`. The
state stays `limit` until a new turn starts, which is the rollout turning
`working`. The watch `limit` event carries `until`, and the excerpt is the cleaned
message, redacted like any excerpt (the message holds a URL, no secret).

### 2. The pane is a fallback, and a stale message never outranks a running turn

Add `limit` patterns to `CODEX_ADAPTER` for `hit your usage limit`, written to accept
both `'` and `’`, because the pane prints one and the rollout the other. The pane has
no scrollback, but the message can stay visible below a resumed turn's first lines,
and the shared precedence puts `limit` above `working`. So for Codex the pane
`limit` counts only when the pane also shows the idle composer and no `Working (`
marker. This keeps a resumed turn `working` and still catches a session whose rollout
cannot be found.

### 3. The reset time is read against the event, not against now

`resolve_clock_time(text, now)` resolves `12:51 PM` against `now`'s date and rolls
to the next day when that is earlier. The wake-up can come hours later, so the base
is the error's own timestamp converted to local time, which is the clock Codex
printed. A time that is past by then (the common case after an overnight wait) is
simply over. The pane fallback keeps resolving against now, as it does today. When no
time is readable, `until` is `None`.

### 4. The dispatcher waits, resumes once, and never nudges a limit

`_limit_step` already waits for a known reset when `limit_source` is `event`. The
rollout source behaves the same: wait until `until`, then send the one resume. The
pane source for Codex is treated the same too, since a Codex pane limit does not
clear on its own. Nudge steps already need `idle`, so none fires while the state is
`limit`; a test pins that, because the failure was two nudges.

A resume whose turn hits the limit again is a new limit: the resume key includes
the error's timestamp, not only the first `since`, and the stored `until` is
replaced from the newer error. Each limit error is resumed at most once, so a
weekly limit that outlasts the reported reset cannot loop.

With no readable reset time the dispatcher sends nothing and queues one `stuck`
item once, with the reason `usage limit, reset time unknown` and the excerpt,
instead of staying silent behind a misleading `idle, clean, no pull request`. The
item clears when the state leaves `limit`.

### 5. The usage gate is untouched

The gate reads Codex usage as unknown at launch (`docs/usage-limits.md`). Making
it known is a separate change; this one only stops a session that is already at its
limit from being mistaken for idle.

### 6. Pi emit: wait longer, never block, keep order

The extension runs each `scripts/nogg session emit` as an unref'd, serialized
`execFile`, so a slow child never blocks Pi and events append in Pi's order.
Only the timeout kills a slow child before it appends. Raise `EMIT_TIMEOUT_MS` from
3000 to 20000. The cost is bounded and invisible to Pi: a stuck child delays only
later events, by at most the timeout each, and `drain` still gives shutdown at most
`DRAIN_MS`. The guard's own 8000 ms check is separate and unchanged.

Rejected: a retry after a kill, because a kill after the append would duplicate a
`guard_continue` and the stop guard counts those. Rejected for now: a second,
cheaper entry point that appends without starting `scripts/nogg`. It would
duplicate the schema, the field whitelist, the excerpt redaction and the rotation
in TypeScript, and the measured cost (about 1.3 s idle, 3.5 s under load) is within
a 20 s bound. If a loss is ever seen again at 20 s, that is the next step. The
cause was measured, not reproduced, so the acceptance task checks the Pi first
turn again.

### 7. One reducer for a rollup: the newest run per check

`gh` returns `statusCheckRollup` entries of two kinds: a CheckRun (`name`,
`workflowName`, `status`, `conclusion`, `startedAt`, `completedAt`) and a
StatusContext (`context`, `state`, `startedAt`). Add one pure helper
`_latest_check_entries(rollup)` that keeps, for each key (`workflowName` plus `name`
for a CheckRun, `context` for a StatusContext), only the entry with the latest
`startedAt`, falling back to `completedAt`. Ties, or entries with no usable time,
keep the worse outcome, because losing a real failure is the harm the rollup exists
to prevent. A newer run that is still pending makes the check pending, and a newer
failure makes it failing.

`_observe_checks` and `_pr_state_for_branch` both call it before they classify. The
fingerprint is computed over the reduced entries, so a re-run that fails again
still gets a new fingerprint, and a superseded run no longer changes it. A
malformed rollup still yields `unknown` and never a pass.

A rollup that holds a run from another pull request on the same commit (PR #354
and #355 shared `82dc660`) is reduced the same way; no PR-number filter is needed.

### 8. One short re-acceptance on the delivery host

A new report covers only what failed: the Codex limit (a replayed real rollout and
pane, because the limit cannot be forced on demand), the Pi first turn under load,
and a fail-then-pass on one commit. The fail-then-pass can be shown live with a
throwaway branch whose workflow is re-run. It stays unsigned.
