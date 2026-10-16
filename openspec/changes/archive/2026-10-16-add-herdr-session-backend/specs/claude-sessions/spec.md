## MODIFIED Requirements

### Requirement: Launched Claude sessions run in a named tmux session on the Pi

Every agent session that Nogging starts for Planning, Lead Agent or
specialist work SHALL run on the delivery host inside a session of its
selected session backend (see the `session-backends` capability). That is:

- on the `tmux` backend (the default), a tmux session managed under a
  dedicated tmux server socket reserved for Nogging;
- on the `herdr` backend, a pane labelled with the session name inside a herdr
  session namespace reserved for Nogging.

Each such session SHALL have a deterministic name that encodes its role and
its mapped Bead (or planning identifier). Nogging SHALL NOT create a session
whose name collides with an existing managed record, a leftover log, or a live
session on any available backend. On a name collision it SHALL either fail or
generate a new distinct name, and SHALL never reuse or overwrite the existing
session.

The **Orchestration Agent** session is the one exception. It always runs on
tmux. It is not anchored to a Bead, and its name is the fixed singleton
`nogg-orchestrator-<slug>`. `scripts/nogg orchestrator run` SHALL **adopt** an
existing live session of that name (re-attach its log pipe and refresh its
record) rather than fail or rename. This is what makes the supervisor
idempotent and the role single-instance.

#### Scenario: A launched session is a named tmux session

- **WHEN** Nogging launches a session for a role and a Bead on the default backend
- **THEN** a tmux session exists on the delivery host under the Nogging tmux server socket
- **AND** its name encodes the role and the Bead ID
- **AND** the agent process runs inside that tmux session

#### Scenario: A herdr launch is a named herdr pane

- **WHEN** Nogging launches a session with `--backend herdr`
- **THEN** a pane labelled with the session name exists in the Nogging herdr session
- **AND** the agent process runs inside that pane

#### Scenario: Session names do not collide

- **WHEN** Nogging launches a session and the generated name already belongs to a managed session
- **THEN** Nogging does not attach to, reuse, or overwrite the existing session
- **AND** it either fails with a clear message or creates a session under a different distinct name

#### Scenario: Managed sessions are isolated from the operator's own tmux

- **WHEN** an operator runs `tmux list-sessions` against their default tmux server
- **THEN** Nogging-managed sessions are not listed there
- **AND** they are listed only under the dedicated Nogging tmux server socket

#### Scenario: The orchestrator session is adopted, not duplicated

- **WHEN** `orchestrator run` is invoked and a live `nogg-orchestrator-<slug>` session already exists
- **THEN** it adopts that session and refreshes its record
- **AND** it does not create a second orchestrator session

### Requirement: Sessions are listable and attachable remotely over SSH

Nogging SHALL provide a command, runnable from an ordinary SSH shell, that
lists every managed session with its runtime metadata — including its session
backend — without attaching to any session. Nogging SHALL provide a separate
command to attach to a named session, including a read-only attach option
where the session's backend supports one. Where it does not, the read-only
attach SHALL be refused rather than granting input.

Listing SHALL reconcile each metadata record against the live state of that
record's own backend. A record whose backend session is gone SHALL be reported
as failed rather than running. A record whose backend's liveness cannot be
determined SHALL be reported as unknown, never as failed.

#### Scenario: An operator lists sessions over SSH

- **WHEN** an operator connects to the delivery host over SSH and runs the session list command
- **THEN** every managed session is shown with its Bead ID, role, start time, working directory, owner, state and backend
- **AND** the command does not attach to any session

#### Scenario: An operator attaches to a chosen session

- **WHEN** an operator runs the attach command with a managed session name
- **THEN** their terminal is attached to that session through its backend
- **AND** a read-only option is available that prevents sending input, or, on a backend without read-only attach, is refused with a pointer to the log

#### Scenario: A dead session is reported as failed

- **WHEN** a metadata record is in the running state but its backend session no longer exists
- **THEN** the list command reports that session as failed
- **AND** it does not report it as running

### Requirement: Attach, stop and cleanup are deliberate operations

Attaching to, stopping and cleaning up a session SHALL each be an explicit
operator command and SHALL NOT occur as a side effect of another operation.

Stopping a session SHALL terminate its agent process and its backend session,
and SHALL record a final state with the time and reason.

Cleanup SHALL remove the backend session and retire its metadata. It SHALL run
only for a session that has completed its task or been stopped, and SHALL
refuse to act on a session that is still starting, running or idle. Once no
session remains, cleanup SHALL stop the dedicated Nogging tmux server. It
SHALL never stop the herdr server.

#### Scenario: Stopping a session records a final state

- **WHEN** an operator stops a running session
- **THEN** the agent process and the backend session are terminated
- **AND** the metadata record shows a terminal state with the end time and the stop reason

#### Scenario: Cleanup refuses a running session

- **WHEN** an operator runs cleanup against a session whose state is starting, running or idle
- **THEN** cleanup does not remove the backend session or the metadata
- **AND** it reports that the session must be stopped first

#### Scenario: Cleanup runs after completion or stop

- **WHEN** a session has completed its task or been stopped and an operator runs cleanup for it
- **THEN** the backend session is removed
- **AND** the metadata record is retired

#### Scenario: Attach never happens automatically

- **WHEN** Nogging launches, lists, logs, stops or cleans up a session
- **THEN** no attach is performed as part of that operation
