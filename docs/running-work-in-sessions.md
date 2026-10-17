# Running work in supervised sessions

A practical guide to `scripts/nogg session` — starting a Claude Code
session on the delivery host, watching it, steering it, and shutting it down.

For the design and internals see the *Session supervision* sections of
`operating-model.md` and `architecture.md`. For a session that crashed or hung
see `failure-recovery.md`.

## What a supervised session is

`scripts/nogg session launch` starts a **separate agent process inside a
supervised session** on the host — Claude Code by default, or Codex with `--agent
codex` (see *Choosing the agent*) — using a switchable session backend (`tmux` by
default, or `herdr` with `--backend herdr` or `session_backend`; see
`using-with-herdr.md`). On tmux, a dedicated tmux server socket (`tmux -L
nogg`) isolates sessions from the operator's personal tmux. Compared with running
the agent in your terminal:

- **It keeps running when you leave.** Close the SSH connection, shut the
  laptop — the session keeps working on the host.
- **It is observable from anywhere.** Any SSH shell — or your phone through
  Remote Control — can list it, tail its output, or attach to it.
- **It is on the record.** A JSON file under `.nogging/state/sessions/`
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
./scripts/nogg session launch --role lead --bead SPEC-xxx --owner "$USER"
```

For an execution role `--bead` is required and must exist; `launch` runs a
read-only `bd show` to check it and **makes no other Beads change** — being
launched is not permission to start work. `--role` is `lead`,
`specialist:<type>` or `planning`. A planning session is Bead-optional — see
*Start a planning session* below. `--cwd <path>`
defaults to the repo root. `--read-only` starts the session in plan mode.
`--profile` / `--prompt` / `--full-access` choose the authority the session
runs under — see *Running with broader authority*.

`launch` prints the session name, the log path and the attach command. It does
not attach you — the session comes up idle at a prompt, waiting for direction.

Before contacting the backend (tmux or herdr), launch verifies that its installed runtime helpers are
executable and support every requested option. A refusal naming a helper
contract calls for a pinned Nogging `update`; see `failure-recovery.md`.
If the agent itself exits during startup, the failed record and redacted log
retain the original error even when the pane has already disappeared. Check
`session list` and `session log <name>` after a suspected quick failure.

### Host-namespace tmux server start and fenced refusal

On the `tmux` backend, the shared tmux server (`tmux -L nogging`) must be
started in the host namespace so that it survives individual sandboxed sessions.
A sandboxed Lead or specialist (running under `openspec-sandbox` with
`NOGG_OPENSPEC_FENCED=1`) cannot start the server: every tmux command it runs
carries tmux's global `-N` flag ("do not start the server").

If a fenced session runs `session launch` on tmux while the server is down,
launch refuses before any session record, effective settings, or log is created:

```text
tmux server -L nogging is not running; a sandboxed session cannot start it, because it would end with this session; launch from an unsandboxed shell (the operator or the Orchestration Agent)
```

**Remedy:** Launch a session or start the Orchestration Agent from an unsandboxed
shell on the host (the operator or `systemctl --user start nogg-orchestrator-<slug>`).
The unsandboxed launch starts the server in the host namespace, where it persists
across sessions. Once running, sandboxed launches connect to it normally.

Then give it its task: attach (below) and tell it what to do, or point it at a
briefing file.

## Start a planning session

```bash
./scripts/nogg session launch --role planning \
  --planning-id <planning-id> --description <description> [--bead SPEC-xxx]
./scripts/nogg session kickoff <name>
```

Both identifiers are kebab-case. Launch allocates a dedicated planning
worktree and records the true `planning` role. It takes no planning lock and
makes no Beads change. An optional `--bead` is context only and is never
claimed; an execution role cannot launch without a real Bead. The bare
session stays idle. Its kickoff tells the planner to run `plan-begin` itself,
which takes the canonical planning lock in the main checkout, owned by that
session. A second planner given a kickoff reports the named owner and writes
nothing. Nobody, the orchestrator included, acquires the lock on a child's
behalf.

The planner commits the validated spec as the `planning` writer before
`materialize`, wires Beads
dependencies explicitly, fast-forward integrates its branch, and removes only
a clean, integrated worktree. Only then does it run `plan-end`, from a
surviving canonical checkout. `session stop`, cleanup and recovery release
only the planning lock owned by that session, never another session's.
Execution sessions stay fenced from `openspec/` while any planning lock is
held.

If the session is **resuming** interrupted work — a previous session ran out of
budget or crashed, or you are switching tools — have it run
`./scripts/nogg recover` and work through what it reports (the
[`failure-recovery.md`](failure-recovery.md) § "Resuming an interrupted run"
playbook) *before* it selects work with `bd ready`. `AGENTS.md` § "Resuming a
run" is the tool-neutral protocol; a `LIMBO` / `resumable` Bead is verified and
closed, never re-implemented.

## Choosing the agent

A session runs **Claude Code** by default. To run **OpenAI Codex** instead:

```bash
./scripts/nogg session launch --role lead --bead SPEC-xxx --agent codex
```

With no `--agent` flag the agent is the `session_agent` key in
`.nogging/config.json` (default `claude`), so an install only runs Codex when
it opts in — per launch, or by setting that key. `session list` shows which
agent each session runs in an `AGENT` column.

The `restricted` and `trusted` authority levels mean the same *intent* for both
agents, resolved differently:

| Level | Claude | Codex |
| --- | --- | --- |
| `restricted` (default) | `restricted.json` settings — deny `git push`, Dolt sync, destructive shell, network | `--sandbox workspace-write --ask-for-approval on-request`, network access off |
| `trusted` | `trusted.json` — `bypassPermissions`, allows `git push`/`merge`/… | `--sandbox workspace-write --ask-for-approval never`, network access off |

So a Codex session is governed by Codex's own **sandbox mode** and **approval
policy** rather than a Claude `permissions` file — there is no per-session
settings file for a Codex launch. `--read-only` forces `--sandbox read-only`.
`--full-access` still means `trusted` + the `autonomous` prompt, mapped to
whichever agent is in use.

The Nogging command floor (`rm -rf`, `sudo`, …) is, for Codex, the repo's
`.codex/rules/` execpolicy directory — `session launch` never passes
`--ignore-rules` or `--dangerously-bypass-approvals-and-sandbox`. That floor
file ships with the `codex-onboarding` change; until it is present `session
launch --agent codex` prints a warning naming the missing file and still
starts.

Codex reads any credential it needs from its own `~/.codex/auth.json` — no
token is ever passed on the command line, exactly as for Claude.

## Choosing the model

With no model setting a session runs on the runtime's own default. To pick one:

```bash
./scripts/nogg session launch --role lead --bead SPEC-xxx --model <model-name>
```

Precedence is `--model`, then an optional `model` key in the launch profile
(Claude `.json`, Codex `.codex.toml`, Pi `.pi.toml`, Antigravity `.agy.toml`),
then the runtime's native default. A Codex profile may also set
`model_reasoning_effort`. The model reaches the runtime as one `--model` argv
element for this launch only: neither the profile nor any user-global runtime
setting (`~/.claude`, `~/.codex`, `~/.pi`) is written.

The session record keeps `requested_model`, `model_source` (`launch`,
`profile` or `runtime-default`), `reasoning_effort` and
`reasoning_effort_source` (same three values). `session list` shows them in
`MODEL` and `MODEL_SOURCE` columns. Without a model setting both show
`runtime-default`: Nogging records that the runtime chose, not a guess at which
model it chose. A record written before this was recorded shows `-`.

### Choosing Claude reasoning effort

A Claude session can request a reasoning effort for that launch only:

```bash
./scripts/nogg session launch --role lead --bead SPEC-xxx --effort high
```

Precedence is `--effort`, then an optional `effort` key in the Claude launch
profile, then Claude's own default (no flag is passed). Allowed values are
exactly `low`, `medium`, `high`, `xhigh` and `max`; anything else (including
`auto`, `none`, case variants and an invalid profile value that a valid
`--effort` would override) refuses before any worktree, settings, record or
backend side effect. The shipped profiles omit `effort`, so defaults are
unchanged. To opt in, add it to a complete custom profile JSON:

```json
{
  "permissions": {"defaultMode": "default", "deny": []},
  "effort": "high"
}
```

Nogging strips the `effort` key from the generated per-session settings and
passes it as Claude's native `--effort <level>` argv (also on exact resumes);
neither the source profile nor `~/.claude` is written. `--effort` is Claude-only:
Codex keeps `model_reasoning_effort` in its `.codex.toml` profile, and Pi and
Antigravity refuse both keys. A helper without the `claude-effort-forwarding`
capability refuses the launch with an update remedy rather than dropping the
effort. If the Claude CLI rejects the level for the chosen model, the session
fails visibly and is not retried at another effort. Flag verified against
Claude Code 2.1.296; which models accept which levels is the runtime's call.

`session list` shows the request and its source in the `MODEL` cell for Claude
and Codex: `effort=high (profile)`, `effort=low (launch)` or
`effort=runtime-default`. A record that predates `reasoning_effort_source`
shows a stored effort as `effort=<level> (unknown)` — provenance is never
inferred — and otherwise keeps its old display. This is the *requested*
setting; Nogging does not observe later `/effort` changes, environment
overrides or the model default the runtime resolved.

### Choosing by tier

Instead of naming a model, name the task's complexity tier and let the shipped
model-selection table pick the model and effort:

```bash
./scripts/nogg models --agent codex --tier standard   # see the entry
./scripts/nogg session launch --role lead --bead SPEC-xxx --agent codex --tier standard
```

Tiers are `routine`, `standard` and `complex`. Per field, an explicit `--model`
still beats the tier, and the tier beats the profile and the runtime default.
Codex gets the tier effort as its `model_reasoning_effort`; Antigravity gets a
model whose name carries the thinking level; Claude gets the tier model and the
tier effort (as its native `--effort`, source `launch`; an explicit `--effort`
beats the tier, and a helper without `claude-effort-forwarding` refuses rather
than drop it).
Pi has no table, so `--tier` with `--agent pi` refuses, as do an unknown tier
and a missing or invalid table — all before any side effect. The record stores
`selection_tier` and `session list` shows `tier=<tier>` in the `MODEL` cell. The
Orchestration Agent launches every sub-session this way. See
`model-selection.md` for the table, the precedence rules and the research.

## Watch without touching

```bash
./scripts/nogg session list                       # all sessions + state
./scripts/nogg session log  <name> --follow        # tail its output
```

`session list` reconciles every record against live backend sessions (tmux or
herdr); a session whose backend session is gone shows as `failed`. It shows
`BACKEND` and `AGENT_STATUS` columns. `session log` never attaches — `Ctrl-C`
stops the tail, not the session.

Console output is streamed by `scripts/session-log-writer` in binary chunks of
up to 64 KiB via `O_APPEND` without waiting for line feeds (LF). This ensures
full-screen TUIs and interactive prompts update live in `session log --follow`
without freezing or unbounded buffer accumulation. Each log file is strictly
bounded by `session_log_max_bytes` and rotated up to `session_log_rotation_depth`.

## Attach and steer

```bash
./scripts/nogg session attach <name>
```

You are now **inside** the session — the same view Claude has. You can type
instructions, ask a side question with `/btw`, change the permission mode with
`Shift-Tab`, or press `Esc` to interrupt what Claude is doing.

**Detach without killing it:** on tmux, press `Ctrl-b`, release, then `d` (the
tmux detach chord); on herdr, detach the herdr client. The session keeps running;
you are back in your own shell. Closing the terminal while attached also just
detaches. The session ends only if the agent itself exits (`/exit`) or you
`session stop` it.

`session attach <name> --read-only` attaches so you can watch keystroke-by-
keystroke but cannot send input (supported on tmux; on herdr, where no read-only
client exists, this is refused with a pointer to `session log --follow`).

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
./scripts/nogg session launch --role lead --bead SPEC-xxx --full-access
```

`--full-access` is shorthand for `--profile trusted --prompt autonomous`:

- **`trusted`** starts in `bypassPermissions` and allows `git push`, `git merge`,
  `git switch`, `git rebase`, `bd`, `openspec` (read commands), `npx` and
  `scripts/*`. It still denies `sudo`, `systemctl`, `curl`/`wget` and
  `WebFetch`.
- **`autonomous`** is the system prompt that authorises the session to execute
  one named change end to end and fast-forward-merge it to `develop` (no PR),
  while keeping every hard rule: never edit `openspec/`, work only that
  change's Beads, record discoveries, commit-and-note before closing a Bead.

You can also pass the two flags separately, or point either at a file of your
own: `--profile ./my-profile.json`, `--prompt ./my-prompt.md`. A bare name
resolves under `.nogging/launch-profiles/` / `.nogging/launch-prompts/`;
anything else is a path.

**The command floor always holds.** `rm -rf`/`rm -fr`, `sudo`, `dd`,
`mkfs`/`mkfs.*`, `shutdown`, `reboot` and a fork bomb are denied in *every*
session regardless of profile — including a profile file you supply yourself.
It is a guard rail against an accident or a prompt-injected `rm -rf ~`, not an
OS sandbox: a `trusted` session genuinely can push and merge.

**It is on the record.** `session list` shows the profile each session runs
under (`restricted` renders as `-`). The merged, floored settings are written
to `.nogging/state/sessions/<name>.settings.json`; the source profile is
never modified, and `session cleanup` removes the per-session file when it
retires the record.

## From your phone

A launched session registers with Remote Control (`/rc` shows in its status
line). It appears in the Claude app on your phone as a session you can read and
type into, with no SSH. This is the same control surface as your other Remote
Control sessions.

## Stop and clean up

```bash
./scripts/nogg session stop    <name> --reason "going the wrong way"
./scripts/nogg session cleanup <name>
```

`stop` sends the agent an interrupt, waits the grace period
(`session_stop_grace_seconds`, default 10), then terminates the backend session
and records `stopped` with the time and reason. It is idempotent.

`cleanup` removes a lingering backend session, archive-rotates the log
(archiving all rotated generations `<name>.log.1..N` together with the active
log under a common timestamp), and retires the record. It **refuses** a record
still in `starting`, `running` or `idle` — `stop` it first. `session cleanup` with
no name cleans up every already-terminal record. For tmux, it stops the dedicated
shared server (`tmux -L nogging`) **only** when its `list-sessions` query succeeds
and reports no sessions on the dedicated server; it never kills a server that still
hosts sessions for other checkouts or the always-on Orchestration Agent. (For herdr,
the dedicated headless herdr server is never killed by cleanup).

## Several at once

You can launch more than one session, and `session list` shows them all with
distinct names and logs. But every session started with the default `--cwd`
shares the one working tree at the repo root — and therefore the one checked-out
Git branch. **Two sessions working the same checkout will collide.**

For genuinely parallel work, give each session its own checkout with a Git
worktree:

```bash
git worktree add ../nogg-cmd feat/planning-and-discovery-commands
./scripts/nogg session launch --role lead --bead SPEC-yyy \
  --cwd "$(cd ../nogg-cmd && pwd)"
```

Otherwise: **one session at a time against the repo root.**

## The always-on Orchestration Agent

The **Orchestration Agent** is a special supervised session — Bead-less,
single-instance, and always-on. It is not launched with `session launch`; a
rendered systemd **user service** runs it:

```bash
systemctl --user enable --now nogg-orchestrator-<slug>.service
loginctl enable-linger "$USER"   # so it starts at boot without a login
```

`init` / `update` print both lines. Then drive it with the `orchestrator`
subcommand group:

```bash
./scripts/nogg orchestrator status    # unit + linger state, the lock, the live session, last log lines
./scripts/nogg orchestrator restart   # bounce service & relaunch Claude with updated prompt/settings (--supervisor-only skips session kill)
./scripts/nogg orchestrator stop      # stop + disable it, end the session, release the lock
./scripts/nogg orchestrator run       # the supervisor itself (what the unit calls); --force reclaims a stale lock
```

`orchestrator run` acquires `.nogging/locks/orchestrator.lock`, adopts a live
`nogg-orchestrator-<slug>` tmux session or starts one (resuming its conversation
with `claude --continue` when one exists), blocks until it exits, releases the
lock and exits non-zero so `Restart=always` brings it back. `orchestrator restart`
terminates the live orchestrator tmux session and restarts the service, causing
the new supervisor run to start a fresh Claude session with the current launch
prompt and configuration while resuming transcript continuity; `--supervisor-only`
restarts the supervisor unit alone without terminating the tmux session. Restart
(including `--supervisor-only`) is refused from within the orchestrator session itself
(e.g. when directed via Remote Control) to avoid terminating before completion, and
must be run from an external shell. The Orchestration
Agent is pinned to tmux and always runs on tmux, even if `herdr` is configured as
the repository's default session backend. It runs under the
`orchestrator` profile with the command floor and the `openspec/` boundary
lifted — `session list` and `doctor` show it as `FULL-ACCESS`. It is Claude-only
and reachable from a phone through Remote Control. See
`docs/operating-model.md` *Orchestration* for the persona and its
orchestrate-only-by-default scope.

## Quick reference

| Command | Effect |
| --- | --- |
| `session launch --role <r> [--backend <b::tmux|herdr>] [--bead <id>] [--planning-id <id> --description <d>] [--cwd <p>] [--read-only] [--owner <o>] [--agent <claude\|codex>] [--profile <n>] [--prompt <n>] [--full-access]` | start a supervised session; no Beads change |
| `session list` | list every session with live-reconciled state and its launch profile |
| `session log <name> [--follow]` | print / tail the log; never attaches |
| `session attach <name> [--read-only]` | attach the terminal; `Ctrl-b d` (tmux) or client detach (herdr) |
| `session stop <name> [--reason <text>]` | interrupt, terminate, record a terminal state; idempotent |
| `session reap` | move vanished active-state records to `failed`; a live one is untouched |
| `session cleanup [<name>] [--reap]` | retire terminal records, archives all rotated logs; refuses a live one; stops shared tmux server only when completely empty |
| `session herdr-server start` | idempotently verify or start dedicated host-namespace herdr server; host-only |
| `orchestrator run [--force]` | the always-on supervisor the systemd unit runs; `--force` reclaims a stale lock |
| `orchestrator status` | unit enabled/active state, linger on/off, the lock holder, the live `FULL-ACCESS` session |
| `orchestrator stop` \| `orchestrator restart [--supervisor-only]` | stop-and-disable the unit (idempotent), or restart it (terminating the live session to relaunch Claude with updated prompt/settings while resuming transcript; `--supervisor-only` retains the live session) |

Config keys (`.nogging/config.json`): `session_agent` (`claude` |  `codex`,
default `claude`), `session_backend` (`tmux` | `herdr`, default `tmux`),
`session_tmux_socket`, `session_herdr_command` (default `herdr`),
`session_herdr_session` (default `nogging`), `session_state_dir`,
`session_log_max_bytes`, `session_log_rotation_depth`,
`session_stop_grace_seconds`, `orchestrator_lock_ttl_seconds` (default 86400),
`orchestrator_poll_seconds` (default 5). The launch profile / prompt directories default
to `.nogging/launch-profiles/` and `.nogging/launch-prompts/` and are
overridable with `session_launch_profile_dir` / `session_launch_prompt_dir`; a
`session_launch_profile` / `session_launch_prompt` key still pins a single file
and wins over the directory default.

## This repository’s autonomous Claude configuration

This checkout opts into autonomous Claude operation at the Product Owner’s
request. `.nogging/config.json` selects the trusted Claude profile and the
autonomous prompt for new supervised sessions. Explicit `--profile` and
`--prompt` selections still win. To start a restricted, manually directed
session, pass both `--profile restricted --prompt no-autonomous-claim`.
Codex and Pi retain their own profile defaults; the configured prompt is
shared. Planning sessions retain their planning prompt. Existing running
sessions keep their launch settings; these changes apply on a new launch.

The trusted Claude profile uses `bypassPermissions` and no longer denies
WebFetch, curl, wget or systemctl. The fixed Nogging command floor and
execution OpenSpec write boundary still apply. This grants tool authority,
while the autonomous prompt keeps work scoped to the assigned change and
its review workflow. The orchestrator profile already uses bypass permissions
and remains unchanged.

For Anthropic-hosted Cloud, `.claude/settings.json` selects `acceptEdits`
and pre-approves Bash, WebFetch and WebSearch, preserving the existing hooks.
This is a broad shell grant requested by the repository owner. Cloud does
not support bypass permissions. In an existing Cloud session, select
**Accept edits** in the mode dropdown; a resumed session can retain Auto
instead of adopting the new default. A broad Bash grant is suspended in
Auto mode, so staying in Auto does not provide the same behavior.

Provider-managed policy, protected paths, explicit ask/deny rules, hooks,
network restrictions and connector-specific approvals can still require
interaction. Repository settings do not configure `autoMode` trust rules.
No classifier bypass or credential changes are installed. For interactive
Orchestration Agent sessions, operators can adapt the template at
`templates/claude/orchestrator-permissions.example.json` into user settings
(`~/.claude/settings.json`); allow rules in that template do not bypass the
classifier in Auto mode. Hosted Cloud behavior must be checked in an actual
new Cloud session after the branch is integrated and available to clone.

References: [Claude permission modes](https://code.claude.com/docs/en/permission-modes)
and [Auto-mode configuration](https://code.claude.com/docs/en/auto-mode-config).

## Sweep work scope and integration

`session sweep` defaults to the assigned mapped task and its blocking dependency
cone. An unrelated blocked sibling does not block that session. Specialists
always retain this single-task scope. To explicitly authorize a lead to execute
the whole assigned change at kickoff, use:

```bash
./scripts/nogg session kickoff <name> --change <change-name>
```

This records `authorized_change` in the session record. A custom kickoff message
alone does not expand sweep scope. Sweep remains read-only: it neither claims
work nor sends input. Idle duration and buffered input are separate observations.

Completion requires closed mapped work and a verified merged PR for the current
branch head, with no unresolved checks. Open PRs, unavailable evidence, reused
branches and failed lookups cannot establish completion. Unknown work or
integration evidence is displayed explicitly. A successful lookup that finds no
PR also needs explicit local integration evidence: the operator records
`integration_evidence` with `commit` (the full current HEAD SHA) and `target_ref`
(`refs/heads/develop`) in the session record. Sweep verifies a clean worktree and
that this commit is an ancestor of the target; the record alone is insufficient.

## Explicit CI check observations

Plain `session sweep` never reports check details. The explicit remote check
path is:

```bash
./scripts/nogg session sweep --checks
./scripts/nogg session checks-ack <name> [--fingerprint <fingerprint>]
```

`sweep --checks` looks up the PR for each running session's branch and prints
its status (`passing`, `failing`, `pending`, `no-pr` or `unknown`), the PR head
SHA and a check/run fingerprint. The fingerprint covers the head SHA and each
check's name, outcome and run URL, so a new run (including a re-run that fails
again) gets a new fingerprint. The observation is cached in
`<session>.checks.json` beside the session record.

Observing never acknowledges. A fingerprint stays `unchecked` until an operator
runs `session checks-ack`, which acknowledges exactly the cached observation
without a remote call (and refuses a `--fingerprint` that no longer matches).
A lookup failure, ambiguous PRs or unparseable output is cached as `unknown`
and can be neither acknowledged nor read as success.

`doctor` reuses the cache and makes no check call. It prints a NOTE for a running
session whose checks are unknown, unchecked, or stale (older than
`session_checks_stale_seconds`, default 1800).

## Nudging a session: placeholders are not input

An idle Claude pane often shows a suggested next instruction in its `❯` input
box. That suggestion is rendered dim and is a placeholder, not typed input, so
`session nudge` never executes it. To submit an instruction, pass it explicitly:

```bash
./scripts/nogg session nudge <name> --message "<instruction>"
```

With `--message`, nudge replaces any actual pending input and submits the supplied
message with bounded verification. For every agent whose composer Nogging can
classify (Claude, the Codex pane fallback, and Antigravity) across both session
backends (tmux and herdr), nudge performs a bounded clear and exact-message
comparison before submitting:

1. **Clear pending input:**
   - While the composer shows input, nudge sends `ctrl+u` repeatedly (up to 8 times)
     as long as the text gets shorter, clearing wrapped buffers one visual row at a time.
   - If input remains, nudge sends `backspace` once per remaining character plus once
     per composer row (bounded to 4096 keys).
   - The composer must reach `empty` or `placeholder`. If it does not, or if it reads as
     `unknown` at any point, nudge refuses to type or submit anything, fails with
     `<name>: pending input could not be cleared; nothing was typed or submitted`, and exits non-zero.
2. **Type and compare:**
   - Nudge types the message and reads back the composer. It proceeds only if the
     composer holds *exactly* the supplied message (ignoring whitespace differences caused by
     line re-wrapping) or the runtime's recognized collapsed-paste marker (e.g. Codex `Pasted Content`).
   - If the composer contains merged text (leftover stale input merged with the message)
     or unexpected content, nudge clears the composer again and fails with `<name>: the
     composer did not hold exactly the message; nothing was submitted` without sending Enter.
3. **Submit and verify:**
   - Only when the composer is verified to hold exactly the message does nudge send Enter
     and verify submission. If input remains pending afterwards, it retries the submit step
     once, then fails.

A pane whose input box cannot be identified also fails as unverified rather than reporting
success. `send --verify` uses the same check.

Without `--message`, nudge resends only single-line input that it can
positively identify: non-dim text in Claude's framed input box, captured with
attributes (`tmux capture-pane -e` or herdr `pane.read --format ansi`). A placeholder-only, empty, multi-line or
unidentifiable prompt sends no keys at all, and the command tells you to pass
`--message`. Codex and other runtimes cannot expose the buffered text, so they
always need `--message`. Nudge still refuses any session that is not running,
before touching the backend. `session sweep` reports `has-unsent-input` as `yes`, `no`
(a placeholder or empty prompt) or `unknown`.

## Read-only quota inspection

Run `./scripts/nogg usage --agent codex` or `--agent claude`; add `--json`
for normalized machine-readable observations. Short and weekly windows are
reported separately. Missing, unsupported, malformed, future-dated, older than
600 seconds, and already-reset observations are unknown rather than zero.
This observation command does not install capture, launch sessions, reserve
headroom, or access authentication files. Account and model-group identities are reported as
unknown; a source directory does not prove account or model-group identity.

Codex observations come from `event_msg` / `token_count` metadata under
`$CODEX_HOME/sessions` (default `~/.codex/sessions`), selected by event timestamp.
The supported window fields are `used_percent`, `window_minutes`, and epoch
`resets_at` in `rate_limits.primary` and `rate_limits.secondary`.

Claude inspection reads the opt-in cache at
`$XDG_CACHE_HOME/nogging/usage/claude.json` (default
`~/.cache/nogging/usage/claude.json`). Cache schema version 1 contains
`schema_version: 1`, an RFC3339 `observed_at` stamped at capture time, and the
statusline `rate_limits` object. Its `five_hour` and `seven_day` windows contain
`used_percentage` and epoch `resets_at`. Only these quota fields belong in the
cache; do not copy the full statusline payload. Inspection does not modify
Claude settings or install a statusline. The source schemas were verified with
Codex 0.162.1 and Claude Code 2.1.296; other schemas report unknown.

## Launch usage gate

`./scripts/nogg session launch` admits an execution session (lead or
specialist) only when every known usage window of the launching agent still
fits: `used + reserved + estimate <= cap` per window. A refusal exits **75**
and names each limiting window with its reset time and the latest reset to
retry after; it happens before any helper negotiation, worktree, trust change,
backend session or session record. Planning and orchestrator launches are not
gated by default. `./scripts/nogg usage` prints the same estimate, projection
and fit (`gate` in `--json`). Admission checks and reserves headroom under a
same-host lock in the owner-only user cache
(`$XDG_CACHE_HOME/nogging/usage/reservations`, default `~/.cache`). This ledger
is shared across repositories. Each window counts its outstanding estimates;
a reset releases only reservations from that window's previous period.
Failed launches release immediately. Pending launchers hold kernel file locks,
so process death releases ownership across PID namespaces. Terminal sessions
and dead pending launchers are reconciled on the next admission or usage inspection; live backend
sessions retain their reservation after the launcher exits.

Current adapters do not identify accounts or model groups, so identity remains
unknown in usage output. Reservations conservatively share an opaque scope
per provider for the OS user, including across different source directories,
rather than claiming separate account headroom. When an adapter
provides account/group identity, those scopes are independent. The ledger
stores no raw account identity or credentials. A launch admitted with unknown
usage still reserves its estimate against subsequent fresh observations.
Running sessions may already be part of `used`; their full outstanding
estimates remain reserved conservatively, and no extra running-session count
is added. The gate reduces risk but cannot guarantee a task fits. Cross-host
coordination is unsupported in v1 even with `multi_machine: true`: the
reservation ledger is strictly host-local, and other machines or external
tools consuming the account's quota are only observed once local usage snapshots
update.

The shared reservation ledger (`ledger.json`) uses a single top-level token
map with integer per-entry `schema_version: 1` on new pending entries. Missing
versions represent legacy entries (both unversioned tmux and backend-neutral
shapes remain readable). All entries across versions share a strict accounting
core: nonempty string `scope`, finite nonnegative `estimate`, a `windows`
dictionary whose reset values are ISO timestamps or null, and a safe owner file
basename in `owner`.

### Tolerant reader floor and opaque entries

Readers validate the entire ledger's accounting core before any action or
rewrite. Corrupt accounting or malformed top-level data halts admission
safely with a clear diagnostic (`usage reservation ledger is malformed; admission refused`).

When an entry carries a future version (`schema_version > 1`), an invalid
version, or malformed session metadata but retains a valid accounting core:
- It is classified as **opaque**.
- It is preserved verbatim across unrelated admissions, bindings, and releases.
- It counts toward its matching scope and reset windows in totals and admission.
- A concise stderr diagnostic (`warning: reservation <token>: <reason>; retained without probing`) is emitted once during ledger transactions.
- Its probe is **never executed**, its session record is never inspected, its owner lock is never taken as proof of death, and it is **never reaped**, even if its record appears terminal.
- Direct `bind()` and `release()` refuse to alter an opaque target (`cannot bind/release opaque reservation <token>`).

To operate safely across concurrent versions, all active consumers on the host
must meet the **tolerant reader floor**: updating older installations to a release
incorporating tolerant decoding is required before relying on mixed-version operation.
Downgrading or running unpatched versions (such as v2.2.0) alongside newer
versioned writers is unsupported because unpatched readers crash on backend-neutral
or versioned shapes (`KeyError: 'tmux'`).

### Direct test execution and environment isolation

Direct test invocations (such as running `scripts/*.test.sh` directly from a
terminal or from within a supervised session) isolate their execution
environment by sourcing `scripts/lib/test-env.sh`.

This removes inherited `NOGG_*` session environment variables (such as
`NOGG_SESSION_ROLE`, `NOGG_SESSION_NAME`, `NOGG_OPENSPEC_FENCED`, and
`NOGG_TASK_DONE_SOCKET`) and `NOGGING_ROOT` before imports, fixtures, or child
processes run. This ensures that direct test runs:
- Never accidentally contact a live operator's task-done broker socket or emit ticks.
- Never inherit execution roles that cause false OpenSpec write refusals during planning tests.
- Never inherit planning roles that grant unauthorized OpenSpec writes during guard tests.
- Always retain unrelated environment variables, custom quota fixtures, and npm cache settings.
Fixtures explicitly configure any required session variables after sourcing `test-env.sh`.

Configure it with the optional `usage_gate` object in `.nogging/config.json`;
these are the defaults:

```json
"usage_gate": {
  "enabled": true,
  "cap_percent": 92,
  "estimate_percent": 5,
  "stale_seconds": 600,
  "on_unknown": "warn",
  "size_multipliers": {"small": 0.5, "medium": 1, "large": 2},
  "exclude_roles": ["planning", "orchestrator"]
}
```

`estimate_percent` may instead be an object per agent (`claude`, `codex`,
`pi`, `antigravity`) with an optional `default`. A Bead labelled
`size:<name>` scales only its reservation estimate by the matching multiplier;
conflicting or unconfigured size labels refuse the launch. `exclude_roles`
takes `lead`, `specialist`, `planning` and `orchestrator`. Unknown keys and
out-of-range or mistyped values refuse every launch until fixed.

Missing, stale, malformed or unsupported usage (Pi and Antigravity have no
source yet) is unknown, never zero: the launch warns and continues, or exits 75
with `"on_unknown": "deny"`. A known window over the cap denies even when the
other window is unknown. `--ignore-usage-gate` launches without admission; it
warns and is recorded as `usage_gate.decision: "ignored"` on the session
record, alongside `admitted`, `unknown-admitted`, `disabled` or `excluded`.

### Learned estimates and usage history

Nogging learns base reservation estimates per agent and model from complete,
attributable, non-reset intervals. Samples are collected only when a session
runs in isolation; intervals spanning concurrent workers are rejected because
account delta attribution cannot be known. Quota window resets, counter drops,
and statistical outliers are also rejected.

History is stored per agent/model in an owner-only cache
(`$XDG_CACHE_HOME/nogging/usage/history/history.json`, mode 0600 in mode 0700
directory) and is strictly bounded. When fewer than three valid samples exist,
admission falls back conservatively to the configured `estimate_percent`.
With sufficient samples, Nogging uses the conservative learned median
(favoring the higher value on even sample counts). A Bead's `size:<name>` label
scales the learned estimate by the configured multiplier. The history store
records only deltas and timestamps; no credentials, tokens, or account
identifiers are stored or exposed.

### Statusline usage capture and doctor freshness

Claude Code quota observation requires opt-in capture from Claude's statusline:

```bash
./scripts/nogg usage install-statusline
```

`usage install-statusline` installs a composable wrapper script to
`$XDG_DATA_HOME/nogging/claude-statusline` (default `~/.local/share/nogging`)
and configures `"statusLine"` in `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR`).
If the user already has a custom statusline command configured, Nogging
composes with it: Claude's stdin JSON is forwarded to the existing command and
its stdout is rendered normally, while `rate_limits` are captured atomically to
`$XDG_CACHE_HOME/nogging/usage/claude.json`. All unrelated settings in
`settings.json` are preserved. If the existing configuration cannot be composed
safely, the command refuses with manual configuration instructions.

`./scripts/nogg doctor` reports advisory notes on quota cache freshness:
- Missing observation sources (advising `nogg usage install-statusline` when
  Claude statusline cache is absent).
- Stale observations exceeding `stale_seconds` (default 600s).
- Fresh observation caches.

### Orchestrator retry guidance and scheduling

When launch admission is denied (exit code 75):
- The denial reports every limiting window and names the latest reset time
  across all limiting windows (`retry after <timestamp>`).
- The Orchestrator's scheduling guidance requires bounded retry at that latest
  limiting reset time.
- Model switching is explicitly prohibited as a limit workaround; the
  orchestrator must wait for the limiting window to reset rather than switching
  models to bypass account or bucket quotas.
