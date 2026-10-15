## Purpose

Defines the switchable substrate that supervised sessions run on. It covers:

- backend selection, with tmux as the default and permanent fallback;
- the primitive-only seam that keeps supervision semantics backend-neutral;
- mixed-backend dispatch by record;
- the herdr backend, with its CLI-plus-one-socket-method transport, log
  recorder, process-bound liveness, wrapper-safe restore, nudge and send
  verification, agent status and attach rules;
- test doubles that reproduce only verified herdr interfaces;
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
(`session_herdr_session`, default `nogging`). Nogging SHALL start and own the
dedicated headless herdr server and supply its own config using
`HERDR_CONFIG_PATH`. That config SHALL set
`[session] resume_agents_on_restore = false` and disable
`[update] version_check` and `manifest_check`. The server SHALL start with a
scrubbed environment so inherited variables such as `CLAUDECODE`, `TMUX` and
tokens do not leak into panes. Its Unix socket path SHALL be shorter than 108
bytes; launch SHALL fail with a clear diagnostic if it cannot fit. Nogging
SHALL reach that server only as the herdr transport requirement allows: the
local `herdr` CLI (`session_herdr_command`, default `herdr`), plus the single
local-socket pane-creation call.

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

#### Scenario: Dedicated server configuration prevents unwrapped restore

- **WHEN** Nogging starts its dedicated herdr server
- **THEN** it passes its own config through `HERDR_CONFIG_PATH`
- **AND** automatic agent restore, version checks and manifest checks are disabled
- **AND** the server starts with a scrubbed environment and a socket path under 108 bytes

### Requirement: Nogging reaches herdr through its CLI plus one local-socket method

Nogging SHALL reach herdr through the local `herdr` CLI for every operation
that has a verified CLI form. herdr 0.9.x has no CLI form that starts a pane
with a given argv, so pane creation is the single exception. The herdr backend
SHALL create each session pane with the socket method `layout.apply`, sent
directly to the Unix socket of the dedicated herdr server that Nogging
started. It SHALL use no other socket method. Adding a method SHALL need a
planning revision that names the method and shows it has no verified CLI
form.

Before it connects, Nogging SHALL:

- take the socket path from herdr's own report for the dedicated session
  (`herdr session list --json`, field `socket_path`), never from an inherited
  `HERDR_SOCKET_PATH` or other environment variable;
- check that the path is shorter than 108 bytes;
- check that the path is a Unix socket and not a symlink;
- check that the socket is owned by the invoking user and has mode 0600, with
  no group or other permission bits.

A failed check SHALL refuse the launch with a diagnostic that names the check.
The refusal SHALL happen before any session record or pane is created.

The connection SHALL be a local `AF_UNIX` stream connection made with the
Python standard library. It SHALL carry one request line and read one reply
line under a bounded timeout. Nogging SHALL NOT:

- open a TCP or other network connection to herdr;
- use herdr `--remote` or `--machine`;
- forward or relocate the socket, or widen its permissions;
- write the request unredacted to a session record or log.

An error reply, for example `workspace_not_found`, SHALL fail the launch and
name herdr's error code. If the reply is missing or malformed, the backend
SHALL resolve the pane by its unique label through the CLI. It SHALL NOT send
a second `layout.apply` for the same session.

#### Scenario: Pane creation uses the local socket and everything else the CLI

- **WHEN** `session launch --backend herdr` creates a session
- **THEN** one `layout.apply` request on the dedicated server's Unix socket creates the pane with the recorder-wrapped argv, working directory, label and session environment
- **AND** every other herdr operation of that launch and of later lifecycle commands uses the `herdr` CLI

#### Scenario: An unsafe socket refuses the launch

- **WHEN** the dedicated session's socket has group or other permission bits, is not owned by the invoking user, is a symlink, or has a path of 108 bytes or more
- **THEN** the launch is refused with a diagnostic that names the failed check
- **AND** no session record and no pane is created

#### Scenario: An inherited socket variable is ignored

- **WHEN** Nogging runs inside a herdr pane whose `HERDR_SOCKET_PATH` names another herdr session
- **THEN** the launch targets the socket that `herdr session list --json` reports for `session_herdr_session`

#### Scenario: A lost reply never creates a second pane

- **WHEN** the `layout.apply` connection closes before a reply arrives
- **THEN** the backend looks the pane up by its label through the CLI
- **AND** no second `layout.apply` is sent for that session

### Requirement: herdr tests exercise only verified herdr interfaces

The fake herdr used by Nogging's test suites SHALL implement only:

- the CLI forms in the committed spike help and fixtures for herdr 0.9.5;
- the socket methods that the herdr transport requirement allows.

Any other CLI form SHALL fail the way herdr fails on a CLI syntax error:
plain usage on stderr and exit status 2. Any other socket method SHALL get an
error reply.

The fake SHALL serve `layout.apply` over a real local Unix socket with mode
0600, at the path its `session list --json` reports. The reply SHALL have the
spike fixture's shape, and a pane it creates SHALL be visible to the fake's
CLI forms. Test-only controls, such as seeding, a simulated restart and fault
injection, SHALL stay outside herdr's command surface.

#### Scenario: A synthetic CLI form fails

- **WHEN** a test calls `herdr layout apply`, `herdr pane create` or `herdr pane split --command …` on the fake
- **THEN** the call exits with status 2 and prints usage on stderr, as the real CLI does

#### Scenario: A socket-created pane is visible through the CLI

- **WHEN** a test sends `layout.apply` to the fake's socket
- **THEN** the reply matches the shape of the spike's `layout-apply.json`
- **AND** `herdr pane list` and `herdr pane process-info` report the new pane

### Requirement: herdr sessions keep an append-only bounded log through a PTY recorder

The herdr backend SHALL capture each session's console output to the
record's append-only, size-rotated log. It SHALL do so by running the launch
wrapper under `scripts/session-pty-recorder`. The recorder:

- SHALL use only the Python standard library;
- SHALL forward input and output transparently, including the initial window
  size and every resize;
- SHALL tee output to `scripts/session-log-writer`;
- SHALL start the log writer in a separate session/process group so pane-close
  SIGHUP and subsequent SIGKILL cannot terminate it with the recorder before
  it flushes buffered output;
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

A herdr server restart SHALL therefore reconcile the session to `failed`,
exactly like a vanished tmux session. On herdr v0.9.5, plain `herdr update`
keeps endpoint-generation-1 servers and their panes running; the one-time
pre-generation-1 upgrade is the exception. Killing a herdr session SHALL
close its pane. It SHALL terminate the recorded process group, after
re-verifying its start time, when closing the pane does not end it.

#### Scenario: A server restart fails the session

- **WHEN** the herdr server restarts and restores a pane with the same label but a new process
- **THEN** `session list` reports the record as `failed`
- **AND** `session reap` moves it to `failed` so cleanup can retire it

#### Scenario: A changed pane ID is tolerated

- **WHEN** a live session's pane ID changes but its label and process are unchanged
- **THEN** the session is still reported alive

### Requirement: herdr native restore never starts an agent outside the launch wrapper

Nogging SHALL set herdr's server-level `resume_agents_on_restore = false` in
its own config passed through `HERDR_CONFIG_PATH`; herdr provides no per-pane
switch. A globally installed herdr integration may still report session
references inside Nogging panes because the `HERDR_*` environment passes
through the wrapper, so this server-level setting is required even though
Nogging never reports references itself.
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
A herdr server restart ends every Nogging herdr session. On herdr v0.9.5, plain
`herdr update` keeps endpoint-generation-1 servers and their panes running;
only a server restart (apart from the one-time pre-generation-1 upgrade) ends
those sessions.

#### Scenario: Silent when unused

- **WHEN** `session_backend` is absent and no herdr record exists
- **THEN** doctor prints no herdr line

#### Scenario: A configured backend without its binary fails

- **WHEN** `session_backend` is `herdr` and no `herdr` binary is on PATH
- **THEN** doctor reports a failure naming the missing binary

#### Scenario: Update note reflects v0.9.5 behavior

- **WHEN** doctor shows herdr diagnostics for herdr v0.9.5
- **THEN** its note says a server restart ends the sessions
- **AND** it does not claim that plain `herdr update` ends endpoint-generation-1 sessions

### Requirement: Codex launch flags match the installed CLI

`scripts/session-launch` SHALL omit `--add-dir <repo-root>` when launching
Codex with read-only permissions, because the effective permissions do not
allow adding writable roots. Before passing `--ask-for-approval`, it SHALL
validate the configured value against the values accepted by the installed
Codex CLI version. An unsupported value SHALL be rejected with a clear
preflight diagnostic before the agent starts.

#### Scenario: Read-only Codex launch omits additional writable roots

- **WHEN** a Codex session launches with read-only permissions
- **THEN** its command omits `--add-dir`

#### Scenario: Approval setting follows installed Codex values

- **WHEN** the configured `ask_for_approval` value is accepted by the
  installed Codex CLI
- **THEN** the launcher passes it through
- **WHEN** that value is not accepted
- **THEN** preflight fails clearly without starting the agent

### Requirement: Operators have a herdr setup and operations guide

Nogging SHALL ship `docs/using-with-herdr.md`, marking the herdr backend as
experimental. The guide SHALL describe:

- a user-level install with release-checksum verification;
- backend selection;
- the dedicated herdr session, the log recorder, liveness and restart
  semantics;
- the effects of `herdr update` and server restart (plain update in v0.9.5
  keeps endpoint-generation-1 sessions running);
- disabled auto-restore and exact resume;
- the nudge deviation and read-only attach behaviour;
- `agent_status`;
- the transport: the CLI for every operation except pane creation, which uses
  local-socket `layout.apply` after the socket ownership and mode check;
- the security posture: no listener, no plugins, no integrations installed by
  Nogging, screen history off;
- tmux as the fallback.

The session-supervision documentation SHALL describe both backends and SHALL
state that the Orchestration Agent stays on tmux.

#### Scenario: Update and restart behavior is documented

- **WHEN** an operator reads the herdr guide
- **THEN** it states that plain `herdr update` in v0.9.5 keeps
  endpoint-generation-1 sessions running
- **AND** it states that a server restart ends the sessions
