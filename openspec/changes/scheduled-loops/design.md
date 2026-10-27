## Context

The Product Owner's request of 2026-10-27, from speech to text and translated
here: Claude Code has a loop function that resends one command every few hours.
Nogging should have one too, but richer. Every 30 minutes at night, to get a lot
done, and no loop during the day, when the Product Owner looks at things in
person. Several intervals and several prompts: loop 1 does X every hour, loop 2
does Y every 5 days, for example a dependency check. This is the first roadmap
epic to build (GitHub #286, epic Bead SPEC-ij1w), ahead of the dashboard (#283).

Facts gathered while planning, on `develop` at `3936829`:

- **Today's only loop is session-only.** The Orchestration Agent's transcript
  shows `CronCreate` jobs since 2026-10-10: hourly at `:07`, then
  `7,27,47 * * * *`, then `7 */4 * * *`, last `7 2,7,12,17,22 * * *`. All are
  recurring Claude Code session crons. They run in the host's local time
  (Europe/Berlin), die with the conversation and are not visible to
  `nogg session list` or `doctor`. The last prompt (German) asks the
  orchestrator to check GitHub for new issues and plan the quick ones, to start
  planned work that resolves issues, and to close issues that can be closed.
- **Units.** `bin/lib/systemd.js` renders `templates/systemd/*.tmpl` into the
  target's `systemd/` directory: the sync service and its 30-second timer, and
  the always-on `nogg-orchestrator-<slug>.service`. `--no-systemd` skips that
  rendering. `bin/lib/nextsteps.js` prints the `systemctl --user enable --now`
  line. `doctor` reports the orchestrator unit without failing on its absence.
  `systemctl` is denied to the restricted and trusted profiles. Only the
  operator or the Orchestration Agent can enable a unit.
- **Supervised sessions.** `session launch` (role `lead`, `planning`,
  `specialist:<type>` or `orchestrator`) refuses a missing agent binary before
  any side effect (`require_agent_binary`). That covers the 2026-10-27
  `claude: not found` during an auto-update. It applies the usage gate
  (`usage_gate_admission`, roles `lead`, `planning`, `orchestrator`,
  `specialist`; planning and orchestrator excluded by default; cap 92 %; denial
  exits 75 naming the reset). With `--kickoff` it delivers a first message once
  the composer is ready. `session send` takes the per-session delivery lock and
  verifies submission. `classify_session` returns `working`, `idle`, `limit`,
  `needs_input`, `ended` or `unknown`. A busy Codex queue send has lost messages
  (SPEC-t374), and the 2026-10-19 change now refuses it.
- **Caller identity.** `calling_session_record()` proves by process ancestry
  whether a command runs inside a supervised session, failing closed. It is
  what lets `orchestrator restart` refuse itself.
- **Authority.** `restricted` Claude runs in `defaultMode: default`, so any
  Bash call waits for an approval that never comes unattended. `trusted` is
  `bypassPermissions` with the floor plus `systemctl`, `curl`, `wget` and
  `WebFetch` denied. A restricted Codex session cannot reach the shared Dolt
  server.
- **Docs site.** `branded-docs-site` is in flight. Every page under `docs/`
  needs a `docs/_config.yml` defaults placement (`scripts/docs-site.test.sh`).
  TASK-BDS-007 (`docs/commands.md`) compares headings with `nogg --help`.
  TASK-BDS-013 (`docs/configuration.md`) checks key coverage against the config
  template and `scfg()` literals. Twelve pages are copied into consumers under
  `docs/nogging/`. They may link relatively only to each other.
- **Discoveries.** `nogg discoveries` lists 148 pending discoveries. None is
  about schedules, cron or loops, so none is carried into this change, and none
  is acknowledged here.

## Goals / Non-Goals

**Goals:** several named, versioned, reviewable loops with schedules and time
windows. A per-loop choice between messaging the orchestrator and a fresh
supervised session. Durability across reboot and orchestrator restart. A
predictable overlap, retry and missed-run policy. Usage-gate admission on every
run. Authority no higher than the operator approved. Every run listed and
logged. The orchestrator's 5-hour loop migrated.

**Non-Goals:** a resident daemon; cron expressions; loops that message any
session but the orchestrator; launch-mode runs on a Bead, in a worktree or as a
planning session; automatic tier, model or agent fallback; the dashboard; a
loop editor UI; sub-minute precision.

## Decisions

### Decision 1: Test and implementation discipline

Every suite is offline and runs in `scripts/test`. No real systemd, no Dolt
or `bd` (stub it as `scripts/nogg.test.sh` does), no shared `-L nogging` tmux
server (private sockets under 108 bytes, `scripts/lib/test-env.sh`), and the
stub agents from `scripts/lib/test-agents.sh`. Clocks are injected, with no real
sleep. Timezone cases use `zoneinfo` with `Europe/Berlin` (2026-10-25 and
2027-03-28 transitions) and `UTC`. No new runtime dependency: Python standard
library and Node standard library only. Pure logic lives in new modules
`scripts/lib/loop_schedule.py` (schedule) and `scripts/lib/loop_config.py`
(definitions, validation, hashing). They load beside `scripts/nogg` like
`session_backend`, and `bin/lib/manifest.js` ships them. Each failing-first
suite is red on develop before the fix. Prompts, fixtures and docs contain no
email address, and the owner is named only as Jonas or `JoMe92`.

### Decision 2: Definitions in one versioned file, state outside Git

Definitions live in `.nogging/loops.json`. The config key `loops_file`
(repository-relative) can move it, for example under `.nogging/state/` to keep
loops host-local and untracked. Each loop's prompt is the file
`loops/<name>.md` in the definitions file's directory, so `.nogging/loops/<name>.md`
by default. Prompts are files only, never inline, so the approval hash, review
diffs and multi-line prompts stay simple. A missing definitions file means no
loops. The installer never writes either path, and `update` preserves both.

The tracked `.nogging/loops.json` stays the shipped default
(`templates/nogging-config.json`) for every other repository. This repository
keeps its own loops host-local (Product Owner decision 1): its
`.nogging/config.json` sets `loops_file: ".nogging/state/loops.json"`, so the
definitions and the prompts (`.nogging/state/loops/<name>.md`) are gitignored
and never published. In that layout the prompts share `.nogging/state/loops/`
with the runtime files below. Those have fixed names that never end in `.md`, so
no loop name can collide with them, and Nogging never deletes that directory as
a whole: `nogg loop remove` deletes only the one prompt file.

```json
{
  "schema_version": 1,
  "timezone": "Europe/Berlin",
  "scheduler": {"max_active_launch_runs": 2, "suspend_after_failures": 3},
  "loops": {
    "orchestrator-issues": {
      "schedule": {"every": "5h", "start": "02:07"},
      "run": {"mode": "send", "target": "orchestrator"}
    },
    "night-work": {
      "schedule": {"every": "30m", "windows": ["22:00-07:00"]},
      "run": {"mode": "send", "target": "orchestrator"},
      "usage": {"max_used_percent": 70}
    },
    "dependency-check": {
      "schedule": {"every": "5d", "start": "2026-10-28T03:00"},
      "run": {"mode": "launch", "agent": "codex", "tier": "routine",
              "authority": "trusted", "max_runtime": "45m"},
      "host": "raspberrypi"
    }
  }
}
```

Loop names are kebab-case, unique and at most 40 characters. A duplicate JSON
key is a validation error, read with an `object_pairs_hook`. Unknown keys are
refused at every level, as `usage_gate` does. A loop may also set `enabled`
(default `true`) and `usage.on_unknown`. The `schedule` object may also set
`grace`, `days` and `windows`. The `run` object of either mode may set
`max_runtime`. Runtime
state lives under `.nogging/state/loops/` in the main checkout: `state.json`
(pause, last evaluated slot, active run, consecutive failures), `approvals.json`
and `runs.jsonl`. That state is gitignored and host-local.

Prompt files must be non-empty UTF-8 without NUL and at most 16 KiB. They must
contain no email address and no secret. A secret is a value of a set
secret-named environment variable (the existing `secret_values()`), a
`NAME=value` secret assignment (`_SECRET_ASSIGN_RE`), or a known token shape:
GitHub `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`/`github_pat_`, `sk-ant-`, `sk-`
followed by 20 or more token characters, `AKIA` plus 16, Slack `xox?-`, or a
PEM private-key header. The error names the file, the line and the rule, never
the matched value.

### Decision 3: Schedule semantics

A schedule has exactly one of `every` or `at`, plus optional `start`, `days`,
`windows` and `grace`. Times are wall-clock times in the file's `timezone`
(required, a valid IANA name). Persisted timestamps are UTC with `Z`. Displays
show both local time and UTC.

- `every: "<n>m|h"` (5 minutes or more, under 24 hours, whole minutes):
  slots repeat within each local day from the anchor time of day (`start:
  "HH:MM"`, default `00:00`) while they stay before the next day's anchor. The
  day restarts at the anchor, like cron. So `every: 5h, start: 02:07` gives
  02:07, 07:07, 12:07, 17:07 and 22:07, the orchestrator's current schedule.
- `every: "<n>d|w"`: one slot every n local days (or 7n) at the anchor time.
  For n greater than 1 day, `start` must be a full local datetime
  (`YYYY-MM-DDTHH:MM`), so the phase is deterministic on every host. For `1d`,
  `HH:MM` is enough.
- `at: ["HH:MM", ...]`: those daily times, sorted, without duplicates.
- `windows: ["HH:MM-HH:MM", ...]`: a slot is kept only inside a window. The
  start is inclusive, the end exclusive, start and end are different, and a
  window may cross midnight.
- `days: ["mon", ...]` filters by local weekday. For a slot inside a window
  that crosses midnight, the weekday is that of the date the window opened, so
  Friday 22:00 to 07:00 includes Saturday 01:00.
- Daylight saving: a slot in a skipped hour fires at the first instant after
  the gap. A slot in a repeated hour fires once, at its first occurrence.
  Day-based intervals keep their wall-clock time across a change.
- `grace` is how long a due slot may wait for admission. The default is half
  the interval up to 30 minutes for `every`, and 30 minutes for `at`, with a
  1-minute minimum. A slot's **deadline** is the earliest of slot + grace, the
  next slot and the end of the window that contains it.

The engine is pure. It provides `next_slots(schedule, after, n)`,
`due(schedule, last_evaluated, now)` (returns the latest due slot and the
count, first and last of the older ones) and `deadline(schedule, slot)`.

### Decision 4: Run modes and authority

`run.mode` is chosen per loop.

- **`send`** delivers to `target: "orchestrator"` only: the canonical singleton
  `nogg-orchestrator-<slug>`, whatever runtime it uses (so it stays compatible
  with `dual-runtime-orchestrator`). The message is one header line,
  `[nogg loop <name> run <run-id>]`, then the prompt file. It goes through
  `session send --verify` under the existing delivery lock, and only when
  `classify_session` reports `idle`. `working`, `needs_input`, `limit`,
  `unknown` or no live session defers the slot. The scheduler never queues to a
  busy session, never launches or restarts the orchestrator, and never stops a
  session it did not launch. A send loop names no agent, tier or authority,
  because it inherits the target's. It may set `max_runtime` (default
  1 hour), the horizon for confirming the run.
- **`launch`** starts a fresh supervised session per run through the same
  internal `session launch` path, with the new role `loop`. That role has no
  Bead. The record holds `loop_name` and `loop_run_id`, and the name is
  `sf-loop-<name>-<nonce>` through the safe-name helper. The working directory is
  the main checkout. Required: `agent` and `tier`. Optional: `model` and
  `effort`, for a Product Owner instruction only, recorded as launch
  provenance, plus `authority` and `max_runtime` (default 1 hour, 5 minutes to
  12 hours). `authority` is `restricted` (default) or `trusted`, the
  tool-neutral levels. The launch prompt is the new
  `.nogging/launch-prompts/loop.md`, never `autonomous` or `orchestrator`, and
  the kickoff message is the header plus the prompt. The `loop` role always gets
  the command floor and the `openspec/` read-only fence, and is refused the
  `orchestrator` profile. `session launch --role loop` on the command line is
  refused with a pointer to `nogg loop run-now`. The role joins the usage gate's
  role set and is gated by default.

The `loop.md` persona: a scheduled, unattended, one-shot run. Do only what the
loop prompt asks. Inspect, then report through Beads (`bd create`, notes) or
GitHub issues as the prompt directs. Never claim a Bead, never edit tracked
files, never commit, push or merge, never write `openspec/`, never launch
sessions. End the turn with a short summary. Restricted authority suits
read-only analysis only: the first Bash approval prompt leaves the run in
`needs_input`. Work that needs `bd` or `gh` needs `trusted`, set explicitly.
These limits are prompt-borne beyond the floor and fence, as the existing
`trusted` model already states. The loop's approval (Decision 8) is what makes
`trusted` an operator decision. This inspect-and-report scope is the whole of
launch mode in v1 (Product Owner decision 4): no own worktree, no commits, and
code-changing recurring work goes through the orchestrator.

### Decision 5: One timer, a stateless tick, the main checkout as home

Systemd units are not generated per loop. The installer renders
`nogg-loops-<slug>.service` (`Type=oneshot`, `scripts/nogg loop tick`) and
`nogg-loops-<slug>.timer` (`OnCalendar=minutely`, `AccuracySec=5s`,
`Persistent=false`). Missed slots are the tick's policy, not a systemd
catch-up. Adding, editing or pausing a loop needs no `systemctl`. `loop tick`
runs only in the main checkout (as `orchestrator run` does) and refuses inside
any supervised session. It takes a non-blocking `flock` on
`.nogging/locks/loops.lock`. Under contention it prints
`loop tick: busy (another tick is running)` and exits 0. A crash releases the
lock with the process. It writes `last_tick` to `state.json` on every pass.

`--no-systemd`: no units are rendered and nothing fires automatically. Every
other command works. `doctor` prints a NOTE when enabled loops exist but the
timer is absent or disabled. The guide shows `nogg loop tick` and `run-now`
for manual use and an operator-owned external scheduler.

Multi-machine: when `multi_machine` is `true`, every enabled loop must name
its `host`. A tick on another host does not evaluate that loop and records
nothing for it. Approvals are host-local too (Decision 8), so a loop runs only
where it is assigned and approved.

### Decision 6: Run policy

Per loop and tick, in this order:

1. **Evaluate.** Compute the due slots since `last_evaluated` (initially the
   approval time, so a new loop never fires for past slots). More than one due
   slot coalesces into one `missed` event (count, first, last). Only the latest
   slot is a candidate, and only before its deadline. Past the deadline it is
   also `missed`.
2. **Hard skips**, logged once per slot with no retry: disabled, paused,
   suspended, unapproved or stale approval, or a usage-gate denial (Decision 7).
3. **Deferrals**, retried every tick until the deadline, then logged as
   `skipped` with the last reason. The reasons: `previous-run-active` (the
   loop's own run is not finished), `active-run-limit`
   (`max_active_launch_runs`, default 2, across launch loops; the host is a
   Raspberry Pi, and the Product Owner confirmed 2 in decision 3), `target-busy`, `target-needs-input`, `target-limit` or
   `target-not-running`. A deferral is logged when its reason changes, not on
   every tick.
4. **Start.** Write a `starting` event with the run ID
   (`<name>-<slot as UTC compact>`) before any side effect. A send records
   `delivered`. A launch records `started` with the session name.
5. **Retry.** A transient start failure is retried after 2, 4 and 8 minutes,
   at most 3 attempts per slot, never past the deadline. Transient means a
   missing agent binary (an auto-update in progress), no tmux server, a
   delivery or kickoff timeout, or a refused kickoff. A launched session whose
   kickoff fails is stopped and retired, so nothing is orphaned. A permanent
   failure is not retried: invalid configuration, a refused authority or an
   unknown agent.
6. **Finish.** A run is `completed` when its session is `idle` on two
   consecutive ticks after delivery (the turn ended). A launched run's session
   is then stopped and retired with `session stop` and `session cleanup`, and the
   archived log path is recorded. A launched session that ends on its own is
   `failed`. A run older than `max_runtime` is `stale`. A launched stale run is
   stopped and retired (`stopped-stale`). A sent stale run is only recorded
   (`unconfirmed`); the orchestrator is never stopped.
7. **Suspend.** Each slot that ends `failed` or `stopped-stale` increments
   `consecutive_failures`. An `unconfirmed` send run does not, because a long
   orchestrator turn is not a loop failure. A completed run resets it. At
   `suspend_after_failures` (default 3) the loop is paused with reason
   `suspended`. `doctor` warns until `nogg loop resume`.

A `starting` event with no session and no delivery after 10 minutes (a tick
that crashed mid-start) is reconciled. The tick scans session records for that
`loop_run_id`, adopts a live session, or records `failed: start interrupted`.
`run-now <name>` runs one manual slot through the same chain from step 2 on,
with no schedule or window. It reports `skipped: <reason>` instead of deferring.

### Decision 7: Usage admission on every run

Before a start, the tick observes the usage windows of the run's agent: the
loop's own agent for launch, the target record's agent for send. It uses the
existing `observe` and `gate_config`. The run is skipped with
`usage-gate: <bucket> <used>% (cap <cap>%), resets <time>` when a known window
plus the configured estimate exceeds the cap. It is also skipped when a known
window exceeds `usage.max_used_percent`, a per-loop budget that can only be
stricter than the cap. Unknown usage follows `usage.on_unknown` (default: the
global `usage_gate.on_unknown`). A warn admission is recorded on the run. Send
mode applies the check even though the orchestrator role is excluded from
launch admission: a night loop must not drain the weekly window. Launch mode
then passes through the normal `session launch` admission and reservation for
role `loop`. A denial with exit 75 there is the same hard skip. `--ignore-usage-gate`
is never used by the scheduler. A denial never lowers the tier, changes the
model or agent, or retries sooner than the next slot.

### Decision 8: Approval and who may manage loops

`approvals.json` maps each loop name to the SHA-256 of the canonical JSON of
the file's `timezone`, the loop's normalized definition and its prompt bytes,
plus `approved_at` and the OS user name, never an email address. A loop whose
current hash differs, for example after a hand edit or a merge from `develop`,
is `unapproved`. It does not run until `nogg loop approve <name>` shows the
schedule, mode, target or agent, tier, authority and prompt hash and records
the new approval. `nogg loop add` approves what it writes. `add`, `approve`,
`remove`, `pause`, `resume`, `run-now` and `tick` are refused when
`calling_session_record()` proves a supervised session other than the
Orchestration Agent. The orchestrator may run them, including `add` and
`approve` on the Product Owner's instruction from the phone (Product Owner
decision 2). Its prompt allows that only on an explicit Product Owner
instruction. `list`, `show` and `log` are
read-only and allowed everywhere. The approval guards against an accidental or
merged change taking effect unseen. It is not a boundary against a hostile
process with host write access, the same posture as the command floor.

### Decision 9: Observability contract

`runs.jsonl` holds one JSON object per event:
`{schema_version: 1, at, loop, run_id, slot, trigger: scheduled|manual,
event, reason?, mode, target?, session?, agent?, tier?, attempt?, usage?,
log_path?}`. The `event` values are `missed`, `deferred`, `skipped`,
`starting`, `delivered`, `started`, `retry-scheduled`, `completed`, `failed`,
`stale`, `stopped-stale`, `unconfirmed` and `suspended`. The file is
size-rotated at 1 MiB to 3 generations. `nogg loop list` shows the name, state
(`enabled`, `disabled`, `paused`, `suspended`, `unapproved`, `other-host`),
schedule, mode and target or agent/tier/authority, next slot (local and UTC),
and the last outcome. `show <name>` adds the definition, the approval state, the
next 5 slots and the active run. `log <name> [--limit N]` prints history
newest-first. `list --json` and `log --json` are the documented read contract
for #283. `session list` shows a loop run's role as `loop:<name>`.

`nogg validate` and `doctor` FAIL on an invalid definitions file or prompt.
`doctor` WARNs on an unapproved, suspended or stale-run loop, and on a timer
that is enabled while `last_tick` is older than 5 minutes. It prints a NOTE when
enabled loops exist and the timer is not installed or not enabled.

### Decision 10: Migrating the orchestrator's loop

`.nogging/launch-prompts/orchestrator.md` and `.claude/commands/orchestrate.md`
say: recurring work goes into `nogg loop`. Never create a session-only schedule
(`CronCreate`, `/loop`) for it. A message headed `[nogg loop <name> run <id>]`
is a scheduled run of an operator-approved standing instruction: do it within
orchestrate-only scope and end with a short report. Propose `nogg loop add`
when the Product Owner asks for something recurring. The live migration happens
in the acceptance task. It defines `orchestrator-issues`
(`every: 5h, start: "02:07"`, send to the orchestrator) with the Product
Owner's current prompt, approves it, has the operator or orchestrator enable
the timer, and then deletes the orchestrator's session cron (`CronDelete`).
The prompt stays host-local (Product Owner decision 1). TASK-SCL-002 sets this
repository's `loops_file` to `.nogging/state/loops.json`, so it is on `develop`
before the acceptance runs. `nogg loop add` in the main checkout then writes the
definition to that file and the prompt to
`.nogging/state/loops/orchestrator-issues.md`. Neither is committed, and the
acceptance report names the loop and its schedule but quotes no prompt text.
The shipped orchestrator guidance stays generic: `nogg loop add` writes into
whichever `loops_file` a repository configures.

### Decision 11: Docs and coordination with in-flight changes

There is one new consumer-copied guide page, `docs/scheduled-loops.md`. It
covers concepts, the file format, schedule examples (night window, 5-day check),
modes and authority, approval, the CLI, the run policy, usage, `--no-systemd`,
multi-machine and troubleshooting. It is added to `manifest.docs` and the
package files and placed under Guides in `docs/_config.yml`. It links
relatively only to other consumer-copied pages. There are short sections in
`operating-model.md`, `architecture.md`, `security-model.md` and
`failure-recovery.md`, and a CHANGELOG entry. Since the planning commit was
rebased onto `develop` at `6093d61`, `docs/commands.md` and
`docs/configuration.md` exist there, and `scripts/docs-site.test.sh` requires
their `##`/`###` headings to match `nogg --help` and every template key to be
documented. So the task that adds a config key or a subcommand updates the page
in the same commit: TASK-SCL-002 `loops_file`, TASK-SCL-003 `## loop` and its
commands, TASK-SCL-005 `tick` and `run-now`. No blocking edge goes to the
remaining `branded-docs-site` tasks. `dual-runtime-orchestrator` also edits the
orchestrator prompt: TASK-SCL-008 rebases onto whatever has landed, with no
blocking edge, because the send target resolves the canonical singleton for
either runtime.

### Decision 12: Acceptance on the delivery host

A host-capable Claude `--full-access` Lead runs the acceptance on this
repository's main checkout. Enabling the timer is done by the operator or the
Orchestration Agent, because `systemctl` is denied to Lead profiles. The run
covers the migrated `orchestrator-issues` loop, a short-interval send loop
inside a window observed firing on schedule and deferring while the
orchestrator is busy, a routine Codex launch loop observed launching, completing
and being retired, a forced usage-gate skip through a temporary
`max_used_percent: 1`, an orchestrator restart between two slots, and timer
survival across `systemctl --user restart` of the timer. The report records
versions and honest outcomes and stays unsigned. The shared tmux server is
never stopped.

## Risks / Trade-offs

- **A standing prompt to a god-mode session.** Send loops feed the
  unrestricted orchestrator on a timer. Mitigations: operator approval bound to
  the prompt hash, idle-only delivery, a visible header, the run log, and the
  orchestrator's own orchestrate-only rule. The residual risk is the
  orchestrator's documented one.
- **Launch runs in the main checkout.** A `trusted` loop run could edit or
  commit on `develop`. That is limited by the prompt, the floor, the fence, the
  approval and visibility, not by a sandbox. Own-worktree loops are a follow-up.
- **Restricted launch loops are narrow** (Claude prompts for Bash). That is
  stated in the docs instead of widened.
- **One-minute granularity and a busy tick.** A long kickoff delays other loops
  by up to the delivery timeout. Grace absorbs it.
- **A tracked file publishes prompts** in a public repository. That is the
  default for other repositories; `loops_file` relocates it, as this repository
  does. Secret and email checks reject the worst case either way.
- **Host-local loops have no Git history.** In this repository a lost or
  corrupted `.nogging/state/` loses the definitions and prompts, and a second
  host does not see them. The run log and `nogg loop show` are the record, and
  re-adding a loop needs a fresh approval anyway.

## Dependencies and parallel lanes

Branches are `<type>/scheduled-loops`. Lanes: `feat/` 001 → 002 → 003 → 005 →
006; `fix/` 004; `chore/` 007; `refactor/` 008; `docs/` 009; `test/` 010. A
lane reuses its prefix only after the previous branch is integrated and
deleted. TASK-SCL-001 and TASK-SCL-004 start in parallel. The edges are in
`tasks.md`.

## Product Owner decisions (2026-10-27)

The Product Owner approved the plan and answered its open questions:

1. **Host-local loops in this repository.** This repository sets
   `loops_file: ".nogging/state/loops.json"`, so its loop definitions and
   prompts, including the German `orchestrator-issues` prompt, are never
   committed. The tracked `.nogging/loops.json` stays the default for every
   other repository (Decisions 2 and 10, TASK-SCL-002 and TASK-SCL-010).
2. **The Orchestration Agent may `add` and `approve` loops** on the Product
   Owner's explicit instruction, for example from the phone. Approval is not
   limited to an operator shell (Decision 8, TASK-SCL-003 and TASK-SCL-008).
3. **`max_active_launch_runs` is 2** by default (Decision 6, TASK-SCL-002 and
   TASK-SCL-006).
4. **Launch mode is inspect-and-report only in v1**: no own worktree and no
   commits. Code-changing recurring work goes through the orchestrator
   (Decision 4, TASK-SCL-004).
