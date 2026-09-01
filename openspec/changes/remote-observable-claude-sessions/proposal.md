# Make SpecForge-launched Claude sessions remotely observable

## Why

The concept conversation of 2026-08-31 (`docs/source/konversation-export.md`,
sections 5, 6 and 9) established that SpecForge runs a Lead Agent (Main Worker)
session and delegates isolated implementation work to specialist agents. Today
those Claude Code sessions are treated as ephemeral foreground processes: the
docs describe specialists only as "per Task-Tool aufgerufen" and nothing in the
repository says where a session runs, how an operator sees it, or how it is
stopped.

The delivery host is a Raspberry Pi that the Product Owner reaches over SSH.
Without a supervision substrate:

- A running Lead Agent or specialist session is invisible from a fresh SSH
  shell. There is no way to list what SpecForge is currently running, for which
  Bead, since when, or in which working directory.
- There is no durable record of a session. If the launching process or the SSH
  connection drops, the association between a Claude session and its Bead is
  lost.
- There is no way to look at what a session is doing without being the terminal
  that launched it, and no append-only transcript to inspect after the fact.
- Stopping a session and cleaning up after it are undefined operations, so a
  stuck session is killed ad hoc with `kill` and leaves no trace.
- Nothing constrains a launched session from autonomously running `bd ready`
  and claiming work, which contradicts the operating model where claiming is a
  deliberate Main Worker action.

## What changes

- **Named tmux sessions on the Pi:** every Claude Code session SpecForge starts
  for Lead Agent or specialist work runs inside a tmux session on the Pi, under
  a dedicated tmux server socket, with a deterministic collision-free name that
  encodes the role and the Bead.
- **Durable runtime metadata:** each session has an on-disk metadata record
  holding the Bead ID, the role, the start time, the working directory, the
  launch command (with secrets redacted), the owner, and a lifecycle state.
  The record survives a restart of the launching process.
- **Remote listing and attach:** a SpecForge command run from any SSH shell
  lists every managed session with its metadata, and a second command attaches
  to a named session (with a read-only option). Listing never requires
  attaching.
- **Inspectable log:** each session streams its console output to an
  append-only log file that is readable without attaching to the tmux session;
  the log path is recorded in the metadata.
- **Deliberate attach, stop and cleanup:** attach, stop and cleanup are
  explicit operator commands. Stop terminates the Claude process and the tmux
  session and records a final state. Cleanup removes the tmux session and
  retires its metadata, and runs only after the session has completed its task
  or been stopped — never against a running session.
- **No autonomous claiming:** a launched session does not claim or start a Bead
  as an automatic consequence of being launched; it operates on the Bead passed
  to it and claiming stays a deliberate action.

## Impact

- Affected specs: `claude-sessions` (new capability).
- Affected code (implementation deferred to execution): `scripts/specforge` (or
  a dedicated session-supervisor module invoked by it), `.specforge/config.json`
  (tmux socket name, session-state directory, log retention, launch profile),
  `.claude/settings.json` and any launch permission profile, `AGENTS.md`,
  `docs/operating-model.md`, `docs/architecture.md`, `docs/failure-recovery.md`.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
- Behavioural change for operators: Lead Agent and specialist sessions are
  started, observed and stopped through SpecForge session commands rather than
  as ad hoc foreground processes.
