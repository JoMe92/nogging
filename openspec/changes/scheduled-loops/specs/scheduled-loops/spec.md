## ADDED Requirements

### Requirement: Loops are defined in one versioned file with an explicit timezone

Nogging SHALL read scheduled loop definitions from one JSON file, by default
`.nogging/loops.json`, relocatable through the repository-relative config key
`loops_file`. The file SHALL carry `schema_version: 1`, a required IANA
`timezone`, an optional `scheduler` object (`max_active_launch_runs`, default 2;
`suspend_after_failures`, default 3) and a `loops` object keyed by loop name.
Loop names SHALL be kebab-case, at most 40 characters and unique; a duplicate
JSON key SHALL be an error. Each loop SHALL have a `schedule` and a `run` object
and MAY set `enabled` (default `true`), `host` and `usage`. Unknown keys
at any level SHALL be refused. A missing file SHALL mean no loops. Runtime state
SHALL live only under `.nogging/state/loops/` in the main checkout and SHALL NOT
be written into the definitions file. Persisted timestamps SHALL be UTC.

#### Scenario: A valid file loads

- **WHEN** `.nogging/loops.json` declares `timezone: "Europe/Berlin"` and two well-formed loops
- **THEN** both loops load with their defaults filled and no state is written into the file

#### Scenario: A missing timezone is refused

- **WHEN** the file has no `timezone`, or names one that is not a valid IANA zone
- **THEN** loading fails naming the key and no loop is evaluated

#### Scenario: Unknown keys and duplicate names are refused

- **WHEN** a loop carries an unsupported key, or two loops share one name through a duplicate JSON key
- **THEN** loading fails naming the loop and the key

#### Scenario: The file can be moved out of Git

- **WHEN** `.nogging/config.json` sets `loops_file` to `.nogging/state/loops.json`
- **THEN** loops are read from that path and its prompts from the `loops/` directory beside it, and neither is tracked by Git

#### Scenario: The shipped default stays tracked

- **WHEN** a repository's configuration does not set `loops_file`
- **THEN** loops are read from `.nogging/loops.json` and prompts from `.nogging/loops/`

### Requirement: Loop prompts are files that carry no secret or email address

Each loop's prompt SHALL be the file `loops/<name>.md` in the directory of the
definitions file. When that directory is `.nogging/state/`, the prompts SHALL
share `.nogging/state/loops/` with the runtime files, whose fixed names never
end in `.md`, and removing a loop SHALL delete only its own prompt file. A
prompt SHALL be non-empty UTF-8 without NUL bytes and at most
16 KiB. Validation SHALL reject a prompt that contains an email address, the
value of a set secret-named environment variable, a secret assignment of the
form recognized by the session redactor, a GitHub, Anthropic, OpenAI-style, AWS
or Slack token shape, or a PEM private-key header. A rejection SHALL name the
file, line and rule and SHALL NOT print the matched text.

#### Scenario: A prompt with a token is rejected without echoing it

- **WHEN** a prompt file contains a string shaped like a GitHub personal access token
- **THEN** validation fails naming the file, the line and the token rule, and the output does not contain the token

#### Scenario: A prompt with an email address is rejected

- **WHEN** a prompt file contains an email address
- **THEN** validation fails naming the file and line

#### Scenario: A missing prompt file is an error

- **WHEN** a loop is defined but `loops/<name>.md` does not exist
- **THEN** validation fails naming the expected path

### Requirement: Schedules support intervals, daily times, weekdays and time windows

A schedule SHALL have exactly one of `every` or `at`, and MAY have `start`,
`days`, `windows` and `grace`, all in the file's timezone. `every` SHALL accept
`<n>m` or `<n>h` from 5 minutes to under 24 hours in whole minutes, repeating
within each local day from the anchor time of day (`start: "HH:MM"`, default
`00:00`) and restarting at the anchor each day, and `<n>d` or `<n>w`, firing
every n days (or 7n) at the anchor time, where `start` SHALL be a full local
datetime when n exceeds one day. `at` SHALL list daily `HH:MM` times. `windows`
SHALL list `HH:MM-HH:MM` ranges, start inclusive and end exclusive, possibly
crossing midnight, and a slot SHALL be kept only inside one. `days` SHALL filter
by local weekday, taken for a slot inside a midnight-crossing window from the
date that window opened. A slot falling in a skipped daylight-saving hour SHALL
fire at the first instant after the gap. A slot in a repeated hour SHALL fire
once, at its first occurrence. A slot's deadline SHALL be the earliest of
slot + `grace` (default half the interval up to 30 minutes for `every`,
30 minutes for `at`, minimum 1 minute), the next slot and the end of its window.

#### Scenario: A night window every 30 minutes

- **WHEN** a loop has `every: "30m"` and `windows: ["22:00-07:00"]` in Europe/Berlin
- **THEN** its slots are 22:00, 22:30 through 06:30 local time each night, and none falls between 07:00 and 22:00

#### Scenario: The orchestrator's current schedule

- **WHEN** a loop has `every: "5h"` and `start: "02:07"`
- **THEN** its daily slots are 02:07, 07:07, 12:07, 17:07 and 22:07 local time

#### Scenario: Every five days from an explicit anchor

- **WHEN** a loop has `every: "5d"` and `start: "2026-10-28T03:00"`
- **THEN** its slots are 03:00 local time on 2026-10-28, 2026-11-02, 2026-11-07, and so on, on every host

#### Scenario: A multi-day interval without an anchor date is refused

- **WHEN** a loop has `every: "5d"` and no `start` date
- **THEN** validation fails naming the loop and the `start` key

#### Scenario: Weekdays follow the window's opening date

- **WHEN** a loop has `days: ["fri"]` and `windows: ["22:00-07:00"]`
- **THEN** a slot at 01:00 on Saturday is kept, and a slot at 01:00 on Friday is not

#### Scenario: Daylight-saving transitions

- **WHEN** a daily slot at 02:30 Europe/Berlin falls on 2027-03-28 and on 2026-10-25
- **THEN** it fires once at 03:00 local time on 2027-03-28 and once at the first 02:30 on 2026-10-25

### Requirement: A send loop delivers only to an idle Orchestration Agent

A loop with `run.mode: "send"` SHALL name `target: "orchestrator"` and no agent,
tier or authority, and MAY set `max_runtime` (default 1 hour, 5 minutes to
12 hours). The target SHALL resolve the canonical orchestrator session
of the main checkout, whatever runtime it uses. A run SHALL send one message,
the header line `[nogg loop <name> run <run-id>]` followed by the prompt,
through the verified `session send` path under its delivery lock, and only when
the target's classified state is `idle`. A target that is `working`,
`needs_input`, in a `limit`, `unknown` or not live SHALL defer the slot. The
scheduler SHALL NOT queue a message to a busy session, start or restart the
orchestrator, or stop it.

#### Scenario: Idle orchestrator receives the run

- **WHEN** a send loop's slot is admitted and the orchestrator is idle
- **THEN** the header and prompt are submitted with verification and the run is logged `delivered`

#### Scenario: Busy orchestrator defers without queueing

- **WHEN** the orchestrator is `working` at the slot
- **THEN** nothing is typed or queued, the run is deferred with `target-busy`, and it is delivered on a later tick once the orchestrator is idle before the deadline

#### Scenario: No orchestrator

- **WHEN** no live orchestrator session exists until the deadline
- **THEN** the slot is logged `skipped` with `target-not-running` and no session is launched

### Requirement: A launch loop runs a fresh, bounded loop session

A loop with `run.mode: "launch"` SHALL start one supervised session per run
through the internal `session launch` path, with role `loop`. That role SHALL
have no Bead, a record carrying `loop_name` and `loop_run_id`, the name
`sf-loop-<name>-<nonce>` from the safe-name helper, and the main checkout as
working directory. The loop SHALL name `agent` and `tier`, and MAY name `model`,
`effort`, `authority` (`restricted` by default, or `trusted`) and `max_runtime`
(default 1 hour, 5 minutes to 12 hours). The session SHALL use the launch prompt
`loop`. Its kickoff SHALL be the header line plus the prompt. A run SHALL be
complete when the session is `idle` on two consecutive ticks after kickoff, and
the scheduler SHALL then stop and retire that session and record the archived
log path. A run whose kickoff is refused SHALL stop and retire its session.
`session launch --role loop` given on the command line SHALL be refused with a
pointer to `nogg loop run-now`.

#### Scenario: A routine Codex loop runs and is retired

- **WHEN** a launch loop with `agent: "codex"` and `tier: "routine"` is admitted
- **THEN** a `loop:<name>` session starts with the routine tier's model and effort, receives the prompt as kickoff, is logged `started`, and after its turn ends is stopped, retired and logged `completed`

#### Scenario: A refused kickoff leaves no session

- **WHEN** the launched session never shows a ready composer before the kickoff deadline
- **THEN** that session is stopped and retired and the attempt is logged as a transient failure

#### Scenario: The role is not a public launch role

- **WHEN** an operator runs `nogg session launch --role loop`
- **THEN** the launch is refused before any side effect and names `nogg loop run-now`

### Requirement: A loop run never exceeds the authority its loop configures

A `loop` session SHALL always have the command floor unioned in and `openspec/`
fenced read-only, whatever profile it uses. It SHALL use the `restricted`
authority level unless its loop sets `authority: "trusted"`. A loop SHALL NOT
select the `orchestrator` profile, the `autonomous` or `orchestrator` prompt, or
`--ignore-usage-gate`. The scheduler SHALL never raise a run's authority,
including on retry. `session list` SHALL show the run's role as `loop:<name>`
and its profile.

#### Scenario: Default authority is restricted

- **WHEN** a launch loop sets no `authority`
- **THEN** its session runs under the `restricted` level for its agent with the floor and the `openspec/` fence

#### Scenario: Trusted only when explicit

- **WHEN** a launch loop sets `authority: "trusted"`
- **THEN** its session runs under `trusted` with the floor and the fence, and `session list` shows the profile

#### Scenario: The orchestrator profile is refused

- **WHEN** a loop definition tries to select the `orchestrator` profile or prompt
- **THEN** validation fails and the loop never runs

### Requirement: One minutely tick schedules every loop from the main checkout

`nogg loop tick` SHALL evaluate every loop once. It SHALL run only in the
repository's main checkout and refuse in a linked worktree. It SHALL refuse
inside any supervised session. It SHALL hold a non-blocking exclusive lock on
`.nogging/locks/loops.lock`. A tick that cannot take the lock SHALL print that
another tick is running and exit 0. Each pass SHALL record `last_tick`. The
installed scheduler SHALL be one systemd user timer firing every minute with no
systemd catch-up, so that adding, editing or pausing a loop needs no `systemctl`
call. Without that timer nothing SHALL fire automatically, and `loop tick` and
`loop run-now` SHALL still work when invoked by hand or by an external scheduler.

#### Scenario: Two ticks overlap

- **WHEN** a tick runs while another holds the loop lock
- **THEN** it exits 0 with the busy message and evaluates nothing

#### Scenario: A tick from a linked worktree

- **WHEN** `nogg loop tick` runs in a linked worktree
- **THEN** it refuses and names the main checkout

#### Scenario: Durable across reboot and orchestrator restart

- **WHEN** the host reboots or the orchestrator restarts between two slots
- **THEN** the next slot is still evaluated from the definitions file and state on disk, with no prior registration in any agent session

### Requirement: In multi-machine mode a loop runs only on its assigned host

When `multi_machine` is `true`, every enabled loop SHALL name a `host`, and
validation SHALL fail otherwise. A tick on a host whose name differs from a
loop's `host` SHALL neither evaluate nor log that loop. With `multi_machine`
`false`, `host` SHALL be optional and SHALL still restrict the loop when set.

#### Scenario: Another host ignores the loop

- **WHEN** a loop names `host: "pi-a"` and the tick runs on `pi-b`
- **THEN** that loop is not evaluated and `nogg loop list` on `pi-b` shows it as `other-host`

#### Scenario: Multi-machine without a host is invalid

- **WHEN** `multi_machine` is `true` and an enabled loop has no `host`
- **THEN** validation fails naming the loop

### Requirement: A loop never overlaps itself and a deferred slot ends at its deadline

A slot whose loop still has an active run SHALL be deferred with
`previous-run-active`. A launch slot that would exceed `max_active_launch_runs`
active launch runs SHALL be deferred with `active-run-limit`. A deferred slot
SHALL be retried on each tick until its deadline and then logged `skipped`
with its last deferral reason. A deferral SHALL be logged when its reason
changes, not on every tick. At most one run per loop SHALL start per tick.

#### Scenario: The previous run is still working

- **WHEN** a slot is due while the loop's previous run has not completed
- **THEN** no second run starts, and the slot is logged `skipped` with `previous-run-active` at its deadline if the previous run is still active then

#### Scenario: The window end caps a deferral

- **WHEN** a slot at 06:50 in a `22:00-07:00` window is deferred
- **THEN** it is never started at or after 07:00

### Requirement: Missed slots never cause a catch-up storm

A tick SHALL consider only the latest due slot since the loop's last
evaluation, and only before that slot's deadline. Older due slots SHALL be
logged as one `missed` event with their count, first and last slot. A latest
slot past its deadline SHALL also be logged `missed`. A newly added or approved
loop SHALL NOT fire for slots before its approval time.

#### Scenario: Six hours of downtime

- **WHEN** a 30-minute loop's host was down from 22:00 to 04:10 inside its window
- **THEN** one `missed` event covers the earlier slots and only the 04:00 slot may start, within its deadline

#### Scenario: A new loop does not fire for the past

- **WHEN** a loop is added at 14:05 with `at: ["14:00"]`
- **THEN** it first fires at 14:00 the next day

### Requirement: Failed starts retry with bounded backoff and repeated failures suspend the loop

A transient start failure SHALL be retried after 2, 4 and 8 minutes, at most
3 attempts per slot, and never past the slot's deadline. Transient failures
are a missing agent binary, an unavailable tmux server, a delivery or kickoff
timeout, and a refused kickoff. A permanent failure SHALL NOT be retried:
invalid configuration, a refused authority or an unknown agent. A slot that
ends `failed` or `stopped-stale` SHALL increment the loop's consecutive-failure
count. An `unconfirmed` send run SHALL NOT count as a failure.
A `completed` run SHALL reset it. At `suspend_after_failures` the loop SHALL be
paused with reason `suspended` until `nogg loop resume`.

#### Scenario: The agent CLI is updating

- **WHEN** a launch is refused because the agent binary is not on PATH
- **THEN** the run is logged `retry-scheduled` and tried again after 2 minutes, before the deadline

#### Scenario: Three failed slots in a row

- **WHEN** three consecutive slots of a loop end `failed` with the default limit
- **THEN** the loop is logged `suspended`, later slots are skipped as `suspended`, and `doctor` warns

### Requirement: Stale runs are detected and only the loop's own sessions are stopped

A run active longer than its `max_runtime` SHALL be logged `stale`. A stale
launch run SHALL have its own session stopped and retired and be logged
`stopped-stale`. A stale send run SHALL be logged `unconfirmed`, and the target
SHALL NOT be stopped. A `starting` run with no session and no delivery after
10 minutes SHALL be reconciled: the tick adopts a live session carrying its
`loop_run_id`, or logs `failed` with `start interrupted`. A launched session
that ends on its own before completion SHALL be logged `failed`.

#### Scenario: A hung launch run

- **WHEN** a launch run's session is still `working` after `max_runtime`
- **THEN** that session is stopped and retired and the run is logged `stopped-stale`

#### Scenario: A long orchestrator turn

- **WHEN** the orchestrator is still working on a delivered run after `max_runtime`
- **THEN** the run is logged `unconfirmed` and the orchestrator keeps running

### Requirement: Every run passes usage admission and quota never lowers a tier

Before every start, the scheduler SHALL observe the run's agent usage windows:
the loop's agent for launch, the target session's agent for send. It SHALL skip
the run with a logged reason naming the window, its used percent, the cap and
the reset time when the usage-gate cap would be exceeded. It SHALL also skip the
run when a known window exceeds the loop's optional `usage.max_used_percent`,
which SHALL be stricter than the cap or equal to it. Unknown usage SHALL follow
`usage.on_unknown`, defaulting to the global `usage_gate.on_unknown`, and a
warn admission SHALL be recorded on the run. This check SHALL apply to send runs
although the orchestrator role is excluded from launch admission. Launch runs
SHALL also pass the normal launch admission and reservation, where `loop` SHALL
be a gated role by default. The scheduler SHALL NOT pass `--ignore-usage-gate`,
lower the tier, change the model or agent, or retry a denied slot.

#### Scenario: A night loop near the weekly limit

- **WHEN** the orchestrator's agent weekly window is at 91 % and a send loop sets `max_used_percent: 70`
- **THEN** the run is logged `skipped` with the window, 91 %, the limit and its reset time, and nothing is sent

#### Scenario: A denied launch keeps its tier

- **WHEN** a `complex` launch loop is denied by the gate
- **THEN** no session starts with any other tier, model or agent, and the slot is logged `skipped`

### Requirement: A loop runs only while its exact definition is approved on the host

The scheduler SHALL run a loop only when the host-local approval ledger
`.nogging/state/loops/approvals.json` holds the SHA-256 of the canonical JSON
of the file's timezone, that loop's normalized definition and its prompt
bytes. The ledger entry SHALL record the approval time and the OS user name,
never an email address. `nogg loop add` SHALL approve what it writes.
`nogg loop approve <name>` SHALL display the schedule, mode, target or agent,
tier, authority and prompt hash before recording the approval. Any change to
the definition or prompt, including one merged from `develop`, SHALL make the
loop `unapproved` until approved again.

#### Scenario: A merged edit does not take effect unseen

- **WHEN** a merge changes a loop's prompt file in the main checkout
- **THEN** the loop is shown `unapproved`, its slots are logged `skipped` with `unapproved`, and `doctor` warns until `nogg loop approve` is run

#### Scenario: Approval shows the authority

- **WHEN** an operator runs `nogg loop approve dependency-check`
- **THEN** the output names its launch mode, agent, tier, `trusted` authority and prompt hash before recording the approval

### Requirement: Loop management is refused inside other supervised sessions

`nogg loop add`, `approve`, `remove`, `pause`, `resume`, `run-now` and `tick`
SHALL be refused when process ancestry proves the caller runs inside a
supervised session other than the Orchestration Agent. A loop-run session
counts as such a session. `tick` SHALL be refused inside every supervised
session, including the orchestrator. `list`, `show` and `log` SHALL be
read-only and allowed everywhere.

#### Scenario: A Lead cannot add a loop

- **WHEN** a `lead` session runs `nogg loop add`
- **THEN** the command is refused before writing any file

#### Scenario: The orchestrator manages loops

- **WHEN** the Orchestration Agent runs `nogg loop pause night-work`
- **THEN** the loop is paused and the change is logged

#### Scenario: The orchestrator adds and approves on the Product Owner's instruction

- **WHEN** the Product Owner instructs the Orchestration Agent from the phone to add a loop and it runs `nogg loop add` and later `nogg loop approve` for that loop
- **THEN** both commands succeed and the approval records the OS user name and no email address

### Requirement: The loop CLI lists, shows, logs and controls loops

Nogging SHALL provide `nogg loop add`, `list`, `show`, `log`, `pause`,
`resume`, `run-now`, `approve`, `remove` and `tick`. `add` SHALL accept the
schedule, run and usage fields as options plus `--prompt-file` or `--prompt`.
On first use it SHALL write the host timezone into a new file and print it. It
SHALL refuse an existing name and print that the files need committing. `remove`
SHALL delete the definition and its prompt file and keep the run log. `pause`
and `resume` SHALL change host-local state only. `run-now` SHALL run one manual
slot through every admission check except the schedule and window, report a
skip reason instead of deferring, and log `trigger: manual`. `list` SHALL show
each loop's name, state (`enabled`, `disabled`, `paused`, `suspended`,
`unapproved` or `other-host`), schedule, mode and target or agent, tier and
authority, next slot in local time and UTC, and last outcome. `show` SHALL add
the definition, the approval state, the next five slots and the active run.
`log <name>` SHALL print the run history newest first, with `--limit`.
`list --json` and `log --json` SHALL emit versioned JSON as a documented read
contract.

#### Scenario: Next slots in both clocks

- **WHEN** an operator runs `nogg loop show night-work`
- **THEN** the next five slots are printed in Europe/Berlin time and in UTC

#### Scenario: Run now while busy

- **WHEN** `nogg loop run-now orchestrator-issues` runs while the orchestrator is working
- **THEN** it reports `skipped: target-busy`, sends nothing and logs a manual skip

### Requirement: Every run outcome is logged in a versioned run log

The scheduler SHALL append one JSON object per event to
`.nogging/state/loops/runs.jsonl` with `schema_version: 1`, `at`, `loop`,
`run_id` (`<name>-<slot as compact UTC>`), `slot`, `trigger`
(`scheduled` or `manual`), `event`, and when known `reason`, `mode`, `target`,
`session`, `agent`, `tier`, `attempt`, `usage` and `log_path`. Events SHALL be
`missed`, `deferred`, `skipped`, `starting`, `delivered`, `started`,
`retry-scheduled`, `completed`, `failed`, `stale`, `stopped-stale`,
`unconfirmed` and `suspended`. A `starting` event SHALL be written before any
start side effect. The log SHALL be size-rotated at 1 MiB, keeping 3
generations. It SHALL contain no prompt text and no secret.

#### Scenario: A skipped run is explained

- **WHEN** a slot is skipped by the usage gate
- **THEN** `nogg loop log <name>` shows the slot, `skipped` and the gate reason with its reset time

#### Scenario: The log never holds the prompt

- **WHEN** any run is logged
- **THEN** no event contains the prompt text

### Requirement: Validation and doctor report loop health

`nogg validate` and `doctor` SHALL fail on an invalid definitions file or
prompt. `doctor` SHALL warn on an enabled loop that is unapproved, suspended or
has a stale run. It SHALL warn on a scheduler timer that is enabled while
`last_tick` is older than 5 minutes. It SHALL print a note, never a failure,
when enabled loops exist but the scheduler timer is not installed or not
enabled, saying that those loops will not run.

#### Scenario: No scheduler installed

- **WHEN** an install made with `--no-systemd` has an enabled, approved loop
- **THEN** `doctor` notes that the loop will not run without the timer or a manual `nogg loop tick`, and does not fail

#### Scenario: A stalled scheduler

- **WHEN** the timer is enabled but no tick has run for 10 minutes
- **THEN** `doctor` warns with the age of the last tick
