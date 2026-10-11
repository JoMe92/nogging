# Running work in supervised sessions

A practical guide to `scripts/nogg session` — starting a Claude Code
session on the delivery host, watching it, steering it, and shutting it down.

For the design and internals see the *Session supervision* sections of
`operating-model.md` and `architecture.md`. For a session that crashed or hung
see `failure-recovery.md`.

## What a supervised session is

`scripts/nogg session launch` starts a **separate agent process inside a
tmux session** on the host — Claude Code by default, or Codex with `--agent
codex` (see *Choosing the agent*) — on a dedicated tmux server socket (`tmux -L
nogg`). Compared with running the agent in your terminal:

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

Before contacting tmux, launch verifies that its installed runtime helpers are
executable and support every requested option. A refusal naming a helper
contract calls for a pinned Nogging `update`; see `failure-recovery.md`.
If the agent itself exits during startup, the failed record and redacted log
retain the original error even when the pane has already disappeared. Check
`session list` and `session log <name>` after a suspected quick failure.

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
tmux side effect. The shipped profiles omit `effort`, so defaults are
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
model whose name carries the thinking level; Claude gets the tier model, and a
`NOTE` says its tier effort is not applied until Claude effort forwarding lands.
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

`session list` reconciles every record against live tmux; a session whose tmux
is gone shows as `failed`. `session log` never attaches — `Ctrl-C` stops the
tail, not the session.

## Attach and steer

```bash
./scripts/nogg session attach <name>
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
./scripts/nogg orchestrator restart   # bounce the service
./scripts/nogg orchestrator stop      # stop + disable it, end the session, release the lock
./scripts/nogg orchestrator run       # the supervisor itself (what the unit calls); --force reclaims a stale lock
```

`orchestrator run` acquires `.nogging/locks/orchestrator.lock`, adopts a live
`nogg-orchestrator-<slug>` tmux session or starts one (resuming its conversation
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
| `session launch --role <r> [--bead <id>] [--planning-id <id> --description <d>] [--cwd <p>] [--read-only] [--owner <o>] [--agent <claude\|codex>] [--profile <n>] [--prompt <n>] [--full-access]` | start a supervised session; no Beads change |
| `session list` | list every session with live-reconciled state and its launch profile |
| `session log <name> [--follow]` | print / tail the log; never attaches |
| `session attach <name> [--read-only]` | attach the terminal; `Ctrl-b d` to detach |
| `session stop <name> [--reason <text>]` | interrupt, terminate, record a terminal state; idempotent |
| `session reap` | move vanished active-state records to `failed`; a live one is untouched |
| `session cleanup [<name>] [--reap]` | retire terminal records; refuses a live one (`--reap` fails the dead ones first) |
| `orchestrator run [--force]` | the always-on supervisor the systemd unit runs; `--force` reclaims a stale lock |
| `orchestrator status` | unit enabled/active state, linger on/off, the lock holder, the live `FULL-ACCESS` session |
| `orchestrator stop` \| `orchestrator restart` | stop-and-disable the unit (idempotent), or restart it |

Config keys (`.nogging/config.json`): `session_agent` (`claude` |  `codex`,
default `claude`), `session_tmux_socket`, `session_state_dir`,
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

With `--message`, nudge clears any actual pending input, types the message,
submits it and verifies submission: if the input is still pending it retries
the submit step once, then fails. A pane whose input box cannot be identified
also fails as unverified rather than reporting success. `send --verify`
uses the same check.

Without `--message`, nudge resends only single-line input that it can
positively identify: non-dim text in Claude's framed input box, captured with
attributes (`tmux capture-pane -e`). A placeholder-only, empty, multi-line or
unidentifiable prompt sends no keys at all, and the command tells you to pass
`--message`. Codex and other runtimes cannot expose the buffered text, so they
always need `--message`. Nudge still refuses any session that is not running,
before touching tmux. `session sweep` reports `has-unsent-input` as `yes`, `no`
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
tmux session or session record. Planning and orchestrator launches are not
gated by default. `./scripts/nogg usage` prints the same estimate, projection
and fit (`gate` in `--json`). Admission checks and reserves headroom under a
same-host lock in the owner-only user cache
(`$XDG_CACHE_HOME/nogging/usage/reservations`, default `~/.cache`). This ledger
is shared across repositories. Each window counts its outstanding estimates;
a reset releases only reservations from that window's previous period.
Failed launches release immediately. Pending launchers hold kernel file locks,
so process death releases ownership across PID namespaces. Terminal sessions
and dead pending launchers are reconciled on the next admission or usage inspection; live tmux
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
is added. The gate reduces risk but cannot guarantee a task fits.

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
