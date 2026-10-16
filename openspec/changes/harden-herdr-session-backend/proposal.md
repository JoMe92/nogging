## Why

The real Pi acceptance of `add-herdr-session-backend`
(`docs/acceptance/2026-10-16-herdr-backend.md`) ended **Overall: fail**
(26 pass, 9 fail) with discoveries D1–D10 on `SPEC-emer`. Some defects are
dangerous regardless of herdr. `session cleanup` can kill the shared tmux
server under the Orchestration Agent (D6). A day-old `orchestrator.lock` with a
live holder reads as stale and halts every autonomous Lead. `task-done` ticks
the wrong checkout (D10). The herdr backend is unsafe in the normal
multi-checkout, sandboxed-Lead topology (D1, D9). It cannot recover a stopped
server (D2). Logs, nudge verification and Codex resume fall short of the spec
(D3, D4, D5, D7). The Product Owner's goal stays the same: switch quickly
between tmux and herdr, with nothing reachable from outside.

## What Changes

- **Shared tmux server is never killed by cleanup (D6).** `session cleanup`
  stops the dedicated `tmux -L nogging` server only when that server hosts no
  session at all, whatever the current checkout's records say.
- **Orchestrator lock staleness is liveness-bound.** The lock records the
  holder's PID, process start time and PID namespace. A holder verified alive
  is never stale, whatever the lock's age. A caller that cannot observe the
  holder's namespace never reports it stale. `recover`, `doctor`,
  `orchestrator status` and `orchestrator run` apply the same rule.
- **`task-done` ticks the requesting checkout (D10).** The sandbox broker
  ticks the `tasks.md` of the checkout that asked, and only when that checkout
  is a registered worktree of the same repository. Anything else is refused.
- **herdr server and identities are host-namespace safe (D9).** The dedicated
  herdr server is started only outside the OpenSpec sandbox. Receipts and
  records carry the PID namespace of every PID they store. Each pane is also
  identified by herdr's `terminal_id`, which works from any namespace. No
  caller reads or signals a PID that belongs to another namespace.
- **Recovery while the herdr server is down (D2).** A definite "server not
  running" answer makes the server's records vanished, not unknown, so reap,
  a same-Bead launch and exact resume proceed. A new `session herdr-server
  start` command starts or verifies the dedicated server from the host
  namespace.
- **Cleanup touches only this checkout's herdr panes (D1).** A pane counts as
  an orphan only when the current checkout's record store names it.
- **No stray shell pane (D8).** The root `/bin/bash` pane that `workspace
  create` opens is closed once the first session pane exists.
- **Byte-based bounded log (D3, both backends).** `session-log-writer` appends
  output as it arrives, without waiting for a newline. Its memory and every
  log generation stay within `session_log_max_bytes`. Cleanup archives every
  rotated generation.
- **Agent-specific submit verification (D4, D5).** A Codex `nudge --message`
  is delivered like `send`, through `codex queue`. A Codex pane message that
  cannot be positively verified fails as unverified and never reports
  success. An Antigravity classifier ignores the permanent status bar, and on
  herdr a `working` or `done` agent status counts as submitted.
- **Codex exact resume (D7).** `session launch --resume <thread-id>` supports
  Codex through `codex resume <id>` inside the unchanged launch wrapper. The
  requirement is kept, not dropped.
- **Docs and re-acceptance.** The herdr guide, failure recovery, session and
  Codex docs are updated. A new unsigned real Pi acceptance report repeats
  every failed check and regresses the passed ones. The Product Owner signs
  it.

## Non-Goals

- Switching the default backend to herdr, or removing tmux.
- Moving the Orchestration Agent off tmux.
- Any network listener, herdr remote access, plugins, or integrations that
  Nogging installs.
- Changing the sandbox model itself. Sandboxed Leads keep their PID
  namespace; this change only makes herdr safe around it.
- Protecting a tmux server that a sandboxed Lead starts itself (see
  `design.md` *Risks*).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-backends`: tmux server stop rule, host-namespace server start,
  namespace-safe identities, a definite-down state and a recovery command,
  checkout-scoped orphans, no root shell pane, and guide topics.
- `claude-sessions`: a live, byte-bounded log on both backends, and cleanup
  that leaves the shared tmux server running and archives every log
  generation.
- `orchestration-agent`: liveness-bound orchestrator-lock staleness.
- `sync-safety`: the immediate tick lands in the requesting checkout.
- `session-observability`: agent-specific submit verification for Codex and
  Antigravity.
- `agent-neutral-launch`: exact resume for Codex.

## Impact

- Code: `scripts/nogg` (cleanup tail, orchestrator lock, `task_done` client,
  the nudge/verify region, launch resume gating, the new `session
  herdr-server` subcommand, orphan notes, `_archive_log`),
  `scripts/lib/session_backend_herdr.py`, `scripts/lib/session_backend_tmux.py`,
  `scripts/openspec-sandbox` (broker request), `scripts/session-log-writer`
  (rewritten byte-based, stdlib only), `scripts/session-launch` (Codex
  resume).
- Tests: one new suite per task, all runnable on GitHub runners with no Dolt
  or `bd`, no PID-range assumptions, no user namespaces, and socket paths under
  108 bytes. Existing suites change only where they asserted a fixed defect.
- Docs: `docs/using-with-herdr.md`, `docs/failure-recovery.md`,
  `docs/running-work-in-sessions.md`, `docs/using-with-codex.md`,
  `docs/operating-model.md`, `docs/architecture.md`, plus a new acceptance
  report.
- Host: no new dependency. Installs that use only tmux see one behaviour
  change: the shared tmux server is no longer killed under other sessions.

This planning artifact authorizes no execution work, release, push or human
acceptance sign-off.
