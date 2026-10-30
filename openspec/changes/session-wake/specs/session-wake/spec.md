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
`stalled`, `ready_for_review` or `planner_finished`. Items SHALL be re-evaluated on
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
