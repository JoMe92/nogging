# Operating model

## Roles

- **Product Owner:** describes desired outcomes, decides ambiguities, accepts and archives changes.
- **Planning Agent:** works only in a deliberate planning session; writes OpenSpec and creates/reconciles Beads.
- **Main Worker:** selects `bd ready`, delegates isolated implementation work, validates, commits, records evidence and closes Beads.
- **Specialists:** work only on a claimed Bead and report results to the Main Worker.
- **Sync timer:** polls every 30 seconds and mirrors facts only.

## Branches and commits

`main` is the stable integration branch. `develop` is the active integration
branch. Use Conventional Branches: `feat/<change-id>`, `fix/<change-id>`,
`chore/<topic>`. Use Conventional Commits, for example
`feat(import): add filesystem picker [SPEC-abc123]`.

Planning changes are committed on their change branch and merged into `develop`
after `./scripts/specforge validate`. The timer makes local commits only when
there is a tracked execution-log update; it never pushes.

## Session supervision

Every Claude Code session SpecForge starts for Lead Agent or specialist work
runs inside a **named tmux session on the Pi**, under a dedicated tmux server
socket (`tmux -L specforge`) that is isolated from the operator's own tmux. The
session is started with `scripts/specforge session launch --role <lead |
specialist:<type>> --bead <id> [--cwd <path>] [--read-only]`, which:

- generates a collision-free name `sf-<role>-<bead>-<nonce>`;
- writes a durable JSON record to `.specforge/state/sessions/<name>.json`
  (Bead ID, role, host, start time, working directory, redacted launch
  command, owner, lifecycle state, log path) **before** the Claude process
  starts, so the association survives an SSH drop or a restart of the launcher;
- streams all console output to an append-only `<name>.log` beside the record
  (`tmux pipe-pane` → `scripts/session-log-writer`, size-rotated);
- starts Claude through `scripts/session-launch` with the restricted profile
  `.specforge/session-launch-profile.json` (no `git push`, no remote Dolt
  sync, no destructive shell, scoped to the working directory) and the
  no-autonomous-claim system prompt.

`session launch` performs **no `bd` mutation**. Being launched is not
permission to start a Bead — claiming stays a deliberate in-session action the
operator directs.

From any plain SSH shell (no `TERM`, no tmux client needed):

| Command | What it does |
| --- | --- |
| `session list` | every managed session with Bead, role, age, working dir, owner, state; reconciles each record against live tmux and reports a vanished `running` session as `failed`. Read-only, never attaches. |
| `session attach <name> [--read-only]` | attach the terminal to a session (`-r` blocks input). The only command that attaches. |
| `session log <name> [--follow]` | print or tail the append-only log without attaching. |
| `session stop <name> [--reason <text>]` | interrupt Claude, terminate the pane after the grace period, record `stopped` with `ended_at`/`exit_reason`. Idempotent. |
| `session cleanup [<name>]` | remove a lingering tmux session, archive-rotate the log, retire the record. **Refuses** a `starting`/`running`/`idle` record — stop it first. |

### Relationship to Task-tool specialists

The specialist roster (`specialist-agents-and-skills`) defines the six
specialists as **Task-tool subagents of the Lead Agent's session**. That is
still the default: when the Lead Agent delegates an isolated implementation or
review pass, it does so **in process** with the Task tool. Those calls do not
get their own tmux session or metadata record — they run inside the Lead
Agent's supervised session, share its restricted profile, and are visible in
that session's own log.

A specialist run gets **its own observable tmux session** only when it must run
as a separate, long-lived Claude Code process — a large self-contained chunk of
work the operator wants to watch, attach to, or stop independently. The
operator (or the Lead Agent on operator direction) then runs `session launch
--role specialist:<type> --bead <id>`. Such a launched specialist still obeys
every specialist boundary rule: one already-claimed Bead, no `openspec/`
writes, no claim/close/commit, discoveries reported up to the Lead Agent.

## Discoveries

Agents record every material discovery on their active Bead using the native
Beads `discovery` label plus a required human-readable note:

```bash
bd update <id> --add-label discovery --append-notes "<prose summary>"
```

Execution agents never edit `openspec/`, so every discovery waits for the next
planning session (`bd list --label discovery`) and does not alter an approved
OpenSpec change automatically.

A discovery is **non-blocking** when the claimed task still finishes as
specified; the agent keeps working. It is **blocking** when the task cannot be
finished sensibly as specified; the agent also runs `--status blocked` and
moves to the next independent Bead. `/discovery-review` lists blocked
discoveries first so they do not get lost.
