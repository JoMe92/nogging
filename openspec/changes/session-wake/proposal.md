## Why

Agents finish fast and then nobody notices. Between 2026-10-27 and 2026-10-30
in this repository, a Pi Lead reached its pull request in 5 minutes and waited
4 h 50 min for a merge, another waited 12 h 45 min, two sessions sat for 2 days
with uncommitted work, and a Codex Lead that hit a sandbox refusal wrote the
blocker into a Bead note and stopped for 90 minutes. The Product Owner asked on
2026-10-30 for this to be researched and solved cleanly: finished sessions must
be recognized immediately, for Claude Code, Codex and Pi, and it must be
token-efficient. Antigravity stays experimental.

Waking the orchestrator is what costs. Measured on its transcript for those
3.5 days: 61 wakes, 9.5 assistant messages per wake, a mean context of 320k
tokens, 54M tokens a day. Its own "wait in the background for CI" watchers made
41 % of those wakes and 46 % of the tokens. A wake after more than an hour idle
also misses the one-hour prompt cache and rewrites the whole context, which on
the list price of Opus 5.5 costs 40 times a cached read. So sparse wakes alone
do not save much: they move the spend from reads to writes. The saving needs
fewer wakes, fewer turns per wake and a smaller orchestrator context together.

## What Changes

- **One normalized lifecycle stream.** Claude hooks, a new always-loaded Pi
  lifecycle extension and Codex's rollout feed the same per-session view of
  state and signals. `session emit` keeps a bounded, redacted excerpt of the
  agent's last message. Pi stops being `unknown` in `session watch`, and a Claude
  session stops reading `idle` during any turn after its first.
- **`session signal blocked|done`.** A machine-readable way for a Lead to end
  its work that works in every runtime and sandbox, including one that cannot
  reach Dolt.
- **A Lead never stops silently.** A pure completion check (uncommitted work,
  unpushed commits, missing signal) drives a bounded stop guard that uses each
  runtime's own mechanism: `decision: "block"` on Claude's and Codex's `Stop`
  hooks and `continue: true` on Pi's `agent_before_settle`. The guard costs a
  Lead turn, never an orchestrator turn. Launch prompts state the rule.
- **Codex hooks through an explicit user-level install.** `nogg session-hooks
  install --agent codex` adds one user-level hook, gated on the supervised
  session's environment, and records its trust. Project hooks cannot work in a
  Lead worktree and `--dangerously-bypass-hook-trust` is refused, because Codex
  hooks run outside its sandbox. Without the install, Codex still reports
  through its rollout and only loses the stop guard.
- **A deterministic dispatcher.** `nogg session dispatch` is a stateless,
  level-triggered pass that reconciles every Lead's real state each tick: it
  nudges a Lead with a fixed message, tracks CI through the existing
  observation, finishes a usage-limit resume, and retires a merged session.
  It uses no model. It is opt-in with `session_dispatch.enabled`.
- **One coalesced wake digest.** Only decisions reach the orchestrator:
  blocked, needs input, crashed, stuck after its nudges, ready for review.
  Items wait for a quiet period, drop out if their condition clears, and
  arrive as one short message that holds what the orchestrator needs to decide,
  delivered through the verified idle-only send path. `nogg session inbox`
  shows the same data on demand.
- **Orchestrator wake protocol and context budget.** The orchestrator acts on a
  digest in a few turns and runs no background watcher of its own. Its launch
  sets a compaction budget, and the dispatcher compacts it before the cache
  expires when the native idle compaction does not.
- **A user pause and quiet hours.** `nogg pause --until|--days` and `nogg resume` let
  the user switch automation off for a few days and on again: no digest or keep-warm to
  the orchestrator, loops skipped except named ones, events kept and delivered as one
  digest when the pause ends by itself or by `resume`. `wake.quiet_hours` holds wakes
  inside daily windows. Both are shown in `doctor`, `session list` and `loop list`.
- **A keep-warm rule.** While work is active the dispatcher sends one minimal message
  shortly before the one-hour cache lapses, because one cold start costs 20 to 40 warm
  empty wakes. With nothing active, in quiet hours or paused, it compacts the
  orchestrator once and lets the cache expire. The user guide explains the cost, when
  keep-warm pays, when pausing does, and the commands.
- **Runtime capabilities are explicit.** `nogg session capabilities` states what
  an agent and profile can do, so a kickoff never demands the impossible, and a
  sandboxed child-session launch fails with a clear message instead of a raw
  `Errno 30`.

## Capabilities

### New Capabilities

- `session-wake`: the dispatcher, its deterministic follow-ups, nudge bounds,
  the wake queue and digest, delivery, the inbox and its diagnostics, quiet hours,
  the keep-warm rule, and the user pause.

### Modified Capabilities

- `session-observability`: normalized lifecycle events for every focus runtime,
  `session signal`, the completion check and stop guards, the Codex user-level
  hook, runtime capabilities.
- `orchestration-agent`: the wake protocol, no self-made watchers, the context
  budget, the keep-warm answer and pausing on instruction.
- `installer`: ships the new modules and the Pi extension, inactive by default.

## Impact

New: `scripts/lib/session_signals.py`, `scripts/lib/session_dispatch.py`,
`scripts/lib/session_pause.py`, `scripts/lib/session_warm.py`,
`.pi/extensions/nogging-lifecycle.ts`, `docs/session-wake.md`, new offline
suites. Changed: `scripts/nogg` (`session emit`, `signal`, `dispatch`, `inbox`,
`completion-check`, `capabilities`, `session-hooks`, `classify_session`,
`doctor`, `pause`, `resume`, `session list`, `loop list`, hook wiring), `.nogging/launch-prompts/{autonomous,orchestrator}.md`,
`.claude/commands/orchestrate.md`, `AGENTS.md`, `templates/nogging-config.json`,
`bin/lib/manifest.js`, and the operating-model, architecture, commands,
configuration, failure-recovery and per-runtime pages.

`nogg loop tick` from `scheduled-loops` runs the dispatch pass, and the
idle-only send helper of `TASK-SCL-005` is reused rather than duplicated.
`pi-extensions-glm-usage` is unaffected: optional extensions stay under
`.pi/nogging/`, and this mandatory one lives beside the guard.

Existing installs need no migration. With `session_dispatch` absent, nothing
nudges, retires or wakes; only the richer `session watch` and event file are
visible. Antigravity keeps its current events and pane classification and gets
no guard, no nudge and no new hook.

Not in scope: an open-ended pause, a pause that stops running sessions, push notifications to a human, a resident daemon, Claude Code
Channels or `asyncRewake` as the delivery path, automatic merging, a dispatcher
that launches sessions, and signing human acceptance.
