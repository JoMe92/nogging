## Why

Every Nogging-supervised session runs in tmux. tmux keeps processes alive and
gives Nogging an append-only log, but it knows nothing about the agent inside
the pane: Nogging has to scrape screens to guess whether a Claude, Codex or
Antigravity session is idle, working or blocked, and it delivers input by
simulating keystrokes.

herdr (https://herdr.dev, github.com/herdrdev/herdr, Rust, Apache-2.0, v0.9.x,
linux-aarch64 build available) is a terminal multiplexer built for coding
agents. It reports a live per-agent status (idle/working/blocked/done, with
integrations for Claude, Codex and Antigravity), offers native conversation
resume, and exposes a local Unix-socket API (`pane.send_text`,
`pane.send_keys`, `agent.prompt`, `agent.wait`, `pane.read`) instead of
keystroke simulation.

The Product Owner has decided (2026-10-15, through the Orchestration Agent)
that Nogging gets a **switchable session backend**: `tmux` stays the default
and the permanent fallback, and `herdr` is added as a second backend. This
change does not reopen that decision. It plans the safe, test-backed
introduction of herdr while every existing tmux guarantee stays intact.

The research (`research_notes/Herder und Nogging Sessionverwaltung/`,
`reports/Herder und Nogging Sessionverwaltung.md`, unversioned, 2026-10-15)
found the tmux coupling to be narrow. It is one wrapper
(`scripts/nogg` `tmux()` / `tmux_has_session` / `tmux_sessions`) with about
40 call sites, plus the usage-reservation liveness probe in
`scripts/nogg_usage.py`. The research also names four gaps that must be proven
or worked around before anything is built:

1. herdr has no append-only log: `events.subscribe` is not durable, and
   `pane.read` returns only a window.
2. It is undocumented whether `pane.read` keeps the ANSI attributes that the
   nudge placeholder detection needs (SGR dim).
3. It is undocumented whether pane IDs stay stable across a herdr server
   restart.
4. A herdr server restart, or `herdr update` without `--handoff`, ends every
   pane process.

## What Changes

- **Gate spike first.** The first task installs herdr v0.9.x at user level
  (`~/.local/bin`, no sudo, release checksum verified) and tests it for real on
  the delivery Pi, under the real Nogging launch wrapper. It checks five
  things: (a) status detection for Claude, Codex and Antigravity; (b) ANSI/dim
  attributes in `pane.read`; (c) pane-ID stability across a server restart;
  (d) native resume per agent after a server restart; (e) an append-only log
  captured by a PTY recorder without breaking the Codex or Antigravity TUI.
  The results are Bead evidence. If two or more of these fail, the spike
  records a blocking discovery and the change returns to planning. Every other
  task depends on the spike.
- **Backend seam.** A primitive-only backend interface: start, send_text,
  send_keys, capture, alive, list, kill, attach, log_capture, plus optional
  pid and agent_status. Records, locks, Beads binding, reap, kickoff/nudge
  logic and the usage gate stay above the seam and are backend-neutral.
- **tmux backend** = today's behaviour, moved behind the seam into
  `scripts/lib/session_backend_tmux.py` without any behaviour change. Every
  existing test stays green.
- **Backend selection.** A new `session_backend: tmux|herdr` config key
  (default `tmux`) and a per-launch `--backend` override. Session records get a
  `backend` field, and a legacy record without one means tmux. Mixed backends
  run at the same time: `list`, `reap`, `stop`, `cleanup`, `attach` and `send`
  each follow the record's own backend. The Orchestration Agent stays pinned
  to tmux.
- **herdr backend** (`scripts/lib/session_backend_herdr.py`) over the local
  `herdr` CLI, in a dedicated herdr session namespace. It includes:
  - an append-only, size-rotated log through a new PTY recorder
    (`scripts/session-pty-recorder`) feeding the existing
    `scripts/session-log-writer`;
  - liveness bound to the launched process;
  - nudge/send verification, or a documented deviation with a replacement
    check;
  - a new optional `agent_status` field in `session list`, shown as `-` for
    tmux.
- **Setup and diagnostics.** `doctor` herdr checks (binary, version, server
  reachable) run only when `session_backend=herdr` or herdr records exist, and
  print nothing otherwise. Adds a `docs/using-with-herdr.md` install and
  operations guide, including the `herdr update --handoff` warning.
- **Tests.** Script and unit tests run against a fake `herdr` CLI stub, because
  CI has no herdr. A real acceptance task on the Pi runs one Lead session each
  with Claude, Codex and Antigravity over herdr, exercises
  send/nudge/log/stop/reap, and writes an acceptance report with a blank
  `Signed-off-by:` line for the Product Owner.

## Non-Goals

- Moving the Orchestration Agent off tmux + systemd (`Restart=always`,
  `claude --continue`). That is a later change.
- Switching the default to herdr, or removing tmux. The default switch is a
  later change after a period of parallel operation.
- herdr plugins, web or phone access, or a Nogging web UI (parked in
  `tmp/ideen/nogging-web-oberflaeche/`).
- Any new network listener. herdr's socket is a local Unix socket and is never
  exposed.
- Nogging installing herdr or herdr agent integrations on the operator's
  behalf. The guide documents a user-level install; Nogging only detects and
  reports.
- Replacing Nogging's per-agent pane adapters (`session watch`) with herdr's
  status. `agent_status` is reported alongside them, not instead of them.

## Capabilities

### New Capabilities

- `session-backends`: the switchable session backend: selection, the primitive
  seam, mixed-backend dispatch, the herdr backend (log recorder, liveness,
  nudge/send verification, agent status, attach), the Orchestration Agent pin
  and herdr diagnostics.

### Modified Capabilities

- `claude-sessions`: the substrate, list/attach, and attach/stop/cleanup
  requirements now name the record's session backend instead of hard-wiring
  tmux.
- `run-recovery`: reap follows the record's backend.

## Impact

- Code: `scripts/nogg` (every tmux call site routed through the seam, plus
  launch selection, list columns and doctor). New modules
  `scripts/lib/session_backend.py`, `scripts/lib/session_backend_tmux.py` and
  `scripts/lib/session_backend_herdr.py`. New helper
  `scripts/session-pty-recorder`. Changes to the reservation liveness probe in
  `scripts/nogg_usage.py`. New fake-herdr fixtures under
  `scripts/fixtures/herdr/`.
- Packaging: `package.json` `files` and `bin/lib/manifest.js` ship the new
  modules, helper and guide.
- Docs: new `docs/using-with-herdr.md`. Updates to
  `running-work-in-sessions.md`, `operating-model.md`, `architecture.md`,
  `security-model.md`, `failure-recovery.md`, `compatibility.md`, `README.md`,
  `AGENTS.md` and the backend-neutral launch-prompt wording.
- Host: herdr is optional and user-level. Default installs that keep `tmux`
  see no change.
- Effort: about 12 tasks, executed by parallel Codex and Antigravity Lead
  sessions in separate worktrees (see `design.md` *Dependencies and
  parallel lanes*).

This planning artifact authorizes no execution work, release, push or human
acceptance sign-off.
