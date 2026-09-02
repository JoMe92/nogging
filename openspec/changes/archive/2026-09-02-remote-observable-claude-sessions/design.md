# Design

## Context

SpecForge already runs on the Pi as a deterministic, no-LLM bridge
(`scripts/specforge`) plus a set of Claude Code personas and specialist agents
described in `docs/operating-model.md`. The operating model names a Main Worker
that selects `bd ready`, delegates isolated implementation work, and closes
Beads, and specialists that "work only on a claimed Bead and report results to
the Main Worker".

What the repository does not define is the *process* substrate for those
sessions. This change adds one: a thin supervision layer that launches each
Claude Code session inside tmux, records durable metadata about it, and exposes
list / attach / log / stop / cleanup operations that work from a plain SSH
shell. It deliberately stays mechanical — it starts and tracks processes; it
makes no product decision and does not itself drive a Claude session.

## Goals / Non-goals

- Goal: from a fresh SSH shell an operator can see every SpecForge-managed
  Claude session, its Bead, its role, its age, its working directory and its
  state, without attaching to anything.
- Goal: the association between a Claude session and its Bead is durable across
  a restart of the launching process and across SSH disconnects.
- Goal: an operator can read what a session has been doing (append-only log) and
  can deliberately attach, stop, and clean up.
- Goal: session names never collide.
- Goal: a launched session never claims or starts a Bead on its own.
- Goal: no credential or secret is written to a log, to metadata, or to tmux
  scrollback; a session runs with least authority.
- Non-goal: materializing Beads for this change or editing implementation files
  in this planning session.
- Non-goal: supervising sessions on hosts other than the Pi (single-host for
  now; the metadata records a host field to keep multi-host open later).
- Non-goal: a web UI, a daemon that auto-restarts crashed sessions, or any
  scheduling of which Bead runs next.
- Non-goal: changing the change lifecycle (`open`, `done`, `archived`) or what
  the sync process does.

## Decisions

### tmux as the supervision substrate

tmux is already present on the Pi, is SSH-native, survives disconnects, and
gives attach/detach and output capture for free. SpecForge uses a **dedicated
tmux server socket** (e.g. `tmux -L specforge`) so managed sessions are
isolated from the operator's personal tmux and are trivially enumerable with
`tmux -L specforge list-sessions`. The tmux server runs as the same
non-privileged user as SpecForge; no `sudo`, no root.

### Session naming

Names are deterministic and collision-free:

```
sf-<role>-<bead-id>-<short-nonce>
```

where `<role>` is `lead` or `spec-<specialist-type>` (for example
`spec-backend-engineer`), `<bead-id>` is the mapped Beads issue ID, and
`<short-nonce>` is a short timestamp or random suffix. Before creating a
session SpecForge checks `tmux has-session -t <name>` (and the metadata store);
on any collision it fails or regenerates the nonce rather than reusing or
overwriting an existing session. A single Bead may legitimately have had
several sessions over time (a retried specialist run); the nonce keeps their
names and their logs distinct.

### Durable metadata store

One JSON record per session under `.specforge/state/sessions/<name>.json`:

- `name` — the tmux session name;
- `bead_id` — the Beads issue the session is for;
- `role` — `lead` or `specialist:<type>`;
- `host` — the Pi's hostname;
- `started_at` — ISO-8601 UTC;
- `working_dir` — absolute path the Claude process runs in;
- `command` — the launch argv, **with secret-bearing arguments and env values
  redacted**;
- `owner` — the operating-system user (and, when known, the human operator) who
  launched it;
- `state` — one of `starting`, `running`, `idle`, `stopped`, `failed`;
- `log_path` — path to the append-only log;
- `ended_at`, `exit_reason` — set on stop or failure.

The record is written before the Claude process is exec'd and updated on every
state transition. Because liveness also lives in tmux, `list` cross-checks each
record against `tmux list-sessions`: a record in state `running` with no tmux
session is reported as `failed` (crash) rather than silently trusted. The store
is local state, is not committed, and is safe to delete (a deleted record just
drops history for an already-finished session).

### Append-only log

At launch SpecForge runs `tmux pipe-pane -o` on the session's pane to stream
all pane output to `<name>.log` beside the metadata record. The log is a plain
file: `cat`, `tail -f`, `less` all work from any SSH shell with no tmux attach.
Log growth is bounded by a size cap from config with simple rotation
(`<name>.log` → `<name>.log.1`); rotation is size-based only, matching the
conversation's note about the sync failure log.

### Lifecycle operations

All five are explicit subcommands; none happens as a side effect of another:

- `session launch --role <r> --bead <id> [--cwd <path>]` — create the tmux
  session, write metadata, start the log pipe, exec Claude with the restricted
  profile. Refuses if the Bead does not exist or a live session already covers
  the same role+Bead.
- `session list` — print every record with live-state reconciliation. Read
  only. Works from a plain SSH shell.
- `session attach <name> [--read-only]` — `tmux -L specforge attach -t <name>`
  (with `-r` when `--read-only`). Purely an operator action.
- `session log <name> [--follow]` — print / follow the log file. Never attaches.
- `session stop <name> [--reason <text>]` — send the Claude process an
  interrupt, then terminate the pane/session if it does not exit within a grace
  period; set state `stopped`, record `ended_at` and `exit_reason`. Idempotent.
- `session cleanup [<name>]` — kill the (already dead-or-stopped) tmux session
  if any lingering, rotate the log to an archived name, and mark the record
  retired. **Refuses on a record whose state is `running`, `idle` or
  `starting`** — an operator must `stop` first. With no name, cleans up only
  records already in a terminal state.

### No autonomous claiming

The launch profile does not grant the session a "pick the next ready Bead"
instruction, and the session prompt states that claiming and starting a Bead is
a deliberate action taken on operator direction, not on launch. For a
specialist this is already the rule ("work only on a claimed Bead"); for the
Lead Agent the session may still run `bd update --claim` later, but only as an
in-session step the operator asked for — never as an automatic consequence of
being started. `session launch` itself never runs any `bd` mutation.

### Least authority and no credential logging

- The Claude session is started with a **restricted permission profile**: no
  `git push`, no remote Dolt sync, no destructive shell, scoped to the working
  directory. It gets no more authority than the delegated work needs.
- Secrets are never passed as command-line arguments (visible in `ps` and in
  the metadata `command`). Any token needed is read from the environment or a
  file by the child; the metadata `command` and the log redact known
  secret-bearing variable names and values.
- `tmux pipe-pane` captures pane output; the launch wrapper must ensure no
  `set -x`, no `echo $TOKEN`, and no credential prompt is echoed into the pane.

## Risks / open questions

- **tmux server lifetime:** the dedicated `-L specforge` server persists after
  its last session ends; `session cleanup` should optionally `kill-server` when
  no records remain. Execution confirms this does not race a concurrent
  `launch`.
- **Crash vs idle detection:** distinguishing an idle-but-alive Claude session
  from a hung one is heuristic. The design only requires reporting `idle` vs
  `running` best-effort and `failed` when the tmux session is gone; a richer
  health check can follow later.
- **Read-only attach:** `tmux attach -r` prevents keystrokes but a determined
  operator can still detach and re-attach writable; it is a convenience guard,
  not a security boundary.
- **Relationship to the Task-tool specialist model:** the current docs describe
  specialists as Task-tool subagents. This change treats a specialist run that
  needs its own observable session as a launched tmux session; the doc update
  (TASK-SESSION-010) must reconcile the two framings rather than leave both.
- **Config defaults:** tmux socket name, `sessions/` directory, log size cap and
  rotation depth, stop grace period, and the restricted profile path need
  concrete values in `.specforge/config.json`, consistent with existing keys
  like `sync_lock_ttl_seconds`.
- **Owner identity:** on a single-user Pi the OS user is not very informative;
  execution decides whether to also capture `SSH_CONNECTION` / an operator name
  passed to `launch`.
