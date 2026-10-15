## Purpose

Defines the switchable substrate that supervised sessions run on. It covers:

- backend selection, with tmux as the default and permanent fallback;
- the primitive-only seam that keeps supervision semantics backend-neutral;
- mixed-backend dispatch by record;
- the herdr backend, with its log recorder, process-bound liveness,
  wrapper-safe restore, nudge and send verification, agent status and attach
  rules;
- the Orchestration Agent's tmux pin;
- herdr diagnostics and operator guidance.

## ADDED Requirements

### Requirement: The session backend is selectable with tmux as the default

`scripts/nogg session launch` SHALL run a supervised session on one of two
session backends, `tmux` or `herdr`. The backend SHALL be chosen in this order:
the `--backend` option, then the `session_backend` key in
`.nogging/config.json`, then `tmux`.

- An invalid value SHALL be refused before any worktree, trust, usage
  reservation, session record or backend side effect.
- `herdr`, when the herdr backend or binary is unavailable, SHALL be refused
  under the same rule.
- A launch with neither the option nor the key SHALL behave exactly as before
  this capability existed.
- Every new session record SHALL carry a `backend` field and the backend's own
  reference. A record without a `backend` field SHALL be treated as a tmux
  record.

#### Scenario: Default stays tmux

- **WHEN** `session launch` runs with no `--backend` and no `session_backend` key
- **THEN** the session runs on tmux exactly as before
- **AND** its record carries `backend: tmux`

#### Scenario: Per-launch override

- **WHEN** `session_backend` is `tmux` and `session launch --backend herdr …` runs
- **THEN** that session runs on herdr and its record carries `backend: herdr`

#### Scenario: An unusable backend is refused before side effects

- **WHEN** `session launch --backend herdr` runs and the `herdr` binary is not available
- **THEN** the launch is refused with a message naming the missing backend
- **AND** no worktree, trust entry, reservation, record, log or backend session is created

#### Scenario: A legacy record is tmux

- **WHEN** a session record written before this capability has no `backend` field
- **THEN** every lifecycle operation treats it as a tmux record

### Requirement: Supervision semantics stay above a primitive-only backend seam

A session backend SHALL implement only session primitives: start, send text,
send a normalized key, capture the visible screen, report liveness, list, kill
and attach, plus optional process-ID and agent-status queries and static
capability flags. Log capture SHALL be wired when the session starts.

Session records and their transitions, name generation and collision checks,
locks, the Bead binding, reap and cleanup policy, the stop grace sequence, the
kickoff, nudge and send policy, pane classification, the usage gate and usage
collection SHALL stay backend-neutral above the seam. A backend SHALL NOT
decide a lifecycle state.

Wherever another supervision requirement refers to a session's tmux session,
it SHALL mean the record's backend session — the tmux session for a tmux
record, the labelled herdr pane for a herdr record.

#### Scenario: Stop uses the same policy on both backends

- **WHEN** an operator stops a running session of either backend
- **THEN** Nogging sends an interrupt key, waits the configured grace period, kills the backend session if it is still alive, and records `stopped` with end time and reason

#### Scenario: No direct tmux invocation remains in the CLI

- **WHEN** the CLI source is inspected
- **THEN** every tmux invocation lives in the tmux backend module

### Requirement: The tmux backend preserves existing behaviour

Moving tmux behind the seam SHALL NOT change any observable tmux behaviour.
The following SHALL all stay as before:

- the dedicated socket;
- `new-session` with environment;
- the `pipe-pane` log;
- the `display-message` PID;
- the key sequences, including Claude's double Enter;
- `capture-pane` with and without attributes;
- `kill-session`, and `kill-server` once no session remains;
- `attach` with `-r`.

The pre-existing session test suite SHALL pass unchanged.

#### Scenario: Existing tests stay green

- **WHEN** the seam has been introduced and no herdr session exists
- **THEN** every pre-existing session, orchestrator and nudge test passes with unchanged expectations

### Requirement: Mixed backends coexist and every operation follows the record

Sessions of both backends SHALL run at the same time. `session list`, `reap`,
`stop`, `cleanup`, `attach`, `send`, `nudge`, `kickoff` and `watch` SHALL
resolve the backend from each session's record, never from the current
configuration.

When a backend's tool is unavailable or fails unexpectedly, its records SHALL
be reported with unknown liveness. `reap` and `cleanup` SHALL leave them
untouched and print a note. A tool failure SHALL NOT be treated as proof that a
session ended. `session list` SHALL show each session's backend.

#### Scenario: Changing the configured backend does not strand a session

- **WHEN** a herdr session is running and `session_backend` is changed to `tmux`
- **THEN** `session list`, `session stop` and `session attach` still act on that herdr session through herdr

#### Scenario: A failing backend tool does not reap its sessions

- **WHEN** a herdr record is `running` and the `herdr` CLI fails unexpectedly
- **AND** `session reap` runs
- **THEN** the record keeps its state and a note reports the unknown liveness

### Requirement: herdr sessions run in labelled panes of a dedicated local herdr session

The herdr backend SHALL run each supervised session in its own pane, labelled
with the session name, inside a herdr session namespace dedicated to Nogging
(`session_herdr_session`, default `nogging`). It SHALL reach herdr only through
the local `herdr` CLI (`session_herdr_command`, default `herdr`) over herdr's
local Unix socket.

The pane SHALL run the unchanged Nogging launch wrapper with the same
effective settings, prompt, command floor, OpenSpec boundary and session
environment as on tmux, plus `HERDR_AGENT` naming the agent.

Nogging SHALL NOT:

- open a network listener;
- enable herdr remote access or plugins;
- install herdr or any herdr agent integration;
- enable pane screen history;
- install a service;
- stop or update the herdr server;
- touch panes or herdr sessions it did not launch.

#### Scenario: A herdr launch keeps the authority wrapper

- **WHEN** `session launch --backend herdr --agent codex …` runs
- **THEN** the pane command is the Nogging launch wrapper with the resolved Codex authority level
- **AND** the record is written before the pane process starts

#### Scenario: Cleanup never stops the herdr server

- **WHEN** the last herdr record is retired by `session cleanup`
- **THEN** the herdr server and any non-Nogging pane keep running

### Requirement: herdr sessions keep an append-only bounded log through a PTY recorder

The herdr backend SHALL capture each session's console output to the
record's append-only, size-rotated log. It SHALL do so by running the launch
wrapper under `scripts/session-pty-recorder`. The recorder:

- SHALL use only the Python standard library;
- SHALL forward input and output transparently, including the initial window
  size and every resize;
- SHALL tee output to `scripts/session-log-writer`;
- SHALL pass the child's exit status through;
- SHALL forward termination signals;
- SHALL keep the agent running if logging fails;
- SHALL answer a side-effect-free `--contract` query.

An agent for which the recorder breaks the terminal user interface SHALL be
refused on the herdr backend before any side effect, with a pointer to the tmux
backend.

#### Scenario: herdr output reaches the log

- **WHEN** a herdr session produces console output
- **THEN** that output is appended to the session's log and is readable with `session log` without attaching

#### Scenario: A resized pane resizes the agent

- **WHEN** the herdr pane is resized
- **THEN** the agent running under the recorder receives the new window size

#### Scenario: A logging failure does not kill the agent

- **WHEN** the log writer dies during a session
- **THEN** the agent keeps running and the failure is recorded where possible

### Requirement: herdr liveness is bound to the launched process

A herdr record SHALL be alive only when both of these hold:

- its pane resolves, by recorded pane ID or else by unique label;
- that pane's root process is the recorded session process, by PID and process
  start time.

A herdr server restart, or an update without live handoff, SHALL therefore
reconcile the session to `failed`, exactly like a vanished tmux session. Killing
a herdr session SHALL close its pane. It SHALL terminate the recorded process
group, after re-verifying its start time, when closing the pane does not end
it.

#### Scenario: A server restart fails the session

- **WHEN** the herdr server restarts and restores a pane with the same label but a new process
- **THEN** `session list` reports the record as `failed`
- **AND** `session reap` moves it to `failed` so cleanup can retire it

#### Scenario: A changed pane ID is tolerated

- **WHEN** a live session's pane ID changes but its label and process are unchanged
- **THEN** the session is still reported alive

### Requirement: herdr native restore never starts an agent outside the launch wrapper

Nogging SHALL keep herdr's automatic agent restore disabled for Nogging panes.
A restored Nogging-labelled pane that no live record owns SHALL be reported
and closed by cleanup, and SHALL never be adopted. Resuming a conversation
SHALL go through Nogging's exact resume (`session launch --resume <id>`) on
either backend.

#### Scenario: No unwrapped agent after restart

- **WHEN** the herdr server restarts while a Nogging herdr session was running
- **THEN** no agent process starts in a Nogging pane without the Nogging launch wrapper

### Requirement: Nudge and send verification degrade safely without screen attributes

The nudge and send policy SHALL be identical on both backends. When the
backend's capture keeps SGR attributes, placeholder detection SHALL behave as
on tmux.

When the capture does not keep SGR attributes:

- a Claude prompt box holding text SHALL classify as unknown, never as input
  or placeholder;
- a nudge without `--message` SHALL submit nothing and SHALL ask for
  `--message`.

A `--message` nudge or a `send --verify` SHALL count as submitted when either:

- the backend reports the agent working after the submit, or
- the identifiable prompt box no longer holds the sent text.

Otherwise the submit step SHALL be retried once and the operation SHALL then
fail as unverified.

#### Scenario: A placeholder is never executed without attributes

- **WHEN** a herdr Claude pane shows a suggested placeholder and the capture has no attributes
- **AND** `session nudge` runs without `--message`
- **THEN** nothing is submitted and the operator is told to pass `--message`

#### Scenario: An explicit message is verified by the replacement check

- **WHEN** `session nudge <name> --message "…"` runs on a herdr Claude session without capture attributes
- **AND** herdr reports the agent working after the submit
- **THEN** the nudge is reported as verified

### Requirement: session list reports a live agent status

`session list` SHALL show an `AGENT_STATUS` value for every record. For a live
herdr record the value SHALL be herdr's status — `idle`, `working`, `blocked`,
`done` or `unknown`. It SHALL be `-` for tmux records, terminal records and
backends without the capability.

The status query SHALL be read-only and bounded. A failing query SHALL show
`unknown` and SHALL NOT fail the listing. The status SHALL supplement, not
replace, the per-agent classification used by `watch`, `sweep` and `doctor`.

#### Scenario: Mixed listing

- **WHEN** one tmux and one live herdr session exist and herdr reports the herdr agent `working`
- **THEN** `session list` shows `-` for the tmux session and `working` for the herdr session

### Requirement: herdr attach never silently grants input

`session attach` SHALL attach through the record's backend. For a herdr record
it SHALL attach the herdr client to the dedicated session, focused on the
session's pane.

When herdr offers no read-only client, `session attach --read-only` on a herdr
record SHALL be refused with a pointer to `session log --follow`. It SHALL NOT
attach with input enabled.

#### Scenario: Read-only attach without herdr support

- **WHEN** herdr has no read-only client and an operator runs `session attach <herdr-session> --read-only`
- **THEN** the command refuses and names `session log --follow`

### Requirement: The Orchestration Agent stays on tmux

The Orchestration Agent session SHALL always run on tmux, whatever the
`session_backend` value. `orchestrator run` SHALL launch and adopt only on
tmux. `session launch --role orchestrator --backend herdr` SHALL be refused.

#### Scenario: A herdr default does not move the orchestrator

- **WHEN** `session_backend` is `herdr` and `orchestrator run` starts the orchestrator
- **THEN** the orchestrator session runs on tmux

### Requirement: Usage reservations probe liveness through the record's backend

A usage-admission reservation SHALL store a backend-neutral liveness probe for
its session. A failing probe tool SHALL NOT be treated as proof that the
session ended. Reservations written before this capability SHALL still be
read.

#### Scenario: A herdr reservation stays bound while its pane lives

- **WHEN** a herdr session holds a usage reservation and its pane is alive
- **THEN** the reservation is not released as stale

### Requirement: doctor reports herdr only when herdr is in use

`scripts/nogg doctor` SHALL report herdr diagnostics only when
`session_backend` is `herdr` or a non-retired herdr record exists. Otherwise it
SHALL print nothing about herdr.

When herdr is the configured backend:

- a missing binary or a recorder contract mismatch SHALL be a failure;
- a version outside the verified `0.9.x` range SHALL be a warning;
- server reachability SHALL be a note.

When only herdr records exist, herdr diagnostics SHALL be notes or warnings
only. Whenever herdr diagnostics are shown, doctor SHALL note that
`herdr update` without `--handoff`, or a herdr server restart, ends every
Nogging herdr session.

#### Scenario: Silent when unused

- **WHEN** `session_backend` is absent and no herdr record exists
- **THEN** doctor prints no herdr line

#### Scenario: A configured backend without its binary fails

- **WHEN** `session_backend` is `herdr` and no `herdr` binary is on PATH
- **THEN** doctor reports a failure naming the missing binary

### Requirement: Operators have a herdr setup and operations guide

Nogging SHALL ship `docs/using-with-herdr.md`, marking the herdr backend as
experimental. The guide SHALL describe:

- a user-level install with release-checksum verification;
- backend selection;
- the dedicated herdr session, the log recorder, liveness and restart
  semantics;
- the `herdr update --handoff` warning;
- disabled auto-restore and exact resume;
- the nudge deviation and read-only attach behaviour;
- `agent_status`;
- the security posture: no listener, no plugins, no integrations installed by
  Nogging, screen history off;
- tmux as the fallback.

The session-supervision documentation SHALL describe both backends and SHALL
state that the Orchestration Agent stays on tmux.

#### Scenario: The handoff warning is documented

- **WHEN** an operator reads the herdr guide
- **THEN** it states that `herdr update` without `--handoff` ends every Nogging herdr session
