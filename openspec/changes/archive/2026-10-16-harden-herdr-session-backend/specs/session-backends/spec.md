## MODIFIED Requirements

### Requirement: The tmux backend preserves existing behaviour

Moving tmux behind the seam SHALL NOT change any observable tmux behaviour,
except for the shared-server stop rule below. The following SHALL all stay as
before:

- the dedicated socket;
- `new-session` with environment;
- the `pipe-pane` log;
- the `display-message` PID;
- the key sequences, including Claude's double Enter;
- `capture-pane` with and without attributes;
- `kill-session`;
- `attach` with `-r`.

The dedicated tmux server is shared by every checkout of the repository and
by the Orchestration Agent. Cleanup SHALL stop it only when the server's own
session listing succeeds and reports no session. Retiring the current
checkout's records SHALL NOT stop a server that still hosts any session. A
failed listing SHALL count as not empty.

The pre-existing session test suite SHALL pass unchanged, except for
expectations that asserted a server stop while sessions remained.

#### Scenario: Existing tests stay green

- **WHEN** the seam has been introduced and no herdr session exists
- **THEN** every pre-existing session, orchestrator and nudge test passes with unchanged expectations, apart from the corrected server-stop rule

#### Scenario: Cleanup keeps a shared server that hosts other sessions

- **WHEN** every record of the current checkout is retired by `session cleanup`
- **AND** the dedicated tmux server still hosts the Orchestration Agent or another checkout's session
- **THEN** the tmux server keeps running and no `kill-server` is issued

#### Scenario: A failed listing never stops the server

- **WHEN** cleanup runs and the dedicated tmux server's session listing fails
- **THEN** cleanup does not stop the server

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

## ADDED Requirements

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
