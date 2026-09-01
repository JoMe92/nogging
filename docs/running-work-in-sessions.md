# Running work in supervised sessions

A practical guide to `scripts/specforge session` — starting a Claude Code
session on the delivery host, watching it, steering it, and shutting it down.

For the design and internals see the *Session supervision* sections of
`operating-model.md` and `architecture.md`. For a session that crashed or hung
see `failure-recovery.md`.

## What a supervised session is

`scripts/specforge session launch` starts a **separate `claude` process inside a
tmux session** on the host, on a dedicated tmux server socket (`tmux -L
specforge`). Compared with running `claude` in your terminal:

- **It keeps running when you leave.** Close the SSH connection, shut the
  laptop — the session keeps working on the host.
- **It is observable from anywhere.** Any SSH shell — or your phone through
  Remote Control — can list it, tail its output, or attach to it.
- **It is on the record.** A JSON file under `.specforge/state/sessions/`
  records the Bead, role, start time, working directory and lifecycle state,
  and survives a crash or a restart of whatever launched it.
- **It is fenced in.** The launch profile denies `git push`, remote Dolt sync,
  destructive shell commands and outbound network. It can edit files, run
  tests and commit locally; it cannot push or reach the network.

Use one to run a whole OpenSpec change end to end while you watch from another
shell or from your phone, or to hand a long isolated job to a specialist you
want to be able to stop independently.

## Start a session for a change

```bash
# anchor the session to the change's first Bead
./scripts/specforge session launch --role lead --bead SPEC-xxx --owner "$USER"
```

`--bead` is required and must exist; `launch` runs a read-only `bd show` to
check it and **makes no other Beads change** — being launched is not permission
to start work. `--role` is `lead` or `specialist:<type>`. `--cwd <path>`
defaults to the repo root. `--read-only` starts the session in plan mode.

`launch` prints the session name, the log path and the attach command. It does
not attach you — the session comes up idle at a prompt, waiting for direction.

Then give it its task: attach (below) and tell it what to do, or point it at a
briefing file.

## Watch without touching

```bash
./scripts/specforge session list                       # all sessions + state
./scripts/specforge session log  <name> --follow        # tail its output
```

`session list` reconciles every record against live tmux; a session whose tmux
is gone shows as `failed`. `session log` never attaches — `Ctrl-C` stops the
tail, not the session.

## Attach and steer

```bash
./scripts/specforge session attach <name>
```

You are now **inside** the session — the same view Claude has. You can type
instructions, ask a side question with `/btw`, change the permission mode with
`Shift-Tab`, or press `Esc` to interrupt what Claude is doing.

**Detach without killing it:** press `Ctrl-b`, release, then `d`. This is the
tmux detach chord. The session keeps running; you are back in your own shell.
Closing the terminal while attached also just detaches. The session ends only
if Claude itself exits (`/exit`) or you `session stop` it.

`session attach <name> --read-only` attaches so you can watch keystroke-by-
keystroke but cannot send input.

### Autonomous vs. step-by-step

A launched session starts in the profile's default permission mode, which
prompts before actions. Attach and press `Shift-Tab` to cycle to
`acceptEdits` (edits apply, commands still prompt) or a fuller autonomy mode if
you want it to run unattended. Drop back to the default mode the same way when
you want to supervise a risky stretch.

## From your phone

A launched session registers with Remote Control (`/rc` shows in its status
line). It appears in the Claude app on your phone as a session you can read and
type into, with no SSH. This is the same control surface as your other Remote
Control sessions.

## Stop and clean up

```bash
./scripts/specforge session stop    <name> --reason "going the wrong way"
./scripts/specforge session cleanup <name>
```

`stop` sends Claude an interrupt, waits the grace period
(`session_stop_grace_seconds`, default 10), then terminates the tmux session
and records `stopped` with the time and reason. It is idempotent.

`cleanup` removes a lingering tmux session, archive-rotates the log and retires
the record. It **refuses** a record still in `starting`, `running` or `idle` —
`stop` it first. `session cleanup` with no name cleans up every already-terminal
record and kills the tmux server if nothing is left running.

## Several at once

You can launch more than one session, and `session list` shows them all with
distinct names and logs. But every session started with the default `--cwd`
shares the one working tree at the repo root — and therefore the one checked-out
Git branch. **Two sessions working the same checkout will collide.**

For genuinely parallel work, give each session its own checkout with a Git
worktree:

```bash
git worktree add ../specforge-cmd feat/planning-and-discovery-commands
./scripts/specforge session launch --role lead --bead SPEC-yyy \
  --cwd "$(cd ../specforge-cmd && pwd)"
```

Otherwise: **one session at a time against the repo root.**

## Quick reference

| Command | Effect |
| --- | --- |
| `session launch --role <r> --bead <id> [--cwd <p>] [--read-only] [--owner <o>]` | start a supervised session; no Beads change |
| `session list` | list every session with live-reconciled state |
| `session log <name> [--follow]` | print / tail the log; never attaches |
| `session attach <name> [--read-only]` | attach the terminal; `Ctrl-b d` to detach |
| `session stop <name> [--reason <text>]` | interrupt, terminate, record a terminal state; idempotent |
| `session cleanup [<name>]` | retire terminal records; refuses a live one |

Config keys (`.specforge/config.json`): `session_tmux_socket`,
`session_state_dir`, `session_log_max_bytes`, `session_log_rotation_depth`,
`session_stop_grace_seconds`, `session_launch_profile`, `session_launch_prompt`.
