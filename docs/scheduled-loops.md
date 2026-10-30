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

## Command reference

```bash
./scripts/nogg loop add night-work --every 30m --windows 22:00-07:00 \
  --mode send --target orchestrator --prompt-file ./night-work.md
./scripts/nogg loop list --json
./scripts/nogg loop show night-work
./scripts/nogg loop log night-work --limit 20
./scripts/nogg loop pause night-work
./scripts/nogg loop resume night-work
./scripts/nogg loop approve night-work
./scripts/nogg loop remove night-work
```

`list` reports the host state, next slot in local time and UTC, and latest
outcome. `show` includes the normalized definition, approval state, next five
slots and active run. `log` prints newest events first; missing or empty history
is normal. `list --json`, `show --json` and `log --json` are versioned read
interfaces. Removing a loop deletes only its definition, prompt and current
host state; its run history remains available.

## Run policy and troubleshooting

Recurring work belongs in an approved `nogg loop` definition. Do not create a
session-only cron or `/loop` for durable work. A loop-delivered message is a
bounded execution of the approved prompt within orchestrate-only scope and must
end with a short report. Its header does not grant extra authority.

If a loop is unapproved, compare its current definition and prompt with the
approved change before running `nogg loop approve`. If its status is paused or
suspended, inspect the host-local state before resuming it. A loop definition
alone does not schedule work; the operator must enable the scheduler timer when
that capability is installed, or invoke the supported scheduler manually.

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
only while the target is idle. Working, waiting for input, rate limited or
absent targets defer scheduled work until the slot deadline; a manual run-now
reports the reason as skipped. The scheduler never queues to a busy session,
starts or restarts the orchestrator, or stops it. A delivered run completes
after two consecutive idle observations. A run beyond `max_runtime` is logged
as unconfirmed and does not stop the orchestrator.

### Usage admission

Every send observes the target agent's usage windows and applies the repository
usage gate, including its estimate and outstanding reservations. A loop's
`usage.max_used_percent` can impose a stricter limit. Known over-budget and
unknown-denied observations skip the slot with the bucket and reset details;
unknown-warn is recorded on the run. A denial never changes the agent or model.

### Run log

The host-local `runs.jsonl` file contains one version 1 JSON object per event,
including the loop, run ID, slot, trigger, event, and any known reason, target,
agent, tier, attempt or usage observation. Events include `missed`, `deferred`,
`skipped`, `starting`, `delivered`, `retry-scheduled`, `completed`, `failed`,
`unconfirmed` and `suspended`. `starting` is recorded before delivery begins.
The log never stores prompt text and rotates at 1 MiB, keeping three older
generations.
