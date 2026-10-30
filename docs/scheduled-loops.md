# Scheduled loops

Nogging loops put recurring work in a durable definition instead of a timer
held by one agent conversation. A loop has a schedule, a run mode, and a prompt
file. The one minute scheduler and run admission are covered by the later
scheduler tasks; defining a loop does not enable that timer.

## Definitions and prompts

By default definitions live in `.nogging/loops.json`. Set the repository
configuration key `loops_file` to another repository-relative path when needed.
The timezone belongs to the definitions file and must be an IANA timezone.
Runtime state and approvals are always host-local under
`.nogging/state/loops/` in the main checkout.

Prompts are files in a `loops/` directory beside the definitions file. For the
default path that is `.nogging/loops/<name>.md`. A prompt is non-empty UTF-8,
at most 16 KiB, and cannot contain email addresses, recognized secret values,
tokens, secret assignments or private-key headers. Validation names the rule
and line without echoing the matched value.

The default `.nogging/loops.json` is versioned with the repository. Pointing
`loops_file` into an ignored host-local path keeps both definitions and prompt
files private to that checkout. The installer preserves these files and does
not create or replace them.

## Schedules

A schedule uses exactly one of `every` or `at`, with optional `start`, `days`,
`windows` and `grace`. Minute and hour intervals repeat from the daily anchor;
day and week intervals retain their phase. Windows include their start and
exclude their end, including across midnight. The schedule reference describes
the accepted forms in detail; `nogg loop add --help` shows the creation flags.

```json
{
  "schema_version": 1,
  "timezone": "Europe/Berlin",
  "loops": {
    "night-work": {
      "schedule": {"every": "30m", "windows": ["22:00-07:00"]},
      "run": {"mode": "send", "target": "orchestrator"}
    }
  }
}
```

An interval longer than one day keeps its phase from a full local anchor date:

```json
{
  "schema_version": 1,
  "timezone": "Europe/Berlin",
  "loops": {
    "dependency-check": {
      "schedule": {"every": "5d", "start": "2026-10-28T03:00"},
      "run": {"mode": "send", "target": "orchestrator"}
    }
  }
}
```

An anchored daily interval restarts each local day. This schedule fires at
02:07, 07:07, 12:07, 17:07 and 22:07:

```json
{
  "schema_version": 1,
  "timezone": "Europe/Berlin",
  "loops": {
    "orchestrator-issues": {
      "schedule": {"every": "5h", "start": "02:07"},
      "run": {"mode": "send", "target": "orchestrator"}
    }
  }
}
```

## Run modes and approval

`send` delivers an approved standing instruction to the orchestrator. `launch`
starts a fresh bounded supervised run for a named agent and tier, restricted by
default. A trusted launch must be explicitly configured. The loop cannot select
the orchestrator profile or prompt. Secret and authority checks still apply to
every loop prompt and launch.

`nogg loop add` writes the definition and prompt and approves that exact
content on the current host. The approval ledger stores a SHA-256 digest,
approval time and OS user name. Editing a definition or prompt changes its
digest, so the loop becomes unapproved until `nogg loop approve <name>` displays
its schedule, mode, target or agent, tier, authority and prompt hash and records
a new approval. Approval does not make unreviewed content safe; inspect it
before approving.

Only an operator or the Orchestration Agent can add, approve, remove, pause or
resume loops. Other supervised sessions are refused. `list`, `show` and `log`
are read-only and available to all roles.

## Launch mode and authority

A launch loop starts one fresh supervised session per run in the main checkout,
with the internal `loop` role, the loop launch prompt and exactly the agent,
tier, model, effort and authority the loop names. The kickoff is the
`[nogg loop <name> run <id>]` header plus the prompt. `session list` shows the
run as `loop:<name>`.

```bash
./scripts/nogg loop add issue-scan --every 6h --start 01:00 --mode launch \
  --agent codex --tier routine --authority trusted --max-runtime 30m \
  --prompt-file ./issue-scan.md
```

Launch mode is inspect-and-report only in this version. A run has no worktree
of its own, and its launch prompt forbids commits, tracked-file edits and
claiming a Bead. That rule is prompt-borne beyond the command floor and the
`openspec/` fence, as with any `trusted` session. Recurring work that changes
code goes through the Orchestration Agent as a send loop.

`restricted` is the default and suits read-only analysis. A restricted run stops
at the first Bash prompt: it waits in `needs_input` until `max_runtime` stops it.
Work that needs `bd` or `gh` needs `authority: "trusted"`, set explicitly and
covered by the loop's approval. The scheduler never raises a run's authority,
including on a retry, and never passes `--ignore-usage-gate`. Every run keeps
the command floor and the `openspec/` fence.

A run that is idle on two consecutive ticks has finished: its session is stopped
and retired, and the `completed` event records the archived log path. A session
that ends on its own is `failed`. A run past `max_runtime` is logged `stale`,
then stopped and retired as `stopped-stale`. Only a session carrying the run's
own `loop_run_id` is ever stopped. At most `scheduler.max_active_launch_runs`
launch runs (default 2) are active at once, so a further loop defers with
`active-run-limit` until its deadline.

A missing agent binary, an unavailable tmux server or a refused kickoff retries
on the same schedule as a failed delivery, and a session whose kickoff failed is
stopped and retired first. An unknown tier or agent is not retried.

## The scheduler timer

`init` and `update` render `systemd/nogg-loops-<slug>.service` and
`systemd/nogg-loops-<slug>.timer`. Nothing fires until you enable the timer,
which the installer's next steps print:

```bash
systemctl --user link "$PWD/systemd/nogg-loops-<slug>.service"
systemctl --user enable --now "$PWD/systemd/nogg-loops-<slug>.timer"
```

One timer serves every loop, so adding, editing or pausing a loop needs no
`systemctl`. It fires every minute with no catch-up: missed slots are the tick's
policy, not a systemd one. Enable it in the main checkout's user session, and run
`loginctl enable-linger` if loops must fire without a login. `remove` prints the
matching disable line.

With `--no-systemd` no unit is rendered and nothing fires automatically; every
command still works. Run `nogg loop tick` once a minute from an
external scheduler you own, in the main checkout and outside any supervised
session, or start single runs with `nogg loop run-now <name>`. A tick that finds
another one running exits at once, so an overlap is harmless. `doctor` keeps its
note about the missing timer in that setup, because it cannot see your scheduler.

With `multi_machine` set to `true`, every enabled loop must name its `host`. A
tick on another host neither evaluates that loop nor records anything for it,
and approvals are per host, so a loop runs only where it is assigned and
approved.

## Command reference

```bash
./scripts/nogg loop add night-work --every 30m --windows 22:00-07:00 \
  --mode send --target orchestrator --prompt-file ./night-work.md
./scripts/nogg loop list --json
./scripts/nogg loop show night-work
./scripts/nogg loop log night-work --limit 20
./scripts/nogg loop pause night-work
./scripts/nogg loop resume night-work
./scripts/nogg loop run-now night-work
./scripts/nogg loop approve night-work
./scripts/nogg loop remove night-work
./scripts/nogg loop tick
```

`list` reports the host state, next slot in local time and UTC, and latest
outcome. `show` includes the normalized definition, approval state, next five
slots and active run. `log` prints newest events first; missing or empty history
is normal. `list --json`, `show --json` and `log --json` are versioned read
interfaces. Removing a loop deletes only its definition, prompt and current
host state; its run history remains available. If a launch run is active, the
next tick stops and retires its session and logs `failed` with `loop removed`,
and a run whose loop moved to another host ends the same way. A loop that only
disappears from the file, for example across a merge, keeps its pause and
failure count, and its run goes on to completion or `max_runtime`.

## Run policy and troubleshooting

Recurring work belongs in an approved `nogg loop` definition. Do not create a
session-only cron or `/loop` for durable work. A loop-delivered message is a
bounded execution of the approved prompt within orchestrate-only scope and must
end with a short report. Its header does not grant extra authority.

If a loop is unapproved, compare its current definition and prompt with the
approved change before running `nogg loop approve`. If its status is paused or
suspended, inspect the host-local state before resuming it. A loop definition
alone does not schedule work; the operator must enable the scheduler timer or
run the tick another way.

`doctor` reports loop health without ever failing on it:

- A loop that *will not run*: the timer is missing or disabled. Enable it, or run
  `nogg loop tick` yourself.
- A timer whose state is *unknown from this session*: `systemctl` is denied
  there (a fenced session), so `doctor` cannot tell. It stays quiet while the
  last tick is under five minutes old; otherwise check from a shell outside
  the session.
- An enabled timer whose last tick is over five minutes old: check
  `systemctl --user status nogg-loops-<slug>.timer` and the service's journal.
- An invalid definitions file is a `doctor` FAIL. Ticks keep running and keep
  supervising started runs, but no new run starts until it is fixed.
- A loop that is `unapproved` or `suspended`: review it with `nogg loop log`, then
  run `nogg loop approve` or `nogg loop resume`.
- A run past `max_runtime`: a tick should have ended it, so the timer is stalled
  or its session could not be retired. The tick reports that on stderr, in the
  service's journal, and tries again every minute. Started runs stay supervised
  while the definitions file is invalid.
- A loop that failed in the last tick: one loop's error does not stop the others,
  and the tick exits non-zero after evaluating them all.

A restricted run that keeps ending `stopped-stale` usually sat in `needs_input`
at an approval prompt. Read the archived log path from `nogg loop log`, then
narrow the prompt to read-only work or approve the loop as `trusted`.

### Tick and run-now

The scheduler evaluates approved definitions once per minute from the main
checkout. Each pass records `last_tick` and takes a non-blocking lock; an
overlapping pass reports that it is busy and exits without evaluating loops.
Missed schedule slots are coalesced, and the latest slot is considered only
until its grace period, next slot, or window end. A loop added or approved now
starts evaluating from that approval time, so it never catches up on earlier
slots. `nogg loop run-now <name>` uses the same approval, pause, usage and target
checks but ignores the schedule and window.

Send mode targets only the canonical Orchestration Agent session. It sends the
prompt with the `[nogg loop <name> run <id>]` header through verified delivery
only while the target is idle or waiting on its own background tasks
(`waiting_background`: the session sits at its prompt and accepts a message).
Working, waiting for input, rate limited or absent targets defer scheduled work
until the slot deadline; a manual run-now reports the reason as skipped. The run
log records a `target-busy`, `target-needs-input`, `target-limit`,
`target-not-running` or `target-unavailable` reason, never the raw state. The scheduler never queues to a busy session,
starts or restarts the orchestrator, or stops it. A delivered run completes
after two consecutive idle observations. A run beyond `max_runtime` is logged
as unconfirmed and does not stop the orchestrator. Transient delivery failures
retry after two and four minutes, with at most three attempts per slot and never
past its deadline. Three consecutive failed slots suspend the loop until it is
resumed.

### Usage admission

Every run observes its agent's usage windows, the loop's agent for launch and
the target's for send, and applies the repository usage gate, including its
estimate and outstanding reservations. A loop's `usage.max_used_percent` can
impose a stricter limit. Known over-budget and unknown-denied observations skip
the slot with the bucket and reset details; unknown-warn is recorded on the run.
A usage observation that fails outright also skips the slot, because headroom
that cannot be observed admits nothing. A launch then passes the normal launch admission and reservation, and a denial
there (exit 75) is the same hard skip. A denial is never retried and never
changes the tier, agent or model.

### Run log

The host-local `runs.jsonl` file contains one version 1 JSON object per event.
Each row has `schema_version`, `at`, `loop`, `run_id`, `slot`, `trigger` and
`event`, plus known `reason`, `mode`, `target`, `session`, `agent`, `tier`,
`attempt`, `usage` and `log_path` fields. Events are `missed`, `deferred`,
`skipped`, `starting`, `delivered`, `started`, `retry-scheduled`, `completed`,
`failed`, `stale`, `stopped-stale`, `unconfirmed` and `suspended`. `starting` is
recorded before delivery begins. The log never stores prompt text and rotates
at 1 MiB, keeping three older generations.
