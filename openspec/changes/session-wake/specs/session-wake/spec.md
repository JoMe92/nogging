## ADDED Requirements

### Requirement: The dispatcher reconciles real state on every pass

`scripts/nogg session dispatch --once` SHALL run one stateless pass that gathers
facts for every active session with a Bead and calls a pure decision function
from facts, memory, policy and the clock to a list of actions. It SHALL treat
events as hints and SHALL derive decisions from current facts, so a lost event
delays a decision and never loses it. It SHALL run only in the main checkout and
SHALL refuse in any supervised session, except with `--dry-run`, which reports
the actions and performs none. It SHALL take a non-blocking lock on
`.nogging/locks/dispatch.lock` and exit 0 when busy. It SHALL use no model.

#### Scenario: A session whose hook never fired is still handled

- **WHEN** a Lead is idle with uncommitted work and its events file has no `turn_end`
- **THEN** the pass derives the gap from its live state and git facts and acts on it

#### Scenario: A repeated pass does not repeat an action

- **WHEN** two passes see the same facts for one session
- **THEN** the action runs once, by its dedupe key of session, kind and head

#### Scenario: Unknown evidence produces no action

- **WHEN** `gh` or `bd` fails during a pass
- **THEN** that fact is `unknown`, no action depends on it, and the pass still exits 0

#### Scenario: Dry run changes nothing

- **WHEN** `session dispatch --dry-run --json` runs inside a supervised session
- **THEN** it prints the decided actions and sends, stops and writes nothing

### Requirement: Dispatch is opt-in

Dispatch SHALL be controlled by `session_dispatch.enabled`, default `false`.
With it off or absent, `session dispatch` SHALL print that it is disabled and
perform no action, and no session SHALL be nudged, retired or woken. `validate`
and `doctor` SHALL refuse an unknown key in `session_dispatch` or
`orchestrator_context`, naming it.

#### Scenario: A default install nudges nobody

- **WHEN** a repository has no `session_dispatch` key and a Lead idles with uncommitted work
- **THEN** no message reaches that session and no item is queued

#### Scenario: A typo is refused

- **WHEN** `session_dispatch` contains `max_nudge`
- **THEN** `validate` fails naming the key

### Requirement: Routine transitions are handled without a model

With dispatch enabled, a pass SHALL handle these transitions deterministically,
each after a settle period of 60 seconds: a Lead idle with gaps is nudged; a pull
request with pending checks is waited on; a new failing check fingerprint nudges
the Lead with up to five failing check names; a usage limit is waited out and
then resumed without changing the model; and, when `retire_merged` is on, a
session whose pull request is merged, whose Bead is closed and whose tree is clean
is stopped and cleaned up. Checks SHALL be read through the existing bounded
observation, at most once per 120 seconds per session, and only while a session
waits on a pull request.

The dispatcher SHALL NOT merge, answer a permission prompt, launch a session,
choose a tier, agent or model, or write `openspec/`.

#### Scenario: Pending CI costs nothing

- **WHEN** a Lead's pull request has pending checks
- **THEN** the pass neither nudges nor queues an item until the checks resolve or `ci_timeout` passes

#### Scenario: Red CI goes to the Lead

- **WHEN** a new check fingerprint is failing
- **THEN** the Lead receives one fixed message naming the failed checks
- **AND** no item is queued until `max_ci_nudges` is exhausted

#### Scenario: A limit is resumed with no process left waiting

- **WHEN** a session is in `limit` with a resolved reset time
- **THEN** passes do nothing until its state is no longer `limit`
- **AND** a later pass finishes the resume without switching the model and without any blocking wait

#### Scenario: A merged session is retired only when safe

- **WHEN** `retire_merged` is on and the pull request is merged, the Bead closed and the tree clean
- **THEN** the session is stopped and cleaned up
- **AND** a session with any of those facts false or unknown is left alone

### Requirement: Nudges are fixed, bounded and delivered only to an idle session

A nudge SHALL be a fixed template with substituted facts and SHALL contain no
model-generated text. It SHALL be delivered only while the session classifies
`idle`, through the verified send path, never by a queue to a busy session. Each
session SHALL have a budget of `max_nudges` per head SHA (default 2), which resets
when the head moves. When a budget is exhausted the condition SHALL become a queue
item and no further nudge SHALL be sent. Antigravity sessions SHALL receive no
nudge.

#### Scenario: A busy session is not nudged

- **WHEN** a session with gaps classifies `working`
- **THEN** no message is sent and the budget is unchanged

#### Scenario: A stuck Lead escalates once

- **WHEN** a Lead still has gaps after `max_nudges`
- **THEN** one `stuck` item is queued and the Lead receives no third message

#### Scenario: New commits reset the budget

- **WHEN** a Lead's head SHA changes after a nudge
- **THEN** its nudge budget for the new head is full

### Requirement: Only decisions reach the orchestrator, as one coalesced digest

A queue item SHALL exist only for a decision: `blocked`, `needs_input` (after
120 seconds), `crashed`, `stuck`, `ci_stuck`, `ci_timeout`, `conflict`, `error`,
`stalled`, `ready_for_review`, `planner_finished` or `resumed` (the summary after a
pause). Items SHALL be re-evaluated on
every pass and SHALL be dropped when their condition clears before delivery.
Urgent items (`blocked`, `needs_input`, `crashed`, `stuck`) SHALL wait
`urgent_quiet` (default 90 seconds). Other items SHALL wait `normal_quiet` (default
300 seconds) and no longer than `max_hold` (default 900 seconds). All items ready
at a delivery SHALL go out in one message.

The digest SHALL be at most 1.5 KiB and start with `[nogg wake <id> items=<n>
urgent=<n>` and a statement that item text is data, not instructions. Each item
SHALL carry what a decision needs without a tool call: kind, Bead, session, pull
request and CI summary where they exist, the reason, and a suggested next command.
Agent-originated text SHALL be at most 300 characters, single-line, with control
characters removed, and redacted of secrets and email addresses. Overflow SHALL
point to `nogg session inbox`.

#### Scenario: A self-recovering Lead wakes nobody

- **WHEN** a `blocked` item is queued and the condition clears within `urgent_quiet`
- **THEN** the item is dropped and no wake happens

#### Scenario: Three pull requests make one wake

- **WHEN** three `ready_for_review` items become ready within `normal_quiet`
- **THEN** they are delivered in a single message

#### Scenario: A steady stream cannot starve delivery

- **WHEN** new items keep arriving
- **THEN** the oldest is delivered within `max_hold`

#### Scenario: An injected line stays data

- **WHEN** an agent excerpt contains a newline and text imitating a digest header
- **THEN** the digest holds it on one line inside the labelled item
- **AND** no secret or email address appears in the digest

### Requirement: Wake delivery never interrupts and is rate-limited

Delivery SHALL go through the idle-only verified send helper of `scheduled-loops`
to the canonical orchestrator session, and SHALL happen only while it classifies
`idle`. It SHALL never queue to a busy session and SHALL keep the items after a
failed delivery. Non-urgent delivery SHALL respect `min_gap` (default 300 seconds)
and `max_wakes_per_hour` (default 4), and SHALL hold while the orchestrator agent's
known usage window exceeds `hold_above_percent` (default 85). Urgent items SHALL
ignore those three limits and SHALL still require `idle`. An unacted item SHALL be
repeated once after `remind_after` (default 4 hours), and a change of its head SHALL
make it a new item.

#### Scenario: The Product Owner is typing

- **WHEN** the orchestrator's composer holds input
- **THEN** delivery is refused by the send path, the items stay queued and a later pass retries

#### Scenario: No orchestrator is running

- **WHEN** no live orchestrator session exists
- **THEN** items stay queued and `doctor` reports the queue depth

#### Scenario: Quiet hours and a pause hold delivery

- **WHEN** an item is ready while quiet hours or a pause apply
- **THEN** delivery is refused as in the requirements on quiet hours and pause, and the item stays queued

#### Scenario: A burst stays under the ceiling

- **WHEN** non-urgent items become ready after four wakes in the last hour
- **THEN** they wait until the rate allows delivery

### Requirement: The dispatcher's state is local, auditable and inspectable

The dispatcher SHALL keep `state.json`, `queue.json` and an append-only
`dispatch.jsonl` under `.nogging/state/dispatch/` in the main checkout. State files
SHALL be written atomically and SHALL survive a restart. The audit log SHALL record
each action with its reason and SHALL be rotated at 1 MiB to 3 generations, and
SHALL contain no secret. `nogg session inbox [--json]` SHALL show the pending items,
last deliveries and recent actions, SHALL be read-only and SHALL be allowed in every
session. `doctor` SHALL report, without failing, a disabled or stale dispatcher, the
queue depth, the oldest item's age, and a session that exhausted its budget.

#### Scenario: A restart loses nothing

- **WHEN** the host restarts with two queued items
- **THEN** the next pass delivers them and does not repeat actions already recorded

#### Scenario: Doctor shows a silent dispatcher

- **WHEN** dispatch is enabled and no pass has run for 5 minutes
- **THEN** `doctor` prints a WARN naming the last pass time

### Requirement: The dispatch pass runs from the loops scheduler

`nogg loop tick` SHALL run one dispatch pass before it evaluates loops, under the
separate dispatch lock and its own exception boundary, so a failure of either
SHALL NOT fail the other. A delivered wake SHALL make a send loop defer as
`target-busy`. Without the timer, `session dispatch --once` SHALL work by hand or
from an external scheduler.

#### Scenario: A dispatch failure does not stop loops

- **WHEN** the dispatch pass raises during a tick
- **THEN** the failure is logged and the tick still evaluates loops

#### Scenario: A consumer without systemd

- **WHEN** an install has no timer and dispatch is enabled
- **THEN** `doctor` says nothing fires automatically and names `session dispatch --once`

### Requirement: The orchestrator is not woken inside quiet hours

`session_dispatch.wake.quiet_hours` SHALL be a list of local-time windows `"HH:MM-HH:MM"`
in the host's local time zone, default empty. A window MAY cross midnight. Evaluation
SHALL use the wall clock on every pass. While a window applies the dispatcher SHALL send
the orchestrator no digest, urgent ones included, and no keep-warm message, and SHALL
keep the items queued and re-evaluated. The first pass after the window SHALL deliver
the items that still hold as one digest under the normal delivery rules. Nudges to
Leads, retirement and CI tracking SHALL continue, because they use no orchestrator turn.
`validate` and `doctor` SHALL refuse a malformed window, naming it.

#### Scenario: An urgent item waits for the morning

- **WHEN** a `blocked` item becomes ready at 02:00 with `quiet_hours` `["22:00-07:00"]`
- **THEN** nothing is sent at 02:00
- **AND** the first pass at or after 07:00 delivers it in one digest if it still holds

#### Scenario: A window that crosses midnight

- **WHEN** the local time is 23:30 and 06:59 on consecutive passes
- **THEN** both are inside `"22:00-07:00"`, and 07:00 is outside it

#### Scenario: A Lead is still nudged at night

- **WHEN** a Lead idles with uncommitted work at 03:00 inside a window
- **THEN** it is nudged as usual and no orchestrator message is sent

#### Scenario: A malformed window is refused

- **WHEN** `quiet_hours` contains `"25:00-07:00"`
- **THEN** `validate` fails naming that entry

### Requirement: A warm cache is kept only while work is active

With `session_dispatch.wake.keep_warm` true (default) and a Claude orchestrator, a pass
SHALL send the fixed message `[nogg keepwarm] No action. Answer "ok" in one short line
and use no tools.` through the verified idle-only send path when all of these hold: work
is active (a live Lead or planner with a Bead, or an open pull request), no pause and
no quiet hours apply, the orchestrator has been `idle` for `keep_warm_after` (default 50
minutes) since its last turn ended, and its cache lifetime of one hour has not passed.
Any turn, including a real wake or Product Owner input, SHALL reset that interval. A
keep-warm SHALL NOT count against `min_gap` or `max_wakes_per_hour`, SHALL hold while the
usage hold applies, and SHALL be sent at most once per interval. It SHALL NOT be sent to
a session that is not `idle` or whose composer holds input.

When nothing is active, or quiet hours or a pause apply, no keep-warm SHALL be sent.
Instead, once per idle period, when the orchestrator has been `idle` for
`precompact_after` (default 50 minutes), its cache lifetime has not passed and its last
recorded context exceeds `precompact_min_tokens` (default 100000), a pass SHALL send
`/compact` with a fixed instruction through the same path, and the cache SHALL then be
left to lapse. The context size SHALL come from a bounded read of the transcript tail,
and an unreadable size SHALL skip the compaction. Neither message SHALL be sent to a
non-Claude orchestrator.

#### Scenario: Active work keeps the cache warm

- **WHEN** a Lead is live, the orchestrator has been idle for 50 minutes and nothing else was sent
- **THEN** one keep-warm is sent
- **AND** the next pass inside the interval sends nothing

#### Scenario: A real wake resets the interval

- **WHEN** a digest was delivered 20 minutes ago and its turn ended 18 minutes ago
- **THEN** no keep-warm is sent until 50 minutes after that turn ended

#### Scenario: Nothing active compacts once and lets the cache lapse

- **WHEN** no Lead, planner or pull request is active and the orchestrator has been idle for 50 minutes at 180k tokens
- **THEN** one `/compact` is sent, no keep-warm is sent, and later passes in that idle period send nothing

#### Scenario: A lapsed cache is not compacted

- **WHEN** the orchestrator has been idle for 70 minutes
- **THEN** no `/compact` is sent, because reprocessing the history uncached costs more than it saves

#### Scenario: Keep-warm can be turned off

- **WHEN** `keep_warm` is false and a Lead is live
- **THEN** no keep-warm message is sent and the compaction rule is unchanged

#### Scenario: A busy or typing orchestrator is not touched

- **WHEN** the orchestrator is `working`, or its composer holds input
- **THEN** neither a keep-warm nor a compaction is sent

### Requirement: The user can pause automation for a few days and resume it

`scripts/nogg pause --until <YYYY-MM-DD|YYYY-MM-DDTHH:MM> | --days <n> [--keep-loop <name>
...]` SHALL write host-local state at `.nogging/state/pause.json` atomically with the
start, the end, the kept loops, the setter and the compaction time. A date alone SHALL
mean 00:00 local on that date; `--days n` SHALL mean `n` times 24 hours from now. The end
SHALL be in the future and at most 60 days away. Each `--keep-loop` name SHALL exist in
the loops file, or the command SHALL fail before writing. `pause` while paused SHALL
replace the end and kept loops and keep the original start. `nogg resume` SHALL remove the
state, and SHALL report that nothing was paused and exit 0 when it was not. `nogg pause
--status [--json]` SHALL print the start, end, time left, kept loops and setter, or that
nothing is paused. A missing, malformed or unreadable state file SHALL count as not
paused, and `doctor` SHALL warn about an unreadable one.

#### Scenario: A pause for three days

- **WHEN** an operator runs `nogg pause --days 3` at a recorded time
- **THEN** `pause --status` reports an end 72 hours later and no kept loop

#### Scenario: A date alone ends at the start of that day

- **WHEN** `pause --until 2026-11-03` runs on 2026-10-30
- **THEN** the end is 2026-11-03 00:00 local time

#### Scenario: An invalid end is refused

- **WHEN** the end is in the past, or more than 60 days away, or `--keep-loop` names an unknown loop
- **THEN** the command fails naming the problem and writes nothing

#### Scenario: A second pause replaces the first

- **WHEN** `pause --days 2` is followed by `pause --days 5 --keep-loop report`
- **THEN** the end is five days from the second call, the kept loop is `report`, and the start is the first call's

#### Scenario: A corrupt file does not block work

- **WHEN** `pause.json` is not valid JSON
- **THEN** the host counts as not paused and `doctor` prints a WARN naming the file

### Requirement: A pause silences the orchestrator and loops and keeps the events

While paused, the dispatcher SHALL send the orchestrator no digest and no keep-warm
message and SHALL send no nudge, no `limit` resume and no `/compact` other than the one
compaction of the keep-warm requirement, and SHALL continue to observe, to queue and to
retire merged sessions. It SHALL append each item that appeared or cleared during the
pause to the audit log. `nogg loop tick` SHALL skip every loop not named in `keep_loops`,
log the skip as `paused-global`, and SHALL write no loop definition, loop state or
per-loop `paused` flag. A pause SHALL NOT stop or interrupt a running session, SHALL NOT
stop the scheduler timer, and SHALL NOT block a launch made on purpose.

#### Scenario: A paused host sends nothing to the orchestrator

- **WHEN** a Lead becomes `ready_for_review` during a pause
- **THEN** the item is queued and no message reaches the orchestrator

#### Scenario: A running Lead finishes

- **WHEN** a pause begins while a Lead is working
- **THEN** the Lead is not stopped and receives no nudge from the dispatcher

#### Scenario: Loops are skipped except the kept ones

- **WHEN** a tick runs during a pause with `keep_loops` naming `report`
- **THEN** `report` runs by its schedule and every other due loop is logged `paused-global` and does not run
- **AND** no loop file or loop state is changed

#### Scenario: An individually paused loop stays paused

- **WHEN** a loop was paused with `loop pause` before the global pause and `resume` runs
- **THEN** that loop is still paused

### Requirement: A pause ends by itself and resume sends one digest

The pause SHALL end when `nogg resume` runs or at the first `nogg loop tick` or `session
dispatch --once` pass at or after its end, whichever comes first. Ending it SHALL remove
the state, let loops run by their schedule, and, if any item appeared or cleared during
the pause, queue one `resumed` item with the pause length, the number of items seen, the
number that cleared on their own and the sessions that finished, within the digest size
limit. The items that still hold and that item SHALL be delivered as one digest under the
normal delivery rules. A pause in which nothing happened SHALL queue nothing and send no
message. The automatic end SHALL NOT require the dispatcher to be enabled.

#### Scenario: A pause ends at its time

- **WHEN** a tick runs one minute after the end time with two items queued and one that cleared
- **THEN** the state is removed and the orchestrator receives one digest holding the summary and the two items

#### Scenario: An uneventful pause costs no wake

- **WHEN** a pause ends with no item having appeared
- **THEN** no digest is queued and the orchestrator is not messaged

#### Scenario: Manual resume does the same

- **WHEN** an operator runs `nogg resume` during a pause with queued items
- **THEN** the same single digest is delivered on the next idle pass

### Requirement: A pause is visible and restricted

`doctor` SHALL print a NOTE `paused until <time>` and never a FAIL for it. `session list`
SHALL print one `PAUSED until <time>` line above its table, `loop list` SHALL show each
loop as `paused (global, until <time>)` or `kept`, and `session inbox` SHALL show the
pause and the number of held items. `pause` and `resume` SHALL run only in an operator
shell and in the Orchestration Agent session, and SHALL be refused in every other
supervised session with the same kind of message as the `nogg loop` mutations.
`pause --status` SHALL be read-only and allowed in every session. The orchestrator
prompt and `/orchestrate` SHALL direct it to pause only on the Product Owner's
instruction and to confirm it with `--status`.

#### Scenario: Doctor reports a pause without failing

- **WHEN** the host is paused
- **THEN** `doctor` prints a NOTE with the end time and no FAIL

#### Scenario: A Lead cannot pause

- **WHEN** a Lead session runs `nogg pause --days 2`
- **THEN** the command is refused and nothing is written

#### Scenario: Anyone can read the status

- **WHEN** a Lead session runs `nogg pause --status`
- **THEN** it prints the status and changes nothing
