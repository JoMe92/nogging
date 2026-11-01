## Why

The Product Owner asked on 2026-10-27 (GitHub epic #286, epic Bead SPEC-ij1w)
for a Nogging loop feature: like Claude Code's `/loop`, which resends one prompt
every few hours, but richer. Several named loops, each with its own prompt and
schedule (loop 1 hourly, loop 2 every 5 days, for example a dependency check),
and time windows (every 30 minutes at night to get a lot done, no loop during
the day while the Product Owner watches in person).

Today the only recurring work is the Orchestration Agent's own issue/close
prompt. It is a Claude Code session-only cron job (`CronCreate`, last set to
`7 2,7,12,17,22 * * *`). It lives inside one conversation, dies with that
session and has been lost several times on a restart. Nothing lists it, logs
its runs, checks the usage gate before a run, or survives a reboot.

## What Changes

- **Named loops in a versioned file.** `.nogging/loops.json` (location
  configurable with `loops_file`) holds every loop. A loop has a name, a prompt
  file under `.nogging/loops/`, a schedule, a run mode, and optional usage
  budget, host and limits. The file states its IANA timezone explicitly. Runtime
  state (pause, last run, failures) and the run log live under
  `.nogging/state/loops/` and are never committed.
- **Schedules with windows.** A schedule is either `every` (an interval of
  minutes, hours, days or weeks with an explicit anchor) or `at` (a list of
  daily times). Optional `days` and `windows` limit when it fires, for example
  every 30 minutes between 22:00 and 07:00. Slots are computed in the loop
  timezone with fixed rules for daylight-saving changes.
- **Two run modes, chosen per loop.** `send` delivers the prompt to the
  long-running Orchestration Agent through the verified `session send` path,
  only while it is idle. `launch` starts a fresh supervised session per run with
  the new Bead-less `loop` role. That session uses the loop's agent and tier and
  `restricted` authority unless the loop explicitly says `trusted`. A run ends
  when its first turn completes. A loop never reaches the orchestrator profile,
  never lifts the command floor and never makes `openspec/` writable.
- **One durable scheduler.** A rendered systemd user timer
  (`nogg-loops-<slug>.timer`) runs a stateless `nogg loop tick` every minute
  from the main checkout. Loop changes need no `systemctl` call. Without
  systemd, nothing fires automatically: `doctor` says so, and `nogg loop tick`
  or `run-now` can be run by hand or by an external scheduler.
- **A strict run policy.** A loop never overlaps itself. A slot whose run is
  blocked (busy target, launch failure) is retried until its deadline. The
  deadline is the grace period, the next slot or the window end, whichever comes
  first. Slots missed during downtime are recorded as one coalesced `missed`
  entry, so there is no catch-up storm. A run that exceeds its `max_runtime` is
  marked stale, and the loop's own launched session is then stopped. A loop
  whose slots fail several times in a row is suspended.
- **Usage gate before every run.** Each run is checked against the usage gate
  and an optional per-loop budget (`max_used_percent`). A denied run is skipped
  and logged with the window and its reset time. Quota never lowers a tier,
  changes the model or switches the agent.
- **Operator approval.** Every loop needs a host-local approval tied to a hash
  of its definition and prompt, written by `nogg loop add` or
  `nogg loop approve` from an operator shell or the Orchestration Agent. An
  edited or merged loop does not run until it is approved again. Loop management
  is refused inside every other supervised session.
- **CLI and observability.** `nogg loop add | list | show | log | pause |
  resume | run-now | approve | remove | tick`. Every slot outcome (started,
  delivered, completed, skipped with a reason, missed, failed, stale) is
  appended to a versioned JSONL run log. `list` and `log` have `--json` output
  as a read contract for the later dashboard (#283). `nogg validate` and
  `doctor` check the file. `doctor` also reports unapproved, suspended and stale
  loops and a scheduler that is not installed or has stalled.
- **Migration.** The orchestrator prompt and `/orchestrate` say to use
  `nogg loop` for recurring work and never a session-only schedule. The current
  5-hour issue/close prompt becomes the configured send loop
  `orchestrator-issues` (`every: 5h`, `start: 02:07`), and its session cron is
  deleted. On the Product Owner's decision, this repository keeps its loops
  host-local (`loops_file: ".nogging/state/loops.json"`), so that prompt is
  never committed. The tracked `.nogging/loops.json` stays the default for
  other repositories.

## Capabilities

### New Capabilities

- `scheduled-loops`: loop definitions and validation, schedule semantics, run
  modes and authority, the scheduler tick and its run policy, usage admission,
  approval, the CLI, the run log and diagnostics.

### Modified Capabilities

- `installer`: renders, explains and removes the loop scheduler timer and
  service, honours `--no-systemd`, and ships the loop launch prompt, the module
  and the guide.
- `orchestration-agent`: the orchestrator keeps recurring work in configured
  loops, never in a session-only schedule, and handles a loop-delivered message
  as a scheduled run.

## Impact

Affected: `scripts/nogg` (the `loop` command group, the `loop` session role,
`validate`, `doctor`, usage-gate roles), new pure modules under `scripts/lib/`,
`templates/systemd/`, `bin/lib/{manifest,systemd,nextsteps,remove}.js`,
`templates/nogging-config.json`, `.nogging/launch-prompts/` (new `loop.md`, an
edited `orchestrator.md`), `.claude/commands/orchestrate.md`, docs (a new
consumer-copied guide page plus operating-model, architecture, security-model
and failure-recovery sections), `CHANGELOG.md`, and new offline suites in
`scripts/test`.

Not in scope: a resident daemon, cron-expression syntax, loops that target any
session other than the Orchestration Agent, launch-mode runs on a Bead or in
their own worktree, automatic tier, agent or model fallback, the dashboard
itself, and signing human acceptance.
