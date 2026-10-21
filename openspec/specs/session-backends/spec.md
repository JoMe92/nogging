# session-backends Specification

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

## Requirements

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

The tmux backend SHALL preserve the dedicated socket, new-session environment,
pane log, PID query, captures with and without attributes, kill-session and
read-only attach. Its text transport SHALL preserve supplied multiline text
as one paste when the application enables bracketed paste mode. Simultaneous
messages SHALL NOT exchange buffer contents, and temporary buffers SHALL be
removed after success or failure. Text transfer SHALL NOT itself send Enter;
submit timing, verification and any retry SHALL remain supervision policy
above the backend seam. Claude SHALL NOT receive an unconditional double Enter.

The dedicated tmux server SHALL remain shared by all checkouts and the
Orchestration Agent. Cleanup SHALL stop it only when the server's own listing
succeeds and reports no sessions. A failed listing SHALL count as not empty.
The fenced caller's no-server-start rule SHALL remain in force on every
transport command. No delivery failure SHALL kill or restart the server.

Existing tests SHALL remain green except assertions of intentionally changed
text transport or unconditional Enter counts and the corrected shared-server
stop rule.

#### Scenario: Existing tests stay green

- **WHEN** the new transport is used without herdr sessions
- **THEN** existing lifecycle tests pass with changes restricted to assertions of corrected behavior

#### Scenario: Cleanup keeps a shared server that hosts other sessions

- **WHEN** current-checkout cleanup finishes but another session remains on the server
- **THEN** no kill-server is issued

#### Scenario: A failed listing never stops the server

- **WHEN** cleanup cannot list the server's sessions
- **THEN** it does not stop the server

#### Scenario: An unsandboxed caller's tmux commands are unchanged

- **WHEN** a caller outside the execution sandbox performs a tmux lifecycle, capture or attach operation
- **THEN** its argv remains byte-identical to the previous behavior
- **AND** only text transfer uses the explicitly changed paste transport specified here

#### Scenario: Parallel multiline pastes are isolated

- **WHEN** two sessions receive different multiline messages concurrently
- **THEN** each receives only its own text with line breaks preserved and paste boundaries when enabled
- **AND** no temporary paste buffer remains

#### Scenario: Paste fails

- **WHEN** loading or pasting a message fails
- **THEN** no submission key is sent, temporary resources are cleaned up and the error propagates
- **AND** the shared server remains untouched

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

The server SHALL be started only in the host PID namespace. A Nogging process
running inside the OpenSpec execution sandbox (`NOGG_OPENSPEC_FENCED=1`) SHALL
NOT start it. When such a process finds the server not running, its launch
SHALL be refused before any session record, workspace or pane is created, and
the refusal SHALL name `scripts/nogg session herdr-server start`.

The pane SHALL run the unchanged Nogging launch wrapper with the same
effective settings, prompt, command floor, OpenSpec boundary and session
environment as on tmux, plus `HERDR_AGENT` naming the agent.

The root shell pane that Nogging's own `workspace create` opens SHALL NOT
remain. Nogging SHALL store that pane's ID and `terminal_id` in its herdr
state directory. It SHALL close the pane after the next successful session
pane creation in that workspace, once it has re-checked that the pane is
still unlabelled and still has the stored identity. An explicit
`workspace_not_found` error reply to pane creation SHALL recreate the
workspace and retry once. A lost or malformed reply SHALL still never cause a
second pane creation.

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

#### Scenario: A sandboxed Lead never starts the server

- **WHEN** a Lead inside the OpenSpec execution sandbox runs `session launch --backend herdr` while the dedicated server is not running
- **THEN** the launch is refused and names `scripts/nogg session herdr-server start`
- **AND** no herdr server, session record, workspace or pane is created

#### Scenario: No unlabelled shell pane remains

- **WHEN** a herdr launch creates the repository workspace and its session pane
- **THEN** the workspace's root shell pane from `workspace create` is closed
- **AND** an unlabelled pane that Nogging did not record is left alone

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

A herdr record SHALL be alive only when all of these hold:

- its pane resolves, by recorded pane ID or else by unique label;
- herdr reports the recorded `terminal_id` for that pane;
- herdr reports the recorded session process as the pane's root process.

When the caller shares the PID namespace recorded for that process and a
process start time is recorded, the start time SHALL also match. A legacy
record without a `terminal_id` SHALL keep the process-ID and start-time rule
in the recorded namespace, and SHALL be reported with unknown liveness from
any other namespace.

A herdr server restart SHALL therefore reconcile the session to `failed`,
exactly like a vanished tmux session. On herdr v0.9.5, plain `herdr update`
keeps endpoint-generation-1 servers and their panes running; the one-time
pre-generation-1 upgrade is the exception. Killing a herdr session SHALL
close its pane. A caller SHALL terminate the recorded process group, when
closing the pane does not end it, only when it shares the recorded PID
namespace and has re-verified the start time.

#### Scenario: A server restart fails the session

- **WHEN** the herdr server restarts and restores a pane with the same label but a new process and a new `terminal_id`
- **THEN** `session list` reports the record as `failed`
- **AND** `session reap` moves it to `failed` so cleanup can retire it

#### Scenario: A changed pane ID is tolerated

- **WHEN** a live session's pane ID changes but its label, `terminal_id` and process are unchanged
- **THEN** the session is still reported alive

#### Scenario: A sandboxed caller verifies a host-namespace session

- **WHEN** a caller inside the OpenSpec execution sandbox lists a herdr session whose process lives in the host PID namespace
- **AND** herdr reports the recorded `terminal_id` and root process for its pane
- **THEN** the session is reported alive without reading or signalling that process ID locally

### Requirement: herdr native restore never starts an agent outside the launch wrapper

Nogging SHALL set herdr's server-level `resume_agents_on_restore = false` in
its own config passed through `HERDR_CONFIG_PATH`; herdr provides no per-pane
switch. A globally installed herdr integration may still report session
references inside Nogging panes because the `HERDR_*` environment passes
through the wrapper, so this server-level setting is required even though
Nogging never reports references itself.

A restored Nogging-labelled pane SHALL be reported and closed by cleanup, and
SHALL never be adopted, when both of these hold:

- a record of the current checkout names it;
- no live record owns it.

Panes that other checkouts' records name are handled only by those checkouts.
Resuming a conversation SHALL go through Nogging's exact resume (`session
launch --resume <id>`) on either backend, for Claude, Codex and Antigravity.

#### Scenario: No unwrapped agent after restart

- **WHEN** the herdr server restarts while a Nogging herdr session was running
- **THEN** no agent process starts in a Nogging pane without the Nogging launch wrapper

### Requirement: Nudge and send verification degrade safely without screen attributes

Nudge and send policy SHALL be identical on both backends. When capture keeps
SGR attributes, placeholder detection SHALL behave as on tmux. Without
attributes, a Claude box containing text SHALL classify as unknown, never
as inferred operator input or a suggestion. Nudge without `--message` SHALL
submit nothing and ask for an explicit message.

For an explicit message, a known safe baseline and the operation's own text
injection SHALL establish ownership before submit. A transition from a box
known to hold that message to an empty box, or an observed new backend
working/done transition after submit, SHALL count as delivery. An unknown
box, a different nonempty box, or an unchanged baseline working status alone
SHALL NOT count. A single retry SHALL be permitted only when the known box
still holds the operation's text; otherwise the operation SHALL fail as
unverified without speculative keys.

#### Scenario: A placeholder is never executed without attributes

- **WHEN** a herdr Claude pane has no attributes and nudge has no explicit message
- **THEN** no input is submitted and the operator is told to pass `--message`

#### Scenario: An explicit message is verified by the replacement check

- **WHEN** an explicit message is typed from a known empty baseline on herdr
- **AND** the backend transitions to working after submit
- **THEN** delivery is verified without an extra Enter

#### Scenario: Changed nonempty text is not a receipt

- **WHEN** the box changes to unrelated nonempty text after submit
- **THEN** that change alone establishes no success and causes no speculative Enter

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
read. Readers SHALL execute probes only for understood reservation versions and
valid session shapes. Unsupported versions and malformed session metadata with
usable accounting SHALL remain conservatively reserved without executing their
probe or using session state as proof of death.

#### Scenario: A herdr reservation stays bound while its pane lives

- **WHEN** a herdr session holds a usage reservation and its pane is alive
- **THEN** the reservation is not released as stale

#### Scenario: A legacy tmux reservation is read

- **WHEN** a reader encounters an unversioned reservation using the old tmux and socket fields
- **THEN** it can verify liveness without requiring a backend-neutral probe field

#### Scenario: An unknown probe shape is retained

- **WHEN** a future or malformed session shape has usable reservation accounting
- **THEN** no probe executes and no shape exception escapes
- **AND** the reservation is retained and a compatibility diagnostic is reported

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
- the host-namespace server start, the sandboxed-Lead refusal and
  `scripts/nogg session herdr-server start`;
- recovery while the server is down;
- terminal-identity liveness;
- checkout-scoped orphan cleanup;
- the closed workspace root pane;
- tmux as the fallback.

The session-supervision documentation SHALL describe both backends and SHALL
state that the Orchestration Agent stays on tmux.

#### Scenario: Update and restart behavior is documented

- **WHEN** an operator reads the herdr guide
- **THEN** it states that plain `herdr update` in v0.9.5 keeps
  endpoint-generation-1 sessions running
- **AND** it states that a server restart ends the sessions

#### Scenario: Server-down recovery is documented

- **WHEN** an operator reads the herdr guide or the failure-recovery guide
- **THEN** it explains how records of a stopped server are reconciled and how `scripts/nogg session herdr-server start` restarts the server from the host

### Requirement: herdr server ownership and process identities hold across PID namespaces

Every process ID that Nogging stores for herdr SHALL carry the PID namespace
it belongs to. This covers the server receipt and the session record. A
Nogging process SHALL NOT read `/proc` for, or send a signal to, a stored
process ID whose namespace differs from its own.

The server receipt SHALL record:

- the server's process ID, process start time and PID namespace;
- the identity of its socket file: device, inode and change time.

A running dedicated server SHALL be accepted as Nogging's own only when all of
these hold:

- its config is byte-equal to Nogging's config;
- its socket passes the ownership and mode check;
- its socket identity equals the receipt.

A caller in the receipt's namespace SHALL also verify the process ID and start
time. A legacy receipt without a namespace or socket identity SHALL be
verifiable only from the host namespace. A sandboxed caller SHALL treat it as
unverifiable and refuse.

A session record SHALL store:

- the pane's `terminal_id`;
- the herdr-reported root process ID;
- the server's PID namespace, taken from the receipt;
- a process start time, but only when the launching caller shares that
  namespace.

#### Scenario: A restarted foreign server is not adopted

- **WHEN** the dedicated herdr server was restarted outside Nogging, so its socket identity no longer matches the receipt
- **THEN** a launch refuses the server as not owned by Nogging and names the failed check

#### Scenario: No foreign-namespace process is touched

- **WHEN** a sandboxed caller stops or lists a herdr session whose recorded process ID belongs to the host namespace
- **THEN** it reads no `/proc` entry for that process ID and sends it no signal

### Requirement: A stopped dedicated herdr server has an explicit recovery path

The herdr backend SHALL report the records of a dedicated herdr session as
vanished, not unknown, when both of these hold:

- `herdr --session <name> status` succeeds and reports the server as not
  running;
- `herdr session list --json` reports that session as not running.

Any CLI failure, timeout, disagreement or unparsable answer SHALL keep unknown
liveness. Vanished records SHALL then follow the normal rules: `session list`
reports them as `failed` and `session reap` reaps them. A same-Bead launch or
an exact resume SHALL NOT be refused as covered by a live session.

`scripts/nogg session herdr-server start` SHALL start or verify the dedicated
server through the same code path a launch uses. The command:

- SHALL be idempotent;
- SHALL refuse inside the OpenSpec execution sandbox;
- SHALL refuse a running server that fails the ownership checks, name the
  failed check, and leave stopping that server to the operator;
- SHALL upgrade a legacy receipt after a host-namespace verification;
- SHALL create no session record, workspace or pane;
- SHALL print the resulting server state.

#### Scenario: A stopped server releases its records

- **WHEN** the dedicated herdr server has been stopped and herdr reports it as not running in both its status and its session list
- **THEN** `session list` reports the server's running records as `failed`
- **AND** a same-Bead `session launch --resume <id>` proceeds instead of being refused as covered

#### Scenario: A failing herdr CLI still means unknown

- **WHEN** the `herdr` CLI fails or times out while a herdr record is `running`
- **THEN** the record keeps unknown liveness and `reap` leaves it untouched

#### Scenario: The operator restarts the server from the host

- **WHEN** an operator runs `scripts/nogg session herdr-server start` in a host shell while the dedicated server is down
- **THEN** the server starts with Nogging's config, scrubbed environment and a fresh receipt
- **AND** a second run reports the already-running owned server and changes nothing

### Requirement: herdr orphan handling is limited to the current checkout

The dedicated herdr server and the repository workspace are shared by every
checkout. Session records are kept per checkout. A Nogging-labelled pane SHALL
be treated as an orphan only when both of these hold:

- its label names a record of the current checkout, in any state;
- no live or starting record of the current checkout owns it.

A Nogging-labelled pane whose label names no record of the current checkout
SHALL be treated as foreign. Cleanup and listing SHALL never close or adopt a
foreign pane. `session list` SHALL report how many foreign panes it left
untouched.

#### Scenario: Cleanup in one checkout spares another checkout's live pane

- **WHEN** checkout A runs `session cleanup` while checkout B has a live herdr session in the shared workspace
- **THEN** B's pane keeps running and is not reported as A's orphan

#### Scenario: A pane without any local record is only reported

- **WHEN** a Nogging-labelled pane names no record of the current checkout
- **THEN** `session list` counts it as foreign and `session cleanup` leaves it open
