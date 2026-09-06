# Running work in supervised sessions

A practical guide to `scripts/specforge session` — starting a Claude Code
session on the delivery host, watching it, steering it, and shutting it down.

For the design and internals see the *Session supervision* sections of
`operating-model.md` and `architecture.md`. For a session that crashed or hung
see `failure-recovery.md`.

## What a supervised session is

`scripts/specforge session launch` starts a **separate agent process inside a
tmux session** on the host — Claude Code by default, or Codex with `--agent
codex` (see *Choosing the agent*) — on a dedicated tmux server socket (`tmux -L
specforge`). Compared with running the agent in your terminal:

- **It keeps running when you leave.** Close the SSH connection, shut the
  laptop — the session keeps working on the host.
- **It is observable from anywhere.** Any SSH shell — or your phone through
  Remote Control — can list it, tail its output, or attach to it.
- **It is on the record.** A JSON file under `.specforge/state/sessions/`
  records the Bead, role, start time, working directory and lifecycle state,
  and survives a crash or a restart of whatever launched it.
- **It is fenced in.** By default the launch profile (`restricted`) denies
  `git push`, remote Dolt sync, destructive shell commands and outbound
  network. It can edit files, run tests and commit locally; it cannot push or
  reach the network. A broader profile is a deliberate flag on the command
  line (see *Running with broader authority*), and a small command floor holds
  no matter which profile is chosen.

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
`--profile` / `--prompt` / `--full-access` choose the authority the session
runs under — see *Running with broader authority*.

`launch` prints the session name, the log path and the attach command. It does
not attach you — the session comes up idle at a prompt, waiting for direction.

Then give it its task: attach (below) and tell it what to do, or point it at a
briefing file.

If the session is **resuming** interrupted work — a previous session ran out of
budget or crashed, or you are switching tools — have it run
`./scripts/specforge recover` and work through what it reports (the
[`failure-recovery.md`](failure-recovery.md) § "Resuming an interrupted run"
playbook) *before* it selects work with `bd ready`. `AGENTS.md` § "Resuming a
run" is the tool-neutral protocol; a `LIMBO` / `resumable` Bead is verified and
closed, never re-implemented.

## Choosing the agent

A session runs **Claude Code** by default. To run **OpenAI Codex** instead:

```bash
./scripts/specforge session launch --role lead --bead SPEC-xxx --agent codex
```

With no `--agent` flag the agent is the `session_agent` key in
`.specforge/config.json` (default `claude`), so an install only runs Codex when
it opts in — per launch, or by setting that key. `session list` shows which
agent each session runs in an `AGENT` column.

The `restricted` and `trusted` authority levels mean the same *intent* for both
agents, resolved differently:

| Level | Claude | Codex |
| --- | --- | --- |
| `restricted` (default) | `restricted.json` settings — deny `git push`, Dolt sync, destructive shell, network | `--sandbox workspace-write --ask-for-approval on-request`, network access off |
| `trusted` | `trusted.json` — `acceptEdits`, allows `git push`/`merge`/… | `--sandbox workspace-write --ask-for-approval never`, network access off |

So a Codex session is governed by Codex's own **sandbox mode** and **approval
policy** rather than a Claude `permissions` file — there is no per-session
settings file for a Codex launch. `--read-only` forces `--sandbox read-only`.
`--full-access` still means `trusted` + the `autonomous` prompt, mapped to
whichever agent is in use.

The SpecForge command floor (`rm -rf`, `sudo`, …) is, for Codex, the repo's
`.codex/rules/` execpolicy directory — `session launch` never passes
`--ignore-rules` or `--dangerously-bypass-approvals-and-sandbox`. That floor
file ships with the `codex-onboarding` change; until it is present `session
launch --agent codex` prints a warning naming the missing file and still
starts.

Codex reads any credential it needs from its own `~/.codex/auth.json` — no
token is ever passed on the command line, exactly as for Claude.

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

## Running with broader authority

By default a session runs under the `restricted` profile. To let a session work
a whole change unattended — commit per Bead, push its branch, merge to
`develop` when green — launch it with broader authority:

```bash
./scripts/specforge session launch --role lead --bead SPEC-xxx --full-access
```

`--full-access` is shorthand for `--profile trusted --prompt autonomous`:

- **`trusted`** starts in `acceptEdits` and allows `git push`, `git merge`,
  `git switch`, `git rebase`, `bd`, `openspec` (read commands), `npx` and
  `scripts/*`. It still denies `sudo`, `systemctl`, `curl`/`wget` and
  `WebFetch`.
- **`autonomous`** is the system prompt that authorises the session to execute
  one named change end to end and fast-forward-merge it to `develop` (no PR),
  while keeping every hard rule: never edit `openspec/`, work only that
  change's Beads, record discoveries, commit-and-note before closing a Bead.

You can also pass the two flags separately, or point either at a file of your
own: `--profile ./my-profile.json`, `--prompt ./my-prompt.md`. A bare name
resolves under `.specforge/launch-profiles/` / `.specforge/launch-prompts/`;
anything else is a path.

**The command floor always holds.** `rm -rf`/`rm -fr`, `sudo`, `dd`,
`mkfs`/`mkfs.*`, `shutdown`, `reboot` and a fork bomb are denied in *every*
session regardless of profile — including a profile file you supply yourself.
It is a guard rail against an accident or a prompt-injected `rm -rf ~`, not an
OS sandbox: a `trusted` session genuinely can push and merge.

**It is on the record.** `session list` shows the profile each session runs
under (`restricted` renders as `-`). The merged, floored settings are written
to `.specforge/state/sessions/<name>.settings.json`; the source profile is
never modified, and `session cleanup` removes the per-session file when it
retires the record.

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

## The always-on Orchestration Agent

The **Orchestration Agent** is a special supervised session — Bead-less,
single-instance, and always-on. It is not launched with `session launch`; a
rendered systemd **user service** runs it:

```bash
systemctl --user enable --now specforge-orchestrator-<slug>.service
loginctl enable-linger "$USER"   # so it starts at boot without a login
```

`init` / `update` print both lines. Then drive it with the `orchestrator`
subcommand group:

```bash
./scripts/specforge orchestrator status    # unit + linger state, the lock, the live session, last log lines
./scripts/specforge orchestrator restart   # bounce the service
./scripts/specforge orchestrator stop      # stop + disable it, end the session, release the lock
./scripts/specforge orchestrator run       # the supervisor itself (what the unit calls); --force reclaims a stale lock
```

`orchestrator run` acquires `.specforge/locks/orchestrator.lock`, adopts a live
`sf-orchestrator-<slug>` tmux session or starts one (resuming its conversation
with `claude --continue` when one exists), blocks until it exits, releases the
lock and exits non-zero so `Restart=always` brings it back. It runs under the
`orchestrator` profile with the command floor and the `openspec/` boundary
lifted — `session list` and `doctor` show it as `FULL-ACCESS`. It is Claude-only
and reachable from a phone through Remote Control. See
`docs/operating-model.md` *Orchestration* for the persona and its
orchestrate-only-by-default scope.

## Quick reference

| Command | Effect |
| --- | --- |
| `session launch --role <r> --bead <id> [--cwd <p>] [--read-only] [--owner <o>] [--agent <claude\|codex>] [--profile <n>] [--prompt <n>] [--full-access]` | start a supervised session; no Beads change |
| `session list` | list every session with live-reconciled state and its launch profile |
| `session log <name> [--follow]` | print / tail the log; never attaches |
| `session attach <name> [--read-only]` | attach the terminal; `Ctrl-b d` to detach |
| `session stop <name> [--reason <text>]` | interrupt, terminate, record a terminal state; idempotent |
| `session reap` | move vanished active-state records to `failed`; a live one is untouched |
| `session cleanup [<name>] [--reap]` | retire terminal records; refuses a live one (`--reap` fails the dead ones first) |
| `orchestrator run [--force]` | the always-on supervisor the systemd unit runs; `--force` reclaims a stale lock |
| `orchestrator status` | unit enabled/active state, linger on/off, the lock holder, the live `FULL-ACCESS` session |
| `orchestrator stop` \| `orchestrator restart` | stop-and-disable the unit (idempotent), or restart it |

Config keys (`.specforge/config.json`): `session_agent` (`claude` |  `codex`,
default `claude`), `session_tmux_socket`, `session_state_dir`,
`session_log_max_bytes`, `session_log_rotation_depth`,
`session_stop_grace_seconds`, `orchestrator_lock_ttl_seconds` (default 86400),
`orchestrator_poll_seconds` (default 5). The launch profile / prompt directories default
to `.specforge/launch-profiles/` and `.specforge/launch-prompts/` and are
overridable with `session_launch_profile_dir` / `session_launch_prompt_dir`; a
`session_launch_profile` / `session_launch_prompt` key still pins a single file
and wins over the directory default.
